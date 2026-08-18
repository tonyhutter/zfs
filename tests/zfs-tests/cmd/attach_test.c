// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Copyright (c) 2026 by Lawrence Livermore National Security, LLC.
 */

/*
 * Short program to call ZFS_IOC_VDEV_ATTACH via /dev/zfs
 *
 * Usage: attach_test <pool> <existing_vdev_guid_decimal> <new_vdev_path>
 *
 * Initially written by Github Copilot (and modified by hand).
 */

#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include <libnvpair.h>
#include <sys/zfs_ioctl.h>

static void usage(const char *prog) {
	fprintf(stderr,
	    "Usage: %s <pool> <existing_vdev_guid_decimal> <new_vdev_path>\n",
	    prog);
	exit(EXIT_FAILURE);
}

/* Return true if 'newpath' is a block device, false otherwise */
static boolean_t is_block(const char *newpath)
{
	struct stat sb;

	if (stat(newpath, &sb) != 0)
		return (0); /* error */

	return (S_ISBLK(sb.st_mode));
}

int main(int argc, char **argv) {
	char *endptr;
	const char *pool = argv[1];
	uint64_t guid;
	const char *newpath;
	int rc = EXIT_SUCCESS;
	nvlist_t *nvl = NULL;
	nvlist_t *child = NULL;
	char *packed = NULL;

	if (argc != 4)
		usage(argv[0]);

	guid = strtoull(argv[2], &endptr, 10);
	errno = 0;
	if (errno || *endptr != '\0') {
		fprintf(stderr, "Invalid GUID: %s\n", argv[2]);
		return (EXIT_FAILURE);

	}
	newpath = argv[3];

	/*
	 * Build minimal nvlist for the new vdev:
	 *
	 *     type: 'root'
	 *     children[0]:
	 *           path: '/path/to/new/file/or/disk'
	 *           type: 'file'
	 *      is_log: 0
	 */
	nvl = fnvlist_alloc();

	fnvlist_add_string(nvl, ZPOOL_CONFIG_TYPE, "root");
	child = fnvlist_alloc();
	fnvlist_add_string(child, ZPOOL_CONFIG_PATH, newpath);
	fnvlist_add_string(child, ZPOOL_CONFIG_TYPE,
	    is_block(newpath) ? "disk" : "file");
	fnvlist_add_uint64(child, ZPOOL_CONFIG_IS_LOG, 0);
	fnvlist_add_nvlist_array(nvl, ZPOOL_CONFIG_CHILDREN,
	    (const nvlist_t **)& child, 1);

	/* pack */
	size_t packed_size = 0;
	if (nvlist_pack(nvl, &packed, &packed_size, NV_ENCODE_NATIVE, 0) != 0) {
		perror("nvlist_pack");
		rc = EXIT_FAILURE;
		goto end;
	}

	/* Prepare zfs_cmd */
	zfs_cmd_t zc;
	memset(&zc, 0, sizeof (zc));
	strncpy(zc.zc_name, pool, sizeof (zc.zc_name) - 1);
	zc.zc_guid = guid;
	zc.zc_nvlist_conf = (uint64_t)(uintptr_t)packed;
	zc.zc_nvlist_conf_size = (uint64_t)packed_size;
	zc.zc_cookie = 0; /* not replacing; 0 => attach as mirror */

	/* open /dev/zfs */
	int fd = open("/dev/zfs", O_RDONLY);
	if (fd < 0) {
		perror("open /dev/zfs");
		rc = EXIT_FAILURE;
		goto end;
	}

	/* Issue ioctl */
	if (ioctl(fd, ZFS_IOC_VDEV_ATTACH, &zc) != 0) {
		int err = errno;
		fprintf(stderr, "ZFS_IOC_VDEV_ATTACH ioctl failed: %s\n",
		    strerror(err));
		close(fd);
		rc = EXIT_FAILURE;
		goto end;
	}

	printf("Attach ioctl issued successfully; pool=%s guid=%" PRIu64
	    " newpath=%s\n", pool, guid, newpath);

	close(fd);

end:
	if (nvl != NULL)
		nvlist_free(nvl);

	if (child != NULL)
		nvlist_free(child);

	if (packed != NULL)
		free(packed);

	return (rc);
}
