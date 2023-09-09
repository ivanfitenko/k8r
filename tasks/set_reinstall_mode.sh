#!/bin/bash

# critical task: fail on any error
set -e

ALL_DEV="`blkid`"
IMAGE_DEV=`echo "$ALL_DEV" | grep 'LABEL="image"'| head -n 1  | awk -F':' {'print $1'} `
WORKING_PART=`echo "$ALL_DEV" | grep 'LABEL="writable"'| head -n 1  | awk -F':' {'print $1'} `

echo "Setting image partition as bootable device"
e2label $IMAGE_DEV writable
e2label $WORKING_PART image

echo "Mounting image partition and ensuring the setup task is active"
TEMP_DIR=`mktemp -d`
mount $IMAGE_DEV $TEMP_DIR
cp -f $TEMP_DIR/usr/lib/k8r/tasks/setup_node.sh $TEMP_DIR/var/spool/k8r/tasks/
umount $TEMP_DIR

echo "Rebooting"
reboot
