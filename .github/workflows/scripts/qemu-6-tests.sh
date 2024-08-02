#!/usr/bin/env bash

######################################################################
# 6) load openzfs module and run the tests
#
# called via runner:
# - qemu-6-tests.sh $OS $VMs
#
# called on qemu machine:
# - qemu-6-tests.sh $OS $VMcur $VMmax
######################################################################

set -o pipefail

# called directly on the runner
if [ -f /var/tmp/vms.txt ]; then
  OS=`cat /var/tmp/os.txt`
  VMs=`cat /var/tmp/vms.txt`

  P="/var/tmp"
  SSH=`which ssh`
  BASE="$HOME/work/zfs/zfs"
  TESTS='$HOME/zfs/.github/workflows/scripts/qemu-6-tests.sh'
  COLOR="$BASE/scripts/zfs-tests-color.sh"

  cd $P
  df -h /mnt/tests > df-prerun.txt
  for i in `seq 1 $VMs`; do
    IP="192.168.122.1$i"
    daemonize -c $P -p vm${i}.pid -o vm${i}log.txt -- \
      $SSH zfs@$IP $TESTS $OS $i $VMs
    # give us the output of stdout + stderr - with prefix ;)
    tail -fq vm${i}log.txt | $COLOR | sed -e "s/^/vm${i}: /g" &
    echo $! > vm${i}log.pid
  done

  # wait for all vm's to finish
  for i in `seq 1 $VMs`; do
    tail --pid=`cat vm${i}.pid` -f /dev/null
    pid=`cat vm${i}log.pid`
    rm -f vm${i}log.pid
    kill $pid
  done

  # df statistics - keep an eye on disk usage
  du -sh /mnt/tests >> df-postrun.txt
  df -h /mnt/tests >> df-postrun.txt

  exit 0
fi

# called within vm
export PATH="$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/sbin:/usr/local/bin"

case "$1" in
  freebsd*)
    # when freebsd's zfs is loaded, unload this one
    sudo kldstat -n zfs 2>/dev/null && sudo kldunload zfs
    sudo -E ./zfs/scripts/zfs.sh
    sudo dmesg -c > /var/tmp/dmesg-prerun.txt
    TDIR="/usr/local/share/zfs"
    ;;
  *)
    sudo -E modprobe zfs
    sudo dmesg -c > /var/tmp/dmesg-prerun.txt
    TDIR="/usr/share/zfs"
    ;;
esac

# this part runs inside qemu, finally: run tests
cd /var/tmp
uname -a > uname.txt

# ONLY FOR TESTING DO NOT COMMIT
#
TAGS=$2/$3

# TAGS=raidz

# run functional testings
$TDIR/zfs-tests.sh -vK -s 3G -T $TAGS
RV=$?

# we wont fail here, this will be done later
echo $RV > exitcode.txt
exit 0
