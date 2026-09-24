#!/usr/bin/env bash
# NonRAID OS - build a branded, interactive-install Debian ISO.
#
# Takes a stock Debian netinst ISO and remasters it: adds this repo's preseed
# file and first-boot files onto the disc image, and points the boot loader
# at the preseed file. The preseed defaults the backend stuff (locale,
# mirror, clock, the guided-partitioning recipe, packages, bootloader) but
# leaves the actual screens showing and waiting for input - see
# preseed/nonraid.preseed's own comment for exactly what stays interactive
# and why.
#
# This is a netinst image: the installer itself needs internet access to
# fetch packages, plus nonraid-webui's own dependencies - most of those are
# pre-installed during the Debian install itself now (see pkgsel/include and
# late_command in preseed/nonraid.preseed, and the vendoring steps below),
# so first boot only strictly needs network for whatever's left there
# (curl/git/e2fsprogs/samba/nfs-kernel-server - see nonraid.preseed's own
# comment for why those stayed at first boot) - still no fully offline path
# overall, just less first-boot network dependency than before.
#
# Requires: xorriso, ImageMagick (identify, for validating the branding
# PNGs below), cpio, git (to vendor nonraid/nonraid-webui), curl (to vendor
# the mergerfs/rclone .debs - see below). If no source ISO is given, also
# gpg (to verify a downloaded one - see download_and_verify_debian_iso
# below).
#
# Usage:
#   build/build-image.sh [path-to-debian-netinst.iso] [output.iso]
#
# With no ISO path (or a path that doesn't exist), downloads and GPG-
# verifies the Debian 13.6.0 netinst into a local cache and uses that - the
# ISO isn't checked into this repo (too large, not source), so the build
# needs to be able to get it itself rather than assuming a checkout
# already has one lying around.
#
# Not yet tested against real hardware or a real Debian ISO - see PLAN.md's
# open questions. Treat this as a first draft of the remaster steps, not a
# proven pipeline. In particular, the isolinux/grub patching below assumes
# the file layout of a current Debian stable netinst ISO; a Debian release
# change could move things and break the sed patterns.

set -euo pipefail

SRC_ISO="${1:-}"
OUT_ISO="${2:-nonraid-os.iso}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
EXTRACT_DIR="$WORK_DIR/iso"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

log() { echo "==> $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "'$1' not found on PATH - required to build the image."; }

require xorriso
require identify
require cpio
require git
require curl

# Same URLs nonraid-first-boot.sh and nonraid-webui's own tools/install-webui.sh
# clone at runtime - kept here too so the vendored copies below track the
# exact same repos/branches those scripts expect to find pre-seeded.
NONRAID_WEBUI_REPO_URL="https://github.com/domgregori/nonraid-webui.git"
NONRAID_REPO_URL="https://github.com/domgregori/nonraid.git"

# Pinned fingerprints of Debian's own CD-image signing keys (published at
# https://www.debian.org/CD/verify, current as of Debian 13). Hardcoded
# here rather than fetched at build time - trusting a fingerprint fetched
# over the same channel being verified defeats the point of verifying it.
# After importing a key by ID from a keyserver, its actual fingerprint is
# checked against this list before it's trusted for anything; a keyserver
# handing back the wrong key under a matching ID (implausible, but cheap to
# guard) would be caught here instead of silently trusted.
DEBIAN_CD_SIGNING_KEY_FINGERPRINTS="
10460DAD76165AD81FBC0CE9988021A964E6EA7D
DF9B9C49EAA9298432589D76DA87E80D6294BE9B
F41D30342F3546695F65C66942468F4009EA8AC3
"

# Downloads a Debian ISO, verifies SHA256SUMS is authentically Debian's own
# (GPG signature, checked against the pinned fingerprints above - not just
# that the bytes match some SHA256SUMS file, which alone only guards
# against transfer corruption, not a tampered SHA256SUMS itself), then
# verifies the ISO's own checksum against it. Only moves the ISO to $dest
# once all of that passes.
download_and_verify_debian_iso() {
  local iso_name="$1" iso_url="$2" sha256sums_url="$3" sha256sums_sig_url="$4" dest="$5"
  require gpg

  local work
  work="$(mktemp -d)"

  log "Downloading $iso_url"
  curl -fL --progress-bar -o "$work/$iso_name" "$iso_url"

  log "Downloading SHA256SUMS and its GPG signature"
  curl -fsSL -o "$work/SHA256SUMS" "$sha256sums_url"
  curl -fsSL -o "$work/SHA256SUMS.sign" "$sha256sums_sig_url"

  log "Fetching and verifying Debian's CD signing keys"
  local gpg_home="$work/gnupg" fp key_id
  mkdir -m 700 -p "$gpg_home"
  for fp in $DEBIAN_CD_SIGNING_KEY_FINGERPRINTS; do
    key_id="${fp: -16}"
    gpg --homedir "$gpg_home" --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key_id" >/dev/null 2>&1 || true
  done

  local actual_fps trusted=0 want
  actual_fps="$(gpg --homedir "$gpg_home" --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/ {print $10}')"
  for want in $DEBIAN_CD_SIGNING_KEY_FINGERPRINTS; do
    echo "$actual_fps" | grep -qx "$want" && trusted=$((trusted + 1))
  done
  [ "$trusted" -gt 0 ] || fail "none of the imported Debian CD signing keys matched their pinned fingerprint - refusing to trust SHA256SUMS"

  gpg --homedir "$gpg_home" --batch --verify "$work/SHA256SUMS.sign" "$work/SHA256SUMS" \
    || fail "GPG signature on SHA256SUMS did not verify - refusing to trust it"
  log "SHA256SUMS signature verified ($trusted trusted key(s) found)"

  local expected_sum actual_sum
  expected_sum="$(awk -v f="$iso_name" '$2==f {print $1}' "$work/SHA256SUMS")"
  [ -n "$expected_sum" ] || fail "$iso_name not found in SHA256SUMS"
  actual_sum="$(sha256sum "$work/$iso_name" | awk '{print $1}')"
  [ "$expected_sum" = "$actual_sum" ] || fail "checksum mismatch for downloaded $iso_name (expected $expected_sum, got $actual_sum) - try again, the download may be corrupt"
  log "Checksum verified"

  mkdir -p "$(dirname "$dest")"
  mv "$work/$iso_name" "$dest"
  rm -rf "$work"
}

if [ -z "$SRC_ISO" ] || [ ! -f "$SRC_ISO" ]; then
  if [ -n "$SRC_ISO" ]; then
    fail "source ISO not found: $SRC_ISO"
  fi
  DEBIAN_ISO_VERSION="13.6.0"
  DEBIAN_ISO_NAME="debian-${DEBIAN_ISO_VERSION}-amd64-netinst.iso"
  DEBIAN_ISO_BASE_URL="https://cdimage.debian.org/debian-cd/${DEBIAN_ISO_VERSION}/amd64/iso-cd"
  SRC_ISO="$REPO_ROOT/.cache/$DEBIAN_ISO_NAME"
  if [ -f "$SRC_ISO" ]; then
    log "Using cached Debian netinst ISO at $SRC_ISO"
  else
    download_and_verify_debian_iso "$DEBIAN_ISO_NAME" \
      "$DEBIAN_ISO_BASE_URL/$DEBIAN_ISO_NAME" \
      "$DEBIAN_ISO_BASE_URL/SHA256SUMS" \
      "$DEBIAN_ISO_BASE_URL/SHA256SUMS.sign" \
      "$SRC_ISO"
  fi
fi
LOGO="$REPO_ROOT/branding/logo.png"
# Hand-edited static source images (see branding/layered/*.tiff for the
# editable originals) - copied onto the image as-is rather than generated,
# so edits made in an actual image editor are what ships.
#
# isolinux-splash.png is optional, not required like the other two: its
# background is isolinux/vesamenu's graphical boot menu, which Debian's own
# isolinux.cfg (prompt 0) never actually shows on a normal boot - it jumps
# straight to the default entry with no menu ever rendered (confirmed
# across many screendumps spanning the full boot transition on a real
# test). Skips branding that file if absent instead of failing the build.
ISOLINUX_SPLASH_SRC="$REPO_ROOT/branding/isolinux-splash.png"
GRUB_BACKGROUND_SRC="$REPO_ROOT/branding/grub-background.png"
GTK_BANNER_SRC="$REPO_ROOT/branding/gtk-installer-banner.png"
GTK_THEME_SRC="$REPO_ROOT/branding/gtk-installer-theme.gtkrc"
[ -f "$SRC_ISO" ] || fail "source ISO not found: $SRC_ISO"
[ -f "$LOGO" ] || fail "logo not found: $LOGO"
[ -f "$GRUB_BACKGROUND_SRC" ] || fail "missing $GRUB_BACKGROUND_SRC"
[ -f "$GTK_BANNER_SRC" ] || fail "missing $GTK_BANNER_SRC"
[ -f "$GTK_THEME_SRC" ] || fail "missing $GTK_THEME_SRC"

# GRUB's own minimal PNG loader (unlike isolinux/vesamenu or the GTK
# installer's Cairo-based one) renders 16-bit-per-channel PNGs as badly
# channel-corrupted noise instead of failing loudly (confirmed against a
# real UEFI boot) - so a wrong export setting here would silently ship a
# broken boot screen rather than break the build. Check size and depth
# up front instead of trusting whatever was exported.
validate_branding_png() {
  local file="$1" expected_w="$2" expected_h="$3" dims depth
  dims="$(identify -format '%wx%h' "$file")"
  [ "$dims" = "${expected_w}x${expected_h}" ] || fail "$file is ${dims}, expected ${expected_w}x${expected_h}"
  depth="$(identify -format '%z' "$file")"
  [ "$depth" = "8" ] || fail "$file is ${depth}-bit per channel, expected 8-bit (re-export at 8-bit - 16-bit corrupts on GRUB in particular)"
}

log "Extracting $SRC_ISO"
mkdir -p "$EXTRACT_DIR"
xorriso -osirrox on -indev "$SRC_ISO" -extract / "$EXTRACT_DIR"
chmod -R u+w "$EXTRACT_DIR"

log "Staging preseed file, first-boot files, and the console banner onto the image"
mkdir -p "$EXTRACT_DIR/nonraid-os/first-boot" "$EXTRACT_DIR/nonraid-os/banner"
cp "$REPO_ROOT/preseed/nonraid.preseed" "$EXTRACT_DIR/preseed.cfg"
cp "$REPO_ROOT/first-boot/nonraid-first-boot.sh" "$EXTRACT_DIR/nonraid-os/first-boot/"
cp "$REPO_ROOT/first-boot/nonraid-first-boot.service" "$EXTRACT_DIR/nonraid-os/first-boot/"
cp "$REPO_ROOT/banner/nonraid-issue-banner.sh" "$EXTRACT_DIR/nonraid-os/banner/"
cp "$REPO_ROOT/banner/nonraid-issue-banner.service" "$EXTRACT_DIR/nonraid-os/banner/"

# Vendors a checkout of nonraid-webui and nonraid onto the image itself,
# instead of leaving first boot to clone both from scratch with nothing to
# fall back on if the network is flaky right when it needs it (confirmed
# against a real VM run - see nonraid-first-boot.sh's own comment on the
# retry loop this replaces). late_command below stages these into /target at
# the exact paths nonraid-first-boot.sh and install-webui.sh already expect
# a pre-existing checkout at, so both scripts' own "fetch the latest, fall
# back to what's already there if that fails" logic picks them up
# transparently - install-webui.sh already has this fallback for nonraid
# (see its fetch_nonraid_source), and nonraid-first-boot.sh now mirrors it
# for nonraid-webui itself. --depth 1: neither script needs history, only a
# buildable tree to fetch/reset on top of.
log "Vendoring nonraid-webui and nonraid onto the image"
VENDOR_DIR="$EXTRACT_DIR/nonraid-os/vendor"
mkdir -p "$VENDOR_DIR"
git clone --branch main --depth 1 "$NONRAID_WEBUI_REPO_URL" "$VENDOR_DIR/nonraid-webui"
git clone --branch main --depth 1 "$NONRAID_REPO_URL" "$VENDOR_DIR/nonraid"
# Cloned above as whatever user runs this build script (not root, and this script never assumes
# it can chown to root itself) - so these checkouts stay owned by the build user's UID all the way
# onto the ISO. late_command in preseed/nonraid.preseed chowns them to root:root right after staging
# them onto /target, since that step already runs as root - see its own comment for why that matters
# (git's dubious-ownership check on a repo the running user doesn't own).

# mergerfs and rclone aren't in any apt repo at all (see REQUIREMENTS.md in
# nonraid-webui), so unlike the packages in pkgsel/include above, there's no
# "just add it to the package list" option for these two - vendoring the
# actual .deb is the only way to get them installed during the Debian
# install rather than at first boot. Same URLs nonraid-webui's own
# ensure_mergerfs/ensure_rclone use (see tools/install-webui.sh there),
# just run here at build time instead of at first boot.
log "Vendoring mergerfs and rclone .debs onto the image"
mkdir -p "$VENDOR_DIR/debs"
MERGERFS_DEB_URL="$(curl -fsSL https://api.github.com/repos/trapexit/mergerfs/releases/latest \
  | grep -oP '"browser_download_url":\s*"\K[^"]+debian-trixie_amd64\.deb' | head -1)"
[ -n "$MERGERFS_DEB_URL" ] || fail "Could not find a mergerfs debian-trixie_amd64.deb in the latest GitHub release"
curl -fsSL -o "$VENDOR_DIR/debs/mergerfs.deb" "$MERGERFS_DEB_URL"
curl -fsSL -o "$VENDOR_DIR/debs/rclone.deb" "https://downloads.rclone.org/rclone-current-linux-amd64.deb"

# Points the BIOS (isolinux) and UEFI (grub) boot menus at the preseed file
# - deliberately without auto=true priority=critical, since this is a
# branded-but-interactive install (see preseed/nonraid.preseed's own
# comment): that combination is what would otherwise silently apply every
# preseeded answer without ever showing the screen.
BOOT_ARGS="preseed/file=/cdrom/preseed.cfg"

# Both the graphical and text-mode installer entries get the boot args; the
# default selection is the graphical one, since it's nicer to actually
# watch/drive an interactive install with.
ISOLINUX_TXT_CFG="$EXTRACT_DIR/isolinux/txt.cfg"
ISOLINUX_GTK_CFG="$EXTRACT_DIR/isolinux/gtk.cfg"
if [ -f "$ISOLINUX_TXT_CFG" ] && [ -f "$ISOLINUX_GTK_CFG" ]; then
  log "Patching isolinux boot entries (BIOS)"
  sed -i "s#\(append .*\)#\1 $BOOT_ARGS#" "$ISOLINUX_TXT_CFG"
  sed -i "s#\(append .*\)#\1 $BOOT_ARGS#" "$ISOLINUX_GTK_CFG"
  sed -i "s/^default .*/default installgui/" "$EXTRACT_DIR/isolinux/isolinux.cfg"
else
  log "No isolinux/txt.cfg or gtk.cfg found - skipping BIOS boot patch (source ISO may be UEFI-only)"
fi

# grub.cfg splits each entry's kernel command line onto its own "linux ..."
# line rather than combining it with "append" the way isolinux does - a
# pattern requiring "linux" to appear twice on one line (carried over from
# an early draft) never matched that, so the UEFI path was silently getting
# no preseed args at all despite this script logging that it patched it.
# Confirmed by extracting and reading the actual built grub.cfg. Only the
# two top-level "Graphical install" / "Install" entries are targeted here,
# by their exact quoted label - the nested rescue/expert/speech-synthesis
# entries under "Advanced options" etc. are left alone on purpose, so those
# stay manual rather than silently auto-wiping a disk. "Graphical install"
# is already grub's default (first menuentry in the file), so no default
# change is needed here the way isolinux.cfg above needed one.
GRUB_CFG="$EXTRACT_DIR/boot/grub/grub.cfg"
if [ -f "$GRUB_CFG" ]; then
  log "Patching grub boot entries (UEFI)"
  awk -v boot_args="$BOOT_ARGS" '
    /^menuentry.*'"'"'Graphical install'"'"'/ { target = 1 }
    /^menuentry.*'"'"'Install'"'"'/ { target = 1 }
    target && /^    linux / { print $0 " " boot_args; next }
    /^}/ { target = 0 }
    { print }
  ' "$GRUB_CFG" > "$GRUB_CFG.new"
  mv "$GRUB_CFG.new" "$GRUB_CFG"
else
  log "No boot/grub/grub.cfg found - skipping UEFI boot patch (source ISO may be BIOS-only)"
fi

# Boot menu branding: an icon+wordmark watermark in the bottom-right corner
# of the grub (UEFI) boot menu background, so the first thing a user sees is
# NonRAID OS, not the stock Debian swirl. A corner watermark rather than a
# centered treatment - a full-size centered icon sits right behind the boot
# menu's own box, which visibly collided with the menu text (confirmed
# against a real UEFI boot); a corner placement can't collide with a
# centered menu regardless of its exact size.
ISOLINUX_SPLASH="$EXTRACT_DIR/isolinux/splash.png"
if [ -f "$ISOLINUX_SPLASH" ] && [ -f "$ISOLINUX_SPLASH_SRC" ]; then
  log "Branding isolinux boot menu background"
  dims="$(identify -format '%wx%h' "$ISOLINUX_SPLASH")"
  validate_branding_png "$ISOLINUX_SPLASH_SRC" "${dims%x*}" "${dims#*x}"
  cp "$ISOLINUX_SPLASH_SRC" "$ISOLINUX_SPLASH"
else
  log "Skipping BIOS boot menu branding (isolinux/splash.png missing on the ISO, or no branding/isolinux-splash.png to use - that screen is never actually shown on a normal boot anyway, see comment above ISOLINUX_SPLASH_SRC)"
fi

if [ -f "$GRUB_CFG" ]; then
  log "Branding grub boot menu background"
  validate_branding_png "$GRUB_BACKGROUND_SRC" 1024 768
  cp "$GRUB_BACKGROUND_SRC" "$EXTRACT_DIR/boot/grub/nonraid-background.png"
  # Prepend rather than append, so the background is set before the menu
  # itself is drawn. In practice this alone does nothing visible: grub's
  # own theme files (boot/grub/theme/1, 1-1, 1-1-1, 1-2, 1-2-1 - the
  # non-dark ones; the dark-contrast variants have no desktop-image at all)
  # each hardcode desktop-image: "/isolinux/splash.png", which overrides a
  # plain background_image command for the actual rendered graphical menu
  # (confirmed against a real UEFI boot - removing branding/isolinux-
  # splash.png, since that BIOS screen is never shown on a normal boot,
  # silently broke the GRUB background too, since both were pointing at the
  # same file). Repointing every theme's desktop-image at our own grub
  # background file instead is what actually matters visually.
  {
    printf 'insmod png\nbackground_image /boot/grub/nonraid-background.png\n'
    cat "$GRUB_CFG"
  } > "$GRUB_CFG.new"
  mv "$GRUB_CFG.new" "$GRUB_CFG"
  for theme_file in "$EXTRACT_DIR"/boot/grub/theme/1 "$EXTRACT_DIR"/boot/grub/theme/1-1 \
                    "$EXTRACT_DIR"/boot/grub/theme/1-1-1 "$EXTRACT_DIR"/boot/grub/theme/1-2 \
                    "$EXTRACT_DIR"/boot/grub/theme/1-2-1; do
    [ -f "$theme_file" ] || continue
    sed -i 's#desktop-image: "/isolinux/splash.png"#desktop-image: "/boot/grub/nonraid-background.png"#' "$theme_file"
    sed -i 's#title-text: "Debian GNU/Linux [^"]*"#title-text: "NonRAID OS"#' "$theme_file"
  done
fi

# Installer-UI branding: the boot menu splash above is only the screen
# before the installer starts. The GTK installer itself shows its own
# banner (icon + wordmark on a decorative strip) across the top of every
# screen - Debian's build ships that pre-rendered as
# usr/share/graphics/logo_installer(_dark).png inside the GTK frontend's own
# initrd (install.amd/gtk/initrd.gz), as symlinks to logo_debian(_dark).png.
# Replacing those two files (found by extracting and inspecting that initrd)
# is the documented customization point for this - confirmed against a real
# boot that the GTK installer still starts and shows it correctly.
GTK_INITRD="$EXTRACT_DIR/install.amd/gtk/initrd.gz"
if [ -f "$GTK_INITRD" ]; then
  log "Branding the GTK installer's own banner"
  GTK_INITRD_DIR="$WORK_DIR/gtk-initrd"
  mkdir -p "$GTK_INITRD_DIR"
  # The two mknod failures below (dev/console, dev/null) are expected when
  # not running as root - those two device-node entries just don't get
  # recreated in the repacked initrd; the kernel's own devtmpfs populates
  # /dev at boot regardless, so this doesn't affect booting.
  (cd "$GTK_INITRD_DIR" && zcat "$GTK_INITRD" | cpio -idm --no-absolute-filenames) 2>/dev/null || true

  validate_branding_png "$GTK_BANNER_SRC" 800 75
  # logo_installer(_dark).png start as symlinks to logo_debian(_dark).png -
  # remove them first rather than `cp` through the symlink, so this
  # replaces what logo_installer.png points to rather than silently also
  # repointing logo_debian.png's own content.
  rm -f "$GTK_INITRD_DIR/usr/share/graphics/logo_installer.png" "$GTK_INITRD_DIR/usr/share/graphics/logo_installer_dark.png"
  cp "$GTK_BANNER_SRC" "$GTK_INITRD_DIR/usr/share/graphics/logo_installer.png"
  cp "$GTK_BANNER_SRC" "$GTK_INITRD_DIR/usr/share/graphics/logo_installer_dark.png"

  # Dark theme: the installer's own gtk-theme-name (set in
  # etc/gtk-2.0/gtkrc, left as "Clearlooks") already points here, and the
  # Clearlooks engine (usr/lib/.../engines/libclearlooks.so) is already in
  # this initrd - overwriting its gtkrc in place with our recolored version
  # keeps that same engine (real widget rounding/gradients) instead of
  # falling back to GTK's bare engine-less rendering. See the file's own
  # comment for where the palette comes from.
  GTK_THEME_DEST="$GTK_INITRD_DIR/usr/share/themes/Clearlooks/gtk-2.0/gtkrc"
  if [ -f "$GTK_THEME_DEST" ]; then
    cp "$GTK_THEME_SRC" "$GTK_THEME_DEST"
  else
    log "No usr/share/themes/Clearlooks/gtk-2.0/gtkrc found in the GTK initrd - skipping dark installer theme"
  fi

  (cd "$GTK_INITRD_DIR" && find . | cpio -o -H newc 2>/dev/null | gzip -9) > "$GTK_INITRD.new"
  mv "$GTK_INITRD.new" "$GTK_INITRD"
else
  log "No install.amd/gtk/initrd.gz found - skipping GTK installer banner"
fi

log "Rebuilding hybrid BIOS/UEFI ISO at $OUT_ISO"
# Rather than hand-assembling the El Torito boot catalog and isohybrid MBR
# from scratch (which needs an isohdpfx.bin from a syslinux/isolinux package
# - not available on every build machine, e.g. not on Arch/Manjaro), read the
# source ISO back in and replay its own boot setup as-is onto the rebuilt
# disc. The source ISO is already a correctly hybridized BIOS+UEFI image, so
# this carries that over unchanged while swapping in our modified file tree.
rm -f "$OUT_ISO"
xorriso \
  -indev "$SRC_ISO" \
  -outdev "$OUT_ISO" \
  -volid "NONRAID_OS" \
  -map "$EXTRACT_DIR" / \
  -boot_image any replay

log "Done: $OUT_ISO"
log "Write it to a USB drive with, e.g.: sudo dd if=$OUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"
