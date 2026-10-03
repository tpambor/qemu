#!/usr/bin/env bash
# Local experiment. Not intended for upstream.
#
# Build QEMU and run the vhost-user checks on the current host.  Used by
# vhost-user-repro.yml both directly on GitHub's macOS and Ubuntu runners and
# inside the FreeBSD/OpenBSD VMs started by cross-platform-actions, so every
# OS-specific detail (packages, configure flags, make, sudo) is decided here
# from uname rather than in the workflow.
#
# usage: vhost-user-ci.sh <repro|functional> <log dir>
#
#   repro       build ppc64-softmmu, run all qos tests once, a diagnostic run
#               of the vhost-user migrate subtest with tracing, a stress run
#               (six qtests in parallel, five repetitions) and the
#               vhost-user/reconnect test 30 times under CPU load.  Test
#               failures are recorded in <log dir>/status.txt, only a build
#               failure makes the script fail.
#   functional  build x86_64-softmmu with the tools and boot Fedora over
#               vhost-user-blk with vhost-user-blk-boot.sh.  The script fails
#               if the boot test fails.
#
# CLEANUP=1 removes the build tree and the large functional-test files at the
# end (used inside the VMs to keep the sync back to the runner small).
set -uo pipefail

MODE=$1
LOGS=$(mkdir -p "$2" && cd "$2" && pwd)
SRC=$PWD
OS=$(uname -s)

PPC64_TESTS="qtest-ppc64/qos-test qtest-ppc64/device-introspect-test qtest-ppc64/cdrom-test qtest-ppc64/migration-test qtest-ppc64/prom-env-test qtest-ppc64/boot-serial-test"
RECONNECT=/ppc64/pseries/spapr-pci-host-bridge/pci-bus-spapr/pci-bus/virtio-net-pci/virtio-net/virtio-net-tests/vhost-user/reconnect

case $OS in
    Linux) NCPU=$(nproc); MAKE=make ;;
    *)     NCPU=$(sysctl -n hw.ncpu); MAKE=gmake ;;
esac
SUDO=sudo; command -v sudo >/dev/null 2>&1 || SUDO=doas

in_group=
section() {
    [ -n "$in_group" ] && echo "::endgroup::"
    echo "::group::$1"
    in_group=1
}
status() { echo "$*" | tee -a "$LOGS/status.txt"; }
result() { # <name> <exit status>
    if [ "$2" -eq 0 ]; then status "$1: ok"; else status "$1: FAILED (exit $2)"; fi
}
finish() {
    local rc=$1
    section "collect logs"
    cp "$SRC"/build/config.log "$LOGS"/ 2>/dev/null
    cp "$SRC"/build/meson-logs/meson-log.txt "$SRC"/build/meson-logs/testlog.txt "$LOGS"/ 2>/dev/null
    if [ -n "${CLEANUP:-}" ]; then
        rm -rf "$SRC"/build "$LOGS"/seed "$LOGS"/seed.iso "$LOGS"/*.qcow2
    fi
    echo "::endgroup::"
    exit "$rc"
}

section "host"
uname -a; echo "cpus: $NCPU"
case $OS in
    Darwin)  sw_vers; sysctl -n hw.memsize machdep.cpu.brand_string ;;
    Linux)   head -2 /etc/os-release; free -g | head -2 ;;
    FreeBSD) freebsd-version; df -h / ;;
    OpenBSD) uname -r; df -h / ;;
esac

section "install dependencies"
case $OS in
    Darwin)
        # keep the preinstalled Homebrew packages: no index refresh, no upgrade of
        # already installed formulae or their dependents.  Upgrading openssl@3 on
        # the macos-15 image fails to link over a stale openssl@1.1 symlink.
        export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
               HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
        brew install bash coreutils dtc gettext glib gnu-sed make meson ninja pixman pkgconf python3 zstd
        ;;
    Linux)
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends \
            build-essential git ninja-build pkg-config python3 python3-venv \
            libglib2.0-dev libpixman-1-dev libfdt-dev zlib1g-dev \
            libcap-ng-dev libattr1-dev genisoimage
        ;;
    FreeBSD)
        sudo pkg install -y bash coreutils curl dtc gettext git glib gmake gnutls gsed meson ninja pixman pkgconf python3 zstd
        PYVER=$(python3 -c 'import sys; print("%d%d" % sys.version_info[:2])')
        sudo pkg install -y py${PYVER}-setuptools py${PYVER}-wheel py${PYVER}-tomli || true
        ;;
    OpenBSD)
        # OpenBSD 7.7's default python3 is 3.12 (QEMU needs >= 3.12).
        # cdrtools (mkisofs) for the seed ISO; mkhybrid from base is the fallback.
        $SUDO pkg_add -I bash bison bzip2 cdrtools curl dtc git glib2 gmake gsed libffi meson ninja pkgconf python3
        ;;
esac

section "configure"
configure_args=()
case $OS in
    Darwin)
        prefix=$(brew --prefix)
        configure_args+=("--extra-cflags=-I$prefix/include" "--extra-ldflags=-L$prefix/lib")
        ;;
    FreeBSD)
        configure_args+=(--extra-cflags=-I/usr/local/include --extra-ldflags=-L/usr/local/lib)
        ;;
    OpenBSD)
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/X11R6/lib/pkgconfig
        configure_args+=(--cc=cc --python=/usr/local/bin/python3
            "--extra-cflags=-I/usr/local/include -I/usr/X11R6/include"
            "--extra-ldflags=-L/usr/local/lib -L/usr/X11R6/lib")
        ;;
esac
case $MODE in
    repro)      configure_args+=(--target-list=ppc64-softmmu) ;;
    functional) configure_args+=(--target-list=x86_64-softmmu --enable-tools) ;;
    *)          echo "unknown mode '$MODE'"; exit 2 ;;
esac
mkdir -p build && cd build || exit 1
../configure "${configure_args[@]}" \
    --enable-vhost-user \
    --enable-vhost-user-blk-server \
    --disable-docs \
    --disable-rust \
    --disable-plugins \
    --disable-werror \
    || { cat config.log meson-logs/meson-log.txt; finish 1; }

section "build"
$MAKE -j"$NCPU" || finish 1

if [ "$MODE" = functional ]; then
    section "boot Fedora over vhost-user-blk"
    cd "$SRC"
    bash .github/workflows/vhost-user-blk-boot.sh "$SRC/build" "$LOGS"
    finish $?
fi

section "build tests"
$MAKE -j"$NCPU" check-build || finish 1

# Raise the soft data-size limit: OpenBSD charges anonymous mmap to
# RLIMIT_DATA and its 1.5G default is below what a TCG pseries guest needs
# (512 MiB RAM plus the 1 GiB code buffer), so boot-serial-test's QEMU died
# with "Cannot set up 512 MiB of guest memory 'ppc_spapr.ram'".  Harmless
# elsewhere.
ulimit -d "$(ulimit -H -d)" 2>/dev/null || true
echo "datasize limit for the tests: $(ulimit -d) KiB"

export QTEST_QEMU_BINARY=./qemu-system-ppc64 QTEST_QEMU_IMG=./qemu-img
export QTEST_QEMU_STORAGE_DAEMON_BINARY=./storage-daemon/qemu-storage-daemon
: > "$LOGS/status.txt"

section "all qos tests (unloaded, once, no arguments)"
rc=0
./tests/qtest/qos-test 2>&1 | tee "$LOGS/virtio.log" || rc=$?
grep -q '^not ok' "$LOGS/virtio.log" && rc=1
result "all qos tests" $rc

section "diagnostic run (migrate subtest with vhost-user and chardev tracing)"
QTEST_QEMU_BINARY="./qemu-system-ppc64 -trace vhost_user_* -trace chr_socket_*" \
    ./tests/qtest/qos-test -p "${RECONNECT%/reconnect}/migrate" 2>&1 | tee "$LOGS/diag.log" || true

section "stress run (six qtests in parallel, five repetitions)"
rc=0
$MAKE -j6 check-qtest-ppc64 MTESTARGS="--repeat 5 $PPC64_TESTS" 2>&1 | tee "$LOGS/stress.log" || rc=$?
result "stress run" $rc

section "reconnect loop under CPU load"
hogs=""
for i in $(seq 1 $((NCPU * 2))); do yes > /dev/null & hogs="$hogs $!"; done
fails=0
for i in $(seq 1 30); do
    if ./tests/qtest/qos-test -p "$RECONNECT" > "$LOGS/loop-$i.log" 2>&1; then
        echo "iteration $i: ok"
    else
        echo "iteration $i: FAILED"; fails=$((fails + 1))
    fi
done
kill $hogs
status "loop failures: $fails/30"

finish 0
