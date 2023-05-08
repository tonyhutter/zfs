#!/usr/bin/env bash

set -e

export PATH=$PATH:/Library/Frameworks/Python.framework/Versions/Current/bin

_script="$0"
_script_home="$(dirname "$_script")"


_oldPWD="$PWD"
#everytime we cd to the script home
cd "$_script_home"



#find the release number
if [ -z "$VM_RELEASE" ]; then
  if [ ! -e "conf/default.release.conf" ]; then
    echo "The VM_RELEASE is empty,  but the conf/default.release.conf is not found. something wrong."
    exit 1
  fi
  . "conf/default.release.conf"
  VM_RELEASE=$DEFAULT_RELEASE
fi

export VM_RELEASE


#load the release conf
if [ ! -e "conf/$VM_RELEASE.conf" ]; then
  echo "Can not find release conf: conf/$VM_RELEASE.conf"
  echo "The supported release conf: "
  ls conf/*
  exit 1
fi


. conf/$VM_RELEASE.conf


#load the vm conf
_conf_filename="$(echo "$CONF_LINK" | rev  | cut -d / -f 1 | rev)"
echo "Config file: $_conf_filename"

if [ ! -e "$_conf_filename" ]; then
  wget -q "$CONF_LINK"
fi

. $_conf_filename

export VM_ISO_LINK
export VM_OS_NAME
export VM_RELEASE
export VM_INSTALL_CMD
export VM_SSHFS_PKG
export VM_LOGIN_TAG


##########################################################


vmsh="$VM_VBOX"

if [ ! -e "$vmsh" ]; then
  echo "Downloading vbox ${SEC_VBOX:-$VM_VBOX_LINK} to: $PWD"
  wget -O $vmsh "${SEC_VBOX:-$VM_VBOX_LINK}"
fi



osname="$VM_OS_NAME"
ostype="$VM_OS_TYPE"
sshport=$VM_SSH_PORT

ovafile="$osname-$VM_RELEASE.ova"



importVM() {
  _idfile='~/.ssh/mac.id_rsa'

  bash $vmsh addSSHHost $osname $sshport "$_idfile"

  bash $vmsh setup

  if [ ! -e "$ovafile" ]; then
    echo "Downloading $OVA_LINK"
    wget -O "$ovafile" -q "$OVA_LINK"
  fi

  if [ ! -e "id_rsa.pub" ]; then
    echo "Downloading $VM_PUBID_LINK"
    wget -O "id_rsa.pub" -q "$VM_PUBID_LINK"
  fi

  if [ ! -e "mac.id_rsa" ]; then
    echo "Downloading $VM_PUBID_LINK"
    wget -O "mac.id_rsa" -q "$HOST_ID_LINK"
  fi

  ls -lah

  bash $vmsh addSSHAuthorizedKeys id_rsa.pub
  cat mac.id_rsa >$HOME/.ssh/mac.id_rsa
  chmod 600 $HOME/.ssh/mac.id_rsa

  bash $vmsh importVM "$ovafile"

  if [ "$DEBUG" ]; then
    bash $vmsh startWeb $osname
    bash $vmsh startCF
  fi

}



waitForLoginTag() {
  bash $vmsh waitForText "$osname" "$VM_LOGIN_TAG"
}


#using the default ksh
execSSH() {
  exec ssh "$osname"
}

#using the sh 
execSSHSH() {
  exec ssh "$osname" sh
}


addNAT() {
  bash $vmsh addNAT "$osname" "$@"
}

setMemory() {
  bash $vmsh setMemory "$osname" "$@"
}

setCPU() {
  bash $vmsh setCPU "$osname" "$@"
}

startVM() {
  bash $vmsh startVM "$osname"
}



rsyncToVM() {
  _pwd="$PWD"
  cd "$_oldPWD"
  rsync -avrtopg -e 'ssh -o MACs=umac-64-etm@openssh.com' --exclude _actions --exclude _PipelineMapping --exclude _temp  /Users/runner/work/  $osname:work
  cd "$_pwd"
}


rsyncBackFromVM() {
  _pwd="$PWD"
  cd "$_oldPWD"
  rsync -vrtopg   -e 'ssh -o MACs=umac-64-etm@openssh.com' $osname:work/ /Users/runner/work
  cd "$_pwd"
}


installRsyncInVM() {
  ssh "$osname" sh <<EOF

$VM_INSTALL_CMD $VM_RSYNC_PKG

EOF

}

runSSHFSInVM() {
  # remove these when using the vbox v0.0.2 and newer
  echo "Reloading sshd services in the Host"
  sudo sh <<EOF
  echo "" >>/etc/ssh/sshd_config
  echo "StrictModes no" >>/etc/ssh/sshd_config
EOF
  sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist
  sudo launchctl load -w /System/Library/LaunchDaemons/ssh.plist


  if [ -e "hooks/onRunSSHFS.sh" ] && ssh "$osname" sh <hooks/onRunSSHFS.sh; then
    echo "OK";
  elif [ "$VM_SSHFS_PKG" ]; then
    echo "Insalling $VM_SSHFS_PKG"
    ssh "$osname" sh <<EOF

$VM_INSTALL_CMD $VM_SSHFS_PKG

EOF
    echo "Run sshfs"
    ssh "$osname" sh <<EOF

sshfs -o reconnect,ServerAliveCountMax=2,allow_other,default_permissions host:work /Users/runner/work

EOF

  fi


}


#run in the vm, just as soon as the vm is up
onStarted() {
  if [ -e "hooks/onStarted.sh" ]; then
    ssh "$osname" sh <hooks/onStarted.sh
  fi
}


#run in the vm, just after the files are initialized
onInitialized() {
  if [ -e "hooks/onInitialized.sh" ]; then
    ssh "$osname" sh <hooks/onInitialized.sh
  fi
}


onBeforeStartVM() {
  #run in the host machine, the VM is imported, but not booted yet.
  if [ -e "hooks/onBeforeStartVM.sh" ]; then
    echo "Run hooks/onBeforeStartVM.sh"
    . hooks/onBeforeStartVM.sh
  else
    echo "Skip hooks/onBeforeStartVM.sh"
  fi
}

waitForBooting() {
  #press enter for grub booting to speedup booting
  if [ -e "hooks/waitForBooting.sh" ]; then
    echo "Run hooks/waitForBooting.sh"
    . hooks/waitForBooting.sh
  else
    echo "Skip hooks/waitForBooting.sh"
  fi
}


showDebugInfo() {
  echo "==================Debug Info===================="
  pwd && ls -lah
  bash -c 'pwd && ls -lah ~/.ssh/ && cat ~/.ssh/config'
  cat $_conf_filename

  echo "===================Debug Info in VM============="
  ssh "$osname" sh <<EOF
pwd
ls -lah
whoami
tree .

EOF
  echo "================================================"

}

"$@"






















