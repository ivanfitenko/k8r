#!/bin/bash

source /usr/lib/k8r/variables.cfg

if [ "$1" != "" ] ; then
  echo "Override parameter set: targetting K8S_VERSION $1 instead of $K8S_VERSION"
  K8S_VERSION="$1"
fi

echo "Updating kubeadm"
apt-mark unhold kubeadm && \
apt-get update && apt-get install -y kubeadm=$K8S_VERSION-00 && \
apt-mark hold kubeadm
# since apt-get version 1.1 you can also use the following method
#apt-get update && \
#apt-get install -y --allow-change-held-packages kubeadm=1.21.x-00

echo "Running kubeadm plan."
kubeadm upgrade plan
echo "Upgrading cluster to version $K8S_VERSION"
kubeadm upgrade apply v$K8S_VERSION -y

echo "Done"
