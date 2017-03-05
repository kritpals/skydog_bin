#!/bin/sh
#
# Copyright 2010-2012 PowerCloud Systems, All Rights Reserved
#
# Handles a change in station of interfaces
#
#  Available environment:
# 
#    $IFACE           - interface name
#    $MAC             - mac address of interface
#    $IP              - ip address of interface
#    $UP              - if the interface is now in UP state
#    $RUNNING         - if the interface is now in RUNNING state
#    $OLD_UP          - if the interface is WAS in UP state
#    $OLD_RUNNING     - if the interface is WAS in RUNNING state
#    $IN_PKTS         - input (recvd) packets
#    $OUT_PKTS        - output (sent) packets
#    $IN_BYTES        - bytes (recvd) packets
#    $OUT_BYTES       - bytes (sent) packets
#    $IN_LOCAL_BYTES  - local bytes (recvd) packets
#    $OUT_LOCAL_BYTES - local bytes (sent) packets

case "$1" in 
    new)
	;;
    update)
	case "$IFACE" in
	    br-wan|eth1|eth0.2)
		if [ "$OLD_RUNNING" = "0" -a "$RUNNING" = "1" ]
		then
		    kill -USR2 $(cat /var/run/udhcpc-*.pid)
		    kill -USR1 $(cat /var/run/udhcpc-*.pid)
		fi
		;;
	esac
	;;
esac

