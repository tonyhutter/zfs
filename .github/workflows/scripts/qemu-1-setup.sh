#!/usr/bin/env bash

######################################################################
# 1) setup the action runner to start some qemu instance
######################################################################

set -eu

echo "Info:"
mount
lsblk
sudo swapon --show

ls -l /mnt/swapfile

echo "resize swap"

# Turn swap off
sudo swapoff -a

# Create an empty swapfile
sudo dd if=/dev/zero of=/mnt/swapfile bs=1G count=16

# Set the correct permissions
sudo chmod 0600 /mnt/swapfile

sudo mkswap /mnt/swapfile
sudo swapon /mnt/swapfile

echo "Swap now:"
sudo swapon --show

# docker isn't needed, free some memory
sudo systemd-run --wait docker system prune --force --all --volumes
sudo systemctl stop docker.socket
sudo apt-get remove docker-ce-cli docker-ce podman

# remove unneeded things
sudo apt-get remove google-chrome-stable snapd

# install needed packages
sudo apt-get update
sudo apt-get install axel cloud-image-utils daemonize guestfs-tools \
  virt-manager linux-modules-extra-`uname -r`

# remove unused software
df -h /
sudo systemd-run --wait rm -rf \
  /opt/* \
  /usr/local/* \
  /usr/share/az* \
  /usr/share/dotnet \
  /usr/share/gradle* \
  /usr/share/miniconda \
  /usr/share/swift \
  /var/lib/gems \
  /var/lib/mysql \
  /var/lib/snapd

# disk usage afterwards
sudo df -h /
sudo df -h /mnt
sudo fstrim -a

# generate ssh keys
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -q -N ""

# enable zswap
echo 1 | sudo tee /sys/module/zswap/parameters/enabled
echo lz4 | sudo tee /sys/module/zswap/parameters/compressor

