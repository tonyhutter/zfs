// SPDX-License-Identifier: CDDL-1.0
/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or https://opensource.org/licenses/CDDL-1.0.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * Copyright (c) 2023 by iXsystems, Inc.
 */

#include <sys/zfs_context.h>
#include <sys/spa.h>
#include <sys/spa_impl.h>
#include <sys/vdev.h>
#include <sys/vdev_impl.h>

/*
 * Check if the reserved boot area is in-use. This is called from
 * spa_vdev_attach() when adding a device to a raidz vdev, to ensure that the
 * reserved area is available as scratch space for raidz expansion.
 *
 * This function currently always returns 0. On Linux, there are no known
 * external uses of the reserved area. On FreeBSD, the reserved boot area is
 * used when booting to a ZFS root from an MBR partition.
 *
 * Currently nothing using libzpool can add a disk to a pool, so this does
 * nothing.
 */
int
vdev_check_boot_reserve(spa_t *spa, vdev_t *childvd)
{
	(void) spa;
	(void) childvd;

	return (0);
}
