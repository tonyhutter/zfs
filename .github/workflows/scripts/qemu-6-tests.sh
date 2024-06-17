#!/usr/bin/env bash

######################################################################
# 6) load openzfs module and run the tests
######################################################################

set -o pipefail

# force unsing these tests only:
TESTS="tests_functional"

# you can switch to some debugging tests here:
# TESTS="tests_debug"
function tests_debug() {
  TF="$TDIR/zfs-tests/tests/functional"
  echo -n "-T "
  case "$1" in
    part1)
      echo "checksum"
      ;;
    part2)
      echo "casenorm,trim"
      ;;
    part3)
      echo "cp_files"
      ;;
  esac
}

function tests_functional() {
  TF="$TDIR/zfs-tests/tests/functional"
  echo -n "-T "
  case "$1" in
    part1)
      # ~1h 30m @ Almalinux 9
      echo "cli_root"
      ;;
    part2)
      # ~1h 40m @ Almalinux 9
      ls $TF|grep '^[a-p]'|grep -v "cli_root"|xargs|tr -s ' ' ','
      ;;
    part3)
      # ~1h 50m @ Almalinux 9
      ls $TF|grep '^[q-z]'|xargs|tr -s ' ' ','
      ;;
  esac
}

if [ -z "$1" ]; then

  # called directly on the runner
  P="/var/tmp"
  cd $P
  df -h /mnt > df-prerun.txt

  # start as daemon and log stdout
  SSH=`which ssh`
  IP1="192.168.122.11"
  IP2="192.168.122.12"
  IP3="192.168.122.13"
  OS=`cat os.txt`
  CMD='$HOME/zfs/.github/workflows/scripts/qemu-6-tests.sh'

  daemonize -c $P -p vm1.pid -o vm1log.txt -- \
    $SSH zfs@$IP1 $CMD $OS part1
  daemonize -c $P -p vm2.pid -o vm2log.txt -- \
    $SSH zfs@$IP2 $CMD $OS part2
  daemonize -c $P -p vm3.pid -o vm3log.txt -- \
    $SSH zfs@$IP3 $CMD $OS part3

  # give us the output of stdout + stderr - with prefix ;)
  BASE="$HOME/work/zfs/zfs"
  CMD="$BASE/scripts/zfs-tests-color.sh"
  tail -fq vm1log.txt | $CMD | sed -e "s/^/vm1: /g" &
  tail -fq vm2log.txt | $CMD | sed -e "s/^/vm2: /g" &
  tail -fq vm3log.txt | $CMD | sed -e "s/^/vm3: /g" &

  # wait for all vm's to finnish
  tail --pid=`cat vm1.pid` -f /dev/null
  tail --pid=`cat vm2.pid` -f /dev/null
  tail --pid=`cat vm3.pid` -f /dev/null

  df -h /mnt > df-postrun.txt
  du -sh /mnt/openzfs.qcow2 >> df-postrun.txt
  du -sh /mnt/vm1.qcow2 >> df-postrun.txt
  du -sh /mnt/vm2.qcow2 >> df-postrun.txt
  du -sh /mnt/vm3.qcow2 >> df-postrun.txt

  # kill the tail/sed combo
  killall tail
  exit 0
fi

function freebsd() {
  # when freebsd zfs is loaded, unload this one
  kldstat -n zfs 2>/dev/null && sudo kldunload zfs
  sudo -E ./scripts/zfs.sh
  sudo kldstat -n openzfs
  sudo dmesg -c > /var/tmp/dmesg-prerun.txt
  TDIR="/usr/local/share/zfs"
}

function linux() {
  # remount rootfs with relatime + trim
  mount -o remount,rw,relatime,discard /
  sudo -E modprobe zfs
  sudo dmesg -c > /var/tmp/dmesg-prerun.txt
  TDIR="/usr/share/zfs"
}

# called within vm
export PATH="$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/sbin:/usr/local/bin"

case "$1" in
  freebsd*)
    freebsd
    ;;
  *)
    linux
    ;;
esac

# this part runs inside qemu, finally: run tests
cd /var/tmp
uname -a > /var/tmp/uname.txt

#    -h          Show this message
#    -v          Verbose zfs-tests.sh output
#    -q          Quiet test-runner output
#    -D          Debug; show all test output immediately (noisy)
#    -x          Remove all testpools, dm, lo, and files (unsafe)
#    -k          Disable cleanup after test failure
#    -K          Log test names to /dev/kmsg
#    -f          Use files only, disables block device tests
#    -S          Enable stack tracer (negative performance impact)
#    -c          Only create and populate constrained path
#    -R          Automatically rerun failing tests
#    -m          Enable kmemleak reporting (Linux only)
#    -n NFSFILE  Use the nfsfile to determine the NFS configuration
#    -I NUM      Number of iterations
#    -d DIR      Use world-writable DIR for files and loopback devices
#    -s SIZE     Use vdevs of SIZE (default: 4G)
#    -r RUNFILES Run tests in RUNFILES (default: common.run,freebsd.run)
#    -t PATH|NAME Run single test at PATH relative to test suite or search for test by NAME
#    -T TAGS     Comma separated list of tags (default: 'functional')
#    -u USER     Run single test as USER (default: root)
OPTS=`$TESTS $2`
$TDIR/zfs-tests.sh -vK -s 3G $OPTS

RV=$?
echo $RV > /var/tmp/exitcode.txt
exit $RV
