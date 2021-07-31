#!/bin/bash

if [ "`id -u`" != 0 ] ; then
  echo Need to be root to run this
  exit 1
fi

# include sbin dirs, in particular, for parted
export PATH=/sbin:/usr/sbin:/usr/local/sbin:$PATH

source ./variables.cfg

# never set DEVICE from configuration, as it may change over attachments
#if [ -z "$DEVICE" -o -z "$IMAGE" -o -z "$K8S_VERSION" ] ; then
DEVICE="none"
while [ "$DEVICE" = "none" ] ; do
  echo "Enter device to use (e.g. /dev/sdc, /dev/mmcblk1...)"
  read DEVICE
  echo "Checking device $DEVICE..."
  parted -s $DEVICE print
  if [ "$?" != 0 ] ; then
    echo "Device $DEVICE seems to be invalid."
    echo "Please try another device."
    DEVICE="none"
  fi
done

if [ -z "$IMAGE" -o -z "$K8S_VERSION" ] ; then
  echo "Please configure variables.cfg before running this script"
  exit 1
fi


# for mmcblk* devices, set "p" suffix for partitions
if [ "`echo $DEVICE | grep mmcblk`" != "" ] ; then
  DEVICEPART=${DEVICE}p
else
  DEVICEPART=${DEVICE}
fi
