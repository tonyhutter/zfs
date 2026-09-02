#!/bin/bash
#
# Wait for a VM to boot up and become active.  This is used in a number of our
# scripts.
#
# $1: VM hostname or IP address

# Save the VM's serial output (ttyS0) to /var/tmp/console.txt                    
# - ttyS0 on the VM corresponds to a local /dev/pty/N entry                      
# - use 'virsh ttyconsole' to lookup the /dev/pty/N entry
VMs=1
RESPATH=/tmp
sudo virsh list --all || true
       mkdir -p $RESPATH/openzfs
        read "pty" <<< $(sudo virsh ttyconsole openzfs)                                   

        # Create the file so we can tail it, even if there's no output.                
        sudo nohup bash -c "cat $pty > $RESPATH/openzfs/console.txt" &                    

        # Write all VM boot lines to the console to aid in debugging failed boots.     
        # The boot lines from all the VMs will be munged together, so prepend each     
        # line with the openzfs hostname (like 'openzfs:').                                     
        (while IFS=$'\n' read -r line; do echo "openzfs: $line" ; done < <(sudo tail -f $RESPATH/openzfs/console.txt)) &

echo "Console logging for ${VMs}x $OS started." 

while pidof /usr/bin/qemu-system-x86_64 >/dev/null; do
  ssh 2>/dev/null zfs@$1 "uname -a" && break
done
