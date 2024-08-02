#!/usr/bin/env bash

######################################################################
# 7) output the results of the previous stage in an ordered way
######################################################################

set -o pipefail

cd /var/tmp
OS=`cat os.txt`

# build failed
if [ ! -s vms.txt ]; then
  scp -r 2>/dev/null zfs@192.168.122.10:/var/tmp .
  tar cf /tmp/qemu-$OS.tar -C /var/tmp -h . || true
  exit 0
fi

VMs=`cat vms.txt`

# build was okay
echo "********************************************************************"
echo "Disk usage before:"
cat df-prerun.txt

echo "Disk usage afterwards:"
cat df-postrun.txt
echo "********************************************************************"

FAIL="[1;91mFAIL[0m"
PASS="[92mPASS[0m"

BASE="$HOME/work/zfs/zfs"

# exit code of testing, default is "all good 0"
RV=0

for i in `seq 1 $VMs`; do
  f="exitcode.vm$i"
  scp 2>/dev/null zfs@192.168.122.1$i:/var/tmp/exitcode.txt $f
  test -f $f || echo 2 > $f
  rv=`cat $f`
  if [ $rv != 0 ]; then
    msg=$FAIL
    RV=$rv
  else
    msg=$PASS
  fi

  echo "##[group]Results vm$i [$msg]"
  cat "vm${i}log.txt" | $BASE/scripts/zfs-tests-color.sh
  echo "##[endgroup]"
done

RESPATH="/var/tmp/test_results"

# all tests without grouping:
MERGE="$BASE/.github/workflows/scripts/merge_summary.awk"
$MERGE vm*log.txt | $BASE/scripts/zfs-tests-color.sh | tee $RESPATH/summary.txt

for i in `seq 1 $VMs`; do
  rsync -arL zfs@192.168.122.1$i:$RESPATH/current $RESPATH/vm$i || true
  scp zfs@192.168.122.1$i:"/var/tmp/*.txt" $RESPATH/vm$i || true
done
cp -f /var/tmp/*.txt $RESPATH || true


# Save a list of all failed test logs for easy access
awk '/\[FAIL\]|\[KILLED\]/{ show=1; print; next; }; /\[SKIP\]|\[PASS\]/{ show=0; } show' \
    $RESPATH/vm*/current/log >> $RESPATH/summary-failure-logs.txt

cp $RESPATH/summary.txt $RESPATH/summary-with-logs.txt
cat $RESPATH/summary-failure-logs.txt >> $RESPATH/summary-with-logs.txt

tar cf /tmp/qemu-$OS.tar -C $RESPATH -h . || true

echo "********************************************************************"

echo "TODO: debug messages ..."
echo "TODO: serial messages ..."
echo "TODO: dmesg messages ..."

# FreeBSD findings:
# lock order reversal: -> FreeBSD problem
#
# Linux findings:
# "] PANIC at " .. "]  </TASK>" -> Linux Ops

echo "********************************************************************"
exit $RV
