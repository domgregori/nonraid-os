# NonRAID OS

*NonRAID OS, built on Debian.*



This repository will hold the build for a NonRAID OS image — a bootable operating system with
[NonRAID](https://github.com/domgregori/nonraid) and
[nonraid-webui](https://github.com/domgregori/nonraid-webui) pre-installed and ready to use.

## Instructions

Write image to a USB drive and boot. Follow instructions like a normal distro install.

Once the install finishes and the machine reboots, the
dashboard sets itself up automatically on first boot.

---


## Related repositories

- [`nonraid`](https://github.com/domgregori/nonraid) — the kernel driver (`md_nonraid`,
  `nonraid6_pq`) and the `nmdctl` command-line tool.
- [`nonraid-webui`](https://github.com/domgregori/nonraid-webui)

### To plant, grow, and harvest your own iso
```
git clone git@github.com:domgregori/nonraid-os.git

cd nonraid-os

./build/build-image.sh
```

The script will pull the latest debian 13 release and create the iso in the same dir.

## Repository layout
```
src/
	preseed/nonraid.preseed 	Debian installer preseed file. Defaults the backend stuff (locale, mirror, clock, the guided-partitioning recipe, packages, bootloader) but leaves the actual install screens interactive

	first-boot/					the systemd unit and script that run once, on the freshly installed system's first boot, to clone `nonraid-webui` and run its existing `tools/install-webui.sh`

	banner/						the systemd unit and script that regenerate `/etc/issue` and `/etc/motd` with the dashboard's address (or a "still setting up" / failure message) on every boot.

	branding/					Logos, images, and debian installer theme

	build/build-image.sh		remasters a stock Debian netinst ISO with the files above, producing a bootable, branded, interactive install image. 

	.github/workflows/release-iso.yml	CI that runs `build-image.sh` and publishes `nonraid-os-<tag>.iso` as a release asset
```


This uses the Debian net installer so it needs internet access to fetch packages, and on first boot needs it for whatever `nonraid-webui` dependencies aren't pre-installed during the Debian install itself.

## TODO
- Create an offline iso installer
- Translations to more languages
