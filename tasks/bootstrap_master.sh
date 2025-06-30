#!/bin/bash

# We don't want to break master, we'd better fail halfway
set -e

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
  rm -f /etc/kubernetes/{admin.conf,kubelet.conf,controller-manager.conf,scheduler.conf}
  ln -sf /master_persistent/confs/{admin.conf,kubelet.conf,controller-manager.conf,scheduler.conf} /etc/kubernetes/
  rm -f /var/lib/kubelet/config.yaml
  ln -sf /master_persistent/confs/kubelet_config.yaml /var/lib/kubelet/config.yaml
}

source /usr/lib/k8r/variables.cfg

# This directory is pre-created on persistent partition, so its existence itself
# must not abort initialization. We will manually ensure that it is empty later
KUBEADM_ARGS=$KUBEADM_ARGS" --ignore-preflight-errors=DirAvailable--var-lib-etcd"

echo "(re-)initializing emply configuration in /var/spool/k8r/kubeadm-config.yaml to use it as configuration source"
echo "---
apiVersion: kubeadm.k8s.io/v1beta3" > /var/spool/k8r/kubeadm-config.yaml

KUBEADM_ARGS=$KUBEADM_ARGS" --config /var/spool/k8r/kubeadm-config.yaml"

echo "Writing apiserver configuration"
echo "kind: ClusterConfiguration" >> /var/spool/k8r/kubeadm-config.yaml

echo "Setting kubernetes version to $K8S_VERSION"
echo "kubernetesVersion: $K8S_VERSION" >> /var/spool/k8r/kubeadm-config.yaml

if [ "$CONTROL_PLANE_ENDPOINT" != "" ] ; then
  echo "Setting control plane endpoint to $CONTROL_PLANE_ENDPOINT"
  echo "controlPlaneEndpoint: \"$CONTROL_PLANE_ENDPOINT\"" >> /var/spool/k8r/kubeadm-config.yaml
fi

POD_NETWORK_CIDR=${POD_NETWORK_CIDR:-"172.30.0.0/16"}
echo "networking:" >> /var/spool/k8r/kubeadm-config.yaml
echo "Setting pod network CIDR to $POD_NETWORK_CIDR"
echo "  podSubnet: \"$POD_NETWORK_CIDR\"" >> /var/spool/k8r/kubeadm-config.yaml

echo "Setting cgroupDriver for kubelet to \"systemd\""
echo "---
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd" >> /var/spool/k8r/kubeadm-config.yaml

# By default, use unlimited token TTL
TOKEN_TTL=${TOKEN_TTL:-0}
echo "Creating bootstrap token with TTL $TOKEN_TTL"
# Format for token is "([a-z0-9]{6}).([a-z0-9]{16})". 
#FIXME: "hex" here means that we only use a-f, which is less secure than a-z
BOOTSTRAP_TOKEN="`openssl rand -hex 3`.`openssl rand -hex 8`"
echo "---
kind: InitConfiguration
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
  - token: \"$BOOTSTRAP_TOKEN\"
    description: \"kubeadm bootstrap token\"
    ttl: \"$TOKEN_TTL\"" >> /var/spool/k8r/kubeadm-config.yaml


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

while [ "$TEST_K8S_VERSION" = "" ] ; do
  echo "Waiting for k8s API to become available and provide server version."
  sleep 30
  TEST_K8S_VERSION=`kubectl version | grep 'Server Version' | awk {'print $NF'} | sed 's/.*v//g'`
done

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
  *)
    # By default, use calico CNI
    echo "Using calico CNI (default)"
    CALICO_VERSION=${CALICO_VERSION:-"3.25.1"}
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v${CALICO_VERSION}/manifests/calico-typha.yaml
    echo "Allowing calico-node to run on master"
    kubectl patch ds -n kube-system calico-node --type='json' -p='[{"op": "add", "path": "/spec/template/spec/tolerations/-", "value": {"operator": Exists}}]'
    echo "Allowing calico-typha to run on master"
    kubectl patch deploy -n kube-system calico-typha --type='json' -p='[{"op": "add", "path": "/spec/template/spec/tolerations/-", "value": {"operator": Exists}}]'
    #echo "Using legacy iptables backend instead of BPF on arm64"
    #kubectl patch -n kube-system FelixConfiguration default --type='json' -p='[{"op": "add", "path": "/spec/iptablesBackend", "value": "Legacy"}]'
    ;;
esac

echo "Master initialized"

# Kubelet would try to restart stopped API server and etcd, so need to stop it
# first.
echo "Stopping kubelet and killing apiserver and etcd for data migrations."
systemctl stop kubelet.service
pkill kube-apiserver
pkill etcd

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

echo "Mounting persistent master data parttition if it was previously unmounted"
mount /master_persistent || true
echo "Starting kubelet to relaunch etcd and kubernetes API server."
systemctl start kubelet.service

#Upgrade

echo "FRESH_INSTALLATION=$FRESH_INSTALLATION. Check if this is correct."

if [ "$FRESH_INSTALLATION" != "1" ] ; then
  echo "Pre-existing master data was detected. Checking if upgrade is needed."
  OLD_K8S_VERSION=`kubectl version | grep 'Server Version' | awk {'print $NF'} | sed 's/.*v//g'`
  while [ "$OLD_K8S_VERSION" = "" ] ; do
    echo "Waiting for k8s API to become available and provide server version."
    sleep 30
    OLD_K8S_VERSION=`kubectl version | grep 'Server Version' | awk {'print $NF'} | sed 's/.*v//g'`
  done


  KUBELET_VERSION=`kubelet --version | awk {'print $NF'} | sed 's/.*v//g'`
  KUBEADM_CLUSTER_VERSION=`kubectl -n kube-system get cm kubeadm-config -o yaml | grep kubernetesVersion | awk '{print $NF}' | sed 's/^v//g'`

  # A little dirty: first compare major-minor-patch for installed kubelet vs
  # installed API server to make sure that we have up-to-date images running,
  # then make the same comparison for kubeadm's configmap vs kubelet to know
  # if we need to migrate API versions and apply migrations.
  if [ "`cut -d'.' -f1 <<< $KUBELET_VERSION`" -le "`cut -d'.' -f1 <<< $OLD_K8S_VERSION`" -a \
       "`cut -d'.' -f2 <<< $KUBELET_VERSION`" -le "`cut -d'.' -f2 <<< $OLD_K8S_VERSION`" -a \
       "`cut -d'.' -f3 <<< $KUBELET_VERSION`" -le "`cut -d'.' -f3 <<< $OLD_K8S_VERSION`" -a \
       "`cut -d'.' -f1 <<< $KUBELET_VERSION`" -le "`cut -d'.' -f1 <<< $KUBEADM_CLUSTER_VERSION`" -a \
       "`cut -d'.' -f2 <<< $KUBELET_VERSION`" -le "`cut -d'.' -f2 <<< $KUBEADM_CLUSTER_VERSION`" -a \
       "`cut -d'.' -f3 <<< $KUBELET_VERSION`" -le "`cut -d'.' -f3 <<< $KUBEADM_CLUSTER_VERSION`" ] ; then
    echo "Kubelet is $KUBELET_VERSION"
    echo "API is $OLD_K8S_VERSION version"
    echo "Kubeadm installed components for $KUBEADM_CLUSTER_VERSION"
    echo "Everything is up to date."
  else
    echo "Kubelet is $KUBELET_VERSION"
    echo "API is $OLD_K8S_VERSION version"
    echo "Kubeadm installed components for $KUBEADM_CLUSTER_VERSION"
    echo "Upgrade is required."
    # Master node might still not be ready even when API is responding. Kubeadm
    # expects the control plane to be fully ready to procees, so need to wait for
    # it to be ready.
    K8S_MASTER_UNREADY_NODES=`kubectl get no | grep control-plane | grep NotReady | wc -l`
    while [ "$K8S_MASTER_UNREADY_NODES" != "0" ] ; do
      echo "Waiting for k8s API to become ready. Unready nodes count: $K8S_MASTER_UNREADY_NODES"
      sleep 30
      K8S_MASTER_UNREADY_NODES=`kubectl get no | grep control-plane | grep NotReady | wc -l`
    done
    # CreateJob check would make the whole upgrade process fail due to some
    # non-fatal conditions, while such conditions could otherwise be addressed
    # by automations during later stages. This check is now disabled.
    echo "Running kubeadm plan."
    kubeadm upgrade plan v$KUBELET_VERSION --ignore-preflight-errors=CreateJob
    echo "Upgrading cluster to version $K8S_VERSION"
    kubeadm upgrade apply v$KUBELET_VERSION -y --ignore-preflight-errors=CreateJob
  fi
fi

echo "Scheduling reboot via post-run task"
cp -f /usr/lib/k8r/tasks/reboot.sh /var/spool/k8r/immediate_jobs/
echo "Done running K8S Master bootstrap script."
