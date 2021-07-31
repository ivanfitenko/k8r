#!/bin/bash

# critical task: fail on any error
set -e

ALL_DEV="`blkid`"
IMAGE_DEV=`echo "$ALL_DEV" | grep 'LABEL="image"'| head -n 1  | awk -F':' {'print $1'} `
WORKING_PART=`echo "$ALL_DEV" | grep 'LABEL="writable"'| head -n 1  | awk -F':' {'print $1'} `

# change bootable device to image partition

e2label $IMAGE_DEV writable
e2label $WORKING_PART image

# mount image partition to and enable image flashing task
TEMP_DIR=`mktemp -d`
mount $IMAGE_DEV $TEMP_DIR
cp -f $TEMP_DIR/usr/lib/k8r/tasks/update_working_partition.sh $TEMP_DIR/var/spool/k8r/tasks/
umount $TEMP_DIR

# enable reboot post-run task
cp -f /usr/lib/k8r/tasks/reboot.sh /var/spool/k8r/immediate_jobs/

# set error handling back to normal
set +e
