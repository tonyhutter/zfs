######################################################################
# 3) Wait for VM to boot from previous step and launch dependencies
#    script on it.
#
# $1: OS name (like 'fedora41)'
######################################################################

while pidof /usr/bin/qemu-system-x86_64 >/dev/null; do
  ssh 2>/dev/null zfs@vm0 "uname -a" && break
done
scp .github/workflows/scripts/qemu-3-deps-vm.sh zfs@vm0:qemu-3-deps-vm.sh
PID=`pidof /usr/bin/qemu-system-x86_64`
ssh zfs@vm0 '$HOME/qemu-3-deps-vm.sh' $1
# wait for poweroff to succeed
tail --pid=$PID -f /dev/null
sleep 5 # avoid this: "error: Domain is already active"
rm -f $HOME/.ssh/known_hosts
