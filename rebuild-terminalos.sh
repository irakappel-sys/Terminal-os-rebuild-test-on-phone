#!/usr/bin/env bash
set -Eeuo pipefail

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
ROOTFS="$WORK_DIR/rootfs"
ISO_TREE="$WORK_DIR/iso"
PKG_REPO="$WORK_DIR/TerminalOS-Packages"
OUTPUT_ISO="$OUT_DIR/TerminalOS-1.0.1-rebuild.iso"
PACKAGE_REPO_URL="https://github.com/irakappel-sys/TerminalOS-Packages.git"
PACKAGE_REPO_COMMIT="3f180afa011e9fdc2294775ca5a10ff75f9fb56f"
SIGNING_FINGERPRINT="981B65A121E34AB45318ED7BF5AB23E53B9B48DC"
VOLUME_ID="TERMINALOS_1_0_1_REBUILD"

log() { printf '\n=== %s ===\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo --preserve-env=WORK_DIR,OUT_DIR bash "$0" "$@"
fi

for cmd in debootstrap git gpg gpgv sha256sum rsync chroot mksquashfs grub-mkrescue xorriso file python3; do
  require "$cmd"
done

cleanup() {
  set +e
  for mountpoint in "$ROOTFS/run" "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys"; do
    if mountpoint -q "$mountpoint" 2>/dev/null; then
      umount -l "$mountpoint"
    fi
  done
}
trap cleanup EXIT INT TERM

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

log "FETCHING PINNED TERMINALOS PACKAGE REPOSITORY"
git clone --filter=blob:none "$PACKAGE_REPO_URL" "$PKG_REPO"
git -C "$PKG_REPO" checkout --detach "$PACKAGE_REPO_COMMIT"
[[ "$(git -C "$PKG_REPO" rev-parse HEAD)" == "$PACKAGE_REPO_COMMIT" ]] || die "package repo commit mismatch"

log "VERIFYING TERMINALOS PACKAGE BYTES"
(
  cd "$PKG_REPO"
  sha256sum -c "$REPO_ROOT/manifest/terminalos-packages.sha256"
)

fingerprint="$(gpg --batch --show-keys --with-colons "$PKG_REPO/terminalos-archive-signing-key.asc" | awk -F: '$1 == "fpr" {print $10; exit}')"
[[ "$fingerprint" == "$SIGNING_FINGERPRINT" ]] || die "signing-key fingerprint mismatch: $fingerprint"
gpgv --keyring "$PKG_REPO/terminalos-archive-keyring.gpg" \
  "$PKG_REPO/dists/stable/Release.gpg" \
  "$PKG_REPO/dists/stable/Release"

grep -q '^Package: terminalos-base$' "$PKG_REPO/dists/stable/main/binary-amd64/Packages" || die "repository metadata missing terminalos-base"
grep -q '^Package: terminalos-kernel-1.0.0$' "$PKG_REPO/dists/stable/main/binary-amd64/Packages" || die "repository metadata missing custom kernel"

log "BOOTSTRAPPING DEBIAN TRIXIE ROOT FILESYSTEM"
debootstrap --arch=amd64 --variant=minbase trixie "$ROOTFS" https://deb.debian.org/debian

cat > "$ROOTFS/etc/apt/sources.list" <<'EOF'
deb https://deb.debian.org/debian trixie main contrib non-free-firmware
deb https://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb https://security.debian.org/debian-security trixie-security main contrib non-free-firmware
EOF

cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
mount --rbind /dev "$ROOTFS/dev"
mount --make-rslave "$ROOTFS/dev"
mount --bind /run "$ROOTFS/run"

log "INSTALLING LIVE DESKTOP AND INSTALLER BASE"
chroot "$ROOTFS" /bin/bash -Eeuo pipefail <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update
apt-get install -y --no-install-recommends \
  systemd-sysv dbus sudo locales ca-certificates initramfs-tools kmod \
  live-boot live-config live-config-systemd \
  gnome-core gdm3 network-manager network-manager-gnome \
  calamares zenity x11-xserver-utils \
  plymouth grub-common grub-pc-bin grub-efi-amd64-bin efibootmgr \
  firmware-iwlwifi wpasupplicant rfkill \
  linux-base os-prober pciutils usbutils less nano vim-tiny
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

log "INSTALLING PRESERVED TERMINALOS OFFLINE REPOSITORY"
mkdir -p "$ROOTFS/opt/terminalos/repository"
rsync -a --delete \
  --exclude='.git' \
  --exclude='.gitignore' \
  --exclude='README.md' \
  "$PKG_REPO/" "$ROOTFS/opt/terminalos/repository/"
install -Dm0644 "$PKG_REPO/terminalos-archive-keyring.gpg" \
  "$ROOTFS/usr/share/keyrings/terminalos-archive-keyring.gpg"

cat > "$ROOTFS/etc/apt/sources.list.d/terminalos-rebuild.sources" <<'EOF'
Types: deb
URIs: file:/opt/terminalos/repository
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/terminalos-archive-keyring.gpg
EOF

chroot "$ROOTFS" /bin/bash -Eeuo pipefail <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update
apt-get install -y \
  terminalos-base=1.0.0 \
  terminalos-branding=1.0.2 \
  terminalos-installer-config=1.0.3 \
  terminalos-kernel-1.0.0=1.0.1 \
  terminalos-network-config=1.0.1 \
  terminalos-package-manager=1.2.2
rm -f /etc/apt/sources.list.d/terminalos-rebuild.sources
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOT

log "VERIFYING INSTALLED TERMINALOS COMPONENTS"
expected_packages=(
  'terminalos-base:1.0.0'
  'terminalos-branding:1.0.2'
  'terminalos-installer-config:1.0.3'
  'terminalos-kernel-1.0.0:1.0.1'
  'terminalos-network-config:1.0.1'
  'terminalos-package-manager:1.2.2'
)
for item in "${expected_packages[@]}"; do
  package="${item%%:*}"
  version="${item#*:}"
  installed="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' "$package")"
  [[ "$installed" == "$version" ]] || die "$package version mismatch: $installed != $version"
  printf 'PASS: %s %s\n' "$package" "$version"
done

[[ -f "$ROOTFS/boot/vmlinuz-6.12.94-terminalos" ]] || die "custom kernel image missing"
[[ -d "$ROOTFS/lib/modules/6.12.94-terminalos" ]] || die "custom kernel modules missing"
chroot "$ROOTFS" depmod 6.12.94-terminalos
chroot "$ROOTFS" update-initramfs -c -k 6.12.94-terminalos 2>/dev/null || \
  chroot "$ROOTFS" update-initramfs -u -k 6.12.94-terminalos
[[ -f "$ROOTFS/boot/initrd.img-6.12.94-terminalos" ]] || die "custom initramfs missing"
file "$ROOTFS/boot/vmlinuz-6.12.94-terminalos" | grep -q '6.12.94-terminalos' || die "kernel release string mismatch"

if [[ -x "$ROOTFS/usr/bin/tos" ]]; then
  chroot "$ROOTFS" /usr/bin/tos doctor || die "tos doctor failed"
fi

log "CONFIGURING LIVE SESSION"
cat > "$ROOTFS/etc/hostname" <<'EOF'
terminalos
EOF
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 terminalos
::1 localhost ip6-localhost ip6-loopback
EOF

# live-config creates the live user. Keep the runtime system passwordless for the
# live session only; Calamares creates the installed user's real credentials.
mkdir -p "$ROOTFS/etc/live/config.conf.d"
cat > "$ROOTFS/etc/live/config.conf.d/10-terminalos.conf" <<'EOF'
LIVE_USERNAME="user"
LIVE_HOSTNAME="terminalos"
EOF

rm -f "$ROOTFS/usr/sbin/policy-rc.d"

log "CLEANING AND UNMOUNTING ROOT FILESYSTEM"
rm -f "$ROOTFS/etc/resolv.conf"
cleanup
trap - EXIT INT TERM

find "$ROOTFS/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf "$ROOTFS/root/.cache" "$ROOTFS/home"/*/.cache 2>/dev/null || true

log "ASSEMBLING LIVE ISO TREE"
rm -rf "$ISO_TREE"
mkdir -p "$ISO_TREE/live" "$ISO_TREE/boot/grub"
cp "$ROOTFS/boot/vmlinuz-6.12.94-terminalos" "$ISO_TREE/live/vmlinuz"
cp "$ROOTFS/boot/initrd.img-6.12.94-terminalos" "$ISO_TREE/live/initrd.img"

mksquashfs "$ROOTFS" "$ISO_TREE/live/filesystem.squashfs" \
  -comp xz -b 1048576 -noappend

du -sx --block-size=1 "$ROOTFS" | awk '{print $1}' > "$ISO_TREE/live/filesystem.size"
chroot "$ROOTFS" dpkg-query -W -f='${Package} ${Version}\n' | sort > "$ISO_TREE/live/filesystem.packages"

cat > "$ISO_TREE/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5

menuentry "TerminalOS 1.0.1 Rebuild (Live)" {
    linux /live/vmlinuz boot=live components live-media-path=/live live-media-timeout=90 username=user hostname=terminalos quiet splash
    initrd /live/initrd.img
}

menuentry "TerminalOS 1.0.1 Rebuild (Live, verbose)" {
    linux /live/vmlinuz boot=live components live-media-path=/live live-media-timeout=90 username=user hostname=terminalos systemd.show_status=true
    initrd /live/initrd.img
}
EOF

if grep -R --binary-files=without-match -n 'live-media=/dev/sr0' "$ISO_TREE"; then
  die "hardcoded /dev/sr0 found in ISO tree"
fi

grep -q 'live-media-path=/live' "$ISO_TREE/boot/grub/grub.cfg" || die "automatic live media configuration missing"

(
  cd "$ISO_TREE"
  find . -type f ! -name md5sum.txt ! -name boot.catalog -print0 \
    | sort -z \
    | xargs -0 md5sum > md5sum.txt
)

log "BUILDING HYBRID BIOS/UEFI ISO"
rm -f "$OUTPUT_ISO"
grub-mkrescue -o "$OUTPUT_ISO" "$ISO_TREE" -- -volid "$VOLUME_ID"
sync

log "STRUCTURAL ISO VALIDATION"
[[ -s "$OUTPUT_ISO" ]] || die "ISO was not created"
report="$(xorriso -indev "$OUTPUT_ISO" -report_el_torito plain 2>&1)"
printf '%s\n' "$report" | tee "$OUT_DIR/el-torito-report.txt"
printf '%s\n' "$report" | grep -qi 'BIOS' || die "BIOS El Torito image missing"
printf '%s\n' "$report" | grep -qi 'UEFI' || die "UEFI El Torito image missing"

extract_dir="$(mktemp -d)"
trap 'rm -rf "$extract_dir"' EXIT
xorriso -osirrox on -indev "$OUTPUT_ISO" \
  -extract /live/vmlinuz "$extract_dir/vmlinuz" \
  -extract /boot/grub/grub.cfg "$extract_dir/grub.cfg" >/dev/null 2>&1
file "$extract_dir/vmlinuz" | grep -q '6.12.94-terminalos' || die "ISO kernel is not 6.12.94-terminalos"
! grep -q 'live-media=/dev/sr0' "$extract_dir/grub.cfg" || die "ISO contains hardcoded /dev/sr0"
grep -q 'live-media-path=/live' "$extract_dir/grub.cfg" || die "ISO lacks live-media-path"

sha256sum "$OUTPUT_ISO" | tee "$OUTPUT_ISO.sha256"
stat -c 'ISO bytes: %s' "$OUTPUT_ISO"

log "RUNNING 50 FULL BYTEWISE VERIFICATION PASSES"
python3 "$REPO_ROOT/scripts/verify-iso-50x.py" \
  "$OUTPUT_ISO" \
  --passes 50 \
  --report "$OUT_DIR/verification-50x.json"

log "REBUILD COMPLETE"
printf 'ISO: %s\n' "$OUTPUT_ISO"
printf 'SHA256: %s\n' "$(sha256sum "$OUTPUT_ISO" | awk '{print $1}')"
