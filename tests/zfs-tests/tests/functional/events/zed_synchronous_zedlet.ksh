#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2025 by Lawrence Livermore National Security, LLC.
#

# DESCRIPTION:
# Verify ZED synchronous zedlets work as expected
#
# STRATEGY:
# 1. Create a scrub_start zedlet that runs quickly
# 2. Create a scrub_start zedlet that runs slowly (takes seconds)
# 3. Create a scrub_finish zedlet that is synchronous
# 4. Scrub the pool
# 5. Verify the synchronous scrub_finish zedlet waited for the scrub_start
#    zedlets to finish (including the slow one).  If the scrub_finish zedlet
#    was not synchronous, it would have completed before the slow scrub_start
#    zedlet.

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/events/events_common.kshlib

verify_runnable "both"

OUR_ZEDLETS="scrub_start-async.sh scrub_start-slow.sh scrub_finish-sync-test.sh"

OUTFILE="$TESTDIR/zed_synchronous_zedlet_lines"

function cleanup
{

	log_must zed_stop
	log_must zed_cleanup_zedlets $OUR_ZEDLETS
	for i in $OUR_ZEDLETS ; do
		rm $TESTDIR/$i
	done
	rm -f $OUTFILE
}

# Create zedlets
cat << EOF > $TESTDIR/scrub_start-async.sh
#!/bin/ksh -p
echo "\$(date) \$(basename \$0)"  >> $OUTFILE
EOF

cat << EOF > $TESTDIR/scrub_start-slow.sh
#!/bin/ksh -p
sleep 3
echo "\$(date) \$(basename \$0)"  >> $OUTFILE
EOF

cat << EOF > $TESTDIR/scrub_finish-sync-test.sh
#!/bin/ksh -p
echo "\$(date) \$(basename \$0)"  >> $OUTFILE
EOF

for i in $OUR_ZEDLETS ; do
	chmod +x $TESTDIR/$i
done

log_assert "Verify ZED synchronous zedlets work as expected"
log_onexit cleanup

# Do an initial scrub
log_must zpool scrub -w $TESTPOOL

log_must zpool events -c
log_must zed_stop

# Copy our custom zedlets to the zed.rc directory
log_must zed_setup_zedlets $TESTDIR/scrub_start-async.sh $TESTDIR/scrub_start-slow.sh \
	$TESTDIR/scrub_finish-sync-test.sh

log_must zed_start

# Continue scrub from where out last scrub TXG.  We haven't written anything
# so the scrub should be instantaneous, which is the goal.
log_must zpool scrub -C -w $TESTPOOL

log_must file_wait_event $ZED_DEBUG_LOG 'sysevent\.fs\.zfs\.scrub_finish' 10
log_note "zedlet output was: $(echo && cat $OUTFILE)"

# If our zedlets were run in the right order, with sync correctly honored, you
# will see this ordering in $OUTFILE:
#
# Thu Apr 10 14:47:00 PDT 2025 scrub_start-async.sh
# Thu Apr 10 14:47:07 PDT 2025 scrub_start-slow.sh
# Thu Apr 10 14:47:08 PDT 2025 scrub_finish-sync-test.sh
#
# Check for this ordering

# Get a list of just the script names in the order they were executed
# from OUTFILE
lines="$(echo $(grep -Eo 'scrub_.+\.sh$' $OUTFILE))"

# Compare it to the ordering we expect
expected="scrub_start-async.sh scrub_start-slow.sh scrub_finish-sync-test.sh"
log_must test "$lines" == "$expected"

log_pass "Verified synchronous zedlets"
