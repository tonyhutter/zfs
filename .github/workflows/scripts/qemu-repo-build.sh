#!/usr/bin/env bash

# wget -A rpm,gz,bz2,xml,asc -r -l 9 -nd -x  http://download.zfsonlinux.org/repo
#
# Get zfs version '2.2.99'
# zfsver=$(ls | grep -m1  -Eo ^zfs-[0-9]+\.[0-9]+\.[0-9]+ | grep -Eo [0-9]+\.[0-9]+\.[0-9]+)

# Get el8/fedora40 OS string
# OS_STR=$(ls | grep -Eo -m1 '.[fc|el][0-9]+\.')



######################################################################
# 4) configure and build openzfs modules
######################################################################

set -eu

function run() {
  LOG="/var/tmp/build-stderr.txt"
  echo "****************************************************"
  echo "$(date) ($*)"
  echo "****************************************************"
  ($@ || echo $? > /tmp/rv) 3>&1 1>&2 2>&3 | stdbuf -eL -oL tee -a $LOG
  if [ -f /tmp/rv ]; then
    RV=$(cat /tmp/rv)
    echo "****************************************************"
    echo "exit with value=$RV ($*)"
    echo "****************************************************"
    echo 1 > /var/tmp/build-exitcode.txt
    exit $RV
  fi
}

function rpm_build_and_install() {
  EXTRA_CONFIG="${1:-}"
  echo "##[group]Autogen.sh"
  run ./autogen.sh
  echo "##[endgroup]"

  echo "##[group]Configure"
  run ./configure --enable-pyzfs --enable-debug --enable-debuginfo $EXTRA_CONFIG
  echo "##[endgroup]"

  echo "##[group]Build"
  run make pkg-kmod pkg-utils pkg-dkms
  echo "##[endgroup]"
}

# Debug: show kernel cmdline
if [ -f /proc/cmdline ] ; then
  cat /proc/cmdline || true
fi

# save some sysinfo
uname -a > /var/tmp/uname.txt

cd $HOME/zfs
export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"

# build
case "$1" in
  alma*|centos*)
    rpm_build_and_install "--with-spec=redhat"
    ;;
  fedora*)
    rpm_build_and_install
    ;;
  *)
    echo "Not EL or Fedora, nothing to do"
    ;;
esac

# building the zfs module was ok
echo 0 > /var/tmp/build-exitcode.txt

# reset cloud-init configuration and poweroff
sudo cloud-init clean --logs
sync && sleep 2 && sudo poweroff &
exit 0
