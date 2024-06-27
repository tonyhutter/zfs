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
  SSH=`which ssh`
  CMD='$HOME/zfs/.github/workflows/scripts/qemu-6-tests.sh'

  df -h /mnt > df-prerun.txt
  for i in $(seq 1 $NUM_VMS) ; do
      LAST=$((10 + $i))
      IP="192.168.122.$LAST"

      # start as daemon and log stdout
         daemonize -c $P -p vm$i.pid -o vm${i}log.txt -- \
        $SSH zfs@$IP $CMD $OS "$i/$NUM_VMS"

      # give us the output of stdout + stderr - with prefix ;)
      tail -fq vm${i}log.txt | sed -e "s/^/vm"$i": /g" &
  done

  for i in $(seq 1 $NUM_VMS) ; do
      # wait for all vm's to finnish
      tail --pid=`cat vm${i}.pid` -f /dev/null
  done

  df -h /mnt > df-postrun.txt
  du -sh /mnt/openzfs.qcow2 >> df-postrun.txt

  for i in $(seq 1 $NUM_VMS) ; do
      du -sh /mnt/vm$i.qcow2 >> df-postrun.txt
  done

  # kill the tail/sed combo
  killall tail
  exit 0
else
    # Called from inside VM
    OS="$1"
    FRACTION="$2"
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
    TDIR="/usr/share/zfs"
    linux
    ;;
esac

# this part runs inside qemu, finally: run tests
cd /var/tmp
uname -a > /var/tmp/uname.txt
cd $HOME/zfs
$TDIR/zfs-tests.sh -vKR -s 3G -T $FRACTION | scripts/zfs-tests-color.sh
RV=$?
echo $RV > /var/tmp/exitcode.txt

# exit $RV
exit 0
