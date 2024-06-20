#!/usr/bin/env bash

######################################################################
# 7) output the results of the previous stage in an ordered way
######################################################################

set -o pipefail
cd /var/tmp

echo "VM disk usage before:"
cat disk-before.txt
echo "and afterwards:"
cat disk-afterwards.txt

exitcode=0
for i in `seq 1 3`; do
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

exit $exitcode
