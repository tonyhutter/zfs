#!/usr/bin/env bash

######################################################################
# 4) configure and build openzfs modules
#
# Usage:
#
#       qemu-4-build-vm.sh OS [--dkms] [--save]
#
# OS:           OS name like 'fedora41'
# --dkms:       Build DKMS RPMs as well (optional) 
# --save:       Save RPMs to artifacts after they're built
######################################################################

DKMS=""
SAVE_RPMS=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --dkms)
      DKMS=1
      shift # past value
      ;;
    --save)
      SAVE_RPMS=1
      shift # past value
      ;;
    *)
      OS=$1
      shift
      ;;
  esac
done

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

function freebsd() {
  export MAKE="gmake"
  echo "##[group]Autogen.sh"
  run ./autogen.sh
  echo "##[endgroup]"

  echo "##[group]Configure"
  run ./configure \
    --prefix=/usr/local \
    --with-libintl-prefix=/usr/local \
    --enable-pyzfs \
    --enable-debug \
    --enable-debuginfo
  echo "##[endgroup]"

  echo "##[group]Build"
  run gmake -j$(sysctl -n hw.ncpu)
  echo "##[endgroup]"

  echo "##[group]Install"
  run sudo gmake install
  echo "##[endgroup]"
}

function linux() {
  echo "##[group]Autogen.sh"
  run ./autogen.sh
  echo "##[endgroup]"

  echo "##[group]Configure"
  run ./configure \
    --prefix=/usr \
    --enable-pyzfs \
    --enable-debug \
    --enable-debuginfo
  echo "##[endgroup]"

  echo "##[group]Build"
  run make -j$(nproc)
  echo "##[endgroup]"

  echo "##[group]Install"
  run sudo make install
  echo "##[endgroup]"
}

function rpm_build_and_install() {
  EXTRA_CONFIG="${1:-}"
  echo "##[group]Autogen.sh"
  run ./autogen.sh
  echo "##[endgroup]"

  echo "##[group]Configure"
  run ./configure --enable-debug --enable-debuginfo $EXTRA_CONFIG
  echo "##[endgroup]"

  echo "##[group]Build"
  run make pkg-kmod pkg-utils
  echo "##[endgroup]"

  echo "##[group]Install"
  run sudo dnf -y --nobest install $(ls *.rpm | grep -v src.rpm)
  echo "##[endgroup]"

}

function deb_build_and_install() {
echo "##[group]Autogen.sh"
  run ./autogen.sh
  echo "##[endgroup]"

  echo "##[group]Configure"
  run ./configure \
    --prefix=/usr \
    --enable-pyzfs \
    --enable-debug \
    --enable-debuginfo
  echo "##[endgroup]"

  echo "##[group]Build"
  run make native-deb-kmod native-deb-utils
  echo "##[endgroup]"

  echo "##[group]Install"
  # Do kmod install.  Note that when you build the native debs, the
  # packages themselves are placed in parent directory '../' rather than
  # in the source directory like the rpms are.
  run sudo apt-get -y install $(find ../ | grep -E '\.deb$' \
    | grep -Ev 'dkms|dracut')
  echo "##[endgroup]"
}

# Debug: show kernel cmdline
if [ -f /proc/cmdline ] ; then
  cat /proc/cmdline || true
fi

# Set our hostname to our OS name and version number.  Specifically, we set the
# major and minor number so that when we query the RPMs we build, we can see
# what specific version of RHEL/ALMA we were using to build them.  This is
# helpful for matching up KMOD versions.
#
# Examples:
#
# rhel8.10
# almalinux9.5
# fedora40
source /etc/os-release
sudo hostname "$ID$VERSION_ID"

# save some sysinfo
uname -a > /var/tmp/uname.txt

cd $HOME/zfs
export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"

# build
case "$OS" in
  freebsd*)
    freebsd
    ;;
  alma*|centos*)
    rpm_build_and_install "--with-spec=redhat"
    if [ -n "$DKMS" ] ; then
        make rpm-dkms
    fi
    ;;
  fedora*)
    rpm_build_and_install
    if [ -n "$DKMS" ] ; then
        make rpm-dkms
    fi
    ;;
  debian*|ubuntu*)
    deb_build_and_install
    ;;
  *)
    linux
    ;;
esac

# building the zfs module was ok
echo 0 > /var/tmp/build-exitcode.txt

if [ -n "$SAVE_RPMS" ] ; then
        cp *.rpm /var/tmp
fi

# reset cloud-init configuration and poweroff
sudo cloud-init clean --logs
sync && sleep 2 && sudo poweroff &
exit 0
