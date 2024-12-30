#!/bin/bash

if [ ! -r /image.img.xz ] ; then
  echo "Root FS image file /image.img.xz not found. Aborting installation."
  exit 1
fi

# critical task: fail on any error
set -e

# Filter out the last digits only to get a "device prefix" representation,
# like /dev/sda from /dev/sda1 of /dev/mmcblk0p from /dev/mmcblk0p1
DEVPATH=`blkid | grep system-boot | awk -F: {'print $1'} | sed 's/[0-9]*$//g'`
# Remove trailing 'p', if any, from loop or mmcblk devices to get device name.
DEVICE=`echo $DEVPATH | sed 's/p*$//g'`

IMAGE_PARTITION=${DEVPATH}2
WORKING_PARTITION=${DEVPATH}3

# clean up logs
journalctl --vacuum-size=1
#FIXME: /var/log/task_runner.log is not managed by journald, so need to clean
#FIXME: it up explicitly - but how do we know the location which is set in
#FIXME: systemd unit file?

echo "Cleaning up all pending tasks from source image partition"
rm -f /var/spool/k8r/tasks/*

# just have less errors on FS, we're going to live-copy it next
sync

# IMPORTANT: we are running on image partition, so disk labels are swapped
echo "Writing updated image to working partition $WORKING_PARTITION"
#FIXME: direct FS copy should still be an emergency option
#dd if=$IMAGE_PARTITION of=$WORKING_PARTITION bs=100M status=progress
unxz -v --stdout /image.img.xz | dd of=$WORKING_PARTITION bs=100M
echo "fixing FS at target partition $WORKING_PARTITION"
e2fsck -yf $WORKING_PARTITION || true
echo "Resizing fs on working partition $WORKING_PARTITION to all available space"
resize2fs $WORKING_PARTITION

TEMP_DIR=`mktemp -d`
mount $WORKING_PARTITION $TEMP_DIR

# Task files removed before copying still have their FDs open by this script.
# This means that the deleted tasks may get resurrected at target, delete them.
echo "Cleaning up all pending tasks from target partition"
rm -f $TEMP_DIR/var/spool/k8r/tasks/*
rm -f $TEMP_DIR/var/spool/k8r/immediate_jobs/*

echo "Enabling boot-time task to setup K8S node."
cp -f $TEMP_DIR/usr/lib/k8r/tasks/setup_node.sh $TEMP_DIR/var/spool/k8r/tasks/

umount $TEMP_DIR

echo "Checking fs on updated working partition."
# e2fsck will return error when fixing a corrupted FS, so need to suppress it
e2fsck -yf $WORKING_PARTITION || true

echo "Setting boot target to working partition $WORKING_PARTITION"
e2label $WORKING_PARTITION writable
e2label $IMAGE_PARTITION image
