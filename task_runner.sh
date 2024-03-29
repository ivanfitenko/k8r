#!/bin/bash

while true ; do
  # clean all obsolete post-run tasks
  rm -Rf /var/spool/k8r/immediate_jobs/* > /dev/null 2>&1

  if [ "`ls /var/spool/k8r/tasks/`" != "" ] ; then
    for tasks in /var/spool/k8r/tasks/* ; do
      echo "Executing $tasks"
      bash $tasks
      # done, remove the tasks from queue
      rm $tasks
    done
  fi

  # exectute post-run tasks that might be scheduled to run immediately by
  # already executed regular tasks
  if [ "`ls /var/spool/k8r/immediate_jobs/`" != "" ] ; then
    for tasks in /var/spool/k8r/immediate_jobs/* ; do
      echo "Executing post-run $tasks"
      bash $tasks
      # done, remove the tasks from queue
      rm $tasks
    done
  fi

  # re-run every minute
  sleep 60

done
