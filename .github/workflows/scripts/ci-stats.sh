#!/usr/bin/env bash
#
# Output:
# UNIX_timestamp CPU_usage% MemTotal MemAvailable SwapTotal SwapFree DiskSize DiskFree
#
# Mem/swap/disk sizes in MB

# Use the date format from ZTS reporting, so we can correlate our samples to
# the ZTS test times in the graph.
echo -n "$(date +%T.%6N)"
if uname | grep -qi bsd ; then 
	# Load average
	load=$(sysctl -n vm.loadavg | grep -Eo -m 1 '[0-9\.]+' | head -n 1)

	# Total memory
	total=$(( $(sysctl -n hw.realmem)  / 1024 / 1024))

	# Available memory
	avail=$((($(sysctl -n vm.stats.vm.v_free_count) + $(sysctl -n vm.stats.vm.v_inactive_count) + $(sysctl -n vm.stats.vm.v_cache_count)) * $(sysctl -n vm.stats.vm.v_page_size) / 1024 / 1024 ))

	# Swap total / avail
	swap="$(swapinfo -m | awk '/\/dev/{print $2" "$4}')"

	echo -n "$load $total $avail $swap "

else
	awk '{printf $1" "}' /proc/loadavg
	awk '/MemTotal:|MemFree:|SwapTotal:|SwapFree:/{printf "%lu ", $2/1024};' /proc/meminfo
fi

# Works on both Linux and FreeBSD
df -k /var/tmp/ | awk '/\/dev/{printf "%lu %lu", $2/1024, $4/1024}'
echo
