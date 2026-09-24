#!/usr/bin/env bash
# Regenerates /etc/issue (shown on the physical console before login, on
# every virtual terminal) and /etc/motd (shown after logging in, both at
# the console and over SSH) with the NonRAID dashboard's address, a note
# that first-time setup takes a while if it hasn't finished yet, or a
# failure notice if it's actually failed - without this last case, a
# crashed first boot would otherwise claim "still finishing" forever, since
# nothing would ever tell the banner it's not still working.
#
# The address list itself doesn't wait on nonraid-webui actually answering
# HTTP requests (an earlier version did, bounded-retrying that check here) -
# the IP/hostname are already known as soon as DHCP assigns one, well
# before first boot finishes building and starting the dashboard, so
# showing them immediately is both simpler and more useful than waiting.
#
# Run at every boot via nonraid-issue-banner.service; again directly by
# nonraid-first-boot.sh right when it finishes successfully; and again via
# that service's own OnFailure= if it fails instead. agetty only re-reads
# /etc/issue when it re-displays the prompt (e.g. after a failed login), so
# without these direct calls the console could keep showing a stale message
# until someone happens to press a key.

set -u

ISSUE_FILE=/etc/issue
MOTD_FILE=/etc/motd
HOSTNAME="$(hostname)"
# hostname -I lists every interface indiscriminately, including docker0 and
# any LXC/bridge networks install-webui.sh's own packages set up - neither
# is reachable from the actual LAN, so listing them here would just be
# confusing/wrong. Restrict to interfaces backed by real hardware: bridges,
# veth pairs, and other software-only interfaces never get a
# /sys/class/net/*/device symlink (there's no bus device behind them), but
# a real NIC does - including virtio in a VM, which is what matters for
# testing this in QEMU. Loopback is excluded the same way (no device
# symlink), no separate case needed for it.
#
# One real exception to that device-symlink rule: install-webui.sh's own
# ensure_lxc_bridge() bridges the primary NIC as br0 so LXC containers can
# get a real LAN DHCP lease, and once that runs, the NIC itself becomes a
# bridge port with no address of its own - the actual LAN IP moves onto
# br0, which (being a software bridge, same as docker0/lxcbr0) has no
# /device symlink either and would otherwise go undetected here, leaving
# the banner wrongly claiming no network address. Rather than special-case
# "br0" by name, a bridge counts as LAN-facing if any of its own bridged
# member ports (/sys/class/net/<bridge>/brif/*) is itself device-backed -
# true for br0 (its member is the real NIC ensure_lxc_bridge() enslaved),
# still false for docker0/lxcbr0 (their members are veth pairs, which have
# no /device symlink of their own either) - so those stay correctly
# excluded without needing to know their names.
#
# Bounded-retried for the same reason nonraid-first-boot.sh waits on
# network itself: this unit's After=network-online.target isn't a real
# guarantee that DHCP has actually finished (Debian's default ifupdown
# setup brings the primary interface up as allow-hotplug, not auto, and
# doesn't block on it) - a single early check can catch the interface
# before it has an address yet, and since nothing else re-runs this script
# while first boot is still working, that stale "no network address" would
# otherwise just sit there for however long first boot takes (confirmed
# against a real boot). Bounded rather than the indefinite wait
# nonraid-first-boot.sh uses, since this is just cosmetic info, not
# something that has to succeed before anything else can proceed.
detect_lan_ips() {
  local i found
  for i in $(seq 1 15); do
    found="$(
      for iface in /sys/class/net/*/; do
        iface="$(basename "$iface")"
        if [ -e "/sys/class/net/$iface/device" ]; then
          : # a real, unbridged NIC - always counts
        elif [ -d "/sys/class/net/$iface/bridge" ] \
          && ls /sys/class/net/"$iface"/brif/*/device >/dev/null 2>&1; then
          : # a bridge with at least one device-backed member port (br0) - see comment above
        else
          continue
        fi
        ip -4 -o addr show dev "$iface" scope global up 2>/dev/null | awk '{print $4}' | cut -d/ -f1
      done
    )"
    if [ -n "$found" ]; then
      echo "$found"
      return
    fi
    sleep 2
  done
}
ips="$(detect_lan_ips)"

# Tailscale isn't installed by nonraid-webui's own install - this is a
# no-op unless the user has set it up themselves. tailscale0 has no
# /sys/class/net/*/device symlink (it's a userspace tun interface), so the
# LAN-only loop above correctly leaves it out; listed separately here,
# labeled as Tailscale, since a CGNAT/overlay address isn't really "on the
# LAN" the same way. Only the `tailscale` CLI actually knows the assigned
# MagicDNS name - that's not something derivable from local interface data
# alone, unlike the plain IP.
tailscale_ip=""
tailscale_dns=""
if command -v tailscale >/dev/null 2>&1; then
  tailscale_ip="$(tailscale ip -4 2>/dev/null)"
  if [ -n "$tailscale_ip" ]; then
    tailscale_dns="$(tailscale status --json 2>/dev/null | grep -o '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4)"
    tailscale_dns="${tailscale_dns%.}"
  fi
fi

body() {
  echo
  echo "  NonRAID OS  -  built with Debian"
  echo "  ================================"
  echo

  if systemctl is-failed --quiet nonraid-first-boot.service; then
    echo "  First-time setup failed. Check what happened with:"
    echo "    journalctl -u nonraid-first-boot.service"
    echo
    return
  fi

  if [ ! -e /var/lib/nonraid-os/first-boot-done ]; then
    echo "  First-time setup is still running (building the storage driver and"
    echo "  the dashboard) - this can take a while. Once it's done, the"
    echo "  dashboard will be at:"
  else
    echo "  Dashboard:"
  fi
  echo
  # Plain http:// on the default port (80), no port number needed - what
  # nonraid-webui actually listens on out of the box. If HTTPS gets enabled
  # later (Settings -> Security), the app itself moves to 443 (also its
  # scheme's default port, still no number needed) and port 80's listener
  # switches roles to a redirect into it (see nonraid-webui's config.ts) -
  # so this http:// link keeps working either way, just as a redirect hop
  # once HTTPS is on, since this script doesn't track that toggle's state
  # to print the https:// link directly.
  if [ -n "$ips" ]; then
    while IFS= read -r ip; do
      echo "    http://$ip/"
    done <<< "$ips"
    # .local (mDNS) only means anything if there's an actual LAN-facing
    # device to answer it - showing it with no such device (e.g. nothing
    # but loopback/Docker/Tailscale) would be a link nothing could reach.
    echo "    http://$HOSTNAME.local/"
  fi
  if [ -n "$tailscale_ip" ]; then
    echo "    http://$tailscale_ip/  (Tailscale)"
    [ -n "$tailscale_dns" ] && echo "    http://$tailscale_dns/  (Tailscale)"
  fi
  if [ -z "$ips" ] && [ -z "$tailscale_ip" ]; then
    echo "    (no network address yet)"
  fi
  echo
}

# /etc/issue is processed by agetty for \S \n \l style escapes; /etc/motd
# is printed as plain text (by pam_motd, for both console and SSH logins) -
# same body, only /etc/issue gets that trailing escape line.
{ body; echo "\\S \\n \\l"; echo; } > "$ISSUE_FILE"
body > "$MOTD_FILE"
