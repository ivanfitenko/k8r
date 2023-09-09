#!/bin/bash

source /usr/lib/k8r/variables.cfg

# Filter out the last digits only to get a "device prefix" representation,
# like /dev/sda from /dev/sda1 of /dev/mmcblk0p from /dev/mmcblk0p1
DEVPATH=`blkid | grep system-boot | awk -F: {'print $1'} | sed 's/[0-9]*$//g'`
#FIXME: maybe no need to know this here? It's not used
# Remove trailing 'p', if any, from loop or mmcblk devices to get device name.
DEVICE=`echo $DEVPATH | sed 's/p*$//g'`

WORKING_PARTITION=`blkid | grep ${DEVPATH}3`

if [ "$WORKING_PARTITION" != "" ] ; then
  echo "Working partition is already present, skipping partitioning steps."
  if [ "`findmnt -n --raw --evaluate --output=source /`" = "${DEVPATH}2" ] ; then
    echo "Running from image partition."
    echo "Will dump image onto working partition and reboot into it"
    bash /usr/lib/k8r/tasks/update_working_partition.sh
    if [ "$?" != "0" ] ; then
      echo "ERROR: update_working_partition.sh returned non-zero. Exiting."
      exit 1
    else
      echo "Rebooting"
      reboot
    fi
  fi
else
  echo "Working partition was not found, will partition disk and write data."
  bash /usr/lib/k8r/tasks/setup_partitions.sh
  if [ "$?" != 0 ] ; then
    echo "ERROR: setup_partitions.sh returned non-zero. Exiting."
    exit 1
  else
    echo "Rebooting"
    reboot
  fi
fi

#FIXME: Some weird magic happens at this place. If we add this module into image
#FIXME: building script, the file becomes some binary garbage after it is packed
#FIXME: into image and then written to disk. Different ubuntu releases, verions
#FIXME: of the script - all the same. Could that be a bug in FS of RPI4b's CPU?
#FIXME: I don't know. Just moving it from bootstrap_image.sh to setup_node.sh
#FIXME: to run on startup.
echo "Load br_netfilter at boot time. Kubeadm requires this for a reason."
echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf
modprobe br_netfilter

MASTER_PARTITION=`blkid | grep ${DEVPATH}4`

# Set hostname from IP of an interface having an external route, replacing dots
# with dashes.
NEWHOSTNAME=`ip route get 8.8.8.8 | head -n1 | grep -Eo '([0-9]*\.){3}[0-9]*' \
             | tail -n1 | tr . - `
while [ "$NEWHOSTNAME" = "" ] ; do
  echo "No hostname yet, sleeping for 10 seconds before retry"
  sleep 10
  NEWHOSTNAME=`ip route get 8.8.8.8 | head -n1 \
          | grep -Eo '([0-9]*\.){3}[0-9]*' | tail -n1 | tr . - `
done
echo "Setting hostname to $NEWHOSTNAME"
hostname $NEWHOSTNAME
echo $NEWHOSTNAME > /etc/hostname

echo "Restarting containerd and kubelet to pick up hostname changes"
systemctl restart containerd.service
systemctl restart kubelet.service

if [ "$MASTER_PARTITION" != "" ] ; then
  echo "Found partition for master node persistent data. Bootstrapping master."
  # Let's save some time. Run this job directly and immediately instead of 
  # scheduling it for the next minute
  bash /usr/lib/k8r/tasks/bootstrap_master.sh
elif [ "$KUBEADM_JOIN_STRING" != "" ] ; then
  echo "Joining k8s cluster as node"
  bash -c "$KUBEADM_JOIN_STRING"
else
  echo "ERROR: no master partition found and KUBEADM_JOIN_STRING not set. Cannot join cluster. Remove this line from /etc/motd when fixed" | tee -a /etc/motd
fi
