#!/usr/bin/env bash

# Helper script to run after installing dependencies.  This brings the VM back
# up and copies over the zfs source directory.
echo "Build modules in QEMU machine"
sudo virsh start openzfs
while pidof /usr/bin/qemu-system-x86_64 >/dev/null; do
    ssh 2>/dev/null zfs@vm0 "uname -a" && break
done
rsync -ar $HOME/work/zfs/zfs zfs@vm0:./
