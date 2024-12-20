#!/usr/bin/env bash

######################################################################
# 4) configure and build openzfs modules
######################################################################
echo "Build modules in QEMU machine"
sudo virsh start openzfs
IP=192.168.122.10
while pidof /usr/bin/qemu-system-x86_64 >/dev/null; do
    ssh 2>/dev/null zfs@$IP "uname -a" && break
done
rsync -ar $HOME/work/zfs/zfs zfs@$IP:./

ssh zfs@$IP '$HOME/zfs/.github/workflows/scripts/qemu-4-build-vm.sh' $@
