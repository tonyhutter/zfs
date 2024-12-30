#!/bin/bash
#
# Do a test install of ZFS from an external repository.
#
# USAGE:
#
# 	./qemu-test-repo-vm [URL]
#
# URL:		URL to use instead of http://download.zfsonlinux.org
#		If blank, use the default repo from zfs-release RPM.

set -e

source /etc/os-release
OS="$ID"
VERSION="$VERSION_ID"

ALTHOST=""
if [ -n "$1" ] ; then
	ALTHOST="$1"
fi

# $1: Repo 'zfs' 'zfs-kmod' 'zfs-testing' 'zfs-testing-kmod'
# $2: (optional) Alternate host than 'http://download.zfsonlinux.org' to
#     install from.  Blank means use default from zfs-release RPM.
function test_install {
	repo=$1
	host=""
	if [ -n "$2" ] ; then
		host=$2
	fi

	args="--disablerepo=zfs --enablerepo=$repo"

	if [ -n "$host" ] ; then
		sudo sed -i "s;baseurl=http://download.zfsonlinux.org;baseurl=$ALTHOST;g" /etc/yum.repos.d/zfs.repo
	fi

	# Sanity test
	sudo dnf -y install $args zfs zfs-test
	sudo /usr/share/zfs/zfs.sh -r
	truncate -s 100M /tmp/file
	sudo zpool create tank /tmp/file
	sudo zpool status
	sudo zfs --version

	# Line up our output columns
	printf %-35s "Installed $repo: " >> $SUMMARY
	echo -e "$(sudo rpm -qa | grep zfs | grep -E 'kmod|dkms')\t(--version user/kernel: $(echo $(sudo zfs --version)))" >> $SUMMARY
	sudo zpool destroy tank
	sudo rm /tmp/file
	sudo dnf -y remove zfs
}

# Just write summary to /tmp/repo so our artifacts scripts pick it up
mkdir /tmp/repo
SUMMARY=/tmp/repo/$OS-$VERSION-summary.txt

echo "##[group]Installing from repo"
# The openzfs docs are the authoritative instructions for the install.  Use
# the specific version of zfs-release RPM it recommends.
case $OS in
almalinux*)
	url='https://raw.githubusercontent.com/openzfs/openzfs-docs/refs/heads/master/docs/Getting%20Started/RHEL-based%20distro/index.rst'
	name=$(curl -Ls $url | grep 'dnf install' | grep -Eo 'zfs-release-[0-9]+-[0-9]+')
	sudo dnf -y install https://zfsonlinux.org/epel/$name$(rpm --eval "%{dist}").noarch.rpm 2>&1
	sudo rpm -qi zfs-release
	test_install zfs $ALTHOST
	test_install zfs-kmod $ALTHOST
	test_install zfs-testing $ALTHOST
	test_install zfs-testing-kmod $ALTHOST
	;;
fedora*)
	url='https://raw.githubusercontent.com/openzfs/openzfs-docs/refs/heads/master/docs/Getting%20Started/Fedora/index.rst'
	name=$(curl -Ls $url | grep 'dnf install' | grep -Eo 'zfs-release-[0-9]+-[0-9]+')
	sudo dnf -y install -y https://zfsonlinux.org/fedora/$name$(rpm --eval "%{dist}").noarch.rpm
	test_install zfs $ALTHOST
	;;
esac
echo "##[endgroup]"     
echo "Summary: "
cat $SUMMARY
