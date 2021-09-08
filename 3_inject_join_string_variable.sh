#!/bin/bash

source variables.cfg

if [ "$KUBEADM_JOIN_STRING" != "" ] ; then
  echo "KUBEADM_JOIN_STRING in variables,cfg is set. Injecting it into image."
else
  echo "ERROR: KUBEADM_JOIN_STRING not set in variables,cfg."
  echo "ERROR: Please set it and re-run the script."
  exit 1
fi

TMP_DIR=`mktemp -d`
mount -o loop images/image.img $TMP_DIR
cp -f variables.cfg $TMP_DIR/usr/lib/k8r/
umount $TMP_DIR
rmdir $TMP_DIR
