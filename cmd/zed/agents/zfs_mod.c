/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or http://www.opensolaris.org/os/licensing.
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
 * Copyright (c) 2007, 2010, Oracle and/or its affiliates. All rights reserved.
 * Copyright (c) 2012 by Delphix. All rights reserved.
 * Copyright 2014 Nexenta Systems, Inc. All rights reserved.
 * Copyright (c) 2016, Intel Corporation.
 */

/*
 * ZFS syseventd module.
 *
 * file origin: openzfs/usr/src/cmd/syseventd/modules/zfs_mod/zfs_mod.c
 *
 * The purpose of this module is to identify when devices are added to the
 * system, and appropriately online or replace the affected vdevs.
 *
 * When a device is added to the system:
 *
 * 	1. Search for any vdevs whose devid matches that of the newly added
 *	   device.
 *
 * 	2. If no vdevs are found, then search for any vdevs whose udev path
 *	   matches that of the new device.
 *
 *	3. If no vdevs match by either method, then ignore the event.
 *
 * 	4. Attempt to online the device with a flag to indicate that it should
 *	   be unspared when resilvering completes.  If this succeeds, then the
 *	   same device was inserted and we should continue normally.
 *
 *	5. If the pool does not have the 'autoreplace' property set, attempt to
 *	   online the device again without the unspare flag, which will
 *	   generate a FMA fault.
 *
 *	6. If the pool has the 'autoreplace' property set, and the matching vdev
 *	   is a whole disk, then label the new disk and attempt a 'zpool
 *	   replace'.
 *
 * The module responds to EC_DEV_ADD events.  The special ESC_ZFS_VDEV_CHECK
 * event indicates that a device failed to open during pool load, but the
 * autoreplace property was set.  In this case, we deferred the associated
 * FMA fault until our module had a chance to process the autoreplace logic.
 * If the device could not be replaced, then the second online attempt will
 * trigger the FMA fault that we skipped earlier.
 *
 * ZFS on Linux porting notes:
 *	In lieu of a thread pool, just spawn a thread on demmand.
 *	Linux udev provides a disk insert for both the disk and the partition
 *
 */

#include <ctype.h>
#include <devid.h>
#include <fcntl.h>
#include <libnvpair.h>
#include <libzfs.h>
#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/list.h>
#include <sys/sunddi.h>
#include <sys/sysevent/eventdefs.h>
#include <sys/sysevent/dev.h>
#include <pthread.h>
#include <unistd.h>
#include "zfs_agents.h"
#include "../zed_log.h"

#define	DEV_BYID_PATH	"/dev/disk/by-id/"
#define	DEV_BYPATH_PATH	"/dev/disk/by-path/"

typedef void (*zfs_process_func_t)(zpool_handle_t *, nvlist_t *, boolean_t);

libzfs_handle_t *g_zfshdl;
list_t g_pool_list;	/* list of unavailable pools at initialization */
list_t g_device_list;	/* list of disks with asynchronous label request */
boolean_t g_enumeration_done;
pthread_t g_zfs_tid;

typedef struct unavailpool {
	zpool_handle_t	*uap_zhp;
	pthread_t	uap_enable_tid;	/* dataset enable thread if activated */
	list_node_t	uap_node;
} unavailpool_t;

typedef struct pendingdev {
	char		pd_physpath[128];
	list_node_t	pd_node;
} pendingdev_t;

static int
zfs_toplevel_state(zpool_handle_t *zhp)
{
	nvlist_t *nvroot;
	vdev_stat_t *vs;
	unsigned int c;

	verify(nvlist_lookup_nvlist(zpool_get_config(zhp, NULL),
	    ZPOOL_CONFIG_VDEV_TREE, &nvroot) == 0);
	verify(nvlist_lookup_uint64_array(nvroot, ZPOOL_CONFIG_VDEV_STATS,
	    (uint64_t **)&vs, &c) == 0);
	return (vs->vs_state);
}

static int
zfs_unavail_pool(zpool_handle_t *zhp, void *data)
{
	zed_log_msg(LOG_INFO, "zfs_unavail_pool: examining '%s' (state %d)",
	    zpool_get_name(zhp), (int)zfs_toplevel_state(zhp));

	if (zfs_toplevel_state(zhp) < VDEV_STATE_DEGRADED) {
		unavailpool_t *uap;
		uap = malloc(sizeof (unavailpool_t));
		uap->uap_zhp = zhp;
		uap->uap_enable_tid = 0;
		list_insert_tail((list_t *)data, uap);
	} else {
		zpool_close(zhp);
	}
	return (0);
}

/*
 * Remove partition suffix from a vdev path.  Partition suffixes may take three
 * forms: "-partX", "pX", or "X", where X is a string of digits.  The second
 * case only occurs when the suffix is preceded by a digit, i.e. "md0p0" The
 * third case only occurs when preceded by a string matching the regular
 * expression "^([hsv]|xv)d[a-z]+", i.e. a scsi, ide, virtio or xen disk.
 */
static void
zfs_strip_partition(char *path)
{
	char *part = NULL, *d = NULL;

	path = strrchr(path, '/');
	path++;

	if ((part = strstr(path, "-part")) && part != path) {
		d = part + 5;
	} else if ((part = strrchr(path, 'p')) &&
	    part > path + 1 && isdigit(*(part-1))) {
		d = part + 1;
	} else if ((path[0] == 'h' || path[0] == 's' || path[0] == 'v') &&
	    path[1] == 'd') {
		for (d = &path[2]; isalpha(*d); part = ++d);
	} else if (strncmp("xvd", path, 3) == 0) {
		for (d = &path[3]; isalpha(*d); part = ++d);
	}
	if (part && d && *d != '\0') {
		for (; isdigit(*d); d++);
		if (*d == '\0')
			*part = '\0';
	}
}

/*
 * Two stage replace on Linux
 * since we get disk notifications
 * we can wait for partitioned disk slice to show up!
 *
 * First stage tags the disk, initiates async partitioning, and returns
 * Second stage finds the tag and proceeds to ZFS labeling/replace
 *
 * disk-add --> label-disk + tag-disk --> partition-add --> zpool_vdev_attach
 *
 * 1. physical match with no fs, no partition
 *	tag it top, partition disk
 *
 * 2. physical match again, see partion and tag
 *
 */

/*
 * The device associated with the given vdev (either by devid or physical path)
 * has been added to the system.  If 'isdisk' is set, then we only attempt a
 * replacement if it's a whole disk.  This also implies that we should label the
 * disk first.
 *
 * First, we attempt to online the device (making sure to undo any spare
 * operation when finished).  If this succeeds, then we're done.  If it fails,
 * and the new state is VDEV_CANT_OPEN, it indicates that the device was opened,
 * but that the label was not what we expected.  If the 'autoreplace' property
 * is not set, then we relabel the disk (if specified), and attempt a 'zpool
 * replace'.  If the online is successful, but the new state is something else
 * (REMOVED or FAULTED), it indicates that we're out of sync or in some sort of
 * race, and we should avoid attempting to relabel the disk.
 *
 * Also can arrive here from a ESC_ZFS_VDEV_CHECK event
 */
static void
zfs_process_add(zpool_handle_t *zhp, nvlist_t *vdev, boolean_t labeled)
{
	char *path;
	vdev_state_t newstate;
	nvlist_t *nvroot, *newvd;
	pendingdev_t *device;
	uint64_t wholedisk = 0ULL;
	uint64_t offline = 0ULL;
	uint64_t guid = 0ULL;
	char *physpath = NULL, *new_devid = NULL;
	char rawpath[PATH_MAX], fullpath[PATH_MAX];
	char devpath[PATH_MAX];
	int ret;
	char *new_devname = NULL; /* UDEV device name (like /dev/sda) */

	if (nvlist_lookup_string(vdev, ZPOOL_CONFIG_PATH, &path) != 0)
		return;

	(void) nvlist_lookup_string(vdev, ZPOOL_CONFIG_PHYS_PATH, &physpath);
	(void) nvlist_lookup_uint64(vdev, ZPOOL_CONFIG_WHOLE_DISK, &wholedisk);
	(void) nvlist_lookup_uint64(vdev, ZPOOL_CONFIG_OFFLINE, &offline);
	(void) nvlist_lookup_uint64(vdev, ZPOOL_CONFIG_GUID, &guid);

	if (offline)
		return;  /* don't intervene if it was taken offline */

	zed_log_msg(LOG_INFO, "zfs_process_add: pool '%s' vdev '%s' (%llu)",
	    zpool_get_name(zhp), path, (long long unsigned int)guid);

	/*
	 * The VDEV guid is preferred for identification (gets passed in path)
	 */
	if (guid != 0) {
		(void) snprintf(fullpath, sizeof (fullpath), "%llu",
		    (long long unsigned int)guid);
	} else {
		/*
		 * otherwise use path sans partition suffix for whole disks
		 */
		(void) strlcpy(fullpath, path, sizeof (fullpath));
		if (wholedisk)
			zfs_strip_partition(fullpath);
	}

	/*
	 * Attempt to online the device.
	 */
	if (zpool_vdev_online(zhp, fullpath,
	    ZFS_ONLINE_CHECKREMOVE | ZFS_ONLINE_UNSPARE, &newstate) == 0 &&
	    (newstate == VDEV_STATE_HEALTHY ||
	    newstate == VDEV_STATE_DEGRADED)) {
		zed_log_msg(LOG_INFO, "  zpool_vdev_online: vdev %s is %s",
		    fullpath, (newstate == VDEV_STATE_HEALTHY) ?
		    "HEALTHY" : "DEGRADED");
		return;
	}

	/*
	 * If the pool doesn't have the autoreplace property set, then attempt
	 * a true online (without the unspare flag), which will trigger a FMA
	 * fault.
	 */
	if (!zpool_get_prop_int(zhp, ZPOOL_PROP_AUTOREPLACE, NULL) ||
	    !wholedisk || physpath == NULL) {
		(void) zpool_vdev_online(zhp, fullpath, ZFS_ONLINE_FORCEFAULT,
		    &newstate);
		zed_log_msg(LOG_INFO, "  zpool_vdev_online: %s FORCEFAULT (%s)",
		    fullpath, libzfs_error_description(g_zfshdl));
		return;
	}

	/*
	 * convert physical path into its current device node
	 */
	(void) snprintf(rawpath, sizeof (rawpath), "%s%s", DEV_BYPATH_PATH,
	    physpath);

	if (realpath(rawpath, devpath) == NULL) {
		zed_log_msg(LOG_INFO, "  realpath: %s failed (%s)",
		    rawpath, strerror(errno));

		(void) zpool_vdev_online(zhp, fullpath, ZFS_ONLINE_FORCEFAULT,
		    &newstate);

		zed_log_msg(LOG_INFO, "  zpool_vdev_online: %s FORCEFAULT (%s)",
		    fullpath, libzfs_error_description(g_zfshdl));
		return;
	}

	/*
	 * we're auto-replacing a raw disk, so label it first
	 */
	if (!labeled) {
		char *leafname;

		/*
		 * If this is a request to label a whole disk, then attempt to
		 * write out the label.  Before we can label the disk, we need
		 * to map the physical string that was matched on to the under
		 * lying device node.
		 *
		 * If any part of this process fails, then do a force online
		 * to trigger a ZFS fault for the device (and any hot spare
		 * replacement).
		 */
#if 0
		fd = open(devpath, O_RDWR|O_EXCL);
		if (fd == -1) {
			if (errno == EBUSY)
				return;
		} else {
			(void) close(fd);
		}
#endif
		leafname = strrchr(devpath, '/') + 1;

		/*
		 * If this is a request to label a whole disk, then attempt to
		 * write out the label.
		 */
		if (zpool_label_disk(g_zfshdl, zhp, leafname) != 0) {
			zed_log_msg(LOG_INFO, "  zpool_label_disk: could not "
			    "label '%s' (%s)", leafname,
			    libzfs_error_description(g_zfshdl));

			(void) zpool_vdev_online(zhp, fullpath,
			    ZFS_ONLINE_FORCEFAULT, &newstate);
			return;
		}

		/*
		 * The disk labeling is asynchronous on Linux. Just record
		 * this label request and return as there will be another
		 * disk add event for the partition after the labeling is
		 * completed.
		 */
		device = malloc(sizeof (pendingdev_t));
		(void) strlcpy(device->pd_physpath, physpath,
		    sizeof (device->pd_physpath));
		list_insert_tail(&g_device_list, device);

		zed_log_msg(LOG_INFO, "  zpool_label_disk: async '%s' (%llu)",
		    leafname, (long long unsigned int)guid);

		return;	/* resumes at EC_DEV_ADD.ESC_DISK for partition */

	} else /* labeled */ {
		boolean_t found = B_FALSE;
		/*
		 * match up with request above to label the disk
		 */
		for (device = list_head(&g_device_list); device != NULL;
		    device = list_next(&g_device_list, device)) {
			if (strcmp(physpath, device->pd_physpath) == 0) {
				list_remove(&g_device_list, device);
				free(device);
				found = B_TRUE;
				break;
			}
		}
		if (!found) {
			/* unexpected partition slice encountered */
			(void) zpool_vdev_online(zhp, fullpath,
			    ZFS_ONLINE_FORCEFAULT, &newstate);
			return;
		}

		zed_log_msg(LOG_INFO, "  zpool_label_disk: resume '%s' (%llu)",
		    physpath, (long long unsigned int)guid);

		if (nvlist_lookup_string(vdev, "new_devid", &new_devid) != 0) {
			zed_log_msg(LOG_INFO, "  auto replace: missing devid!");
			return;
		}

		if (nvlist_lookup_string(vdev, "new_devname", &new_devname)
		    != 0) {
			zed_log_msg(LOG_INFO, "  auto replace: missing name!");
			return;
		}

		path = new_devname;
	}

	/*
	 * Construct the root vdev to pass to zpool_vdev_attach().  While adding
	 * the entire vdev structure is harmless, we construct a reduced set of
	 * path/physpath/wholedisk to keep it simple.
	 */
	if (nvlist_alloc(&nvroot, NV_UNIQUE_NAME, 0) != 0)
		return;

	if (nvlist_alloc(&newvd, NV_UNIQUE_NAME, 0) != 0) {
		nvlist_free(nvroot);
		return;
	}

	if (nvlist_add_string(newvd, ZPOOL_CONFIG_TYPE, VDEV_TYPE_DISK) != 0 ||
	    nvlist_add_string(newvd, ZPOOL_CONFIG_PATH, path) != 0 ||
	    nvlist_add_string(newvd, ZPOOL_CONFIG_DEVID, new_devid) != 0 ||
	    (physpath != NULL && nvlist_add_string(newvd,
	    ZPOOL_CONFIG_PHYS_PATH, physpath) != 0) ||
	    nvlist_add_uint64(newvd, ZPOOL_CONFIG_WHOLE_DISK, wholedisk) != 0 ||
	    nvlist_add_string(nvroot, ZPOOL_CONFIG_TYPE, VDEV_TYPE_ROOT) != 0 ||
	    nvlist_add_nvlist_array(nvroot, ZPOOL_CONFIG_CHILDREN, &newvd,
	    1) != 0) {
		nvlist_free(newvd);
		nvlist_free(nvroot);
		return;
	}

	nvlist_free(newvd);

	/*
	 * auto replace a leaf disk at same physical location
	 */
	ret = zpool_vdev_attach(zhp, fullpath, path, nvroot, B_TRUE);

	zed_log_msg(LOG_INFO, "  zpool_vdev_replace: %s with %s (%s)",
	    fullpath, path, (ret == 0) ? "no errors" :
	    libzfs_error_description(g_zfshdl));

	nvlist_free(nvroot);
}

/*
 * Utility functions to find a vdev matching given criteria.
 */
typedef struct dev_data {
	const char		*dd_compare;
	const char		*dd_prop;
	zfs_process_func_t	dd_func;
	boolean_t		dd_found;
	boolean_t		dd_islabeled;
	uint64_t		dd_pool_guid;
	uint64_t		dd_vdev_guid;
	const char		*dd_new_devid;
	const char		*dd_new_devname;
} dev_data_t;

static void
zfs_iter_vdev(zpool_handle_t *zhp, nvlist_t *nvl, void *data)
{
	dev_data_t *dp = data;
	char *path;
	uint_t c, children;
	nvlist_t **child;

	/*
	 * First iterate over any children.
	 */
	if (nvlist_lookup_nvlist_array(nvl, ZPOOL_CONFIG_CHILDREN,
	    &child, &children) == 0) {
		for (c = 0; c < children; c++)
			zfs_iter_vdev(zhp, child[c], data);
		return;
	}

	/* once a vdev was matched and processed there is nothing left to do */
	if (dp->dd_found)
		return;

	/*
	 * Match by GUID if available otherwise fallback to devid or physical
	 */
	if (dp->dd_vdev_guid != 0) {
		uint64_t guid;

		if (nvlist_lookup_uint64(nvl, ZPOOL_CONFIG_GUID,
		    &guid) != 0 || guid != dp->dd_vdev_guid) {
			return;
		}
		zed_log_msg(LOG_INFO, "  zfs_iter_vdev: matched on %llu", guid);
		dp->dd_found = B_TRUE;

	} else if (dp->dd_compare != NULL) {
		/*
		 * NOTE: On Linux there is an event for partition, so unlike
		 * illumos, substring matching is not required to accomodate
		 * the partition suffix. An exact match will be present in
		 * the dp->dd_compare value.
		 */
		if (nvlist_lookup_string(nvl, dp->dd_prop, &path) != 0 ||
		    strcmp(dp->dd_compare, path) != 0) {
			return;
		}
		zed_log_msg(LOG_INFO, "  zfs_iter_vdev: matched %s on %s",
		    dp->dd_prop, path);
		dp->dd_found = B_TRUE;

		/* pass the new devid for use by replacing code */
		if (dp->dd_islabeled && dp->dd_new_devid != NULL) {
			(void) nvlist_add_string(nvl, "new_devid",
			    dp->dd_new_devid);
			(void) nvlist_add_string(nvl, "new_devname",
			    dp->dd_new_devname);

		}
	}

	(dp->dd_func)(zhp, nvl, dp->dd_islabeled);
}

static void *
zfs_enable_ds(void *arg)
{
	unavailpool_t *pool = (unavailpool_t *)arg;

	assert(pool->uap_enable_tid = pthread_self());

	(void) zpool_enable_datasets(pool->uap_zhp, NULL, 0);
	zpool_close(pool->uap_zhp);
	pool->uap_zhp = NULL;

	/* Note: zfs_slm_fini() will cleanup this pool entry on exit */
	return (NULL);
}

static int
zfs_iter_pool(zpool_handle_t *zhp, void *data)
{
	nvlist_t *config, *nvl;
	dev_data_t *dp = data;
	uint64_t pool_guid;
	unavailpool_t *pool;

	zed_log_msg(LOG_INFO, "zfs_iter_pool: evaluating vdevs on %s (by %s)",
	    zpool_get_name(zhp), dp->dd_vdev_guid ? "GUID" : dp->dd_prop);

	/*
	 * For each vdev in this pool, look for a match to apply dd_func
	 */
	if ((config = zpool_get_config(zhp, NULL)) != NULL) {
		if (dp->dd_pool_guid == 0 ||
		    (nvlist_lookup_uint64(config, ZPOOL_CONFIG_POOL_GUID,
		    &pool_guid) == 0 && pool_guid == dp->dd_pool_guid)) {
			(void) nvlist_lookup_nvlist(config,
			    ZPOOL_CONFIG_VDEV_TREE, &nvl);
			zfs_iter_vdev(zhp, nvl, data);
		}
	}

	/*
	 * if this pool was originally unavailable,
	 * then enable its datasets asynchronously
	 */
	if (g_enumeration_done)  {
		for (pool = list_head(&g_pool_list); pool != NULL;
		    pool = list_next(&g_pool_list, pool)) {

			if (pool->uap_enable_tid != 0)
				continue;	/* entry already processed */
			if (strcmp(zpool_get_name(zhp),
			    zpool_get_name(pool->uap_zhp)))
				continue;
			if (zfs_toplevel_state(zhp) >= VDEV_STATE_DEGRADED) {
				/* send to a background thread; keep on list */
				(void) pthread_create(&pool->uap_enable_tid,
				    NULL, zfs_enable_ds, pool);
				break;
			}
		}
	}

	zpool_close(zhp);
	return (dp->dd_found);	/* cease iteration after a match */
}

/*
 * Given a physical device location, iterate over all
 * (pool, vdev) pairs which correspond to that location.
 */
static boolean_t
devphys_iter(const char *physical, const char *devid, zfs_process_func_t func,
    boolean_t is_slice, char *devname)
{
	dev_data_t data = { 0 };

	data.dd_compare = physical;
	data.dd_func = func;
	data.dd_prop = ZPOOL_CONFIG_PHYS_PATH;
	data.dd_found = B_FALSE;
	data.dd_islabeled = is_slice;
	data.dd_new_devid = devid;	/* used by auto replace code */
	data.dd_new_devname = devname;

	(void) zpool_iter(g_zfshdl, zfs_iter_pool, &data);

	return (data.dd_found);
}

/*
 * Given a device identifier, find any vdevs with a matching devid.
 * On Linux we can match devid directly which is always a whole disk.
 */
static boolean_t
devid_iter(const char *devid, zfs_process_func_t func, boolean_t is_slice,
    char *devname)
{
	dev_data_t data = { 0 };

	data.dd_compare = devid;
	data.dd_func = func;
	data.dd_prop = ZPOOL_CONFIG_DEVID;
	data.dd_found = B_FALSE;
	data.dd_islabeled = is_slice;
	data.dd_new_devid = devid;
	data.dd_new_devname = devname;

	(void) zpool_iter(g_zfshdl, zfs_iter_pool, &data);

	return (data.dd_found);
}

/*
 * Handle a EC_DEV_ADD.ESC_DISK event.
 *
 * illumos
 *	Expects: DEV_PHYS_PATH string in schema
 *	Matches: vdev's ZPOOL_CONFIG_PHYS_PATH or ZPOOL_CONFIG_DEVID
 *
 *      path: '/dev/dsk/c0t1d0s0' (persistent)
 *     devid: 'id1,sd@SATA_____Hitachi_HDS72101______JP2940HZ3H74MC/a'
 * phys_path: '/pci@0,0/pci103c,1609@11/disk@1,0:a'
 *
 * linux
 *	provides: DEV_PHYS_PATH and DEV_IDENTIFIER strings in schema
 *	Matches: vdev's ZPOOL_CONFIG_PHYS_PATH or ZPOOL_CONFIG_DEVID
 *
 *      path: '/dev/sdc1' (not persistent)
 *     devid: 'ata-SAMSUNG_HD204UI_S2HGJD2Z805891-part1'
 * phys_path: 'pci-0000:04:00.0-sas-0x4433221106000000-lun-0'
 */
static int
zfs_deliver_add(nvlist_t *nvl, boolean_t is_lofi)
{
	char *devpath = NULL, *devid;
	boolean_t is_slice;
	char *devname;

	/*
	 * Expecting a devid string and an optional physical location
	 */
	if (nvlist_lookup_string(nvl, DEV_IDENTIFIER, &devid) != 0)
		return (-1);

	(void) nvlist_lookup_string(nvl, DEV_PHYS_PATH, &devpath);
	(void) nvlist_lookup_string(nvl, DEV_NAME, &devname);

	zed_log_msg(LOG_INFO, "zfs_deliver_add: adding %s (%s)", devid,
	    devpath ? devpath : "NULL");

	is_slice = (nvlist_lookup_boolean(nvl, DEV_IS_PART) == 0);

	/*
	 * Iterate over all vdevs looking for a match in the folllowing order:
	 * 1. ZPOOL_CONFIG_DEVID (identifies the unique disk)
	 * 2. ZPOOL_CONFIG_PHYS_PATH (identifies disk physical location).
	 *
	 * For disks, we only want to pay attention to vdevs marked as whole
	 * disks.  For multipath devices does whole disk apply? (TBD).
	 */
	if (!devid_iter(devid, zfs_process_add, is_slice, devname) &&
	    devpath != NULL)
		if (!is_slice)
			devphys_iter(devpath, devid, zfs_process_add,
			    is_slice, devname);

	return (0);
}

/*
 * Called when we receive a VDEV_CHECK event, which indicates a device could not
 * be opened during initial pool open, but the autoreplace property was set on
 * the pool.  In this case, we treat it as if it were an add event.
 */
static int
zfs_deliver_check(nvlist_t *nvl)
{
	dev_data_t data = { 0 };

	if (nvlist_lookup_uint64(nvl, ZFS_EV_POOL_GUID,
	    &data.dd_pool_guid) != 0 ||
	    nvlist_lookup_uint64(nvl, ZFS_EV_VDEV_GUID,
	    &data.dd_vdev_guid) != 0 ||
	    data.dd_vdev_guid == 0)
		return (0);

	zed_log_msg(LOG_INFO, "zfs_deliver_check: pool '%llu', vdev %llu",
	    data.dd_pool_guid, data.dd_vdev_guid);

	data.dd_func = zfs_process_add;

	(void) zpool_iter(g_zfshdl, zfs_iter_pool, &data);

	return (0);
}

static int
zfsdle_vdev_online(zpool_handle_t *zhp, void *data)
{
	char *devname = data;
	boolean_t avail_spare, l2cache;
	vdev_state_t newstate;
	nvlist_t *tgt;

	zed_log_msg(LOG_INFO, "zfsdle_vdev_online: searching for '%s' in '%s'",
	    devname, zpool_get_name(zhp));

	if ((tgt = zpool_find_vdev_by_physpath(zhp, devname,
	    &avail_spare, &l2cache, NULL)) != NULL) {
		char *path, fullpath[MAXPATHLEN];
		uint64_t wholedisk = 0ULL;

		verify(nvlist_lookup_string(tgt, ZPOOL_CONFIG_PATH,
		    &path) == 0);
		verify(nvlist_lookup_uint64(tgt, ZPOOL_CONFIG_WHOLE_DISK,
		    &wholedisk) == 0);

		(void) strlcpy(fullpath, path, sizeof (fullpath));
		if (wholedisk) {
			zfs_strip_partition(fullpath);

			/*
			 * We need to reopen the pool associated with this
			 * device so that the kernel can update the size
			 * of the expanded device.
			 */
			(void) zpool_reopen(zhp);
		}

		if (zpool_get_prop_int(zhp, ZPOOL_PROP_AUTOEXPAND, NULL)) {
			zed_log_msg(LOG_INFO, "zfsdle_vdev_online: setting "
			    "device '%s' to ONLINE state in pool '%s'",
			    fullpath, zpool_get_name(zhp));
			if (zpool_get_state(zhp) != POOL_STATE_UNAVAIL)
				(void) zpool_vdev_online(zhp, fullpath, 0,
				    &newstate);
		}
		zpool_close(zhp);
		return (1);
	}
	zpool_close(zhp);
	return (0);
}

/*
 * This function handles the ESC_DEV_DLE event.
 */
static int
zfs_deliver_dle(nvlist_t *nvl)
{
	char *devname;

	if (nvlist_lookup_string(nvl, DEV_PHYS_PATH, &devname) != 0) {
		zed_log_msg(LOG_INFO, "zfs_deliver_event: no physpath");
		return (-1);
	}

	if (zpool_iter(g_zfshdl, zfsdle_vdev_online, devname) != 1) {
		zed_log_msg(LOG_INFO, "zfs_deliver_event: device '%s' not "
		    "found", devname);
		return (1);
	}
	return (0);
}

/*
 * syseventd daemon module event handler
 *
 * Handles syseventd daemon zfs device related events:
 *
 *	EC_DEV_ADD.ESC_DISK
 *	EC_DEV_STATUS.ESC_DEV_DLE
 *	EC_ZFS.ESC_ZFS_VDEV_CHECK
 *
 * Note: assumes only one thread active at a time (not thread safe)
 */
static int
zfs_slm_deliver_event(const char *class, const char *subclass, nvlist_t *nvl)
{
	int ret;
	boolean_t is_lofi = B_FALSE, is_check = B_FALSE, is_dle = B_FALSE;

	if (strcmp(class, EC_DEV_ADD) == 0) {
		/*
		 * We're mainly interested in disk additions, but we also listen
		 * for new loop devices, to allow for simplified testing.
		 */
		if (strcmp(subclass, ESC_DISK) == 0)
			is_lofi = B_FALSE;
		else if (strcmp(subclass, ESC_LOFI) == 0)
			is_lofi = B_TRUE;
		else
			return (0);

		is_check = B_FALSE;
	} else if (strcmp(class, EC_ZFS) == 0 &&
	    strcmp(subclass, ESC_ZFS_VDEV_CHECK) == 0) {
		/*
		 * This event signifies that a device failed to open
		 * during pool load, but the 'autoreplace' property was
		 * set, so we should pretend it's just been added.
		 */
		is_check = B_TRUE;
	} else if (strcmp(class, EC_DEV_STATUS) == 0 &&
	    strcmp(subclass, ESC_DEV_DLE) == 0) {
		is_dle = B_TRUE;
	} else {
		return (0);
	}

	if (is_dle)
		ret = zfs_deliver_dle(nvl);
	else if (is_check)
		ret = zfs_deliver_check(nvl);
	else
		ret = zfs_deliver_add(nvl, is_lofi);

	return (ret);
}

/*ARGSUSED*/
static void *
zfs_enum_pools(void *arg)
{
	(void) zpool_iter(g_zfshdl, zfs_unavail_pool, (void *)&g_pool_list);
	/*
	 * Linux - instead of using a thread pool, each list entry
	 * will spawn a thread when an unavailable pool transitions
	 * to available. zfs_slm_fini will wait for these threads.
	 */
	g_enumeration_done = B_TRUE;
	return (NULL);
}

/*
 * called from zed daemon at startup
 *
 * sent messages from zevents or udev monitor
 *
 * For now, each agent has it's own libzfs instance
 */
int
zfs_slm_init(libzfs_handle_t *zfs_hdl)
{
	if ((g_zfshdl = libzfs_init()) == NULL)
		return (-1);

	/*
	 * collect a list of unavailable pools (asynchronously,
	 * since this can take a while)
	 */
	list_create(&g_pool_list, sizeof (struct unavailpool),
	    offsetof(struct unavailpool, uap_node));

	if (pthread_create(&g_zfs_tid, NULL, zfs_enum_pools, NULL) != 0) {
		list_destroy(&g_pool_list);
		return (-1);
	}

	list_create(&g_device_list, sizeof (struct pendingdev),
	    offsetof(struct pendingdev, pd_node));

	return (0);
}

void
zfs_slm_fini()
{
	unavailpool_t *pool;
	pendingdev_t *device;

	/* wait for zfs_enum_pools thread to complete */
	(void) pthread_join(g_zfs_tid, NULL);

	while ((pool = (list_head(&g_pool_list))) != NULL) {
		/*
		 * each pool entry has two possibilities
		 * 1. was made available (so wait for zfs_enable_ds thread)
		 * 2. still unavailable (just close the pool)
		 */
		if (pool->uap_enable_tid)
			(void) pthread_join(pool->uap_enable_tid, NULL);
		else if (pool->uap_zhp != NULL)
			zpool_close(pool->uap_zhp);

		list_remove(&g_pool_list, pool);
		free(pool);
	}
	list_destroy(&g_pool_list);

	while ((device = (list_head(&g_device_list))) != NULL) {
		list_remove(&g_device_list, device);
		free(device);
	}
	list_destroy(&g_device_list);

	libzfs_fini(g_zfshdl);
}

void
zfs_slm_event(const char *class, const char *subclass, nvlist_t *nvl)
{
	static pthread_mutex_t serialize = PTHREAD_MUTEX_INITIALIZER;

	/*
	 * Serialize incoming events from zfs or libudev sources
	 */
	(void) pthread_mutex_lock(&serialize);
	zed_log_msg(LOG_INFO, "zfs_slm_event: %s.%s", class, subclass);
	(void) zfs_slm_deliver_event(class, subclass, nvl);
	(void) pthread_mutex_unlock(&serialize);
}
