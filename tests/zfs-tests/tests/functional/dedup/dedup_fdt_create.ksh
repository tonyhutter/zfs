#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
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
# Copyright (c) 2024 Klara, Inc.
#

# Simple test of dedup table operations (FDT)

. $STF_SUITE/include/libtest.shlib

log_assert "basic dedup (FDT) operations work"

# we set the dedup log txg interval to 1, to get a log flush every txg,
# effectively disabling the log. without this it's hard to predict when and
# where things appear on-disk
log_must save_tunable DEDUP_LOG_TXG_MAX
log_must set_tunable32 DEDUP_LOG_TXG_MAX 1

function cleanup
{
	destroy_pool $TESTPOOL
	log_must restore_tunable DEDUP_LOG_TXG_MAX
}

log_onexit cleanup

# create a pool with fast dedup enabled. we disable block cloning to ensure
# it doesn't get in the way of dedup, and we disable compression so our writes
# create predictable results on disk
# Use 'xattr=sa' to prevent selinux xattrs influencing our accounting
log_must zpool create -f \
    -o feature@fast_dedup=enabled \
    -O dedup=on \
    -o feature@block_cloning=disabled \
    -O compression=off \
    -O xattr=sa \
    $TESTPOOL $DISKS

# confirm the feature is enabled
log_must test $(get_pool_prop feature@fast_dedup $TESTPOOL) = "enabled"

# confirm there's no DDT keys in the MOS root
log_mustnot eval "zdb -dddd $TESTPOOL 1 | grep -q DDT-sha256"

# create a file. this is four full blocks, so will produce four entries in the
# dedup table
log_must dd if=/dev/urandom of=/$TESTPOOL/file1 bs=128k count=4
log_must zpool sync

# feature should now be active
log_must test $(get_pool_prop feature@fast_dedup $TESTPOOL) = "active"

# four entries in the unique table
log_must eval "zdb -D $TESTPOOL | grep -q 'DDT-sha256-zap-unique:.*entries=4'"

# single containing object in the MOS
log_must test $(zdb -dddd $TESTPOOL 1 | grep DDT-sha256 | wc -l) -eq 1
obj=$(zdb -dddd $TESTPOOL 1 | grep DDT-sha256 | awk '{ print $NF }')

# with only one ZAP inside
log_must test $(zdb -dddd $TESTPOOL $obj | grep DDT-sha256-zap- | wc -l) -eq 1

# copy the file
log_must cp /$TESTPOOL/file1 /$TESTPOOL/file2
log_must zpool sync

# now four entries in the duplicate table
log_must eval "zdb -D $TESTPOOL | grep -q 'DDT-sha256-zap-duplicate:.*entries=4'"

# now two DDT ZAPs in the container object; DDT ZAPs aren't cleaned up until
# the entire logical table is destroyed
log_must test $(zdb -dddd $TESTPOOL $obj | grep DDT-sha256-zap- | wc -l) -eq 2

# remove the files
log_must rm -f /$TESTPOOL/file*
log_must zpool sync

# feature should move back to enabled
log_must test $(get_pool_prop feature@fast_dedup $TESTPOOL) = "enabled"

# all DDTs empty
log_must eval "zdb -D $TESTPOOL | grep -q 'All DDTs are empty'"

# logical table now destroyed; containing object destroyed
log_must test $(zdb -dddd $TESTPOOL 1 | grep DDT-sha256 | wc -l) -eq 0

log_pass "basic dedup (FDT) operations work"
