set grid

# SVG output, 4k resolution
set terminal svg size 3840,1500 dynamic noenhanced dashed font "Helvetica, 14" background rgb "white"
set output "graph.svg"

# On the VMs, the swap can be zero and so we don't want to graph it.
stats ARG2 using 6 nooutput
swap=1
if (STATS_min == 0 && STATS_max == 0) {
	swap = 0
}

# X-axis handles dates/times
set xdata time

# Our time series data in in Unix Timestamps.  The %S here accepts fractional
# seconds.
set timefmt "%H:%M:%S"

# Display times as hour:minute
set format x "%H:%M"

# Use the first line as column titles
set key autotitle columnhead

# Setup SVG to contain our three graphs
set multiplot layout 3,1 title ARG1 margins 0.1, 0.9, 0.1, 0.9 spacing 0.05

set label "Note: Test group markers signify the end the test.\n  A test mark with a slash '/' like 'test1/test2' marks the end of test1, with test2 only taking a tiny amount of time after.\n CPU usage samples represent 1min average" at screen 0.5, screen 0.05 center

# Mark the test groups on the X-axis.  Make the font really small.
set xtics font ",4"
load 'tics.gp'
set xtics rotate by 45 right

# Data format:
# date CPU MemTotal MemFree MemAvailable SwapCached SwapTotal SwapFree

# Enable the secondary Y-axis tics on the right side
set y2tics

# "stolen" ticks increases over time.  Calculate the difference.  This is
# used to see when our VM is being throttled.
back2 = back1 = 0
shift(x) = (back2 = back1, back1 = x)

# Plot CPU usage
set ylabel "CPUs percentage" font "Helvetica,16"
set y2label "Change in 'stolen' tics (VM throttle)" font "Helvetica,16"

plot ARG2 using 1:2 axes x1y1 with lines title "CPU" lw 1 linecolor "gold", \
       '' using 1:(shift($9), $0 < 1 ? 1/0 : $9 - back2) axes x1y2 with lines title "VM throttled" lw 1 linecolor "purple"

# Plot memory & swap
set ylabel "Mem (MB)" font "Helvetica,,16"
if (swap == 1) {
	set y2label "Swap (MB)" font "Helvetica,,16"
	plot ARG2 using 1:3 axes x1y1 with lines title "MemTotal" linecolor "dark-red" dashtype 1, \
		'' using 1:4 axes x1y1 with lines title "MemFree" lw 1 linecolor "dark-red", \
		'' using 1:5 axes x1y2 with lines title "SwapTotal" linecolor "dark-green" dashtype 2, \
		'' using 1:6 axes x1y2 with lines title "SwapFree" lw 1 linecolor "dark-green"
	unset y2label
} else {
	plot ARG2 using 1:3 axes x1y1 with lines title "MemTotal" linecolor "dark-red" dashtype 1, \
		'' using 1:4 axes x1y1 with lines title "MemFree" lw 1 linecolor "dark-red"
}

# Plot disk usage
set ylabel "Disk (MB)" font "Helvetica,,16"
plot ARG2 using 1:7 with lines axes x1y1 title "DiskTotal" linecolor "dark-blue" dashtype 2, \
	'' using 1:8 with lines axes x1y1 title "DiskFree" lw 1 linecolor "dark-blue"
