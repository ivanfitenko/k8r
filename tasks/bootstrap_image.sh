#!/bin/bash

source /usr/lib/k8r/variables.cfg

if [ "$K8S_VERSION" = "" ] ; then
  echo "K8S_VERSION setting missing in /var/lib/k8r/variables.cfg, exiting"
fi

ALL_DEV="`blkid`"
# A newly flashed disk would have only two partitions, "system-boot" and
# "writable". However, just in case, let's use only the first partition
# labelled "writable"
WORKING_PART=`echo "$ALL_DEV" | grep 'LABEL="writable"'| head -n 1  | awk -F':' {'print $1'} | head -n 1`
EFI_BOOT_PART=`echo "$ALL_DEV" | grep 'LABEL="system-boot"'| head -n 1  | awk -F':' {'print $1'} | head -n 1`
SDCARD_DEV="/dev/`lsblk -no pkname $WORKING_PART`"

#clean up logs to ensure that we have free space
journalctl --vacuum-size=1

# Make things faster by stopping unattended-upgrades
echo "Stopping unattended upgrade service. This may take a while"
systemctl stop unattended-upgrades.service

cat <<EOF | tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sysctl --system

echo "Installing docker and containerd"
echo "Setting up the repo"
apt-get update && apt-get install -y \
  apt-transport-https ca-certificates curl software-properties-common gnupg2
echo "Adding Docker's official GPG key"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key --keyring /etc/apt/trusted.gpg.d/docker.gpg add -
echo "Adding the Docker apt repository"
add-apt-repository \
  "deb [arch=arm64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"
echo 'Installing Docker CE'
apt-get update && apt-get install -y \
  containerd.io=1.2.13-2 \
  docker-ce=5:19.03.11~3-0~ubuntu-$(lsb_release -cs) \
  docker-ce-cli=5:19.03.11~3-0~ubuntu-$(lsb_release -cs)
## Create /etc/docker
mkdir /etc/docker
# Set up the Docker daemon
echo "{" | tee /etc/docker/daemon.json
if [ "$INSECURE_REGISTRY" != "" ] ; then
  echo "\"insecure-registries\": [\"$INSECURE_REGISTRY\"]," | tee -a /etc/docker/daemon.json
fi
cat <<EOF | tee -a /etc/docker/daemon.json

  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
# Create /etc/systemd/system/docker.service.d
mkdir -p /etc/systemd/system/docker.service.d
if [ "$CRI_TYPE" = "docker" ] ; then
  echo "Restart Docker to enable changes"
  systemctl daemon-reload
  systemctl restart docker
  systemctl enable docker
else
  echo "Configure containerd"
  if [ "$INSECURE_REGISTRY" != "" ] ; then
    echo "Checking containerd config syntax version"
    CONTAINERD_OLD_SYNTAX_TEST=`containerd config default | grep '\[plugins.cri\]'`
    if [ "$CONTAINERD_OLD_SYNTAX_TEST" = "" ] ; then
      echo "Using version 2 syntax to configure insecure registry"
      containerd config default \
      | awk '1; /\[plugins."io.containerd.grpc.v1.cri".registry.mirrors\]/{ \
      print "        [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"'$INSECURE_REGISTRY'\"]" ; \
      print "          endpoint = [\"http://'$INSECURE_REGISTRY'\"]" }' \
      | awk '1; /\[plugins."io.containerd.grpc.v1.cri".registry\]/{ \
      print "      [plugins.\"io.containerd.grpc.v1.cri\".registry.configs]" ; \
      print "        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"'$INSECURE_REGISTRY'\".tls]"; \
      print "          insecure_skip_verify = true" }' \
      > /etc/containerd/config.toml
    else
      echo "Using obsolete version 1 syntax to configure insecure registry"
      containerd config default \
      | awk '1; /\[plugins.cri.registry.mirrors\]/{ \
      print "        [plugins.cri.registry.mirrors.\"'$INSECURE_REGISTRY'\"]" ; \
      print "          endpoint = [\"http://'$INSECURE_REGISTRY'\"]" }' \
      | awk '1; /\[plugins.cri.registry\]/{ \
      print "      [plugins.cri.registry.configs]" ; \
      print "        [plugins.cri.registry.configs.\"'$INSECURE_REGISTRY'\".tls]" ; \
      print "           insecure_skip_verify = true" }' \
      > /etc/containerd/config.toml
    fi
  else
    containerd config default > /etc/containerd/config.toml
  fi
  echo "Enable containerd and stop docker"
  systemctl daemon-reload
  systemctl stop docker
  systemctl disable docker
  systemctl restart containerd
fi

echo "Installing NFS client"
apt-get -y install nfs-common

echo "Installing k8s packages"
apt-get update && apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
#FIXME: They still have packages under "xenial". No idea how to track when
#FIXME: this changes
cat <<EOF | tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
# than -00 suffix is something that all packages have, so treat it as magic number
apt-get install -y kubelet=${K8S_VERSION}-00 kubeadm=${K8S_VERSION}-00 kubectl=${K8S_VERSION}-00
apt-mark hold kubelet kubeadm kubectl

echo "Clean up downloades packages and logs"
apt-get -y clean
#clean up logs again: they are plain trash to a new system, but use disk space
journalctl --vacuum-size=1

echo "Unmounting efi boot partition to prevent damage to new kernel firmware."
umount $EFI_BOOT_PART

echo "Wiping boot partition table to prevent system from booting back when a"
echo "shutdown was requested. This addresses a known problem which results in"
echo "damaged images."
sfdisk --delete $SDCARD_DEV
echo "Please ignore \"Re-reading the partition table failed.: Device or resource busy\""
echo "message above"

echo
echo "====================================================================="
echo "Done"
echo "WARNING: PLEASE CHECK THE LOGS ABOVE"
echo "IF ANYTHING LOOKS WRONG, ESPECIALLY KUBELET, PLEASE RE-RUN THIS SCRIPT"
echo "(except for \"Re-reading the partition table failed.\" message which is"
echo "safe to ignore)"
echo
echo "If everything looks fine:"
echo
echo "Now run \"sudo shutdown -h now\" command, put the sdcard back into a "
echo "flashing device and run 1_save_image.sh"
echo
