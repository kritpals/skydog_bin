#!/bin/sh
#
# Copyright 2010-2012 PowerCloud Systems, All Rights Reserved
#
# ccc_tc.sh
#   +-- load_modules 
#   |     Loads required modules.
#   |
#   +-- start <down-rate> <up-rate> <burst> <prio>
#   |     Calls load_modules, stop, and then configures
#   |     default policy on WAN and IFB devices for given
#   |     rate, burst, and priority.
#   |
#   +-- setup_iface <iface-num> <iface-names> <down-rate> <up-rate> <down-ceiling> <up-ceiling> <burst> <prio>
#   |     Setup a shaping "interface" by giving it an iface-num, 
#   |     a list of interface to combine (into IFB) and the rate settings.
#   |
#   +---- cls_create <iface-num> <class-num> <name> <down-rate> <up-rate> <down-ceiling> <up-ceiling> <burst> <prio>
#   |     Create a policy (class) on the given iface-num with the given 
#   |     class-num and rate settings.
#   |
#   +---- cls_add <iface-num> <class-num> <ip-proto> <ports>
#   |     Add (mark) traffic rules to the given iface-num/class-num 
#   |     policy for the given protocol and ports.
#   |
#   +---- iface-classes <iface-num> <down-rate> <up-rate> <down-ceiling> <up-ceiling>
#   |     A convenience function to setup a default class configuration 
#   |     for the given <iface-num>.
#   |
#   +-- mac_limit <mac> <id> <down-rate> <up-rate>
#   |     Will limit on a per-device basis to the give rate. 
#   |     The <id> must be unique per device being tracked.
#   |
#   +-- clear_mac_limit <mac> <id> 
#   |     Will remove limit on a per-device basis.
#   |     The <id> must be same as with mac_limit.
#   |
#   +-- status
#   |     Show qdisc and class status.
#   |
#   +-- stop
#   |     Stops all shapping and deletes all qdisc, class, filters, etc.
#   |
#   +-- test
#   |     An example setup (sequence of configurations).
#
#   About the classid formats:
#
#     1:1         - Root class for all interfaces (htb)
#     1:10        - A high priority traffic class (future use)
#     1:1X(1X:)   - Per interface policy (X=1-9) (htb/sfq)
#     1:1XY(1XY:) - Intra interface policies (X=1-9,Y=1-9) (htb/sfq)
#     
#   About the mark formats:
#
#     0xX0       - mark for 1:1X
#     0xYX0      - mark for 1:1XY
#

ccc_quantum=2000

if [ "$CCC_INCLUDE" != "1" ]
then
    cd $(dirname $0)
    . ./ccc_functions.sh
fi

TCTMP=/tmp/.tc
WAN=$(get_wan_device)
ifb=ifb0

ccc_tc()
{
    tc "$@" || echo "ERROR: $*"
}

calc() 
{
    local v=$1
    local p=$2
    echo $((v * $p / 100))
}

tc_enabled()
{
    if [ "$(tc_tables -L tc_forward 2>/dev/null | grep -i connmark)" = "" ]
    then
	echo false
    else
	echo true
    fi
}

tc_ensure_forward() {
   # If tc_forward chain doesn't exist, create it
   if ! iptables -t mangle -nvx -L tc_forward >/dev/null 2>&1; then
	iptables -t mangle -N tc_forward || echo "Failed: iptables -t mangle -N tc_forward"
	iptables -t mangle -A FORWARD -j tc_forward || echo "Failed; iptables -t mangle -A FORWARD -j tc_forward"
   fi
}

tc_tables()
{
    iptables -t mangle "$@" || echo "Failed: iptables -t mangle $*"
}

tc_stop()
{
    tc qdisc show|egrep 'htb 1: dev'|cut -f5 -d' ' | while read dev
    do
	tc qdisc del dev $dev root 
    done

    tc_ensure_forward
    
    tc_tables -F tc_forward
    tc_tables -F PREROUTING 
}

tc_load_modules()
{
    for mod in ifb sch_sfq sch_htb cls_u32 em_u32 cls_fw act_mirred
    do
	insmod $mod 2>/dev/null
    done
}

tc_usage()
{
    echo $*
    echo " +-- load_modules"
    echo " +-- start <down-rate> <up-rate> <burst> <prio>"
    echo " +-- setup_iface <iface-num> <iface-names> <down-rate> <up-rate> <down-ceiling> <up-ceiling> <burst> <prio>"
    echo " +---- cls_create <iface-num> <class-num> <name> <down-rate> <up-rate> <down-ceiling> <up-ceiling> <burst> <prio>"
    echo " +---- cls_add <iface-num> <class-num> <ip-proto> <ports>"
    echo " +---- iface-classes <iface-num> <down-rate> <up-rate> <down-ceiling> <up-ceiling>"
    echo " +-- mac_limit <mac> <id> <down-rate> <up-rate>"
    echo " +-- clear_mac_limit <mac> <id>"
    echo " +-- status"
    echo " +-- stop"
    echo " +-- test"
    exit
}

tc_saveInterfaceLimit() 
{
    local Interfaces="$1"
    local base="$2"

    local LimitUp=$(ccc_v ${base}DefaultLimitUp)
    local LimitDown=$(ccc_v ${base}DefaultLimitDown)
    local Priority=$(ccc_v ${base}DefaultPriority)

    if [ -n "$Interfaces" -a -n "$LimitUp" -a -n "$LimitDown" ] 
    then
	local iface
	for iface in $Interfaces
	do
	    local d=$TCTMP/dev/$iface
	    mkdir -p $d
	    echo "$LimitUp" > $d/up
	    echo "$LimitDown" > $d/down
	    echo "$Priority" > $d/pri
	done
    fi
}

tc_saveInterfaceClassId() 
{
    local Interfaces="$1"
    local classid="$2"

    if [ -n "$Interfaces" -a -n "$classid" ] 
    then
	local iface
	for iface in $Interfaces
	do
	    local d=$TCTMP/dev/$iface
	    mkdir -p $d
	    echo "$classid" > $d/classid
	done
    fi
}

tc_saveStationLimit() 
{
    local MacAddress="$1"
    local base="$2"
    
    local LimitUp=$(ccc_v ${base}LimitUp)
    local LimitDown=$(ccc_v ${base}LimitDown)
    local Priority=$(ccc_v ${base}Priority)

    echo "Station Limit $MacAddress Up=$LimitUp Down=$LimitDown Priority=$Priority"

    if [ -n "$LimitUp" -a -n "$LimitDown" ]
    then
	local d=$TCTMP/sta/$MacAddress
	mkdir -p $d
	echo "$LimitUp" > $d/up
	echo "$LimitDown" > $d/down
	echo "$Priority" > $d/pri
    fi
}

tc_markStations() 
{
    local sta
    for sta in $(ls $TCTMP/sta 2>/dev/null)
    do
	touch $TCTMP/sta/$sta/remove
    done
}

tc_removeStations() 
{
    local mac
    for mac in $(ls $TCTMP/sta 2>/dev/null)
    do
	[ -e $TCTMP/sta/$mac/remove ] && {
	    rm -f $TCTMP/sta/$mac/remove
	    tc_clear_mac_limit $mac
	}
    done
}

tc_resetTcTmp() 
{
    rm -rf $TCTMP
}

tc_nextStationSeq() 
{
    local seq
    [ -d $TCTMP ] || mkdir -p $TCTMP
    if [ -e $TCTMP/seq ]
    then
	seq=$(cat $TCTMP/seq)
	seq=$((seq + 1))
    else
	seq=1000
    fi
    echo "$seq" | tee $TCTMP/seq
}

tc_start() 
{
    local rate_dn=$1
    local rate_up=$2
    local burst=$3
    local prio=$4

    echo "==========> tc_start $@ <========="

    [ "$rate_dn" = "" -o "$rate_up" = "" -o \
	"$burst" = "" -o "$prio" = "" ] && tc_usage "Invalid parameters to start"

    tc_load_modules

    tc_stop

    # Bring up IFB and reduce/set txqueuelen
    ip link set dev $ifb up
    ifconfig $WAN txqueuelen 32
    ifconfig $ifb txqueuelen 32
    
    # Setup WAN device
    tc qdisc del dev $WAN root 2>/dev/null
    ccc_tc qdisc add dev $WAN root handle 1: htb default 1
    
    # Setup WAN device root class with RATE_UP
    ccc_tc class add dev $WAN parent 1: classid 1:1 htb \
	rate $rate_up burst $burst cburst $burst prio $prio \
	quantum $ccc_quantum
    
    # Setup IFB meta-device
    tc qdisc del dev $ifb root  2>/dev/null
    ccc_tc qdisc add dev $ifb root handle 1: htb default 1
    
    # Setup WAN device root class with aggregate RATE_DN
    ccc_tc class add dev $ifb parent 1: classid 1:1 htb \
	rate $rate_dn burst $burst cburst $burst prio $prio \
	quantum $ccc_quantum

    # Create a base class to be used for prirotiy traffic (todo: adjust rate approproiately)
    ccc_tc class add dev $WAN parent 1:1 classid 1:10 htb \
	rate 1kbit ceil $rate_up burst $burst cburst $burst prio 0 \
	quantum $ccc_quantum

    ccc_tc class add dev $ifb parent 1:1 classid 1:10 htb \
	rate 1kbit ceil $rate_dn burst $burst cburst $burst prio 0 \
	quantum $ccc_quantum

    # Restore marks on re-entry (for tc classification)
    tc_tables -I PREROUTING -j CONNMARK --restore-mark
}

tc_setup_iface()
{
    # Set Internet traffic rate by profile
    local profile=$1
    local ifacenm=$2
    local rate_dn=$3
    local rate_up=$4
    local ceil_dn=$5
    local ceil_up=$6
    local burst=$7
    local prio=$8
    
    # Each rate policy has a class and a mark
    local classid_n="1$profile"
    local classid="1:$classid_n"
    local mask="0x00f0"
    local mark="0x${profile}0"

    echo "=====> tc_setup_iface $@ <====="

    # Create the rate class for the policy, setting rate and ceiling
    ccc_tc class add dev $WAN parent 1:1 classid $classid htb \
	rate $rate_up ceil $ceil_up burst $burst cburst $burst prio $prio \
	quantum $ccc_quantum

    ccc_tc class add dev $ifb parent 1:1 classid $classid htb \
	rate $rate_dn ceil $ceil_dn burst $burst cburst $burst prio $prio \
	quantum $ccc_quantum	

    ccc_tc qdisc add dev $WAN parent $classid handle $classid_n: sfq perturb 10
    ccc_tc qdisc add dev $ifb parent $classid handle $classid_n: sfq perturb 10

    # Assign the mark to the class
    ccc_tc filter add dev $WAN parent 1:0 protocol ip u32 \
	match mark $mark $mask flowid $classid

    ccc_tc filter add dev $ifb parent 1:0 protocol ip u32 \
	match mark $mark $mask flowid $classid

    tc_saveInterfaceClassId "$ifacenm" "$classid"

    # For each interface in the policy, assign the mark to through traffic
    for lan in $ifacenm
    do
	ifconfig $lan >/dev/null 2>/dev/null && {
	    # Each interface gets a qdisc and a filter into
	    # the IFB meta-device to be handled aggregately
	    tc qdisc del dev $lan root  2>/dev/null
	    ccc_tc qdisc add dev $lan root handle 1: htb 

	    ccc_tc filter add dev $lan parent 1: protocol ip prio 1 u32 \
		match u32 0 0 action mirred egress redirect dev $ifb

	    # Mark the through traffic on the bridge to/from Internet and this interface
	    tc_ensure_forward
	    tc_tables -A tc_forward -i $lan -o $WAN -j CONNMARK --set-mark $mark 
	    tc_tables -A tc_forward -i $WAN -o $lan -j CONNMARK --set-mark $mark 
	}
    done
}

tc_cls_add()
{
    local profile=$1
    local cls=$2
    local proto=$3
    local ports=$4

    echo "=====> tc_cls_add $@ <====="

    local mask="0x00f0"
    local mark="0x${profile}0"
    local mark_cls="0x${cls}${profile}0"

    tc_ensure_forward
    case "$proto" in
	udp|tcp)
	    ports=$(echo "$ports"|sed 's/ //g')

	    tc_tables -A tc_forward -o $WAN -m connmark --mark $mark/$mask \
		-p $proto -m multiport --destination-ports $ports \
		-j CONNMARK --set-mark $mark_cls 
	    
	    tc_tables -A tc_forward -i $WAN -m connmark --mark $mark/$mask \
		-p $proto -m multiport --source-ports $ports \
		-j CONNMARK --set-mark $mark_cls 
	    ;;
	layer7)
	    ;;
	ifaces)
	    local iface
	    ports=$(echo "$ports"|sed 's/,/ /g')

	    local classid_n="1$profile$cls"
	    local classid="1:$classid_n"

	    tc_saveInterfaceClassId "$ports" "$classid"

	    for iface in $ports
	    do
		
		tc_tables -A tc_forward -o $WAN -i $iface -m connmark --mark $mark/$mask \
		    -j CONNMARK --set-mark $mark_cls 
		
		tc_tables -A tc_forward -i $WAN -o $iface -m connmark --mark $mark/$mask \
		    -j CONNMARK --set-mark $mark_cls 
	    done
	    ;;
    esac

    tc_tables -A tc_forward -i $WAN -m connmark --mark $mark_cls -j RETURN
    tc_tables -A tc_forward -o $WAN -m connmark --mark $mark_cls -j RETURN
}

tc_cls_end()
{
    local profile=$1
    local cls=$2

    echo "=====> tc_cls_end $@ <====="

    local mask="0x00f0"
    local mark="0x${profile}0"
    local mark_cls="0x${cls}${profile}0"

    tc_ensure_forward
    tc_tables -A tc_forward -o $WAN -m connmark --mark $mark/$mask \
	-j CONNMARK --set-mark $mark_cls 

    tc_tables -A tc_forward -i $WAN -m connmark --mark $mark/$mask \
	-j CONNMARK --set-mark $mark_cls 

    tc_tables -A tc_forward -i $WAN -m connmark --mark $mark_cls -j RETURN
    tc_tables -A tc_forward -o $WAN -m connmark --mark $mark_cls -j RETURN
}

tc_cls_create()
{
    local profile=$1
    local cls=$2
    local name=$3
    local rate_dn=$4
    local rate_up=$5
    local ceil_dn=$6
    local ceil_up=$7
    local burst=$8
    local prio=$9

    echo "=====> tc_cls_create $@ <====="

    # For each sub interface queueing class
    local classid="1:1${profile}"
    local mark_cls="0x${cls}${profile}0"
    local mask_cls="0x0ff0"
    local classid_2_n="1$profile$cls"
    local classid_2="1:$classid_2_n"

    # Create the rate class for the policy, setting rate and ceiling
    ccc_tc class add dev $WAN parent $classid classid $classid_2 htb \
	rate $rate_up ceil $ceil_up burst $burst cburst $burst prio $prio \
	quantum $ccc_quantum

    ccc_tc class add dev $ifb parent $classid classid $classid_2 htb \
	rate $rate_dn ceil $ceil_dn burst $burst cburst $burst prio $prio \
	quantum $ccc_quantum
    
    ccc_tc qdisc add dev $WAN parent $classid_2 \
	handle $classid_2_n: sfq perturb 10
    ccc_tc qdisc add dev $ifb parent $classid_2 \
	handle $classid_2_n: sfq perturb 10
    
    # Assign the mark to the class
    ccc_tc filter add dev $WAN parent 1:0 protocol ip u32 \
	match mark $mark_cls $mask_cls flowid $classid_2

    ccc_tc filter add dev $ifb parent 1:0 protocol ip u32 \
	match mark $mark_cls $mask_cls flowid $classid_2
}

tc_addx() 
{
    local mac=$1; shift
    local tc_resource=$1; shift
    local out=$TCTMP/sta/$mac/undo
    local tmp=$TCTMP/tmp.$$
    mkdir -p $TCTMP/sta/$mac
    ccc_tc $tc_resource add "$@"
    echo "/tmp/cloud/ccc_tc.sh tc $tc_resource del $*" > $tmp
    [ -e $out ] && cat $out >> $tmp
    mv -f $tmp $out
}

tc_iptx()
{
    local mac=$1; shift
    local opt=$1; shift
    local out=$TCTMP/sta/$mac/undo
    local tmp=$TCTMP/tmp.$$
    mkdir -p $TCTMP/sta/$mac
    iptables -t mangle $opt "$@" || echo "Failed: iptables -t mangle $opt $*"
    echo "iptables -t mangle -D $*" > $tmp
    [ -e $out ] && cat $out >> $tmp
    mv -f $tmp $out
}

tc_mac_limit()
{
    local dev=$1
    local mac=$2
    local ip=$3
    local ceil_dn=$4
    local ceil_up=$5
    local pri=$6

    [ -z "$dev" -o -z "$mac" -o -z "$ip" -o -z "$ceil_dn" -o -z "$ceil_up" ] && {
	echo "Usage: tc_mac_limit <dev> <mac> <ip> <ceil_dn> <ceil_up>"
	return
    }
    tc_ensure_forward

    echo "Station Limit $*"

    local rate_dn=1kbit
    local rate_up=1kbit
    local CIF=$ifb

    local C_ID=$(tc_nextStationSeq)

    local C_MAC_0=${mac:0:2}
    local C_MAC_1=${mac:2:2}
    local C_MAC_2=${mac:4:2}
    local C_MAC_3=${mac:6:2}
    local C_MAC_4=${mac:8:2}
    local C_MAC_5=${mac:10:2}

    local parent=1:1

    case $(tc_enabled) in
	false)
	    rate_dn=$ceil_dn
	    rate_up=$ceil_up
	    CIF=$4
	    ;;
    esac

    if [ -e $TCTMP/sta/$mac/undo ]
    then
	echo "Removing (undo) shaping for $mac"
	sh $TCTMP/sta/$mac/undo 
	rm -f $TCTMP/sta/$mac/undo
    fi

    rm -f $TCTMP/sta/$mac/remove

    if [ -e $TCTMP/dev/$dev/classid ]
    then
	parent=$(cat $TCTMP/dev/$dev/classid)
    fi

    mark=0x$C_ID
    mask=0xffff

    tc qdisc add dev $WAN root handle 1: htb 2>/dev/null
    tc_addx $mac class dev $WAN parent $parent classid 1:$C_ID htb \
	rate $rate_up ceil $ceil_up prio $pri \
	quantum $ccc_quantum

    tc_addx $mac qdisc dev $WAN parent 1:$C_ID handle $C_ID: sfq perturb 10
    
#    tc_addx $mac filter dev $WAN parent 1: protocol ip prio 5 u32 \
#	match u16 0x0800 0xffff at -2 \
#	match u16 0x$C_MAC_4$C_MAC_5 0xffff at -4 \
#	match u32 0x$C_MAC_0$C_MAC_1$C_MAC_2$C_MAC_3 0xffffffff at -8 \
#	flowid 1:$C_ID

    tc_addx $mac filter dev $WAN parent 1: protocol ip u32 \
	match mark $mark $mask flowid 1:$C_ID
    
    for iface in $CIF
    do
	tc qdisc add dev $iface root handle 1: htb 2>/dev/null
	tc_addx $mac class dev $iface parent $parent classid 1:$C_ID htb \
	    rate $rate_dn ceil $ceil_dn prio $pri \
	    quantum $ccc_quantum

	tc_addx $mac qdisc dev $iface parent 1:$C_ID handle $C_ID: sfq perturb 10

	tc_addx $mac filter dev $iface parent 1: protocol ip u32 \
	    match mark $mark $mask flowid 1:$C_ID

#	tc_addx $mac filter dev $iface parent 1: protocol ip prio 5 u32 \
#	    match u16 0x0800 0xffff at -2 \
#	    match u32 0x$C_MAC_2$C_MAC_3$C_MAC_4$C_MAC_5 0xffffffff at -12 \
#	    match u16 0x$C_MAC_0$C_MAC_1 0xffff at -14 \
#	    flowid 1:$C_ID
    done

    tc_iptx $mac -I tc_forward -m connmark --mark $mark -j RETURN
    tc_iptx $mac -I tc_forward -i $WAN -d $ip -j CONNMARK --set-mark $mark 
    tc_iptx $mac -I tc_forward -o $WAN -s $ip -j CONNMARK --set-mark $mark 
}

tc_clear_mac_limit()
{
    local mac=$1

    if [ "$mac" = "" ]
    then
	if [ -d $TCTMP ]
	then
	    for file in $TCTMP/sta/*/undo
	    do
		sh $file 
		rm -f $file
	    done
	fi
	return
    elif [ -e $TCTMP/sta/$mac/undo ]
    then
	sh $TCTMP/sta/$mac/undo 2> /dev/null
	rm -f $TCTMP/sta/$mac/undo
	return
    fi

    echo "Could not remove policy for $mac"
}


tc_updateStations()
{
    local d=/tmp/cloud
    local stations_tmpfile=/tmp/.cccs.$$
    local dbg=/tmp/tc.dbg
    
    $d/ccc-cmd stations | sort > $stations_tmpfile 2>/dev/null
    
# TODO:
# - Mark $TCTMP/sta/ entries for possible removal
# - Go through active stations and ensure they have a TC policy, if they should
# - Cleanup inactive stations by removing policy and TCTMP entry 
    
# dev= mac= ip= netname= workgroup= dns1= dns2= last_dns= \
#  useragent= watchlist= options= in_pkts= out_pkts= in_bytes= out_bytes= \
#  in_local_bytes= out_local_bytes= since= last=
    
    tc_markStations
    
    local dev mac ip dn up pri
    
    while read line
    do
	eval "$line"
	mac=$(echo "$mac" | sed 's/://g')
	
	if [ -e "$TCTMP/sta/$mac/up" ]
	then
	    dn=$(cat $TCTMP/sta/$mac/down)
	    up=$(cat $TCTMP/sta/$mac/up)
	    pri=$(cat $TCTMP/sta/$mac/pri)
	else
	    if [ -e "$TCTMP/dev/$dev/up" ]
	    then
		dn=$(cat $TCTMP/dev/$dev/down)
		up=$(cat $TCTMP/dev/$dev/up)
		pri=$(cat $TCTMP/dev/$dev/pri)
	    else
		dn=""
		up=""
		pri=""
	    fi
	fi
	
	[ -n "$dn" -a -n "$up" ] && \
	    tc_mac_limit "$dev" "$mac" "$ip" "${dn}kbit" "${up}kbit" "${pri:-1}"
	
    done < $stations_tmpfile 
    
    rm -f $stations_tmpfile 
    
    tc_removeStations
}


tc_show_class()
{
    local dev=$1
    local classid=$2
    tc -s class show dev $dev classid $classid | while read line
    do
	case "$line" in 
	    "class"*)
		;;
	    *)
		echo "          $line"
		;;
	esac
    done
}

tc_show_qdisc()
{
    local disc=$1
    local data=$2
    local dev=$(echo "$disc"|cut -f5 -d' ')
    tc class show dev $dev | sort | while read line
    do
	echo "      $line"
	local class=$(echo "$line"|cut -f3 -d' ')
	tc_show_class $dev $class
    done
}

tc_status() 
{
    local disc data
    local want=0
    tc -s qdisc show | while read line
    do
	case "$line" in
	    "qdisc htb"*)
		[ "$disc" != "" ] && tc_show_qdisc "$disc" "$data"
		want=1
		echo
		echo $line
		disc=$line
		;;
	    "Sent "*)
		if [ "$want" = "1" ]
		then
		    data=$line
		    echo "   $line"
		fi
		;;
	    "qdisc "*)
		[ "$disc" != "" ] && tc_show_qdisc "$disc" "$data"
		disc=
		data=
		want=0
		;;
	    *)
		;;
	esac
    done
    [ "$disc" != "" ] && tc_show_qdisc "$disc" "$data"
    echo
}

tc_iface_classes() 
{
    local num=$1
    local dn_cls=$2
    local up_cls=$3
    local dn_rate=$4
    local up_rate=$5

    # Device.LANDevice.1.TrafficControl.X.Y.Name (not really used)
    # Device.LANDevice.1.TrafficControl.X.Y.RateDown (kbit/kbps)
    # Device.LANDevice.1.TrafficControl.X.Y.RateUp (kbit/kbps)
    # Device.LANDevice.1.TrafficControl.X.Y.Burst (bytes)
    # Device.LANDevice.1.TrafficControl.X.Y.Priority (0 is higest)
    # Device.LANDevice.1.TrafficControl.X.Y.TcpPorts
    # Device.LANDevice.1.TrafficControl.X.Y.UdpPorts

    # Device.LANDevice.1.TrafficControl.X.Y.Protocols

    dn=$(calc $dn_cls 40)
    up=$(calc $up_cls 40)
    tc_cls_create  $num 1 Priority ${dn}kbit ${up}kbit ${dn_rate}kbit ${up_rate}kbit 500 1
    tc_cls_add     $num 1 udp "67 68 53"
    tc_cls_add     $num 1 tcp "22"    
    dn=$(calc $dn_cls 60)
    up=$(calc $up_cls 60)
    tc_cls_create  $num 2 Normal ${dn}kbit ${up}kbit ${dn_rate}kbit ${up_rate}kbit 500 2
    tc_cls_add     $num 2 tcp "80 443"
    
    tc_cls_create  $num 3 Bulk 1kbit 1kbit ${dn_rate}kbit ${up_rate}kbit 500 3
    tc_cls_add     $num 3 tcp "25 20 21"
}

# TC Wrapper function to take care of a few things (deleing filters, mostly)
tc_tc() {
    case "$1" in
	filter)
	    case "$2" in
		del)
		    while [ "$1" != "" -a "$1" != "dev" ]
		    do
			shift
		    done
		    local dev=$2
		    while [ "$1" != "" -a "$1" != "flowid" ]
		    do
			shift
		    done
		    local flowid=$2
		    if [ -n "$dev" -a -n "$flowid" ]
		    then
			local line=$(tc filter show dev $dev|grep "flowid $flowid"|sed 's/^filter //'|sed 's/ fh .*$//')
			echo "Deleting filter on $dev $line"
			tc filter del dev $dev $line
			return
		    fi
		    ;;
	    esac
	    ;;
    esac
    echo "Running tc $*"
    tc "$@"
}

tc_test()
{
    # in kbit/sec (kbps)
    dn=2000
    up=500
    
    dn_1=$(calc $dn 70)
    up_1=$(calc $up 70)

    dn_2=$(calc $dn 30)
    up_2=$(calc $up 30)

    # Device.LANDevice.1.TrafficControl.RateDown (kbit/kbps)
    # Device.LANDevice.1.TrafficControl.RateUp (kbit/kbps)
    tc_start ${dn}kbit ${up}kbit 500 1
	    
    # Device.LANDevice.1.TrafficControl.X.Interfaces 
    # Device.LANDevice.1.TrafficControl.X.RateDown (kbit/kbps)
    # Device.LANDevice.1.TrafficControl.X.RateUp (kbit/kbps)
    # Device.LANDevice.1.TrafficControl.X.Burst (bytes)
    # Device.LANDevice.1.TrafficControl.X.Priority (0 is highest)
    tc_setup_iface 1 "ath0 ath2" ${dn_1}kbit ${up_1}kbit ${dn}kbit ${up}kbit 500 1
    tc_setup_iface 2 "ath1"      ${dn_2}kbit ${up_2}kbit ${dn}kbit ${up}kbit 500 2
    
    # Device.LANDevice.1.TrafficControl.X.Y
    tc_iface_classes 1 $dn_1 $up_1 $dn $up
    tc_iface_classes 2 $dn_2 $up_2 $dn $up

    # Device.LANDevice.1.ClientTrafficControl.X.MacAddress
    # Device.LANDevice.1.ClientTrafficControl.X.LimitDown
    # Device.LANDevice.1.ClientTrafficControl.X.LimitUp
    tc_mac_limit 147dc52ae98f 100 200kbit 100kbit
    tc_clear_mac_limit 147dc52ae98f 100
}

if [ "$CCC_INCLUDE" = "1" ]; then
	return 0
fi

FUNC=$1
PARAMTYPE=`type tc_$FUNC`
if [ "$PARAMTYPE" = "tc_$FUNC is a shell function" ]
then
    shift
    echo "==========> $0 tc_$FUNC $@ <========="
    tc_$FUNC "$@"
else
    tc_usage "$0: command not recognized: $FUNC"
fi
