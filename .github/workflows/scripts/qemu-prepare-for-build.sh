#!/usr/bin/env bash

# Helper script to run after installing dependencies.  This brings the VM back
# up and copies over the zfs source directory.
echo "Build modules in QEMU machine"
sudo virsh start openzfs
read "pty" <<< $(sudo virsh ttyconsole openzfs)
(cat $pty) &
echo "Waiting..."
.github/workflows/scripts/qemu-wait-for-vm.sh vm0
echo "Rsyncing"
rsync -ar $HOME/work/zfs/zfs/. zfs@vm0:zfs
