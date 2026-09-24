# NonRAID OS

*NonRAID OS, built on Debian.*

### Status: **Approach A validated end-to-end in a VM. Not yet tested on real hardware.**

This repository will hold the build for a NonRAID OS image — a bootable operating system with
[NonRAID](https://github.com/domgregori/nonraid) and
[nonraid-webui](https://github.com/domgregori/nonraid-webui) pre-installed and ready to use.

## Goal

A user writes an image to a USB drive. The user boots a computer from that drive, and walks
through a normal, NonRAID-branded Debian install. Once that finishes and the machine reboots, the
dashboard sets itself up automatically on first boot.

Today, a user must install Debian, then run `nonraid-webui`'s `install-webui.sh` script by hand.
This repository's goal is to remove that separate manual step.

## Related repositories

- [`nonraid`](https://github.com/domgregori/nonraid) — the kernel driver (`md_nonraid`,
  `nonraid6_pq`) and the `nmdctl` command-line tool.
- [`nonraid-webui`](https://github.com/domgregori/nonraid-webui) — the dashboard frontend and
  backend, plus the current manual install script (`tools/install-webui.sh`).

## Approach

See [PLAN.md](PLAN.md) for the two build approaches under consideration, and the current
recommendation.

## Repository layout

- [`preseed/nonraid.preseed`](preseed/nonraid.preseed) — Debian installer preseed file. Defaults
  the backend stuff (locale, mirror, clock, the guided-partitioning recipe, packages, bootloader)
  but leaves the actual install screens interactive — see its own comment for exactly what and why.
- [`first-boot/`](first-boot) — the systemd unit and script that run once, on the freshly
  installed system's first boot, to clone `nonraid-webui` and run its existing
  `tools/install-webui.sh`.
- [`banner/`](banner) — the systemd unit and script that regenerate `/etc/issue` and `/etc/motd`
  with the dashboard's address (or a "still setting up" / failure message) on every boot.
- [`branding/logo.png`](branding/logo.png) — the NonRAID logo, the one source-of-truth art asset.
- [`branding/grub-background.png`](branding/grub-background.png) and
  [`branding/gtk-installer-banner.png`](branding/gtk-installer-banner.png) — the finished, flat
  boot-menu and installer-banner images `build-image.sh` copies onto the ISO as-is (validated for
  size and 8-bit depth first — GRUB's own PNG loader corrupts on 16-bit). Hand-edited directly;
  [`branding/layered/`](branding/layered) holds these (plus an unused `isolinux-splash`, see below)
  as 4-page TIFFs (background, icon, and each text line as separate pages) to actually edit in.
  There's no `branding/isolinux-splash.png` - Debian's own isolinux.cfg (`prompt 0`) never actually
  shows that boot menu screen on a normal boot, so branding it isn't worth maintaining; the stock
  Debian splash just ships there unmodified.
- [`branding/gtk-installer-theme.gtkrc`](branding/gtk-installer-theme.gtkrc) — a dark recolor of
  Debian's own bundled Clearlooks GTK2 theme, for the graphical installer. `build-image.sh`
  overwrites the theme's `gtkrc` inside the installer's GTK initrd with this file.
- [`build/build-image.sh`](build/build-image.sh) — remasters a stock Debian netinst ISO with the
  files above, producing a bootable, branded, interactive install image. Given no source ISO, it
  downloads Debian's netinst image itself, verifies it (GPG signature on `SHA256SUMS`, checked
  against pinned Debian signing-key fingerprints, then a checksum match), and caches it in
  `.cache/` — the ISO itself isn't committed to this repo. It also vendors `nonraid` and
  `nonraid-webui` (git checkouts) and the `mergerfs`/`rclone` `.deb`s onto the ISO itself, staged by
  `preseed/nonraid.preseed`'s `late_command` so the Debian install can install most of
  `nonraid-webui`'s dependencies itself (guaranteed network, unlike first boot's) and first boot has
  something to build from even if the network is down or flaky right when it needs it.
- [`.github/workflows/release-iso.yml`](.github/workflows/release-iso.yml) and
  [`.gitea/workflows/release-iso.yml`](.gitea/workflows/release-iso.yml) — CI that runs
  `build-image.sh` and publishes `nonraid-os-<tag>.iso` as a release asset on a `v*` tag push (or a
  manual run). No VM boot-testing here — that still needs a real machine.

This is a netinst image: the Debian installer still needs internet access to fetch packages, and
first boot needs it for whatever `nonraid-webui` dependencies aren't pre-installed during the
Debian install itself (see `build-image.sh` above) - there's no fully offline path, just
substantially less first-boot network dependency than a live clone/install would have.

## Status

Approach A has been validated end-to-end in a VM (BIOS and UEFI, both graphical and text
installers): the branded interactive install, first boot, and the dashboard coming up all work.
Not yet tested on real hardware — driver/disk-detection issues in particular are exactly what a VM
won't surface.
