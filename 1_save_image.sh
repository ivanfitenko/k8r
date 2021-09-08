#!/bin/bash

source ./init_settings.sh

echo "Hit enter to dump images from ${DEVICE} to images/image.img and images/boot.img"
read

if [ "`parted -m ${DEVICE} print | grep -v BYT | grep -v ${DEVICE}`" = "" ] ; then
  echo "No partition table on device. Restoring partitions from images/master.partitions"
  dd if=images/master.partitions of=${DEVICE}
  partprobe ${DEVICE}
else
  echo "WARNING: source device contains a valid partition table, while an empty"
  echo "partition table was expected. This could be a sign that something went"
  echo "wrong during image bootstrap process, and a produced image will likely"
  echo "be corrupted. Unless you know what you are doing, it is STRONGLY advised"
  echo "to re-run the whole process from scratch (i.e. re-start with running"
  echo "script 0_prepare_image.sh)"
  echo "Hit Enter to proceed anyway, or CTRL-C to abort."
  read
fi

echo "Ensuring proper label (unbootalble label \"image\") is set on image partition"
e2label ${DEVICEPART}2 image

echo "Dumping image from ${DEVICEPART}1 to images/boot.img"
dd if=${DEVICEPART}1 of=images/boot.img status=progress

echo "Dumping image from ${DEVICEPART}2 to images/image.img"
dd if=${DEVICEPART}2 of=images/image.img status=progress

TEMP_DIR=`mktemp -d`
# ensure latest k8r scripts in image
mount -o loop images/image.img $TEMP_DIR
echo "Installing k8r task files"
rm -rf $TEMP_DIR/usr/lib/k8r/tasks
mkdir -p $TEMP_DIR/usr/lib/k8r/tasks
cp -f tasks/* $TEMP_DIR/usr/lib/k8r/tasks/
cp -f variables.cfg $TEMP_DIR/usr/lib/k8r/variables.cfg
umount $TEMP_DIR
rmdir $TEMP_DIR

echo "Shrinking image to $IMAGE_SPACE_USED megabytes plus 50M reserve"
e2fsck -yf images/image.img
IMAGE_BLOCK_SIZE=`dumpe2fs -h images/image.img 2>/dev/null | grep 'Block size' | awk {'print $NF'}`
IMAGE_MIN_SIZE=`resize2fs -P images/image.img | tail -n 1 | awk {'print $NF'}`
IMAGE_SIZE_TARGET=`echo $IMAGE_MIN_SIZE+50*1024/$IMAGE_BLOCK_SIZE | bc`
resize2fs images/image.img ${IMAGE_SIZE_TARGET}
