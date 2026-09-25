#!/usr/bin/env bash

######################################################################
# 1) setup qemu instance on action runner
######################################################################

set -eu

# The default runner has a bunch of development tools and other things
# that we do not need.  Remove them here to free up a total of 35GB.
#
# First remove packages - this frees up ~10GB
echo "Disk space before purge:"
df -h /
sudo docker image prune --all --force
sudo docker builder prune -a
unneeded="microsoft-edge-stable|azure-cli|google-cloud|google-chrome-stable|"\
"temurin|llvm|firefox|mysql-server|snapd|android|dotnet|haskell|ghcup|"\
"powershell|julia|swift|miniconda|chromium"
# refresh package index before removing packages
sudo apt-get -y update
sudo apt-get -y remove $(dpkg-query -f '${binary:Package}\n' -W | grep -E "'$unneeded'")
sudo apt-get -y autoremove

# Next, remove unneeded files in /usr.  This frees up an additional 25GB.
sudo rm -fr /usr/local/lib/android /usr/share/dotnet /usr/local/.ghcup \
        /usr/share/swift /usr/local/share/powershell /usr/local/julia* \
        /usr/share/miniconda /usr/local/share/chromium /home/runner/.rustup \
        /opt/hostedtoolcache /opt/az /usr/lib/google-cloud-sdk \
        /opt/google /opt/microsoft
echo "Disk space after:"
df -h /

# The default 'azure.archive.ubuntu.com' mirrors can be really slow.
# Prioritize the official Ubuntu mirrors.
#
# The normal apt-mirrors.txt will look like:
#
# http://azure.archive.ubuntu.com/ubuntu/       priority:1
# https://archive.ubuntu.com/ubuntu/    priority:2
# https://security.ubuntu.com/ubuntu/   priority:3
#
# Just delete the 'azure.archive.ubuntu.com' line.
sudo sed -i '/azure.archive.ubuntu.com/d' /etc/apt/apt-mirrors.txt
echo "Using mirrors:"
cat /etc/apt/apt-mirrors.txt

# install needed packages
export DEBIAN_FRONTEND="noninteractive"
sudo apt-get -y update
sudo apt-get install -y axel cloud-image-utils daemonize guestfs-tools \
  virt-manager linux-modules-extra-$(uname -r) zfsutils-linux

# generate ssh keys
rm -f ~/.ssh/id_ed25519
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -q -N ""

# not needed
sudo systemctl stop docker.socket
sudo systemctl stop multipathd.socket

sudo swapoff -a

# Special case:
#
# For reasons unknown, the runner can boot-up with two different block device
# configurations.  On one config you get two 75GB block devices, and on the
# other you get a single 150GB block device. Here's what both look like:
#
# --- One 150GB block device ---
# NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
# sda       8:0    0  150G  0 disk
# ├─sda1    8:1    0  149G  0 part /
# ├─sda14   8:14   0    4M  0 part
# ├─sda15   8:15   0  106M  0 part /boot/efi
# └─sda16 259:0    0  913M  0 part /boot
#
# lrwxrwxrwx 1 root root  9 Jan 29 18:07 azure_root -> ../../sda
# lrwxrwxrwx 1 root root 10 Jan 29 18:07 azure_root-part1 -> ../../sda1
# lrwxrwxrwx 1 root root 11 Jan 29 18:07 azure_root-part14 -> ../../sda14
# lrwxrwxrwx 1 root root 11 Jan 29 18:07 azure_root-part15 -> ../../sda15
# lrwxrwxrwx 1 root root 11 Jan 29 18:07 azure_root-part16 -> ../../sda16
#
# --- Two 75GB block devices ---
# NAME    MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
# sda       8:0    0   75G  0 disk
# ├─sda1    8:1    0   74G  0 part /
# ├─sda14   8:14   0    4M  0 part
# ├─sda15   8:15   0  106M  0 part /boot/efi
# └─sda16 259:0    0  913M  0 part /boot
# sdb       8:16   0   75G  0 disk
# └─sdb1    8:17   0   75G  0 part
#
# lrwxrwxrwx 1 root root  9 Jan 29 18:07 azure_resource -> ../../sdb
# lrwxrwxrwx 1 root root 10 Jan 29 18:07 azure_resource-part1 -> ../../sdb1
# lrwxrwxrwx 1 root root  9 Jan 29 18:07 azure_root -> ../../sda
# lrwxrwxrwx 1 root root 10 Jan 29 18:07 azure_root-part1 -> ../../sda1
# lrwxrwxrwx 1 root root 11 Jan 29 18:07 azure_root-part14 -> ../../sda14
# lrwxrwxrwx 1 root root 11 Jan 29 18:07 azure_root-part15 -> ../../sda15
#
# If we have the azure_resource-part1 partition, umount it, partition it, and
# use it as our ZFS disk and swap partition.  If not, just create a file VDEV
# and swap file and use that instead.

# remove default swapfile and /mnt
if [ -e /dev/disk/cloud/azure_resource-part1 ] ; then
  sudo umount -l /mnt
  DISK="/dev/disk/cloud/azure_resource-part1"
  sudo sed -e "s|^$DISK.*||g" -i /etc/fstab
  sudo wipefs -aq $DISK
  sudo systemctl daemon-reload
fi

sudo modprobe loop
sudo modprobe zfs

# Enable zswap
echo 1 | sudo tee /sys/module/zswap/parameters/enabled
echo "Compressor:"
sudo cat /sys/module/zswap/parameters/compressor || true
echo zstd | sudo tee /sys/module/zswap/parameters/compressor
# evict cold pages without mem pressure
echo 1 | sudo tee /sys/module/zswap/parameters/shrinker_enabled

# Enable Kernel Same Page Merging (KSM) to look for duplicate pages and keep
# one copy.
echo "KSM Before"
sudo cat /sys/kernel/mm/ksm/run
echo "pages before / sleep between"
sudo cat /sys/kernel/mm/ksm/pages_to_scan
sudo cat /sys/kernel/mm/ksm/sleep_millisecs
echo 1 | sudo tee /sys/kernel/mm/ksm/run

# Aggressive scanning (more CPU usage, better merging)
# https://lwn.net/Articles/953141/ recommends 2000-5000.
echo 2000 | sudo tee /sys/kernel/mm/ksm/pages_to_scan

# Check THP status
echo "THP:"
sudo cat /sys/kernel/mm/transparent_hugepage/enabled

# Enable THP
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled

# Configure defrag (compaction)
echo defer | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
