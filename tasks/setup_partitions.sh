#!/bin/bash

source /usr/lib/k8r/variables.cfg

# Filter out the last digits only to get a "device prefix" representation,
# like /dev/sda from /dev/sda1 of /dev/mmcblk0p from /dev/mmcblk0p1
DEVPATH=`blkid | grep system-boot | awk -F: {'print $1'} | sed 's/[0-9]*$//g'`
# Remove trailing 'p', if any, from loop or mmcblk devices to get device name.
DEVICE=`echo $DEVPATH | sed 's/p*$//g'`

WORKING_PARTITION=`blkid | grep ${DEVPATH}3`

if [ "$WORKING_PARTITION" != "" ] ; then
  echo "ERROR: Working partition is already present, cannot proceed with partitioning"
  exit
else
  # Find disk parameters
  PARTED_OUTPUT="`parted --machine $DEVICE unit b print free`"
  FREE_SPACE_START=`echo "$PARTED_OUTPUT" | tail -n 1 | awk -F':' {'print $2'}`
  DISK_END="`parted --machine ${DEVICE} unit MB print | grep $DEVICE | awk -F':' {'print $2'} | sed 's/MB//g'`"

  if [ "$KUBEADM_JOIN_STRING" = "" ] ; then
    echo "KUBEADM_JOIN_STRING is not set."
    echo "Setting disk layout for k8s MASTER node."
    WORKING_PARTITION_END=$((DISK_END-1000))
    MASTER_PARTITION_START=$((DISK_END-999))
    echo "Creating working partition on $DEVICE start $FREE_SPACE_START end $WORKING_PARTITION_END"
    parted --script -a opt $DEVICE mkpart primary ext4 $FREE_SPACE_START $WORKING_PARTITION_END
    echo "Creating master partition on $DEVICE start $MASTER_PARTITION_START end $DISK_END"
    parted --script -a opt $DEVICE mkpart primary ext4 $MASTER_PARTITION_START 100%
    echo "Updating partition map in kernel memory"
    partprobe $DEVICE
  else
    echo "Setting disk layout for k8s WORKER node."
    echo "Creating ext4 partition on $DEVICE start $FREE_SPACE_START end $DISK_END"
    parted --script -a opt $DEVICE mkpart primary ext4 $FREE_SPACE_START 100%
    echo "Updating partition map in kernel memory"
    partprobe $DEVICE
  fi
  echo "Done partitioning, will now write the system onto working partition."
  bash /usr/lib/k8r/tasks/update_working_partition.sh
fi

