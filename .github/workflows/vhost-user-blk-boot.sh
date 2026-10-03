#!/usr/bin/env bash
# Local experiment. Not intended for upstream.
#
# Functional test for vhost-user-blk: qemu-storage-daemon exports a Fedora
# cloud image over vhost-user-blk and qemu-system-x86_64 boots it (TCG) with
# that export as its only disk.  A cloud-init NoCloud seed ISO makes the guest
# print lsblk, write 32 MiB to its root filesystem and power off; the markers
# it prints on the serial console are the pass criterion.
#
# usage: vhost-user-blk-boot.sh <qemu build dir> <log dir>
set -uo pipefail

BUILD=$1
LOGS=$2
IMG=Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2
IMG_URL=${IMG_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/$IMG}
SOCK=/tmp/vhost.socket
QEMU=$BUILD/qemu-system-x86_64
QSD=$BUILD/storage-daemon/qemu-storage-daemon
QIMG=$BUILD/qemu-img
BOOT_TIMEOUT=${BOOT_TIMEOUT:-1800}

mkdir -p "$LOGS"
cd "$LOGS" || exit 1

# OpenBSD charges anonymous mmap to RLIMIT_DATA (1.5G by default), less than
# 1G of guest RAM plus the 1G TCG code buffer.
ulimit -d "$(ulimit -H -d)" 2>/dev/null || true
echo "data limit: $(ulimit -d) KiB, host: $(uname -srm)"

echo "== fetch $IMG"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$IMG" "$IMG_URL"
elif command -v fetch >/dev/null 2>&1; then
    fetch -q -o "$IMG" "$IMG_URL"
else
    ftp -V -o "$IMG" "$IMG_URL"
fi || { echo "download failed"; exit 1; }
"$QIMG" info "$IMG" || exit 1

echo "== cloud-init NoCloud seed"
mkdir -p seed
printf 'instance-id: vub-test\nlocal-hostname: vub-test\n' > seed/meta-data
cat > seed/user-data <<'EOF'
#cloud-config
runcmd:
  - [ sh, -c, "lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS > /dev/ttyS0" ]
  - [ sh, -c, "dd if=/dev/urandom of=/var/tmp/vub-write.bin bs=1M count=32 && sync && echo VHOST_USER_BLK_WRITE_OK > /dev/ttyS0" ]
  - [ sh, -c, "echo VHOST_USER_BLK_OK > /dev/ttyS0" ]
power_state:
  mode: poweroff
  timeout: 30
EOF
rm -f seed.iso
if command -v hdiutil >/dev/null 2>&1; then
    hdiutil makehybrid -quiet -o seed.iso -iso -joliet -default-volume-name cidata seed
elif command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -output seed.iso -volid cidata -joliet -rock seed
elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -quiet -o seed.iso -V cidata -J -r seed
elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -quiet -o seed.iso -V cidata -J -r seed
elif command -v mkhybrid >/dev/null 2>&1; then
    mkhybrid -o seed.iso -V cidata -J -r seed
elif command -v makefs >/dev/null 2>&1; then
    makefs -t cd9660 -o rockridge,label=cidata seed.iso seed
else
    echo "no ISO 9660 tool found"; exit 1
fi || { echo "seed ISO creation failed"; exit 1; }
ls -l seed.iso

echo "== qemu-storage-daemon"
rm -f "$SOCK"
"$QSD" \
    --blockdev file,filename=$IMG,node-name=file \
    --blockdev qcow2,file=file,node-name=qcow2 \
    --export vhost-user-blk,addr.type=unix,addr.path=$SOCK,id=vub,num-queues=1,node-name=qcow2,writable=on \
    > qsd.log 2>&1 &
QSD_PID=$!
for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.2; done
ls -l "$SOCK" || { echo "storage daemon did not create $SOCK"; cat qsd.log; exit 1; }

echo "== qemu-system-x86_64"
start=$(date +%s)
"$QEMU" -smp 2 -M q35,memory-backend=mem \
    -object memory-backend-shm,id=mem,size="1G" \
    -device vhost-user-blk-pci,num-queues=1,chardev=char0 \
    -chardev socket,id=char0,path=$SOCK \
    -cpu max -nic none -cdrom seed.iso -display none -no-reboot \
    -serial file:serial.log > qemu.log 2>&1 &
QEMU_PID=$!
# cloud-init powers the guest off at the end; give TCG up to BOOT_TIMEOUT
for i in $(seq 1 $BOOT_TIMEOUT); do kill -0 $QEMU_PID 2>/dev/null || break; sleep 1; done
if kill -0 $QEMU_PID 2>/dev/null; then
    echo "TIMEOUT: guest still running after ${BOOT_TIMEOUT}s, killing it"
    kill $QEMU_PID
fi
rc=0; wait $QEMU_PID || rc=$?
elapsed=$(( $(date +%s) - start ))
echo "qemu exit status $rc after ${elapsed}s"
kill $QSD_PID 2>/dev/null; wait $QSD_PID 2>/dev/null

echo "--- qemu.log"; cat qemu.log
echo "--- qsd.log"; cat qsd.log
echo "--- serial.log (block device and marker lines)"
grep -a -E 'virtio_blk|vda|VHOST_USER_BLK|Cloud-init.*finished|reboot: |Power down' serial.log
{
    echo "qemu exit status $rc after ${elapsed}s"
    grep -a -E 'virtio_blk|^vda|VHOST_USER_BLK|reboot: ' serial.log
} > summary.txt

if grep -a -q VHOST_USER_BLK_WRITE_OK serial.log && grep -a -q VHOST_USER_BLK_OK serial.log; then
    echo "RESULT: PASS"; echo "RESULT: PASS" >> summary.txt; exit 0
fi
echo "RESULT: FAIL"; echo "RESULT: FAIL" >> summary.txt; exit 1
