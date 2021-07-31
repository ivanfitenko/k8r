#!/bin/bash

DEVPATH=`blkid | grep system-boot | awk -F: {'print $1'} | sed 's/[0-9]*$//g'`

make_persistent_links() {
  # Directory /etc/kubernetes/pki cannot be pre-created because it would break
  # kubeadm init which insists on creating the directory on its own. So
  # we will transfer this directory to persistent partition and make a symlink
  # after kubeadm init is completed
  #rm -Rf /etc/kubernetes/pki
  #ln -sf /master_persistent/pki /etc/kubernetes/pki
  rm -Rf /var/lib/etcd
  ln -sf /master_persistent/etcd /var/lib/etcd
  rm -Rf /var/lib/kubelet/pki
  if [ ! -d /var/lib/kubelet ] ; then
    mkdir /var/lib/kubelet
  fi
  ln -sf /master_persistent/kubelet_pki /var/lib/kubelet/pki
  rm -f /etc/kubernetes/{admin.conf,kubelet.conf,bootstrap-kubelet.conf,controller-manager.conf,scheduler.conf}
  ln -sf /master_persistent/confs/{admin.conf,kubelet.conf,bootstrap-kubelet.conf,controller-manager.conf,scheduler.conf} /etc/kubernetes/
  rm -f /var/lib/kubelet/config.yaml
  ln -sf /master_persistent/confs/kubelet_config.yaml /var/lib/kubelet/config.yaml
}

source /usr/lib/k8r/variables.cfg

# Explicitlty install requested k8s version, we had all the components installed
# exactly for it, not for STABLE-1
KUBEADM_ARGS=$KUBEADM_ARGS" --kubernetes-version "$K8S_VERSION

# force using containerd
if [ "$CRI_TYPE" = "docker" ] ; then
  echo "Docker was set as CRI"
  KUBEADM_ARGS=$KUBEADM_ARGS" --cri-socket /var/run/docker.sock"
else
  # use containerd by default
  echo "Using containerd as a default CRI"
  KUBEADM_ARGS=$KUBEADM_ARGS" --cri-socket /run/containerd/containerd.sock"
fi

# By default, use unlimited token TTL
TOKEN_TTL=${TOKEN_TTL:-0}
KUBEADM_ARGS=$KUBEADM_ARGS" --token-ttl "$TOKEN_TTL

POD_NETWORK_CIDR=${POD_NETWORK_CIDR:-"172.30.0.0/16"}
KUBEADM_ARGS=$KUBEADM_ARGS" --pod-network-cidr="$POD_NETWORK_CIDR

# This directory is pre-created on persistent partition, so its existence itself
# must not abort initialization. We will manually ensure that it is empty later
KUBEADM_ARGS=$KUBEADM_ARGS" --ignore-preflight-errors=DirAvailable--var-lib-etcd"

if [ "$CONTROL_PLANE_ENDPOINT" != "" ] ; then
  KUBEADM_ARGS=$KUBEADM_ARGS" --control-plane-endpoint "$CONTROL_PLANE_ENDPOINT
fi

if [ ! -r /master_persistent ] ; then
  mkdir /master_persistent
fi

# release potentially locked files on persistent directories
systemctl stop kubelet.service

if [ "`mount ${DEVPATH}4 /master_persistent ; echo -n $?`" != "0" ] ; then
  echo "No FS on master_persistent partitions, will initialize master data"
  mkfs.ext4 ${DEVPATH}4
  e2label ${DEVPATH}4 masterpersistent
  mount ${DEVPATH}4 /master_persistent
  mkdir /master_persistent/etcd
#  mkdir /master_persistent/pki
  mkdir /master_persistent/kubelet_pki
  mkdir /master_persistent/confs
  make_persistent_links
  FRESH_INSTALLATION=1
elif [ ! -d /master_persistent/pki \
          -o ! -d /master_persistent/etcd \
          -o ! -d /master_persistent/kubelet_pki \
          -o ! -d /master_persistent/confs ] ; then
  echo "pki or etcd dirs missing on persistent partitions, will reinitialize"
  mkdir /master_persistent/etcd
#  mkdir /master_persistent/pki
  mkdir /master_persistent/kubelet_pki
  mkdir /master_persistent/confs
  make_persistent_links
  FRESH_INSTALLATION=1
else
  echo "Existing master data found, will keep it intact"
  # critical operation. Fail on any error to preserve data
  umount /master_persistent
  if [ "$?" != "0" ] ; then
    echo "ERROR: Unable to umount persistent data partition."
    echo "Exiting immediately to preserve data."
    exit 1
  fi
  FRESH_INSTALLATION=0
fi

# directories created, bring kubelet back for kubeadm init
systemctl start kubelet.service

echo "Installing kubernetes master"
kubeadm init $KUBEADM_ARGS | tee /var/log/kubeadm.log

export KUBECONFIG=/etc/kubernetes/admin.conf

echo -n "Installing network addon: "
case "$CNI_TYPE" in
  "flannel")
    echo "Using flannel CNI"
    kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
    ;;
  "weave")
    echo "Using weave-net CNI"
    kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
    ;;
  "*")
    # By default, use calico CNI
    echo "Using calico CNI (default)"
    kubectl apply -f https://docs.projectcalico.org/manifests/calico-typha.yaml
    ;;
esac

echo "Master initialization completed, stopping kubelet for post-install tasks"
systemctl stop kubelet.service

if [ "$FRESH_INSTALLATION" = "0" ] ; then
  echo "Replacing pki and etcd directories with links to persistent storage"
  make_persistent_links
  rm -Rf /etc/kubernetes/pki
  ln -sf /master_persistent/pki /etc/kubernetes/pki
else
  echo "Moving /etc/kubernetes/pki to persistent storage"
  mv /etc/kubernetes/pki /master_persistent/
  ln -sf /master_persistent/pki /etc/kubernetes/pki
fi

echo "Adding fstab entry for persistent data"
echo 'LABEL=masterpersistent /master_persistent ext4 defaults 0 2' >> /etc/fstab
#echo '/master_persistent/pki   /etc/kubernetes/pki none    bind,noerror' >> /etc/fstab
#echo '/master_persistent/etcd         /var/lib/etcd   none    bind,noerror' >> /etc/fstab

if [ "$FRESH_INSTALLATION" = "1" ] ; then
  # kubeadm prints it client join string in 2 lines (master join string
  # would contain 3). It this behavior changes, we need to modify "grep -A1" 
  # here. Also, there will be multiple occurence in the logs. We need only
  # the last one.
  KUBEADM_JOIN_STRING="`grep -A1 'kubeadm join' /var/log/kubeadm.log \
                       | sed 's/\\\//g' \
                       | tr -d '\n' \
                       | sed 's/.*kubeadm/kubeadm/g'`"
  echo "Please add (update) the following line in your variables.cfg:"
  echo 'KUBEADM_JOIN_STRING="'$KUBEADM_JOIN_STRING'"'
  echo $KUBEADM_JOIN_STRING > /usr/lib/k8r/join_string
fi
