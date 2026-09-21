# Monitor stats from VMs, and our own stats
#
# USAGE:
#
# 	all_ci_stats <VMs> <seconds>
#
# Record stats every 'seconds' number of seconds
VMs=$1
seconds=$2

title="date CPU MemTotal MemFree SwapTotal SwapFree DiskTotal DiskFree"
echo "$title" > /var/tmp/runner_stats.txt
for i in $VMs ; do
	echo "$title" > /var/tmp/vm${i}_stats.txt
done

while [ 1 ]  ; do
	# Write our own stats
	./ci-stats.sh >> /var/tmp/runner_stats.txt
	
	# Get and write VM stats.  It's ok if a VM doesn't respond, since it
	# could have crashed.
	for vm in "fedora42" "fedora43" ; do
		ssh -o ConnectTimeout=1 hutter@$vm \
		    $HOME/zfs/.github/workflows/scripts/ci-stats.sh 2>/dev/null >> /var/tmp/vm${i}_stats.txt || true
	done
	sleep $seconds
	wait
done
