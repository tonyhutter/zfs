#!/usr/bin/env bash

######################################################################
# 6) load openzfs module and run the tests
######################################################################

set -o pipefail

# There's two ways this script gets run, on the runner or on the VM.
# The args are a little different
#
# On the runner
# ./qemu-6-tests.sh [OS] [num_vms]
#
# On the VM
# ./qemu-6-tests.sh [group/all]
#
# Examples:
#
# Run tests on three VMs
# ./qemu-6-tests.sh 3
#
# Divide the test list up into thirds, and run the 2nd group of tests
# of the three on fedora40.
# ./qemu-6-tests.sh fedora40 2/3 

if [ -z "$2" ]; then
  NUM_VMS=$1

  # called directly on the runner
  P="/var/tmp"

  cd $P
  OS=`cat os.txt`

  df -h / /mnt > /var/tmp/disk-before.txt
  for i in $(seq 1 $NUM_VMS) ; do
      LAST_DIGIT=((11 + $i))
      IP="192.168.122.$LAST_DIGIT"

      # start as daemon and log stdout
      SSH=`which ssh`
      CMD='$HOME/zfs/.github/workflows/scripts/qemu-6-tests.sh'
      daemonize -c $P -p vm$i.pid -o vm${i}log.txt -- \
        $SSH zfs@$IP $CMD $OS "$i/$NUM_VMS"

      # give us the output of stdout + stderr - with prefix ;)
      tail -fq vm${i}log.txt | sed -e "s/^/vm"$i": /g" &

      # wait for all vm's to finnish
      tail --pid=`cat vm${i}.pid` -f /dev/null
  done

  # kill the tail/sed combo
  killall tail
  df -h / /mnt > /var/tmp/disk-afterwards.txt
  exit 0
else
    # Called from inside VM
    OS=$1
    FRACTION=$2
fi

function freebsd() {
  # when freebsd zfs is loaded, unload this one
  kldstat -n zfs 2>/dev/null && sudo kldunload zfs
  sudo dmesg -c > /var/tmp/dmesg-prerun.txt
  sudo -E ./scripts/zfs.sh
  sudo dmesg -c > /var/tmp/dmesg-module-load.txt
  sudo kldstat -n openzfs
}

function linux() {
  sudo dmesg -c > /var/tmp/dmesg-prerun.txt
  sudo -E modprobe zfs
  sudo dmesg -c > /var/tmp/dmesg-module-load.txt
}

function gettests() {
  TF="$TDIR/zfs-tests/tests/functional"
  echo -n "-T "
  case "$1" in
    part1)
      # ~1h 40m (archlinux)
      echo "cli_root"
#    echo "zpool_add,zpool_create,zpool_export"
      ;;
    part2)
      # ~2h 5m (archlinux)
      ls $TF|grep '^[a-m]'|grep -v "cli_root"|xargs|tr -s ' ' ','
#    echo "zfs_receive,zpool_initialize"
      ;;
    part3)
      # ~2h
      ls $TF|grep '^[n-z]'|xargs|tr -s ' ' ','
#    echo "zfs_unshare,zpool_destroy"
      ;;
  esac
}

function gettestsD() {
  TF="$TDIR/zfs-tests/tests/functional"
  echo -n "-T "
  case "$1" in
    part1)
      echo "checksum,zpool_trim"
      ;;
    part2)
      echo "casenorm,trim"
      ;;
    part3)
      echo "pool_checkpoint"
      ;;
  esac
}

# called within vm
export PATH="$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/sbin:/usr/local/bin"

case "$1" in
  freebsd*)
    TDIR="/usr/local/share/zfs"
    freebsd
#    OPTS=`gettestsD $2`
#    if [ -e /dev/vtbd1 ] && [ -e /dev/vtbd2 ] && [ -e /dev/vtbd3 ] ; then
#      DISKS="/dev/vtbd1 /dev/vtbd2 /dev/vtbd3"
#      export DISKS
#    fi
    ;;
  *)
    TDIR="/usr/share/zfs"
#    OPTS=`gettestsD $2`
    linux
#    if [ -e /dev/vdb ] && [ -e /dev/vdc ] && [ -e /dev/vdd ] ; then
#      DISKS="/dev/vdb /dev/vdc /dev/vdd"
#      export DISKS
#    fi
    ;;
esac

# this part runs inside qemu, finally: run tests
uname -a > /var/tmp/uname.txt
cd $HOME/zfs
$TDIR/zfs-tests.sh -vKR -s 3G -T $FRACTION | scripts/zfs-tests-color.sh
RV=$?
echo $RV > /var/tmp/exitcode.txt
exit $RV
