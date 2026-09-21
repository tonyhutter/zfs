#!/bin/bash
#
# Generate graphs of ZTS CPU/memory/disk/swap usage over time.
#
# This assumes the existence of vm*_stats.txt and runner_stats.txt files
# containing the resource usage logs
# $1: Full path to plot.gp

PLOTPATH="$1"

# Look at all the test completion times in the vm*logs.txt files and
# make tic marks on the X axis for them.
#
# $1: test result file to parse (like 'vm1logs.txt')
#
# This function outputs the gnuplot lines to add the tics.
function make_ticks {
	# Go though our test results files for the VMs, parse out when each test
	# group ended
	out="$( cat $1 | grep ' Test' | \
		sed -e 's/ (run as [a-z]\+)//g' | tr -d '[]' | tr '/' '\ ' | \
		awk 'BEGIN{name=""; last=""};
		{
			if (name=="") {
				# first entry
				name=$(NF-3)
				last=name
				last_num=$1
			} else if($(NF-3)!=last) {
				# New name, so print out last one
				print last_num" "last

				name=$(NF-3)
				last=name
				last_num=$1
			}
		};
		END{print $1" "$(NF-3)}' | tee /tmp/out)"

	# $out contains lines like:
	#
	# 19:21:42.118251 zfs_mount
	# 19:21:53.511293 zfs_promote
	# 19:21:55.990956 zfs_receive
	# 19:23:22.085425 zfs_reservation
	# 19:23:22.844702 zfs_rollback
	# 19:24:09.431932 zfs_set
	# 19:25:09.181524 zfs_snapshot
	# 19:25:27.264086 zfs_unload-key
	# 19:25:30.659305 zfs_unshare
	# 19:25:33.784610 zfs_wait
	# 19:25:37.158466 zinject
	#
	# Some of these lines are really close in time, like:
	#
	# 19:23:22.085425 zfs_reservation
	# 19:23:22.844702 zfs_rollback
	#
	# These lines will overlap each other on the graph and make them
	# unreadable.  Instead, concatenate them together like:
	#
	# 19:23:22.085425 zfs_reservation/zfs_rollback
	#
	# Any tests finishing within 6 seconds of the previous test is combined
	# together into one line.

	tmp="$(mktemp /tmp/make_ticks.XXXXXX)"

	last_name=""
	last_datetime=""
	while read -r datetime name ; do
		if [ "$last_name" == "" ] ; then
			# first entry
			last_name="$name"
			last_datetime="$datetime"
		elif [ "$last_name" != "$name" ] ; then
			# New named entry
			unix1=$(date -d $datetime +%s)
			unix2=$(date -d $last_datetime +%s)
			if [ $((unix1 - unix2)) -le 6 ] ; then
				# Glob together
				last_name="$last_name/$name"
				last_datetime=$datetime
			else
				echo "$datetime $last_name" >> "$tmp"
				last_name=$name
				last_datetime=$datetime
			fi
		fi
	done <<< "$out"
	echo -n "$datetime $name" >> "$tmp"
	sed -i 's/[[:space:]]*$//' "$tmp"

	echo -n "set xtics add ("
	while read -r datetime name ; do
		echo -n "\"$name\" \"$datetime\", "
	done <<< "$(cat $tmp)" | sed -e 's/, $//g'
	echo ")"

	rm "$tmp"
}
export -f make_ticks

# For each vm*log.txt file, make the tics from the test completion times
# and generate the graphs.
for i in $(ls -d * | grep -E 'vm[0-9]$') ; do
	make_ticks ${i}log.txt > tics.gp
	cat tics.gp >> runner_tics.gp
	gnuplot -c "$PLOTPATH" "$i" ${i}_stats.txt
	mv graph.svg $i.svg
done

# Now generate the runner's graph
rm tics.gp
mv runner_tics.gp tics.gp
gnuplot -c "$PLOTPATH" runner runner_stats.txt
mv graph.svg runner.svg
