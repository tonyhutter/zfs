#!/usr/bin/env bash

######################################################################
# 5) start test machines and load openzfs module
######################################################################

set -eu

# wait for poweroff to succeed
PID=`pidof /usr/bin/qemu-system-x86_64`
tail --pid=$PID -f /dev/null
sudo virsh undefine openzfs

PUBKEY=`cat ~/.ssh/id_ed25519.pub`
OSv=`cat /var/tmp/osvariant.txt`
OS=`cat /var/tmp/os.txt`

# NOT OKAY:
# 2x CPU=4 RAM=7 -> AlmaLinux 9 (3h) - fault/auto_replace_002_pos
# 2x CPU=4 RAM=7 -> CentOS 9 (3h 2m) - io/io_uring + cli_root/zpool_status/zpool_status_008_pos
# 2x CPU=4 RAM=7 -> Fedora 39 (3h 28m) - fault/auto_spare_001_pos
# 2x CPU=4 RAM=7 -> Ubuntu 20 (2h 49m) - cli_root/zfs_copies/zfs_copies_006_pos !!??
# 2x CPU=4 RAM=7 -> Ubuntu 24 (3h 10m) - history/history_007_pos (always!)

# re-definition of cpu and ram per operating system
case "$OS" in
  freebsd*)
    # 2x CPU=4 RAM=6 -> FreeBSD 13 (2h 10m)
    # 2x CPU=4 RAM=6 -> FreeBSD 13r (2h 10m)
    # 2x CPU=4 RAM=6 -> FreeBSD 14 (2h 10m)
    # 2x CPU=4 RAM=6 -> FreeBSD 14r (2h 10m)
    VMs=2
    CPU=4
    RAM=6
    ;;
  *)
    # 2x CPU=4 RAM=7 -> Almalinux 8 (3h 12m)
    # 2x CPU=4 RAM=7 -> Debian 11 (3h 11m)
    # 2x CPU=4 RAM=7 -> Ubuntu 22 (3h 26m)
    # 2x CPU=4 RAM=7 -> Fedora40 (3h 33m)
    VMs=2
    CPU=4
    RAM=7
    ;;
esac

echo $VMs > /var/tmp/vms.txt

for i in `seq 1 $VMs`; do
  echo "Generating disk for vm$i..."
  sudo qemu-img create -q -f qcow2 -F qcow2 \
    -o compression_type=zstd,cluster_size=256k \
    -b /mnt/tests/openzfs.qcow2 "/mnt/tests/vm$i.qcow2"

  cat <<EOF > /tmp/user-data
#cloud-config

fqdn: vm$i

# user:zfs password:1
users:
- name: root
  shell: $BASH
- name: zfs
  sudo: ALL=(ALL) NOPASSWD:ALL
  shell: $BASH
  lock-passwd: false
  passwd: \$1\$EjKAQetN\$O7Tw/rZOHaeBP1AiCliUg/
  ssh_authorized_keys:
    - $PUBKEY

growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
EOF

  sudo virsh net-update default add ip-dhcp-host \
    "<host mac='52:54:00:83:79:0$i' ip='192.168.122.1$i'/>" --live --config

  sudo virt-install \
    --os-variant $OSv \
    --name "vm$i" \
    --cpu host-passthrough \
    --virt-type=kvm --hvm \
    --vcpus=$CPU,sockets=1 \
    --memory $((1024*RAM)) \
    --memballoon model=virtio \
    --graphics none \
    --cloud-init user-data=/tmp/user-data \
    --network bridge=virbr0,model=e1000,mac="52:54:00:83:79:0$i" \
    --disk /mnt/tests/vm$i.qcow2,bus=virtio,cache=none,format=qcow2,driver.discard=unmap \
    --import --noautoconsole >/dev/null
done

# trim the qcow2 files
echo "exec 1>/dev/null 2>/dev/null" > cronjob.sh
for i in `seq 1 $VMs`; do
  echo "virsh domfstrim vm$i" >> cronjob.sh
done
echo "fstrim /mnt" >> cronjob.sh
sudo chmod +x cronjob.sh
sudo mv -f cronjob.sh /root/cronjob.sh
echo '*/30 * * * *  /root/cronjob.sh' > crontab.txt
sudo crontab crontab.txt
rm crontab.txt

# check if the machines are okay
echo "Waiting for vm's to come up...  (${VMs}x CPU=$CPU RAM=$RAM)"
for i in `seq 1 $VMs`; do
  while true; do
    ssh 2>/dev/null zfs@192.168.122.1$i "uname -a" && break
  done
done
echo "All $VMs VMs are up now."

# Save the VM's serial output (ttyS0) to /var/tmp/console.txt
# - ttyS0 on the VM corresponds to a local /dev/pty/N entry
# - use 'virsh ttyconsole' to lookup the /dev/pty/N entry
RESPATH="/var/tmp/test_results"
for i in `seq 1 $VMs`; do
  mkdir -p $RESPATH/vm$i
  read "pty" <<< $(sudo virsh ttyconsole vm$i)
  sudo nohup bash -c "cat $pty > $RESPATH/vm$i/console.txt" &
done
OS=`cat /var/tmp/osname.txt`
echo "Console logging for $OS started."
