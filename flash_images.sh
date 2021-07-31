#!/bin/bash

TARGET_NODE_TYPE="$1"

TEMP_DIR=`mktemp -d`

source ./init_settings.sh

if [ "$TARGET_NODE_TYPE" = "master" ] ; then
  PARTMAP="master.partitions"
elif [ "$TARGET_NODE_TYPE" = "node" ] ; then
  PARTMAP="node.partitions"
  if [ "$KUBEADM_JOIN_STRING" = "" ] ; then
    echo "Unable to flash node without KUBEADM_JOIN_STRING setting in variables.cfg"
    exit 1
  fi
  mount -o loop images/image.img $TEMP_DIR
  echo "Setting KUBEADM_JOIN_STRING from variables.cfg to be used on node boot"
  echo "$KUBEADM_JOIN_STRING" > $TEMP_DIR/usr/lib/k8r/join_string
  umount $TEMP_DIR
else
  echo "Usage: $0 master|node"
  exit 1
fi


echo "WARINING! ALL DATA WILL BE LOST ON $DEVICE"
echo "Hit Enter to flash images from images/ directory:"
echo "$PARTMAP, boot.img, image.img"
read

echo "Setting partitions"
dd if=images/$PARTMAP of=$DEVICE
echo "Updating partition map in kernel memory"
partprobe $DEVICE
echo "Flashing boot partition"
dd if=images/boot.img of=${DEVICEPART}1 status=progress
echo "Flashing image partition"
dd if=images/image.img of=${DEVICEPART}2 status=progress

echo "Checking boot FS on ${DEVICEPART}1"
fsck.vfat -a ${DEVICEPART}1
echo "Checking image FS on ${DEVICEPART}2"
e2fsck -yf ${DEVICEPART}2
echo "Flashing image images/image.img to working partition ${DEVICEPART}3"
dd if=images/image.img of=${DEVICEPART}3 status=progress
echo "Checking partition ${DEVICEPART}3"
e2fsck -yf ${DEVICEPART}3
echo "Relabelling partitions to fix boot order"
fatlabel ${DEVICEPART}1 system-boot
e2label ${DEVICEPART}2 image
e2label ${DEVICEPART}3 writable
echo "Resizing fs on image partition ${DEVICEPART}2 to all available space"
resize2fs ${DEVICEPART}2
echo "Resizing fs on working partition ${DEVICEPART}3 to all available space"
resize2fs ${DEVICEPART}3

mount ${DEVICEPART}3 $TEMP_DIR
## sometimes, the task files get corrupted when image is dumped. Renstall them
#echo "Installing k8r task files"
#rm -rf $TEMP_DIR/usr/lib/k8r/tasks
#mkdir -p $TEMP_DIR/usr/lib/k8r/tasks
#cp -f tasks/* $TEMP_DIR/usr/lib/k8r/tasks/

echo "Enabling k8s master bootstrap or node join task via k8s_cluster_member"
cp -f tasks/k8s_cluster_member.sh $TEMP_DIR/var/spool/k8r/tasks/

umount $TEMP_DIR
rmdir $TEMP_DIR
