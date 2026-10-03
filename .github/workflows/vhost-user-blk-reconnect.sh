#!/usr/bin/env bash
# Local experiment. Not intended for upstream.
#
# Reconnect test for vhost-user-blk: a Fedora cloud guest writes to its disk
# in a loop while qemu-storage-daemon (the vhost-user-blk back-end) is
# SIGKILLed and restarted underneath it.  QEMU's chardev reconnects; the
# back-end then has to resume the requests that were in flight (tracked in
# the inflight region) and the ones the guest queued while it was gone.
# The guest prints ITER n after each write and a marker at the end; the
# marker and QEMU exiting on the guest's power-off are the pass criterion.
#
# usage: vhost-user-blk-reconnect.sh <qemu build dir> <log dir> [image]
set -uo pipefail

BUILD=$1
LOGS=$2
IMG=${3:-Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2}
IMG_URL=${IMG_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/$(basename "$IMG")}
SOCK=/tmp/vhost-reconnect.socket
QEMU=$BUILD/qemu-system-x86_64
QSD=$BUILD/storage-daemon/qemu-storage-daemon
QIMG=$BUILD/qemu-img
BOOT_TIMEOUT=${BOOT_TIMEOUT:-1800}   # until the guest reaches ITER 5
RESUME_TIMEOUT=${RESUME_TIMEOUT:-300} # from the back-end restart to power-off
KILL_AT=${KILL_AT:-5}                 # kill the back-end after this ITER
ITERS=${ITERS:-30}

mkdir -p "$LOGS"
cd "$LOGS" || exit 1
ulimit -d "$(ulimit -H -d)" 2>/dev/null || true
echo "host: $(uname -srm)"

if [ ! -f "$IMG" ]; then
    echo "== fetch $IMG"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$IMG" "$IMG_URL"
    elif command -v fetch >/dev/null 2>&1; then
        fetch -q -o "$IMG" "$IMG_URL"
    else
        ftp -V -o "$IMG" "$IMG_URL"
    fi || { echo "download failed"; exit 1; }
fi
# work on a throw-away overlay so the base image survives a SIGKILLed back-end
rm -f disk.qcow2
"$QIMG" create -q -f qcow2 -F qcow2 -b "$IMG" disk.qcow2 || exit 1

echo "== cloud-init NoCloud seed"
mkdir -p seed
printf 'instance-id: vub-reconnect\nlocal-hostname: vub-reconnect\n' > seed/meta-data
cat > seed/user-data <<EOF
#cloud-config
runcmd:
  - [ sh, -c, "for i in \$(seq 1 $ITERS); do dd if=/dev/zero of=/var/tmp/vub-\$i.bin bs=1M count=4 oflag=direct conv=fsync 2>/dev/null && echo ITER \$i > /dev/ttyS0; done" ]
  - [ sh, -c, "sync && echo VHOST_USER_BLK_RECONNECT_OK > /dev/ttyS0" ]
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

start_qsd() {
    rm -f "$SOCK"
    "$QSD" \
        --blockdev file,filename=disk.qcow2,node-name=file \
        --blockdev qcow2,file=file,node-name=qcow2 \
        --export vhost-user-blk,addr.type=unix,addr.path=$SOCK,id=vub,num-queues=1,node-name=qcow2,writable=on \
        >> qsd.log 2>&1 &
    QSD_PID=$!
    for i in $(seq 1 50); do [ -S "$SOCK" ] && break; sleep 0.2; done
    [ -S "$SOCK" ] || { echo "storage daemon did not create $SOCK"; cat qsd.log; return 1; }
    echo "storage daemon pid $QSD_PID listening on $SOCK"
}

wait_serial() { # pattern timeout
    local i
    for i in $(seq 1 "$2"); do
        grep -a -q -E "$1" serial.log 2>/dev/null && return 0
        kill -0 $QEMU_PID 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

echo "== qemu-storage-daemon"
: > qsd.log
start_qsd || exit 1

echo "== qemu-system-x86_64 (chardev reconnects every 500 ms)"
: > serial.log
start=$(date +%s)
"$QEMU" -smp 2 -M q35,memory-backend=mem \
    -object memory-backend-shm,id=mem,size="1G" \
    -device vhost-user-blk-pci,num-queues=1,chardev=char0 \
    -chardev socket,id=char0,path=$SOCK,reconnect-ms=500 \
    -cpu max -nic none -cdrom seed.iso -display none -no-reboot \
    -serial file:serial.log > qemu.log 2>&1 &
QEMU_PID=$!

if ! wait_serial "^ITER $KILL_AT\$" "$BOOT_TIMEOUT"; then
    echo "FAIL: guest did not reach ITER $KILL_AT within ${BOOT_TIMEOUT}s"
    kill $QEMU_PID 2>/dev/null; wait $QEMU_PID 2>/dev/null
    kill $QSD_PID 2>/dev/null; wait $QSD_PID 2>/dev/null
    cat qemu.log; echo "RESULT: FAIL" | tee summary.txt; exit 1
fi
echo "guest reached ITER $KILL_AT after $(( $(date +%s) - start ))s; killing the back-end (pid $QSD_PID)"
kill -9 $QSD_PID; wait $QSD_PID 2>/dev/null
sleep 3
last_before=$(grep -a -E '^ITER [0-9]+' serial.log | tail -1)
echo "last line before restart: $last_before"
echo "== restarting qemu-storage-daemon"
start_qsd || exit 1
restart=$(date +%s)

for i in $(seq 1 "$RESUME_TIMEOUT"); do kill -0 $QEMU_PID 2>/dev/null || break; sleep 1; done
if kill -0 $QEMU_PID 2>/dev/null; then
    echo "TIMEOUT: guest still running ${RESUME_TIMEOUT}s after the back-end restart (I/O hang?), killing it"
    kill $QEMU_PID
fi
rc=0; wait $QEMU_PID || rc=$?
echo "qemu exit status $rc, $(( $(date +%s) - restart ))s after the restart, $(( $(date +%s) - start ))s total"
kill $QSD_PID 2>/dev/null; wait $QSD_PID 2>/dev/null

echo "--- qemu.log"; cat qemu.log
echo "--- qsd.log"; cat qsd.log
echo "--- serial.log (progress and marker lines)"
grep -a -E '^ITER |VHOST_USER_BLK|virtio_blk|reboot: |blk_update_request|I/O error|hung task' serial.log
{
    echo "back-end killed after $last_before"
    echo "iterations completed: $(grep -a -c '^ITER ' serial.log)/$ITERS"
    echo "qemu exit status $rc, $(( $(date +%s) - restart ))s after the restart"
    grep -a -E 'VHOST_USER_BLK|reboot: ' serial.log
} > summary.txt
if grep -a -q VHOST_USER_BLK_RECONNECT_OK serial.log && grep -a -q 'reboot: Power down' serial.log; then
    echo "RESULT: PASS"; echo "RESULT: PASS" >> summary.txt; exit 0
fi
echo "RESULT: FAIL"; echo "RESULT: FAIL" >> summary.txt; exit 1
