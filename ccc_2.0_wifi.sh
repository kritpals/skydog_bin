#!/bin/sh
[ "$CCC_INCLUDE_WIFI" = "1" ] && return
CCC_INCLUDE_WIFI=1
#
# Copyright 2010-2011 PowerCloud Systems, All Rights Reserved
#
# ccc_2.0_wifi.sh encapsulates the platform-specific WLAN operations needed
# by the Cloud Command Client for protocol version 2.0. This script must be
# stored in the CloudCommand.tar.gz at $CLOUD_ROOT (see rc.cloud).
#
# Modify as needed to implement platform-specific support for
# the various functions.
#
# The tree below describes operation of and optional and required
# parameters for each function offered by ccc_2.0_wifi.sh. Parameters
# are described with angle or square brackets to indicate <required>
# or [optional] status.
#
# ccc_2.0_wifi.sh
#   +--start
#   |    turn on wifi using settings made earlier with calls to
#   |    ssid, channel, security, etc.
#   +--stop
#   |    turn wifi off
#   +--status <lanx> <radio> <wifinum>
#   |    get current status: up/down, channel, and frequency
#   +--list_stations <lanx> <radio> <wifinum>
#   |    show list of currently associated stations.
#   +--scan_start <lanx> <radio> <wifinum>
#   |    start a background scan (when supported by platform). If not
#   |    supported, don't do anything.
#   +--scan_result <lanx> <radio> <wifinum>
#   |    print list of APs found in most recent scan. If platform
#   |    supports background scan then return results from that; if
#   |    platform supports only foreground scan, then run the scan
#   |    in this function and print results when finished.
#   +--enable <lanx> <radio> <wifinum> <0|1>
#   |    set the specified virtual AP to be disabled or enabled
#   +--ssid <lanx> <radio> <wifinum> <...>
#   |    set ssid for the given virtual AP.
#   +--hidessid <lanx> <radio> <wifinum> <0|1>
#   |    set the virtual AP to hide the ssid, ie don't beacon.
#   +--channel <radio> <1..14|36|40|44|48..116|136..165>
#   |    set the channel for this virtual AP.
#   +--security <lanx> <radio> <wifinum> <enc=open|wpa-psk|radius> [psk=...] [acl=0|1]
#   |    set security options including encryption mode, passphrase,
#   |    and enable/disable MAC access control list.
#   +--radius <radiusnum> <auth1name=...> <auth1port=...> <auth1secret=...>
#   |  <acct1name=...> <acct1port=...> <acct1secret=...>
#   |  <identifier=...> <acctupdate=...> <retry=...>
#   |  [ <auth2name=...> <auth2port=...> <auth2secret=...> ]
#   |  [ <acct2name=...> <acct2port=...> <acct2secret=...> ]
#   |    set parameters related to 802.1X RADIUS server authentication
##   +--update_guests <lanx> <radio> <wifinum>
##   |    update the ACL for guest network according to list in file.
##   +--update_corp <lanx> <radio> <wifinum>
##   |    update the ACL for primary network according to list in file.
##   +--update_guestdmzhost <lanx> <radio> <wifinum>
##   |    update the ACL for guest network dmz host according to list in file.
##   +--vlantag <lanx> <radio> <wifinum> <tag>
##   |    set VLAN tag for this virtual AP.
#   +--txpower <radio> <level>
#   |    set radio txpower, where 1 = 100%, 2 = 50%, 3 = 25%, and 4 = 12.5% of
#   |    maximum tranmission power in mW (linear scale)
#   +--regdomain <radio> <type> <country> 


DEBUG_FLAG="$script_debug"

map_value()
{
    local dest=$1
    local src=$2
    local def=$3
    local val
    val=$(uci -q get $src)
    val=${val:-$(uci -q get $def)}
    ccc_uci set $dest="$val"
}

map_radius_name() {
    case "$1" in
	auth1name)
	    echo auth_server
	    ;;
	auth1port)
    	    echo auth_port
	    ;;
	auth1secret)
	    echo auth_secret
	    ;;
	acct1name)
	    echo acct_server
	    ;;
	acct1port)
	    echo acct_port
	    ;;
	acct1secret)
	    echo acct_secret
	    ;;
	identifier)
	    echo nasid
	    ;;
    esac
}

cli_wifi_iface() {
    lanx="$2"
    shift
    radio="$2"
    shift
    wifinum="$2"
    shift
    wifiwan="$2"
    if [ -z "$wifiwan" ]; then
	WLANNAME="ath${lanx}-${radio##radio}-${wifinum}"
	WLANSECT="ath${lanx}_${radio##radio}_${wifinum}"
    else
	WLANNAME="ath${wifiwan}-${radio##radio}-${wifinum}"
	WLANSECT="ath${wifiwan}_${radio##radio}_${wifinum}"
    fi
}

set_wifiopt() {
    # internal: set_wifiopt <config> <option> <value> <section_type> <default_value> <state_dir>
    # echo ccc_run_uci set_option wireless "$@"
    ccc_run_uci set_option wireless "$@"
}

wifi_start() {
    wifi down
    wifi up radio1
    wifi up radio0
    return 0
}

wifi_stop()
{
    wifi down
    return 0
}

wifi_status()
{
    cli_wifi_iface "$@"
    shift 3
    wifiwan="$2"
    shift

    RUNNING=`ifconfig $WLANNAME | grep RUNNING`
    if [ "$RUNNING" = "" ]
    then
	echo "Status: down"
    else
	echo "Status: up"
    fi
    
    conf="$(iwinfo $WLANNAME freqlist | grep '^\* ')"
    
    CHANNEL="$(echo "$conf" | cut -f5 -d\ )"
    CHANNEL="${CHANNEL%%)*}"
    echo "Channel: $CHANNEL"
    
    freq="$(echo "$conf" | cut -f2 -d\ )"
    # $FREQ is just the number as before
    echo "Frequency: $FREQ"
    
    return 0
}

wifi_list_stations()
{
    cli_wifi_iface "$@"
    shift 3
    wifiwan="$2"
    shift

    wlanconfig $WLANNAME list
    return 0
}

wifi_scan_start()
{
    # background scanning not supported on this platform, so don't do anything here
    return 0
}

wifi_scan_result()
{
    local phyname

    if [ "$1" == "scan_result2" ]; then
	phyname=phy1
    else
	phyname=phy0
    fi
    # if background scanning were supported, get the results now.
    # if background scan is not supported, then run foreground scan now and print result.
    iwinfo $phyname scan | $CLOUD_RUN/scanparse
    #wifi down
    sleep 1
    #wifi up
    return 0
}

wifi_scan_result2() 
{
    wifi_scan_result "$@"
}


wifi_enable() {
    debug_echo ____ ENABLE $* ____
    cli_wifi_iface "$@"
    shift 3
    wifiwan="$2"
    shift 
    local wanbridge="$2"
    local enable="$3"

    if [ "$lanx" = "0" ] && [ "$wifiwan" != "wan" ]; then
	if [ "$enable" = "1" ]; then
	    set_wifiopt $radio disabled 0 wifi-device 0
	else
	    set_wifiopt $radio disabled 1 wifi-device 0
	fi
    else
	if [ "$enable" = "1" ]; then
	    if [ -z "$wifiwan" ]; then
		set_wifiopt $WLANSECT mode ap wifi-iface ap
	        if [ -n "$wanbridge" ]; then
		    set_wifiopt $WLANSECT network "$wanbridge" wifi-iface
                else
		    set_wifiopt $WLANSECT network lan${lanx} wifi-iface
                fi
		set_wifiopt $WLANSECT ifname $WLANNAME wifi-iface
            else
		set_wifiopt $WLANSECT mode sta wifi-iface sta
		set_wifiopt $WLANSECT network $wifiwan wifi-iface
            fi
	    set_wifiopt $WLANSECT device $radio wifi-iface
	    set_wifiopt $WLANSECT disabled 0 wifi-iface 0
	else
	    set_wifiopt $WLANSECT disabled 1 wifi-iface 0
	fi
    fi
}

wifi_regdomain() {
   local regdomtype="$2"
   local regdom="$3"

   if [ "$(echo "$regdomtype" | tr 'A-Z' 'a-z')" = "iso3166-1-alpha-2" ]; then
       for radio in radio0 radio1; do
	   set_wifiopt "$radio" country "$(echo $regdom | tr 'a-z' 'A-Z')" wifi-device
       done
   fi
}

wifi_txpower()
{
    local radio="$2"
    local level="$3"
    local regdom="$4"
    local txpower=100
    debug_echo "O txpower level = $level"

    determine_txpower_levels "$regdom"

    if [ "$radio" = "${WIFI_2G_RADIO:-radio0}" ]; then
	if [ "$level" = "0" ]
	then
	    txpower=$TXPOWER_2G_LEVEL_100
	else	
	    case "$level" in
		1)	
		    txpower=$TXPOWER_2G_LEVEL_100
		    ;;
		2)
		    txpower=$TXPOWER_2G_LEVEL_50
		    ;;
		3)
		    txpower=$TXPOWER_2G_LEVEL_25
		    ;;
		*)
		    txpower=$TXPOWER_2G_LEVEL_125
		    ;;
	    esac	
	fi
    else
	if [ "$level" = "0" ]
	then
	# for 5 GHz txpower 0 in the openwrt wireless config != max power
	    level=1
	fi
	case "$level" in
	    1)
		txpower=$TXPOWER_5G_LEVEL_100
		;;
	    2)
		txpower=$TXPOWER_5G_LEVEL_50
		;;
	    3)
		txpower=$TXPOWER_5G_LEVEL_25
		;;
	    *)
		txpower=$TXPOWER_5G_LEVEL_125
		;;
	esac
    fi
    set_wifiopt "$radio" txpower "${txpower}" wifi-device 0
    return 0
}

wifi_ssid()
{
    cli_wifi_iface "$@"
    shift 3
    wifiwan="$2"
    shift

    set_wifiopt $WLANSECT ssid "$2" wifi-iface
    debug_echo wifi_ssid: $WLANSECT $2
    wifi_is_up="$(uci_get_state wireless "$WLANSECT" up)"
    return 0
}

wifi_hidessid()
{
    cli_wifi_iface "$@"
    shift 3
    wifiwan="$2"
    shift

    # $2 is 1/0 (hide/no hide)
    set_wifiopt $WLANSECT hidden "$2" wifi-iface 0
    return 0
}

setup24g() 
{
    local radio=$1
    local channel=$2
    local width=$3

    if [ "$channel" -lt "14" ]
    then
	set_wifiopt $radio channel $channel wifi-device 
	debug_echo "<--> Channel to ${channel}"
    else
	echo "Invalid Channel $radio $channel"
    fi

    if [ "$width" = "20" ]
    then
	set_wifiopt $radio htmode HT20 wifi-device HT20
    elif [ "$width" = "40" ]
    then
	if [ "$channel" -lt "8" ]
	then
	    set_wifiopt $radio htmode HT40+ wifi-device HT20
	else
	    set_wifiopt $radio htmode HT40- wifi-device HT20
	fi
    fi  
}

setup5g() 
{
    local radio=$1
    local channel=$2
    local width=$3

    case "$channel" in
	36|40|44|48|149|153|157|161|165)
	    debug_echo "<--> Channel to ${channel}"
	    set_wifiopt $radio channel $channel wifi-device 
	    ;;
    	*)
	    echo "Invalid Channel $radio $channel"
	    ;;	
    esac
    
    if [ "$width" = "20" ]
    then
	set_wifiopt $radio htmode HT20 wifi-device HT20
    elif [ "$width" = "40" ]
    then
	case "$channel" in
	    36|44|149|157)
		set_wifiopt $radio htmode HT40+ wifi-device HT20
		;;
	    40|48|153|161)
		set_wifiopt $radio htmode HT40- wifi-device HT20
		;;
	    165)
    	        # Channel 165 can't be use with HT40
		set_wifiopt $radio htmode HT20 wifi-device HT20
		;;
	    *)
	        # We don't know what this channel can
	        # can handle so do HT20
		set_wifiopt $radio htmode HT20 wifi-device HT20	
		;;
	esac
    fi
}

wifi_channel()
{
    local radio="$2"

    if [ "$radio" = "${WIFI_2G_RADIO:-radio0}" ]
    then
        setup24g "$radio" "$3" "$4"
    else
        setup5g "$radio" "$3" "$4"
    fi
    
    return 0
}

wifi_security()
{
    debug_echo ___ SECURITY $* ____
    cli_wifi_iface "$@"
    shift 3
    wifiwan="$2"
    shift

    while [ "$2" ]
    do
	param="${2#*=}"
	case "$2" in
            "enc="*)
                case $param in
		    open)
			set_wifiopt $WLANSECT encryption none wifi-iface none
			;; 
		    wpa-psk) 
			set_wifiopt $WLANSECT encryption psk2 wifi-iface none
			;; 
		    wpa-eap-radius) 
			set_wifiopt $WLANSECT encryption wpa2 wifi-iface none
			;;
		    *)
			set_wifiopt $WLANSECT encryption none wifi-iface none
			;;
		esac
		;;
	    "psk="*) 
		set_wifiopt $WLANSECT key "$param"
		;; 
	    "wanOnly="*) 
		set_wifiopt $WLANSECT isolate "$param"
		;;
	esac
	shift 1
    done
    
    return 0
}

wifi_radius()
{
    debug_echo ___ RADIUS ___ $*
    cli_wifi_iface "$@"
    shift 3
    wifiwan="$2"
    shift
    
    while [ "$2" ]
    do
	local param="$(map_radius_name "${2%%=*}")"
	if [ "$param" != "" ]
	then
	    local value="${2#*=}"
	    value="${value#\"}"
	    value="${value%\"}"
	    set_wifiopt $WLANSECT "$param" "$value" 
	fi
	shift 1
    done

    return 0
}

# wifi_update_corp()
# {
#     useacl="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_USEACL_0)"

#     if [ "$useacl" = "1" ]
#     then
#         # flush the ebtables' list of authorized corp users, then re-load it from the file
# 	ebtables -t nat -F AUTHORIZE-CORP
# 	if [ -f $CLOUD_TMP/authorized-users ]
# 	then
# 	    md5sum $CLOUD_TMP/authorized-users | cut -f1 -d\  >$CLOUD_TMP/authorized-users.md5sum
#             # the authorized users file isn't written in ebtables' required format.
#             # transform the file before giving it to ebtables.
#             # input format is x:psk:mmmmmmmmmmmm[,x:psk:mmmmmmmmmmmm] ...
#             # required output format is mm:mm:mm:mm:mm:mm[,mm:mm:mm:mm:mm:mm] ...
# 	    sed -e 's/[^:,]*:[^:,]*://g; s/\(,\)\?\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2:\3:\4:\5:\6:\7/g' $CLOUD_TMP/authorized-users > $CLOUD_TMP/authorized-users-ebtables
# 	    ebtables -t nat -A AUTHORIZE-CORP --among-src-file $CLOUD_TMP/authorized-users-ebtables -j ACCEPT
#             result=`ebtables -t nat -L AUTHORIZE-CORP | grep among-src`
#             if [ "$result" = "" ]; then
#                 # --among-src-file failed
# 		maclist=`cat $CLOUD_TMP/authorized-users-ebtables`
# 		maclist=`echo $maclist | sed "s/,/ /g"`
# 		echo "===== CORP Individual MAC addition starts"
# 		for mac in $maclist
# 		do
# 		    ebtables -t nat -A AUTHORIZE-CORP --among-src $mac -j ACCEPT
#                     #echo "MAC[$mac] added individually"
# 		done
# 		echo "===== CORP Individual MAC addition done"
#             fi
# 	else
# 	    rm -f $CLOUD_TMP/authorized-users.md5sum
# 	fi
#     fi
#     return 0
# }

# wifi_update_guests()
# {
#     useacl_guest="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_USEACL_1)"

#     if [ "$useacl_guest" = "1" ]
#     then
#         # flush the ebtables' list of authorized guests, then re-load it from the file
# 	ebtables -t nat -F AUTHORIZE-GUESTS
# 	if [ -f $CLOUD_TMP/authorized-guests ]
# 	then
# 	    md5sum $CLOUD_TMP/authorized-guests | cut -f1 -d\  >$CLOUD_TMP/authorized-guests.md5sum
#             ebtables -t nat -A AUTHORIZE-GUESTS --among-src-file $CLOUD_TMP/authorized-guests -j ACCEPT
#             result=`ebtables -t nat -L AUTHORIZE-GUESTS | grep among-src`
#             if [ "$result" = "" ]; then
#                 # --among-src-file failed
# 		maclist=`cat $CLOUD_TMP/authorized-guests`
# 		maclist=`echo $maclist | sed "s/,/ /g"`
# 		echo "===== GUEST Individual MAC addition starts"
# 		for mac in $maclist
# 		do
#                     ebtables -t nat -A AUTHORIZE-GUESTS --among-src $mac -j ACCEPT
#                 #echo "MAC[$mac] added individually"
# 		done
# 		echo "===== GUEST Individual MAC addition done"
#             fi
# 	else
# 	    rm -f $CLOUD_TMP/authorized-guests.md5sum
# 	fi
#     fi
#     return 0
# }

# wifi_update_guestdmzhost()
# {
#     useacl_guest="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_USEACL_1)"

#     ebtables -t nat -F LOCAL-NET-DMZ
#     ebtables -t nat -F LOCAL-NET-DMZ-OUT
#     if [ -f $CLOUD_TMP/guest-dmz-host ]
#     then
#         md5sum $CLOUD_TMP/guest-dmz-host | cut -f1 -d\  >$CLOUD_TMP/guest-dmz-host.md5sum
#         ebtables -t nat -F LOCAL-NET-DMZ
#         list=`cat $CLOUD_TMP/guest-dmz-host | sed "s/,/ /g"`
#         echo $list

#         for host in $list
#         do
#            echo $host
#            if [ "$useacl_guest" = "1" ]; then
#               # inbound (from radio to bridge)
#               ebtables -t nat -A LOCAL-NET-DMZ -p 0x800 --pkttype-type otherhost --ip-dst $host -j AUTHORIZE-GUESTS   
#               ebtables -t nat -A LOCAL-NET-DMZ -p 0x800 --pkttype-type host --ip-dst $host -j AUTHORIZE-GUESTS   
#            else
#               # inbound (from radio to bridge)
#               ebtables -t nat -A LOCAL-NET-DMZ -p 0x800 --pkttype-type otherhost --ip-dst $host --j ACCEPT  
#            fi

#            # outbound (from bridge to radio)
#            ebtables -t nat -A LOCAL-NET-DMZ-OUT -p 0x800 --ip-src $host -j ACCEPT
#         done
#     else
# 	rm -f $CLOUD_TMP/guest-dmz-host.md5sum
#     fi
# }

# wifi_vlantag()
# {
#     debug_echo "======== VLAN == $1 ID of $2: $3"
#     $CLOUD_RUN/ccc_cloud_conf.sh set "AP_VLAN_$CCC_ifacekey" "$3"
#     return 0
# }

# wifi_vlantag2()
# {
#     wifi_vlantag "$@"
# }

wifi_secondradioexist() 
{
    set_wifiopt radio1 disable 0 wifi-device 0
}

# wifi_configvlan()
# {
#     echo " ___ CONFIG VLAN $* ___ "

#     ethtag=eth0
#     if [ "$MODEL" = "ubdevod" ] || [ "$MODEL" = "WAP224NOC" ] || [ "$MODEL" = "dlrtdev01" ] || [ "$MODEL" = "AP825" ]
#     then
#         ethtag=br-lan
#     fi

#     local j=0
#     local TOTAL_VAPS=$($CLOUD_RUN/ccc_cloud_conf.sh get NUM_VAPS)
#     local TOTAL_RADIO=$($CLOUD_RUN/ccc_cloud_conf.sh get NUMRADIO)

#     local remove=
#     for n in $(ccc_uci show network |grep 'network.vq'|grep =interface)
#     do
# 	net=$(echo $n|cut -d= -f1|cut -d. -f2)
# 	remove="$net $remove"
#     done

#     while [ $j -lt "$TOTAL_RADIO" ]
#     do
# 	local i=0
# 	while [ $i -lt "$TOTAL_VAPS" ]
# 	do
#             echo wifi_configvlan: $j $i

# 	    local RADIONUM="$j"
# 	    local VAPNUM="$i"
# 	    local VARIDX=
# 	    if [ "$RADIONUM" = "0" ]
# 	    then
#     		VARIDX="${VAPNUM}"
# 	    else
#     		VARIDX="$((RADIONUM + 1))_${VAPNUM}"
# 	    fi
# 	    local INDEX="$((VAPNUM + $((TOTAL_VAPS * $RADIONUM))))"
# 	    local vlan="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_VLAN_${VARIDX})"
# 	    local VLAN_NETWORKS=""

# 	    if [ "$vlan" != "" -a "$vlan" != "0" -a "$vlan" != "1" ]
# 	    then
# 		local network=vq$vlan
# 		VLAN_NETWORKS="$network $VLAN_NETWORKS"
# 		remove=$(echo "$remove"|sed s/$network//)
# 		if [ "$(uci -q get network.$network)" = "" ]
# 		then
#                     ccc_uci set network.$network=interface
#                	    ccc_uci set network.$network.ifname="$ethtag.$vlan"
#                     ccc_uci set network.$network.type=bridge
#                     ccc_uci set network.$network.ipaddr=0.0.0.0
#                     ccc_uci set network.$network.gateway=0.0.0.0
#                     ccc_uci set network.$network.proto=dhcp
#                     ccc_uci set network.$network.peerdns=0
#                     ccc_uci set network.$network.stp=1
# 		fi

#                 ccc_uci set wireless.@wifi-iface[$INDEX].network=$network
# 	    else
#                 ccc_uci set wireless.@wifi-iface[$INDEX].network=lan
# 	    fi

# 	    i=$((i + 1))
# 	done
# 	j=$((j + 1))
#     done

#     if [ "$remove" != "" ]
#     then
# 	for net in $remove
# 	do
# 	    ccc_uci delete network.$net
# 	done
#     fi

#     if [ "$(uci -q changes network)" != "" ]
#     then
#         ccc_uci commit
# 	sync
#         debug_echo "===========> reboot"
# 	sleep 2
#         $CLOUDDIR/ccc_platform.sh reboot
# 	#vconfig set_name_type DEV_PLUS_VID_NO_PAD
# 	#/etc/init.d/network restart
#     fi
# }

# create_vlan()
# {
#     dev=eth0
#     if [ "$MODEL" = "ubdevod" ] || [ "$MODEL" = "WAP224NOC" ] || [ "$MODEL" = "AP825" ] || [ "$MODEL" = "dlrtdev01" ]
#     then
# 	dev=br-lan
#     fi

#     # Setup necessary rules for each VLAN.
#     # Determine if there are unused VLANs to purge.

#     local remove=
#     for n in $(uci -q show network |grep 'network.vq'|grep =interface)
#     do
# 	local net=$(echo $n|cut -d= -f1|cut -d. -f2)
# 	if [ "$(grep "'$net'" /etc/config/wireless 2>/dev/null)" != "" ]
# 	then
# 	    local id=${net#vq}

# 	    echo ___ VLAN Setup ___ $net $dev $id ____

#             echo ebtables -t broute -A BROUTING -i $dev --proto 802_1Q --vlan-id $id -j DROP 
#             ebtables -t broute -A BROUTING -i $dev --proto 802_1Q --vlan-id $id -j DROP 
# 	else
# 	    echo ___ Removing VLAN Setup ___ $net $dev $id ____
# 	    remove="$net $remove"
# 	fi
#     done

#     if [ "$remove" != "" ]
#     then
# 	for net in $remove
# 	do
# 	    ccc_uci delete network.$net
# 	    ccc_uci commit network
# 	    sync
#             debug_echo "===========> reboot"
# 	    sleep 2
#             $CLOUDDIR/ccc_platform.sh reboot
# 	done
#     fi

#     return 0
# }

[ "$CCC_INCLUDE" = "1" ] && return

if [ "$CLOUD_TMP" = "" ]
then
    echo "ccc_2.0_wifi.sh: fatal: \$CLOUD_TMP is not set; cloudconf will not be found."
    exit 120
fi

cd $(dirname $0)
. ./ccc_functions.sh

CLOUDDIR=`pwd`
PARAMTYPE=`type wifi_$1`
if [ "$PARAMTYPE" = "wifi_$1 is a shell function" ]
then
    debug_echo "========================> ccc_2.0_wifi.sh $@ <========="
    wifi_$1 "$@"
else
    echo "ccc_2.0_wifi.sh: command not recognized: $1"
fi
# -*- mode: sh; sh-file-style: "linux"; sh-basic-offset: 4 -*-
