#!/usr/bin/env bash

######################################################################
# 4) configure and build openzfs modules
######################################################################
echo "Build modules in QEMU machine"
sudo virsh start openzfs
while pidof /usr/bin/qemu-system-x86_64 >/dev/null; do
    ssh 2>/dev/null zfs@vm0 "uname -a" && break
done
rsync -ar $HOME/work/zfs/zfs zfs@vm0:./

ssh zfs@vm0 '$HOME/zfs/.github/workflows/scripts/qemu-4-build-vm.sh' $@
