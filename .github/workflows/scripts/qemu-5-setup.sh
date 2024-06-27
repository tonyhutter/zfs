#!/usr/bin/env bash

######################################################################
# 5) start test machines and load openzfs module
######################################################################

set -eu
NUM_VMS=$1

# machine not needed anymore
while pidof /usr/bin/qemu-system-x86_64 >/dev/null; do sleep 1; done
sudo virsh undefine openzfs

###############################################################
# 1) 4GB RAM for host
# 2) 3x 4GB RAM for qemu
###############################################################
PUBKEY=`cat ~/.ssh/id_ed25519.pub`
OSv=`cat /var/tmp/osvariant.txt`
OS=`cat /var/tmp/os.txt`

for i in `seq 1 $NUM_VMS`; do

  OPTS="-q -f qcow2 -o compression_type=zstd,preallocation=off,cluster_size=128k"

  echo "Generating vm$i disks."
  sudo qemu-img create $OPTS -b /mnt/openzfs.qcow2 -F qcow2 "/mnt/vm$i.qcow2"

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

  # Each runner has 4 CPUs and 8GB RAM
  CPUS=4
  MEMGB=8

  sudo virt-install \
    --os-variant $OSv \
    --name "vm$i" \
    --cpu host-passthrough \
    --virt-type=kvm --hvm \
    --vcpus=$CPUS,sockets=1 \
    --memory $((1024*$MEMGB)) \
    --memballoon model=none \
    --graphics none \
    --cloud-init user-data=/tmp/user-data \
    --network bridge=virbr0,model=e1000,mac="52:54:00:83:79:0$i" \
    --disk /mnt/vm$i.qcow2,bus=virtio,cache=writeback,format=qcow2,driver.discard=unmap \
    --import --noautoconsole >/dev/null
done

# check if the machines are okay
echo "Waiting for VMs to come up..."

for i in $(seq 1 $NUM_VMS); do
    LAST=$(($i + 10))
    while true; do
        ssh 2>/dev/null zfs@192.168.122.$LAST "uname -a" && break
    done
done

echo "All done waiting for $NUM_VMS VMs"
