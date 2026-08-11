# TerminalOS reconstruction test

This repository reconstructs TerminalOS from the preserved official package repository and the validated TerminalOS 1.0.1 DEV5 build characteristics.

It is intentionally separate from the main `TerminalOS` repository.

## What is preserved exactly

The build verifies and installs these original TerminalOS package bytes before doing anything else:

- `terminalos-base` 1.0.0
- `terminalos-branding` 1.0.2
- `terminalos-installer-config` 1.0.3
- `terminalos-kernel-1.0.0` 1.0.1, runtime kernel `6.12.94-terminalos`
- `terminalos-network-config` 1.0.1
- `terminalos-package-manager` 1.2.2
- the signed `stable/main` repository metadata and public signing key

The package SHA-256 values are pinned in `manifest/terminalos-packages.sha256`.

## Reconstructed DEV5 properties

The builder deliberately reproduces the validated DEV5 architecture:

- Debian trixie amd64 root filesystem
- GNOME/GDM graphical environment
- Calamares installer
- TerminalOS custom `6.12.94-terminalos` kernel and matching modules/initramfs
- owned offline TerminalOS repository under `/opt/terminalos/repository`
- Dell/Wi-Fi network package preserved
- `tos` package manager 1.2.2
- live-boot with automatic media discovery; no `live-media=/dev/sr0`
- xz SquashFS with 1 MiB blocks
- hybrid legacy BIOS + UEFI GRUB ISO

## Build locally

On Debian/Ubuntu x86-64:

```bash
sudo apt-get update
sudo apt-get install -y \
  debootstrap git ca-certificates gnupg gpgv xorriso squashfs-tools \
  grub-common grub-pc-bin grub-efi-amd64-bin mtools dosfstools rsync \
  python3 file coreutils

sudo ./rebuild-terminalos.sh
```

The ISO is written to `out/TerminalOS-1.0.1-rebuild.iso`.

## 50-pass byte verification

After the build:

```bash
python3 scripts/verify-iso-50x.py \
  out/TerminalOS-1.0.1-rebuild.iso \
  --passes 50 \
  --report out/verification-50x.json
```

Without a reference ISO, the verifier makes an independent full physical copy and then performs 50 complete passes. Every pass compares every byte of the ISO with the copy while independently recomputing SHA-256 on both streams. A pass fails immediately on a byte offset mismatch, size change, or hash instability.

If the original canonical ISO is available, use it as the reference instead:

```bash
python3 scripts/verify-iso-50x.py \
  out/TerminalOS-1.0.1-rebuild.iso \
  --reference /path/to/TerminalOS-1.0.1-DEV5.iso \
  --expected-sha256 658b50ad7929f94edd9bb0397e4aa9617871a2979d2cf82d65000bd72962712c \
  --passes 50
```

That mode is an actual 50-pass byte-for-byte comparison against the historical artifact.

## GitHub build

`.github/workflows/rebuild-and-verify.yml` performs the complete build on an x86-64 GitHub runner, structurally validates the ISO, performs the 50 full bytewise passes, and publishes the resulting ISO plus checksum and verification reports as a GitHub Release.

The workflow can also be launched manually from **Actions → Rebuild and verify TerminalOS → Run workflow**.

## Historical canonical identifiers

`manifest/canonical-images.txt` records the known canonical hashes. In particular:

- TerminalOS 1.0.0 final: `0961b2bacb52cf4cbe5dd8c370d9e267c5f49decd05840ccff818b4cbaaf99c6`
- TerminalOS 1.0.1 DEV5: `658b50ad7929f94edd9bb0397e4aa9617871a2979d2cf82d65000bd72962712c`
- DEV5 size: `1513994240` bytes

A newly reconstructed image is not claimed to have the old hash unless the 50-pass external-reference mode actually proves that it does. The preserved TerminalOS packages themselves are hash-pinned and verified before installation.
