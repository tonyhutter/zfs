#!/bin/awk -f
#
# Merge multiple ZTS tests results summaries into a single summary.  This is
# needed when you're running different parts of ZTS on different tests
# runners or VMs.
#
# Usage:
#
#	./merge_summary.awk summary1.txt [summary2.txt] [summary3.txt] ...
#
#	or:
#
#	cat summary*.txt | ./merge_summary.awk
#
# NOTE!!! Make sure all ANSI color is removed before running this script or
# it's not going to work correctly.  To remove ANSI colors:
#
#	sed -e 's/\x1b\[[0-9;]*m//g'
#
BEGIN {
	i=-1
	pass=0
	fail=0
	skip=0
	state="config_lines"
	cl=0
	el=0
	epl=0
	ul=0

	# Total seconds of tests runtime
	total=0;
}

/Configuration/{
	i++;
	if (state != "config_lines") {
		# new file, clear our state
		state="";
	}
}

# Skip empty lines
/^\s*$/{next}

# When we see "test-runner.py" stop saving config lines, and
# save test runner lines
/test-runner.py/{state="testrunner"; runner=runner$0"\n"; next}

# We need to differentiate the PASS counts from test result lines that start
# with PASS, like:
#
#   PASS mv_files/setup
#
# Use state="pass_count" to differentiate
#
/Results Summary/{state="pass_count"; next}
/PASS/{ if (state=="pass_count") {pass += $2}}
/FAIL/{ if (state=="pass_count") {fail += $2}}
/SKIP/{ if (state=="pass_count") {skip += $2}}
/Running Time/{
	state="";
	running[i]=$3;
	split($3, arr, ":")
	total += arr[1] * 60 * 60;
	total += arr[2] * 60;
	total += arr[3]
	next;
}

# Just save the log directory from the first summary since we probably don't
# care what the value is.
/Log directory/{if (i == 0) {logdir_line=$0"\n"}; next}
/Tests with results other than PASS that are expected/{state="expected_lines"; next}
/Tests with result of PASS that are unexpected/{state="unexpected_pass_lines"; next}
/Tests with results other than PASS that are unexpected/{state="unexpected_lines"; next}
{
	# Save the opening configuration lines from first summary file.  These
	# should be relatively common to all the summaries.
	if (state == "config_lines") {
		config_lines[cl] = $0
		cl++;
	}

	if (state == "expected_lines") {
		expected_lines[el] = $0
		el++
	}

	if (state == "unexpected_pass_lines") {
		unexpected_pass_lines[upl] = $0
		upl++
	}
	if (state == "unexpected_lines") {
		unexpected_lines[ul] = $0
		ul++
	}
}

# Reproduce summary
END {
	for (j in config_lines)
		print config_lines[j]
	print ""
	print runner;
	print "  Results Summary"
	print "  PASS\t"pass
	print "  FAIL\t"fail
	print "  SKIP\t"skip
	print ""
	print "  Running Time:\t"strftime("%T", total, 1)

	percent_passed=(pass/(pass+fail+skip) * 100)
	printf "  Percent passed:\t%3.2f%\n", percent_passed
	print logdir_line
	print "  Tests with results other than PASS that are expected:"
	for (j in expected_lines)
		print expected_lines[j]
	print ""
	print "  Tests with result of PASS that are unexpected:"
	for (j in unexpected_pass_lines)
		print unexpected_pass_lines[j]
	print ""
	print "  Tests with results other than PASS that are unexpected:"
	for (j in unexpected_lines)
		print unexpected_lines[j]
}
