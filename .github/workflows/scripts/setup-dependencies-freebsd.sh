#!/bin/sh

echo "Uname $(uname -a) running in $(pwd)"
set -x

FETCH='fetch --ca-cert=/usr/local/etc/ssl/certs/llnl-ca-cert-bundle.pem'

# Temporary workaround for FreeBSD pkg db locking race
pkg_install () {
    local pkg_pid=$(pgrep pkg 2>/dev/null)
    if [ -n  "${pkg_pid}" ]; then
        pwait ${pkg_pid}
    fi
    pkg install "${@}"
}

prerun() {
  echo "::group::Install build dependencies"

    # Temporary workaround for pkg db locking race
    pkg_pid=$(pgrep pkg 2>/dev/null)
    if [ -n "${pkg_pid}" ]; then
        pwait ${pkg_pid}
    fi
    # Always test with the latest packages on FreeBSD.
    pkg upgrade -y --no-repo-update

    # Kernel source
    (
        ABI=$(uname -p)
        VERSION=$(freebsd-version -r)
        cd /tmp

        echo "I am $(whoami)"
	if [ ! -e src.txt ] ; then

        echo "Getting ${ABI}/${VERSION}, ($(freebsd-version -r), $(uname -p))"
        $FETCH https://download.freebsd.org/ftp/snapshots/${ABI}/${VERSION}/src.txz ||
        $FETCH https://download.freebsd.org/ftp/releases/${ABI}/${VERSION}/src.txz
        if [ ! -e src.txz ] ; then
            fetch https://download.freebsd.org/ftp/snapshots/${ABI}/${VERSION}/src.txz ||
            fetch https://download.freebsd.org/ftp/releases/${ABI}/${VERSION}/src.txz
        fi

    fi

        if [ ! -e src.txz ] ; then
            echo "ERROR: NO TARBALL"
            exit 1
        fi 

        tar xpf src.txz -C /
        # rm src.txz
    )

    # Required development tools
    pkg_install -y --no-repo-update \
        autoconf \
        automake \
        autotools \
        bash \
        gmake \
        libtool \
        git

    # Essential testing utilities
    # No tests will run if these are missing.
    pkg_install -y --no-repo-update \
        ksh93 \
        python \
        python3 \
        sudo

    # Important testing utilities
    # Many tests will fail if these are missing.
    pkg_install -y --no-repo-update \
        base64 \
        fio

    # Testing support utilities
    # Only a few tests require these.
    pkg_install -y --no-repo-update \
        samba413 \
        gdb \
        pamtester \
        lcov \
        rsync

    # Python support libraries
    pkg_install -xy --no-repo-update \
        '^py3[[:digit:]]+-cffi$' \
        '^py3[[:digit:]]+-sysctl$' \
        '^py3[[:digit:]]+-packaging$'
  echo "::endgroup::"
}

mod_build() {
  echo "::group::Build local binaries in workspace"
  ./autogen.sh
  env MAKE=gmake ./configure
  MAKE="gmake WITH_DEBUG=true"
  if sysctl -n kern.conftxt | grep -Fqx $'options\tINVARIANTS'; then
      MAKE="$MAKE WITH_INVARIANTS=true"
  fi
  NCPU=$(sysctl -n hw.ncpu)

  $MAKE --no-print-directory --silent -j $NCPU

  echo "$ImageOS-$ImageVersion" > tests/ImageOS.txt
  echo "::endgroup::"
}

mod_install() {
  # install the pre-built module only on the same runner image
  MOD=`cat tests/ImageOS.txt`
  if [ "$MOD" != "$ImageOS-$ImageVersion" ]; then
    mod_build
  fi

  echo "::group::Install and load modules"

  ./scripts/zfs.sh
  ./scripts/zfs-helpers.sh -i
  echo "::endgroup::"
}

case "$1" in
  build)
    prerun
    mod_build
    ;;
  tests)
    mod_install
    ;;
esac
