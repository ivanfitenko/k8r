#!/bin/bash

# critical task: fail on any error
set -e

ALL_DEV="`blkid`"
IMAGE_DEV=`echo "$ALL_DEV" | grep 'LABEL="image"'| head -n 1  | awk -F':' {'print $1'} `
WORKING_PART=`echo "$ALL_DEV" | grep 'LABEL="writable"'| head -n 1  | awk -F':' {'print $1'} `

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
echo "Writing updated image to working partition $IMAGE_DEV"
dd if=$WORKING_PART of=$IMAGE_DEV bs=100M status=progress
echo "fixing FS at target partition $IMAGE_DEV"
# e2fsck will return error when fixing a corrupted FS, so need to suppress it
e2fsck -yf $IMAGE_DEV || true
echo "Resizing fs on working partition $IMAGE_DEV to all available space"
resize2fs $IMAGE_DEV
echo "Swapping partition labels back to normal"
e2label $IMAGE_DEV writable
e2label $WORKING_PART image

TEMP_DIR=`mktemp -d`
mount $IMAGE_DEV $TEMP_DIR

# Task files removed before copying still have their FDs open by this script.
# This means that the deleted tasks may get resurrected at target, delete them.
echo "Cleaning up all pending tasks from target partition"
rm -f $TEMP_DIR/var/spool/k8r/tasks/*
rm -f $TEMP_DIR/var/spool/k8r/immediate_jobs/*

echo "Enabling k8s master bootstrap or node join task via k8s_cluster_member"
cp -f /usr/lib/k8r/tasks/k8s_cluster_member.sh $TEMP_DIR/var/spool/k8r/tasks/

umount $TEMP_DIR

echo "Scheduling reboot via post-run task"
cp -f /usr/lib/k8r/tasks/reboot.sh  /var/spool/k8r/immediate_jobs/

# set error handling back to normal
set +e
