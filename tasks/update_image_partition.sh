#!/bin/bash

# critical task: fail on any error
set -e

source /usr/lib/k8r/variables.cfg

# Allow overriding image path with a parameter
LOCAL_IMAGE_PATH="$1"

if [ "$HTTP_IMAGE_URL" = "" -a "$LOCAL_IMAGE_PATH" = "" ] ; then
  echo "HTTP_IMAGE_URL setting was not configured and image path was not provided."
  echo "Run this as \"$0 /path/to/image.img\" or set HTTP_IMAGE_URL in variables.cfg"
  echo "Exiting now."
  exit 1
fi

if [ "$LOCAL_IMAGE_PATH" != "" ] ; then 
  if [ ! -r "$LOCAL_IMAGE_PATH"/image.img ] ; then
    echo "ERROR: cannot read local image $LOCAL_IMAGE_PATH/image.img. Exiting."
  elif [ ! -r "$LOCAL_IMAGE_PATH"/boot.img ] ; then
    echo "ERROR: cannot read local boot image $LOCAL_IMAGE_PATH/boot.img. Exiting."
    exit 1
  fi
fi

ALL_DEV="`blkid`"
BOOT_DEV=`echo "$ALL_DEV" | grep 'LABEL="system-boot"'| head -n 1  | awk -F':' {'print $1'} `
IMAGE_DEV=`echo "$ALL_DEV" | grep 'LABEL="image"'| head -n 1  | awk -F':' {'print $1'} `

if [ "$LOCAL_IMAGE_PATH" = "" ] ; then
  #FIXME: Check free space before downloading.
  #FIXME: Add checksum verification.
  echo "Downloading boot image from $HTTP_IMAGE_URL"
  curl -Lo /boot.img $HTTP_IMAGE_URL/boot.img
  echo "Writing boot image to boot partition $BOOT_DEV"
  dd if=/boot.img of=$BOOT_DEV status=progress
  echo "Downloading image from $HTTP_IMAGE_URL"
  curl -Lo /image.img $HTTP_IMAGE_URL/image.img
  echo "Writing image to image partition $IMAGE_DEV"
  dd if=/image.img of=$IMAGE_DEV bs=100M status=progress
else
  echo "Writing image $LOCAL_IMAGE_PATH/boot.img to image partition $BOOT_DEV"
  dd if=$LOCAL_IMAGE_PATH/boot.img of=$BOOT_DEV bs=100M status=progress
  echo "Writing image $LOCAL_IMAGE_PATH/image.img to image partition $IMAGE_DEV"
  dd if=$LOCAL_IMAGE_PATH of=$IMAGE_DEV bs=100M status=progress
fi

echo "Verifying FS at target partitions $BOOT_DEV"
fsck.vfat -a $BOOT_DEV || true
echo "Verifying FS at target partition $IMAGE_DEV"
# e2fsck will return error when fixing a corrupted FS, so need to suppress it
e2fsck -yf $IMAGE_DEV || true
# if there were any changes, they will need yet another fsck to mark it clean
e2fsck -yf $IMAGE_DEV || true
echo "Resizing fs on working partition $IMAGE_DEV to all available space"
resize2fs $IMAGE_DEV
echo "Ensuring proper label on boot partition"
fatlabel $BOOT_DEV system-boot
echo "Ensuring proper label on image partition"
e2label $IMAGE_DEV image
echo "Done updating partitions"
# set error handling back to normal
set +e
