#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# This file and its contents are supplied under the terms of the
# Common Development and Distribution License ("CDDL"), version 1.0.
# You may only use this file in accordance with the terms of version
# 1.0 of the CDDL.
#
# A full copy of the text of the CDDL should have accompanied this
# source.  A copy of the CDDL is also available via the Internet at
# https://opensource.org/license/CDDL-1.0.
#

#
# Copyright 2007 Sun Microsystems, Inc.  All rights reserved.
# Use is subject to license terms.
#

. $STF_SUITE/include/libtest.shlib

#
# DESCRIPTION:
#
# Verify you can't vdev attach as a regular user with 'unshare'

verify_runnable "global"

log_assert "Verify we can't vdev attach as regular user with 'unshare'"

ZFSUSER=zfsuser
ZFSGROUP=zfsgroup

log_onexit cleanup

function cleanup
{
	del_user $ZFSUSER
	del_group $ZFSGROUP
	rm -f $FILE_VDEV
	chmod $oldperms /dev/$DISK2
}

read DISK1 DISK2 DISK3 <<< "$DISKS"
guid=$(get_vdev_prop guid $TESTPOOL $DISK1)

log_must add_group $ZFSGROUP
log_must add_user $ZFSGROUP $ZFSUSER

echo "DISK: $DISK1, $DISK2, $DISK3"

DISK1_SIZE=$(lsblk -dbn -o size /dev/$DISK1)
FILE_VDEV=$TEST_BASE_DIR/vdev-file-user_namespace
truncate -s $DISK1_SIZE $FILE_VDEV

# Make /dev/loop1 user accessible
oldperms=$(stat -c "%a" /dev/$DISK2)
chmod o+rwx /dev/$DISK2

# Try create & attach using both a file vdev and a user-accessible block device
for vdev in $FILE_VDEV /dev/$DISK2 ; do
	# Try creating a new pool with 'unshare'.  We can't just check the
	# return code since the pool could have been created but failed to
	# mount, so check for the existence of the pool itself.
	user_run $ZFSUSER unshare -Ur zpool create testpool2 $vdev
	if zpool status testpool2 2>&1 ; then
		zpool status testpool2
		zpool destroy testpool2
		log_fail "Unexpectedly created pool with $vdev using 'unshare'"
	fi

	# Try attaching a disk/file with 'unshare'.  It should fail
	if user_run $ZFSUSER unshare -Ur attach_test $TESTPOOL $guid $vdev ; then
		zpool status $TESTPOOL
		zpool detach $TESTPOOL $vdev
		log_fail "Unexpectedly attached $vdev using 'unshare'"
	fi
done

log_pass "Regular user fails to create or attach using 'unshare' as expected"
