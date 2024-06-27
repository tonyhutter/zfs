#!/usr/bin/env bash

######################################################################
# 7) output the results of the previous stage in an ordered way
######################################################################

NUM_VMS=$1

set -o pipefail
ZFSDIR="$(pwd)"
cd /var/tmp

echo "VM disk usage before:"
cat disk-before.txt
echo "and afterwards:"
cat disk-afterwards.txt

exitcode=0
for i in `seq 1 $NUM_VMS`; do
  f="exitcode.vm$i"
  scp 2>/dev/null zfs@192.168.122.1$i:/var/tmp/exitcode.txt $f
  test -f $f || echo 2 > $f

  rv=`cat $f`
  if [ $rv != 0 ]; then
    msg="[1;91mFAIL[0m -> rv=$rv"
    exitcode=$rv
  else
    msg="[92mPASS[0m"
  fi

  echo "##[group]Summary vm$i [$msg]"
  cat "vm${i}log.txt" | grep -v 'Test[ :]'
  echo "##[endgroup]"

  echo "##[group]Results vm$i [$msg]"
  cat "vm${i}log.txt"
  echo "##[endgroup]"
done

# Merge all summaries
echo "Merging summaries1, zfsdir $ZFSDIR"
echo "current dir: $(ls -l)"
echo "homedir dir: $(ls -l ~)"

# The 'sed' line here removes ANSI color.  This is needed for merge_summary.awk
# to work.  We add the color back in on the final line.
cat vm*log.txt | grep -v 'Test[ :]' | \
    sed -e 's/\x1b\[[0-9;]*m//g' | \
    $ZFSDIR/.github/workflows/scripts/merge_summary.awk | \
    $ZFSDIR/scripts/zfs-tests-color.sh

exit $exitcode
