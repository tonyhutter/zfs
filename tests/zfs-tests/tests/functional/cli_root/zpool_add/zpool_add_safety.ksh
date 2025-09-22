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

# Copyright (c) 2025 by Lawrence Livermore National Security, LLC.

. $STF_SUITE/include/libtest.shlib

verify_runnable "global"
TESTPOOL=testpool

function cleanup
{
	destroy_pool $TESTPOOL
	rm -f $TEST_BASE_DIR/file-vdev-{1..9}
}

log_assert "Verify 'zpool add' safety checks work"

log_must truncate -s 100M $TEST_BASE_DIR/file-vdev-{1..9}
log_must zpool create $TESTPOOL draid1:5d:8c:2s $TEST_BASE_DIR/file-vdev-{1..8}

# Our safety should not let us add a single vdev in raid0 with the draid group
log_mustnot zpool add $TESTPOOL $TEST_BASE_DIR/file-vdev-9

log_must zpool replace $TESTPOOL $TEST_BASE_DIR/file-vdev-8 draid1-0-0
log_must zpool detach $TESTPOOL $TEST_BASE_DIR/file-vdev-8

# Test for bug https://github.com/openzfs/zfs/issues/17756
log_mustnot zpool add $TESTPOOL $TEST_BASE_DIR/file-vdev-9

log_onexit cleanup

log_pass "'zpool add' safety checks work correctly"
