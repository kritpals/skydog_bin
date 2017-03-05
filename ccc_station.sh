#!/bin/sh
#
# Copyright 2010-2013 PowerCloud Systems, All Rights Reserved
#
#  Station Zone Session Start/Stop Script
#
#  Available environment:
# 
#    $IFACE           - interface name
#    $MAC             - mac address of station
#    $IP              - ip address of station
#    $IN_PKTS         - input (recvd) packets
#    $OUT_PKTS        - output (sent) packets
#    $IN_BYTES        - bytes (recvd) packets
#    $OUT_BYTES       - bytes (sent) packets
#    $IN_LOCAL_BYTES  - local bytes (recvd) packets
#    $OUT_LOCAL_BYTES - local bytes (sent) packets
#    $SINCE           - time() of insertion
#    $LAST            - time() of last packet

#echo "$1:$IFACE:$MAC:$IP:$IN_PKTS:$OUT_PKTS:$IN_BYTES:$OUT_BYTES" >> /tmp/st.log

#case "$1" in
#    start)
#	;;
#    stop)
#	;;
#esac

/tmp/cloud/ccc-cmd script add /tmp/cloud/ccc_station_change.sh
