#!/bin/sh
# 
# Copyright 2010-2011 PowerCloud Systems
# All Rights Reserved
#
# start redirect-server
i=`ps | grep redirect-server | grep -v grep`
linecnt=`ps | grep redirect-server | grep -v grep | wc -l`
instance=`echo $i | cut -f1 -d" "`
if [ "${instance}" != "" -a linecnt -gt 1 ]; then
   #echo "Existing instance at ${instance}"
   kill -9 ${instance}
   instance=`ps | grep redirect-server | grep -v grep | cut -f1 -d" "`
   if [ "${instance}" != "" ]; then
      echo "Existing Redirect server is not killed properly"
   else
      echo "Existing Redirect server is killed successfully" 
   fi
else
   echo "No existing instance of Redirect server."
fi
sleep 1

