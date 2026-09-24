#!/usr/bin/env bash
# NonRAID OS - first-boot setup.
#
# Runs once, on the very first boot after the Debian installer finishes. Does
# what nonraid-webui's own tools/install-webui.sh already does by hand today:
# updates the nonraid-webui checkout build/build-image.sh vendored onto the
# image (cloning fresh instead, if that's somehow missing), then runs its
# installer, which builds the NonRAID driver, installs nmdctl, and builds and
# starts nonraid-webui and every service it needs.
#
# Installed by preseed/nonraid.preseed's late_command; run via
# nonraid-first-boot.service. Marks itself done and disables that service so
# this never runs again on a later boot.

set -euo pipefail
export GIT_TERMINAL_PROMPT=0

NONRAID_WEBUI_REPO_URL="https://github.com/domgregori/nonraid-webui.git"
CHECKOUT_DIR=/opt/nonraid-webui-src
STATE_DIR=/var/lib/nonraid-os
LOG_FILE=/var/log/nonraid-os-first-boot.log

log() { echo "==> $*"; }

exec > >(tee -a "$LOG_FILE") 2>&1
log "NonRAID OS first-boot setup starting"

# This is a netinst image: the installer itself needed internet to get this
# far, so first boot needs it too - no offline fallback. But this unit's own
# After=/Wants=network-online.target isn't enough of a guarantee on its own:
# Debian's default /etc/network/interfaces brings up the primary interface
# as allow-hotplug, not auto, and ifupdown's networking.service does not
# block on hotplug interfaces finishing DHCP before marking itself done -
# so network-online.target can be reached before DNS actually works
# (confirmed against a real VM run: this service failed immediately with
# "Could not resolve host: github.com"). Wait for real, rather than giving
# up after a fixed timeout and failing the whole install: there's no way to
# proceed without network anyway (nonraid-webui has to be cloned), so a
# short bound just turns "network came up a bit late" into a hard failure
# needing a manual reboot to retry, instead of just... waiting. The console
# banner (see banner/) already shows "still finishing setup" the whole
# time, so this isn't a silent hang from the user's point of view.
log "Waiting for a working network"
waited=0
until getent hosts github.com >/dev/null 2>&1; do
  sleep 5
  waited=$((waited + 5))
  if [ $((waited % 60)) -eq 0 ]; then
    log "Still waiting for a working network (${waited}s so far)"
  fi
done
log "Network is up (waited ${waited}s)"

# The installed system's own GRUB boot menu (distinct from the installer's
# boot menu, already branded at build time - see build/build-image.sh) gets
# its "Debian GNU/Linux" entry naming from GRUB_DISTRIBUTOR in
# /etc/default/grub, normally `$(lsb_release -i -s 2> /dev/null || echo
# Debian)`. Overriding it here and re-running update-grub is what actually
# changes the entries update-grub generates into /boot/grub/grub.cfg.
log "Rebranding the installed system's own GRUB boot menu"
if grep -q '^#\?GRUB_DISTRIBUTOR=' /etc/default/grub; then
  sed -i 's/^#\?GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="NonRAID OS"/' /etc/default/grub
else
  echo 'GRUB_DISTRIBUTOR="NonRAID OS"' >> /etc/default/grub
fi
update-grub

if [ -d "$CHECKOUT_DIR/.git" ]; then
  # build/build-image.sh vendors a checkout onto the image and
  # preseed/nonraid.preseed's late_command stages it here - fetch+reset to
  # the latest main on top of it, the same fallback pattern nonraid-webui's
  # own install-webui.sh already uses for the nonraid driver checkout it
  # fetches (see that script's fetch_nonraid_source): a failed fetch isn't
  # fatal when there's already a working tree to fall back to, only when
  # there's nothing here at all (the else branch below).
  log "Updating the pre-seeded nonraid-webui checkout at $CHECKOUT_DIR"
  update_attempt=0
  until git -C "$CHECKOUT_DIR" fetch origin main && git -C "$CHECKOUT_DIR" reset --hard origin/main; do
    update_attempt=$((update_attempt + 1))
    if [ "$update_attempt" -ge 5 ]; then
      log "Could not update nonraid-webui after $update_attempt attempts - building from the pre-seeded checkout as-is"
      break
    fi
    log "Updating nonraid-webui failed (attempt $update_attempt/5) - retrying in 5s"
    sleep 5
  done
else
  log "No pre-seeded nonraid-webui checkout - cloning into $CHECKOUT_DIR"
  # getent above only proves DNS resolves, not that the outbound path is
  # fully up - DHCP/routing can still be a beat behind DNS becoming
  # resolvable (confirmed against a real VM run: this clone failed once
  # with "Failed to connect" immediately after "Network is up", then
  # succeeded instantly when run by hand seconds later). A bounded retry
  # here, rather than none, turns that kind of one-off timing blip into a
  # few seconds' delay instead of a hard failure needing a manual reboot.
  clone_attempt=0
  until git clone --branch main "$NONRAID_WEBUI_REPO_URL" "$CHECKOUT_DIR"; do
    clone_attempt=$((clone_attempt + 1))
    [ "$clone_attempt" -lt 5 ] || { log "Cloning nonraid-webui failed after $clone_attempt attempts"; exit 1; }
    log "Cloning nonraid-webui failed (attempt $clone_attempt/5) - retrying in 5s"
    rm -rf "$CHECKOUT_DIR"
    sleep 5
  done
fi

log "Running install-webui.sh"
"$CHECKOUT_DIR/tools/install-webui.sh"

# ensure_lxc_bridge() (bridges the primary NIC as br0, for LXC LAN access) isn't part of
# install-webui.sh's own default run any more - it has no way to tell a fresh appliance apart
# from someone's already-in-use Debian box that just hasn't customized its networking yet, so
# that call is opt-in, left to whoever actually knows which one it is (see its own doc comment
# there). This install image *is* that fresh-appliance case, every time - so first boot opts in
# here, explicitly. Not fatal to first boot if it doesn't work out: ensure_lxc_bridge() already
# self-heals via its own detached watchdog (reverts to the original interface if br0 doesn't
# come up cleanly), so a failure here just means no br0 this boot, not a broken install.
log "Setting up the LXC LAN bridge (br0)"
"$CHECKOUT_DIR/tools/install-webui.sh" --step ensure_lxc_bridge || log "ensure_lxc_bridge failed - continuing without br0"

log "First-boot setup complete - marking done and disabling this service"
mkdir -p "$STATE_DIR"
touch "$STATE_DIR/first-boot-done"
systemctl disable nonraid-first-boot.service

# Refreshes the console's pre-login banner (/etc/issue) from "still setting
# up" to the dashboard URL right now, rather than leaving it stale until
# whoever's at the console happens to press a key (see
# nonraid-issue-banner.sh's own comment on why that's otherwise needed).
/usr/local/sbin/nonraid-issue-banner.sh || true

log "Done. Visit http://<this-host>/ to finish setup."
