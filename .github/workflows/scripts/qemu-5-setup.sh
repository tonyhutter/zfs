#!/usr/bin/env bash

######################################################################
# 5) start test machines and load openzfs module
######################################################################

set -eu

# read our defined variables
source /var/tmp/env.txt

# wait for poweroff to succeed
PID=$(pidof /usr/bin/qemu-system-x86_64)
tail --pid=$PID -f /dev/null
sudo virsh undefine --nvram openzfs

# additional options for virt-install
OPTS[0]=""
OPTS[1]=""

RAM=4
case "$OS" in
  debian13)
    # Boot Debian 13 with uefi=on and secureboot=off (ZFS Kernel Module not signed)
    OPTS[0]="--boot"
    OPTS[1]="firmware=efi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no"
    ;;
esac

# setup the testing vm's
PUBKEY=$(cat ~/.ssh/id_ed25519.pub)

# Convert our source disk from RAW to qcow2 so we can snapshot it
sudo mv $DISK /var/lib/libvirt/images/disk
sudo qemu-img convert -f raw -O qcow2 -c -o compression_type=zstd \
  -p /var/lib/libvirt/images/disk /var/lib/libvirt/images/disk.qcow2 >/dev/null
DISK=/var/lib/libvirt/images/disk.qcow2

# start testing VMs
for ((i=1; i<=VMs; i++)); do
  echo "Creating disk for vm$i..."

  cat <<EOF > /tmp/user-data
#cloud-config

fqdn: vm$i

users:
  - name: root
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
  - name: zfs
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $PUBKEY
    # Workaround for Alpine Linux.
    lock_passwd: false
    passwd: '*'

packages:
  - sudo
  - bash

growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
EOF

  sudo virsh net-update default add ip-dhcp-host \
    "<host mac='52:54:00:83:79:0$i' ip='192.168.122.1$i'/>" --live --config

  THIS_DISK=/var/lib/libvirt/images/disk$i
  TESTDISK=/var/lib/libvirt/images/testdisk$i

  # Each VM gets a snapshot of the OS disk and build disk to save space
  sudo qemu-img create -f qcow2 -o backing_file=$DISK -F qcow2 $THIS_DISK

  # Each VM gets their own separate test data disk
  sudo qemu-img create -f qcow2 -o compression_type=zstd $TESTDISK 18G
  echo "libvirt"
  sudo ls -aclh /var/lib/libvirt/images
  sudo virt-install \
    --os-variant $OSv \
    --name "vm$i" \
    --cpu host-passthrough \
    --virt-type=kvm --hvm \
    --vcpus=$CPU,sockets=1 \
    --memory $((1024*RAM)) \
    --memballoon model=virtio,autodeflate=on \
    --graphics none \
    --cloud-init user-data=/tmp/user-data \
    --network bridge=virbr0,model=$NIC,mac="52:54:00:83:79:0$i" \
    --disk $THIS_DISK,bus=virtio,cache=writeback,format=qcow2,driver.discard=unmap,io=io_uring \
    --disk $TESTDISK,bus=virtio,cache=writeback,format=qcow2,driver.discard=unmap,io=io_uring \
    --import --noautoconsole ${OPTS[0]} ${OPTS[1]} || true

done

# generate some memory stats
cat <<EOF > cronjob.sh
exec 1>>/var/tmp/stats.txt
exec 2>&1
echo "********************************************************************************"
uptime
free -m
zfs list
EOF

sudo chmod +x cronjob.sh
sudo mv -f cronjob.sh /root/cronjob.sh
echo '*/5 * * * *  /root/cronjob.sh' > crontab.txt
sudo crontab crontab.txt
rm crontab.txt

# Save the VM's serial output (ttyS0) to /var/tmp/console.txt
# - ttyS0 on the VM corresponds to a local /dev/pty/N entry
# - use 'virsh ttyconsole' to lookup the /dev/pty/N entry
for ((i=1; i<=VMs; i++)); do
  mkdir -p $RESPATH/vm$i
  read "pty" <<< $(sudo virsh ttyconsole vm$i)

  # Create the file so we can tail it, even if there's no output.
  touch $RESPATH/vm$i/console.txt

  sudo nohup bash -c "cat $pty > $RESPATH/vm$i/console.txt" &

  # Write all VM boot lines to the console to aid in debugging failed boots.
  # The boot lines from all the VMs will be munged together, so prepend each
  # line with the vm hostname (like 'vm1:').
  (while IFS=$'\n' read -r line; do echo "vm$i: $line" ; done < <(sudo tail -f $RESPATH/vm$i/console.txt)) &

done
echo "Console logging for ${VMs}x $OS started."

# check if the machines are okay
echo "Waiting for vm's to come up...  (${VMs}x CPU=$CPU RAM=$RAM)"
for ((i=1; i<=VMs; i++)); do
  .github/workflows/scripts/qemu-wait-for-vm.sh vm$i
done
echo "All $VMs VMs are up now."
