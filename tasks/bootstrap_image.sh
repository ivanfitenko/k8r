#!/bin/bash

source /usr/lib/k8r/variables.cfg

if [ "$K8S_VERSION" = "" ] ; then
  echo "K8S_VERSION setting missing in /var/lib/k8r/variables.cfg, exiting"
fi

ALL_DEV="`blkid`"
# A newly flashed disk would have only two partitions, "system-boot" and
# "writable". However, just in case, let's use only the first partition
# labelled "writable"
# FIXME: The comment abose appears to be unrelated as of now. These variables
# FIXME: are not used anymore and should be deleted.
WORKING_PART=`echo "$ALL_DEV" | grep 'LABEL="writable"'| head -n 1  | awk -F':' {'print $1'} | head -n 1`
EFI_BOOT_PART=`echo "$ALL_DEV" | grep 'LABEL="system-boot"'| head -n 1  | awk -F':' {'print $1'} | head -n 1`

echo "Disabling FS auto-resizing on first boot."
sed -i '/.*growpart.*/d;/.*resizefs.*/d' /etc/cloud/cloud.cfg

echo "Disabling password locking in cloud-init: it is handled by k8r build script now."
sed -i 's/lock_passwd\:\ True/lock_passwd\:\ False/g' /etc/cloud/cloud.cfg

#clean up logs to ensure that we have free space
journalctl --vacuum-size=1

# Make things faster by stopping unattended-upgrades
echo "Stopping unattended upgrade service. This may take a while"
systemctl stop unattended-upgrades.service

#FIXME: need to start snapd for the following to work. Snapd kinda suxxxx
echo "Removing huge and unnescessary lxc and lxd snap packages"
snap remove lxc
snap remove lxd

#FIXME: Some weird magic happens at this place. If we add this module at this
#FIXME: point, the file becomes some binary garbage after it is packed into
#FIXME: image and then written to disk. Different ubuntu releases, different
#FIXME: of the script - all the same. Could that be a bug in FS of RPI4b's CPU?
#FIXME: I don't know. Just moving it from bootstrap_image.sh to setup_node.sh
#FIXME: to run on startup.
echo "Load br_netfilter at boot time. Kubeadm requires this for a reason."
echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sysctl --system

echo "Updating package cache"
apt -y update

echo "Setting DEBIAN_FRONTEND=noninteractive to run in unattended manner"
export DEBIAN_FRONTEND=noninteractive
echo "Removing cloud-initramfs-tools (bug #1967593 on launchpad)"
apt -y -o=Dpkg::Use-Pty=0 remove cloud-initramfs-copymods
echo "Installing containerd"
apt -y -o=Dpkg::Use-Pty=0 install containerd
echo "Configuring containerd. Errors related to /proc/cpuinfo can be safely ignored."
if [ ! -d /etc/containerd ] ; then
  mkdir /etc/containerd
fi

if [ "$INSECURE_REGISTRY" != "" ] ; then
  echo "Configuring insecure registry at $INSECURE_REGISTRY"
  CONTAINERD_CONFIG="`containerd config default`"
  # ...registry.config section present by default, update it
  if [ "`echo $CONTAINERD_CONFIG | grep '\[plugins.\"io.containerd.grpc.v1.cri\".registry.configs\]'`" != "" ] ; then
    echo "$CONTAINERD_CONFIG" \
      | awk '1; /\[plugins."io.containerd.grpc.v1.cri".registry.mirrors\]/{ \
      print "        [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"'$INSECURE_REGISTRY'\"]" ; \
      print "          endpoint = [\"http://'$INSECURE_REGISTRY'\"]" }' \
      | awk '1;  /\[plugins."io.containerd.grpc.v1.cri".registry.configs\]/{ \
      print "        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"'$INSECURE_REGISTRY'\".tls]"; \
      print "          insecure_skip_verify = true" }' \
    > /etc/containerd/config.toml
  else
  # ...registry.config section absent by default, create and add config
    echo "$CONTAINERD_CONFIG" \
      | awk '1; /\[plugins."io.containerd.grpc.v1.cri".registry.mirrors\]/{ \
      print "        [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"'$INSECURE_REGISTRY'\"]" ; \
      print "          endpoint = [\"http://'$INSECURE_REGISTRY'\"]" }' \
      | awk '1; /\[plugins."io.containerd.grpc.v1.cri".registry\]/{ \
      print "      [plugins.\"io.containerd.grpc.v1.cri\".registry.configs]" ; \
      print "        [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"'$INSECURE_REGISTRY'\".tls]"; \
      print "          insecure_skip_verify = true" }' \
    > /etc/containerd/config.toml
  fi
else
    echo "$CONTAINERD_CONFIG" > /etc/containerd/config.toml
fi

echo "Enabling systemd cgroup driver for containerd"
sed -i 's/SystemdCgroup\ =.*/SystemdCgroup = true/g' /etc/containerd/config.toml
echo "Setting pause container version to 3.9 vs default 3.6"
# FIXME: see warning below
echo "WARNING: if your ubuntu image is newer that 22.04, then this might actually"
echo "WARNING: downgrade your pause image. In this case, the script needs to be fixed."
sed -i 's/sandbox_image\ =.*/sandbox_image = \"registry.k8s.io\/pause:3.9\"/g' /etc/containerd/config.toml

echo "Installing NFS client"
apt -y -o=Dpkg::Use-Pty=0 install nfs-common

echo "Installing k8s packages"
apt install -y -o=Dpkg::Use-Pty=0 apt-transport-https curl
K8S_MAJOR_MINOR=`echo $K8S_VERSION| awk -F. {'print $1"."$2}'`
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key | gpg --dearmor > /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v'$K8S_MAJOR_MINOR'/deb/ /' >/etc/apt/sources.list.d/kubernetes.list
apt -y update
echo "Finding deb package versions for kubelet, kubeadm and kubectl"
# Using dash after k8s version in grep to exclude matches like 1.2.33 for
# requested 1.2.3. This adhers to versioning converntion that the packages have
# build version suffix is separated by a dash. If this changes, the logic here will
# be broken and will need to be adjusted to whatever the new versioning would be.
KUBEADM_PKG_VERSION=`apt-cache madison kubeadm | grep "${K8S_VERSION}-" | head -n 1 | awk -F\| {'print $2'} | tr -d [:space:]`
KUBELET_PKG_VERSION=`apt-cache madison kubelet | grep -E "${K8S_VERSION}-" | head -n 1 | awk -F\| {'print $2'} | tr -d [:space:]`
KUBECTL_PKG_VERSION=`apt-cache madison kubectl | grep -E "${K8S_VERSION}-" | head -n 1 | awk -F\| {'print $2'} | tr -d [:space:]`
echo "Installing packages: kubelet=${KUBELET_PKG_VERSION} kubeadm=${KUBEADM_PKG_VERSION} kubectl=${KUBECTL_PKG_VERSION}"
apt install -y -o=Dpkg::Use-Pty=0 kubelet=${KUBELET_PKG_VERSION} kubeadm=${KUBEADM_PKG_VERSION} kubectl=${KUBECTL_PKG_VERSION}
apt-mark hold kubelet kubeadm kubectl

echo "Clean up downloaded packages, package lists and logs"
apt-get -y clean
rm -Rf /var/lib/apt/lists
#clean up logs again: they are plain trash to a new system, but use disk space
journalctl --vacuum-size=1

echo "Enabling boot-time task to setup K8S node."
cp -f /usr/lib/k8r/tasks/setup_node.sh /var/spool/k8r/tasks/

echo
echo "====================================================================="
echo "Done"
echo "WARNING: PLEASE CHECK THE LOGS ABOVE"
echo "IF ANYTHING LOOKS WRONG, PLEASE RE-RUN THIS SCRIPT"
echo "(except for \"Re-reading the partition table failed.\" message which is"
echo "safe to ignore)"
echo
