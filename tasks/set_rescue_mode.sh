#!/bin/bash

# critical task: fail on any error
set -e

ALL_DEV="`blkid`"
IMAGE_DEV=`echo "$ALL_DEV" | grep 'LABEL="image"'| head -n 1  | awk -F':' {'print $1'} `
WORKING_PART=`echo "$ALL_DEV" | grep 'LABEL="writable"'| head -n 1  | awk -F':' {'print $1'} `

echo "Setting image partition as bootable device"
e2label $IMAGE_DEV writable
e2label $WORKING_PART image

echo "Mounting image partition and updating motd"
TEMP_DIR=`mktemp -d`
mount $IMAGE_DEV $TEMP_DIR
echo "======= RESCUE MODE =========" >> $TEMP_DIR/etc/motd
echo "Running from image partition in rescue mode. To return to normal" >> $TEMP_DIR/etc/motd
echo "mode, run the following commands and then reboot" >> $TEMP_DIR/etc/motd
echo "e2label $IMAGE_DEV image" >> $TEMP_DIR/etc/motd
echo "e2label $WORKING_PART writable" >> $TEMP_DIR/etc/motd
umount $TEMP_DIR

echo "Rebooting"
reboot
