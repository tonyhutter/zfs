#!/usr/bin/env bash
# Monitor CPU/memory/swap/disk stats from both the VMs and the runner.
# This script is run on the runner.
#
# USAGE:
#
# 	all_ci_stats <VMs> <seconds>
#
# Record stats every 'seconds' number of seconds.  This will create the
# following files containing the stats:
#
# runner_stats.txt
# vm1_stats.txt
# vm2_stats.txt
# ...

VMs=$1
seconds=$2

title="date CPU MemTotal MemFree SwapTotal SwapFree DiskTotal DiskFree stolen"
echo "$title" > /var/tmp/runner_stats.txt
for i in $(seq 1 $VMs) ; do
	echo "$title" > /var/tmp/vm${i}_stats.txt
done

# The directory this script is run from also contains ci-stats.sh
SCRIPTS_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

while [ 1 ]  ; do
	# Write host stats
	$SCRIPTS_DIR/ci-stats.sh >> /var/tmp/runner_stats.txt

	# Collect and write out the VM stats.  It's ok if a VM doesn't respond
	# since it could have crashed.
	for i in $(seq 1 $VMs) ; do
		ssh -o ConnectTimeout=1 zfs@vm$i \
		    '$HOME/zfs/.github/workflows/scripts/ci-stats.sh' \
		    2>/dev/null >> /var/tmp/vm${i}_stats.txt || true
	done
	sleep $seconds
	wait
done
