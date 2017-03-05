#!/bin/sh
#
# Copyright 2010-2011 PowerCloud Systems, All Rights Reserved
#
# ccc_wifi.sh encapsulates the platform-specific WLAN operations needed
# by the Cloud Command Client. This script must be stored in the
# CloudCommand.tar.gz at $CLOUD_ROOT (see rc.cloud).
#
# Modify as needed to implement platform-specific support for
# the various functions.
#
# The tree below describes operation of and optional and required
# parameters for each function offered by ccc_wifi.sh. Parameters
# are described with angle or square brackets to indicate <required>
# or [optional] status.
#
# ccc_wifi.sh
#   +--start
#   |    turn on wifi using settings made earlier with calls to
#   |    ssid, channel, security, etc.
#   +--stop
#   |    turn wifi off
#   +--status <netnum>
#   |    get current status: up/down, channel, and frequency
#   +--list_stations <netnum>
#   |    show list of currently associated stations.
#   +--scan_start <netnum>
#   |    start a background scan (when supported by platform). If not
#   |    supported, don't do anything.
#   +--scan_result <netnum>
#   |    print list of APs found in most recent scan. If platform
#   |    supports background scan then return results from that; if
#   |    platform supports only foreground scan, then run the scan
#   |    in this function and print results when finished.
#   +--enable <netnum> <0|1>
#   |    set the specified virtual AP to be disabled or enabled
#   +--ssid <netnum> <...>
#   |    set ssid for the given virtual AP.
#   +--hidessid <netnum> <0|1>
#   |    set the virtual AP to hide the ssid, ie don't beacon.
#   +--channel <netnum> <auto2.4G|auto5G|1..14|36|40|44|48..116|136..165>
#   |    set the channel for this virtual AP.
#   +--security <netnum> <enc=open|wpa-psk|radius> [psk=...] [acl=0|1]
#   |    set security options including encryption mode, passphrase,
#   |    and enable/disable MAC access control list.
#   +--radius <auth1name=...> <auth1port=...> <auth1secret=...>
#   |  <acct1name=...> <acct1port=...> <acct1secret=...>
#   |  <identifier=...> <acctupdate=...> <retry=...>
#   |  [ <auth2name=...> <auth2port=...> <auth2secret=...> ]
#   |  [ <acct2name=...> <acct2port=...> <acct2secret=...> ]
#   |    set parameters related to 802.1X RADIUS server authentication
#   +--update_guests <netnum>
#   |    update the ACL for guest network according to list in file.
#   +--update_corp <netnum>
#   |    update the ACL for primary network according to list in file.
#   +--update_guestdmzhost <netnum>
#   |    update the ACL for guest network dmz host according to list in file.
#   +--vlantag <netnum> <tag>
#   |    set VLAN tag for this virtual AP.
#   +--txpower <level>
#        set radio txpower, where 1 = 100%, 2 = 50%, 3 = 25%, and 4 = 12.5% of
#        maximum tranmission power in mW (linear scale)

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

map_radius_value() 
{
    local w_idx=$1
    local r_idx=$2
    local w_name=$3
    local r_name=$4

    map_value "wireless.@wifi-iface[$w_idx].$w_name" \
	radius.profile$r_idx.$r_name \
	radius.profile0.$r_name
}

iface_setup()
{
    RADIONUM="$1"
    VAPNUM="$2"
    if [ "$RADIONUM" = "0" ]
    then
    	VARIDX="${VAPNUM}"
    else
    	VARIDX="$((RADIONUM + 1))_${VAPNUM}"
    fi
    INDEX="$((VAPNUM + $((TOTAL_VAPS * $RADIONUM))))"
    ssid="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_SSID_${VARIDX})"
    eval radio=\${VAPRADIO_${VARIDX}}
    eval renable=\${RADIO_ENABLED_${radio}}
    eval enc=\${AP_KEYMGT_${VARIDX}}
    eval vap_enabled=\${AP_ENABLED_${VARIDX}}
    eval use_isolation=\${AP_USEISOLATION_${VARIDX}}
    eval vlan=\${AP_VLAN_${VARIDX}}
    eval hidden=\${AP_HIDDEN_${VARIDX}}

    echo "................... IFACE SETUP .............."
    echo "IF($INDEX) $VAPNUM/$VARIDX ssid($ssid) radio($radio) enc($enc) vlan($vlan)"
    echo "................... IFACE SETUP .............."

    if [ "$(uci -q get wireless.@wifi-iface[$INDEX])" = "" ]
    then
        echo "=== created wifi[$INDEX] ===="
        ccc_uci add wireless wifi-iface
    fi

    local lan=lan
    if [ "$vlan" != "" -a "$vlan" != "0" -a "$vlan" != "1" ]
    then
	lan=vq$vlan
    fi

    # override settings for Guest networks
    if [ "$VAPNUM" = "1" ]
    then
	use_isolation=1
    fi

    ccc_uci set wireless.@wifi-iface[$INDEX].mode=ap
    ccc_uci set wireless.@wifi-iface[$INDEX].network=$lan
    ccc_uci set wireless.@wifi-iface[$INDEX].ifname=ath$INDEX
    ccc_uci set wireless.@wifi-iface[$INDEX].device=$radio
    ccc_uci set wireless.@wifi-iface[$INDEX].ssid="${ssid}"

    case "$enc" in 
	wpa-psk)
	    key="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_PSK_${VARIDX})"
	    ccc_uci set wireless.@wifi-iface[$INDEX].encryption=psk2+aes+ccmp
	    ccc_uci set wireless.@wifi-iface[$INDEX].key="${key}"
	    ;;

	radius)
	    ccc_uci set wireless.@wifi-iface[$INDEX].encryption=wpa2

	    map_radius_value $INDEX $VAPNUM auth_server auth1name 
	    map_radius_value $INDEX $VAPNUM auth_port   auth1port
	    map_radius_value $INDEX $VAPNUM auth_secret auth1secret
	    
	    map_radius_value $INDEX $VAPNUM acct_server acct1name 
	    map_radius_value $INDEX $VAPNUM acct_port   acct1port
	    map_radius_value $INDEX $VAPNUM acct_secret acct1secret
	    
	    map_radius_value $INDEX $VAPNUM nasid identifier
	    ;;
	
	open|"")
	    ccc_uci set wireless.@wifi-iface[$INDEX].encryption=none
	    ;;

	*)
	    $CLOUD_RUN/ccc_cloud_conf.sh set AP_ENABLED_${VARIDX} "0"
	    vap_enabled=0
	    ;;
    esac

    ccc_uci set wireless.@wifi-iface[$INDEX].isolate="$use_isolation"
    ccc_uci set wireless.@wifi-iface[$INDEX].hidden="$hidden"

    if [ "$vap_enabled" = "1" ]
    then
	ccc_uci set wireless.@wifi-iface[$INDEX].disabled=0
    else
	ccc_uci set wireless.@wifi-iface[$INDEX].disabled=1
    fi

    if [ "$renable" = "1" ]
    then
	ccc_uci set wireless.$radio.disabled=0
    else
	ccc_uci set wireless.$radio.disabled=1
    fi

    return 0
}

wifi_start()
{
    wifi down
    j=0
    TOTAL_VAPS=$($CLOUD_RUN/ccc_cloud_conf.sh get NUM_VAPS)
    TOTAL_RADIO=$($CLOUD_RUN/ccc_cloud_conf.sh get NUMRADIO)
    
    while [ $j -lt "$TOTAL_RADIO" ]
    do
	i=0
	while [ $i -lt "$TOTAL_VAPS" ]
	do
            echo xxxxxxxxxxxxxxxxxxxxx
            echo wifi_start: $j $i
            iface_setup $j $i
	    i=$((i + 1))
	done
	j=$((j + 1))
    done
    echo ------------------------
    ccc_uci changes
    ccc_uci commit
    create_vlan
    echo "++++++++++++++++++++++++++++++++++++++++++++++++++++"
    uci -c ${CLOUD_CONF_UCI_CONFIG_DIR} show | cut -f3- -d.
    echo "++++++++++++++++++++++++++++++++++++++++++++++++++++"
    echo =========================
    wifi up
    $CLOUD_RUN/ccc_firewall.sh
    
    return 0
}

wifi_stop()
{
    wifi down
    return 0
}

wifi_status()
{
    RUNNING=`ifconfig $WLANBASENAME$CCC_ifacenum | grep RUNNING`
    if [ "$RUNNING" = "" ]
    then
	echo "Status: down"
    else
	echo "Status: up"
    fi
    
    conf="$(iwinfo $WLANBASENAME$CCC_ifacenum freqlist | grep '^\* ')"
    
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
    wlanconfig $WLANBASENAME$CCC_ifacenum list
    return 0
}

wifi_scan_start()
{
    # background scanning not supported on this platform, so don't do anything here
    return 0
}

wifi_scan_result()
{
    local ifacename=$WLANBASENAME$CCC_ifacenum
    # if background scanning were supported, get the results now.
    # if background scan is not supported, then run foreground scan now and print result.
    iwinfo $ifacename scan | $CLOUD_RUN/scanparse
    #wifi down
    sleep 1
    #wifi up
    return 0
}

wifi_scan_result2() 
{
    wifi_scan_result "$@"
}

wifi_enable()
{
    echo ____ ENABLE $* ____
    local netnum=$2
    local enabled=$3
    local radio=radio0
    if [ "$1" = "enable2" ]
    then
        radio=radio1
    else
	# on index 0, we will do some defaults that will be overwritten
	# upon subsequent calls to wifi_enable
	[ "$netnum" = "1" ] && {
	    wifi_prepare
	    ccc_cloud_conf_eval
	}
    fi
    local old_enabled=
    eval old_enabled=\${AP_ENABLED_$CCC_ifacekey}
    eval radio_enabled=\${RADIO_ENABLED_$radio}
    old_enabled=${old_enabled:-0}

    $CLOUD_RUN/ccc_cloud_conf.sh set "AP_ENABLED_$CCC_ifacekey" "$enabled"

    if [ "$enabled" = "1" -a "$radio_enabled" != "1" ]
    then
	$CLOUD_RUN/ccc_cloud_conf.sh set "RADIO_ENABLED_$radio" "1"
    fi

    if [ "$old_enabled" != "$enabled" ]
    then
	wifi down
    fi   

    return 0
}

wifi_enable2() 
{
    wifi_enable "$@"
}

# control the transmitting power -- james
# Different hardware has different level and they can't be calculated if the radio isn't
# already up, so we hard-code the mapping of (model, level) -> txpower
wifi_txpower2() 
{
    local level="${2}"
    local txpower=100
    local div=1
    
    debug_echo "O txpower level = $level"
    if [ "$level" = "0" ]
    then
	# for 5 GHz txpower 0 in the openwrt wireless config != max power
	level=1
    fi
    if [ "$MODEL" = "AP825" ] || [ "$MODEL" = "dlrtdev01" ]
    then
	if [ "$level" = "1" ]
	then
	    txpower=13
	elif [ "$level" = "2" ]
	then
	    txpower=10
	elif [ "$level" = "3" ]
	then
	    txpower=7
	else 
	    txpower=5
	fi
    else
	# unrecognized model, set power to minimum max power 
	# for known 5GHz radios
	txpower=17
    fi
    ccc_uci set wireless.radio1.txpower="${txpower}"
    return 0
}

wifi_txpower()
{
    local level="${2}"
    local txpower=100
    local div=1
    debug_echo "O txpower level = $level"

    if [ "$level" = "0" ]
    then
	txpower=0	
    else
	case "$MODEL" in
	    ubdev01|WAP223NC)
		case "$level" in
		    1)
			txpower=27
			;;
		    2)
			txpower=19
			;;
		    3)
			txpower=16
			;;
		    *)
			txpower=13
			;;
		esac
		;;
	    ubdevod|WAP224NOC)
		case "$level" in
		    1)
			txpower=18
			;;
		    2)
			txpower=15
			;;
		    3)
			txpower=12
			;;
		    *)
			txpower=9
			;;
		esac
		;;
	    dlrtdev01|AP825)
		case "$level" in
		    1)
			txpower=19
			;;
		    2)
			txpower=16
			;;
		    3)
			txpower=13
			;;
		    *)
			txpower=10
			;;
		esac
		;;
	    *)
		txpower=0
		;;
	esac
    fi
    ccc_uci set wireless.radio0.txpower="${txpower}"
    return 0
}

wifi_ssid()
{
    echo wifi_ssid: $CCC_ifacekey $3
    $CLOUD_RUN/ccc_cloud_conf.sh set "AP_SSID_$CCC_ifacekey" "$3"
    return 0
}

wifi_ssid2() 
{
    wifi_ssid "$@"
}

wifi_hidessid()
{
    # Wifi must be brought down before bringing up else problems ensue
    wifi down
    # $3 is 1/0 (hide/no hide)
    $CLOUD_RUN/ccc_cloud_conf.sh set "AP_HIDDEN_$CCC_ifacekey" "$3"
    return 0
}

wifi_hidessid2() 
{
    wifi_hidessid "$@"
}

chan24gauto() 
{
    echo "<--> Channel to auto"
    # no auto channel for unifi
    # set we set a random channel out of 1, 6, and 11
    local randnum="$(($(($(hexdump -d -n 4 /dev/urandom | head -n1 | tr -s \ | cut -f2 -d\ | sed -e 's/^0*//') % 3 )) + 1))"
    debug_echo "Auto Channel got Band ${randnum}"
    if [ "$randnum" -eq 1 ]; then 
      	ccc_uci set wireless.radio$1.channel=1
        curchannel=1
    elif [ "$randnum" -eq 2 ]; then
        ccc_uci set wireless.radio$1.channel=6
        curchannel=6
    else
        ccc_uci set wireless.radio$1.channel=11
        curchannel=11
    fi
}

chan24gmanual() 
{
    if [ "$2" -lt "14" ]
    then
        echo "<--> Channel to ${2}"
        ccc_uci set wireless.radio$1.channel=${2}
        curchannel=${2}
    fi
}

chan24g40() 
{
    if [ "$2" = "20" ]; then
	ccc_uci set wireless.radio$1.htmode=HT20
    elif [ "$2" = "40" ]; then
	if [ "$curchannel" -lt "8" ]; then
            ccc_uci set wireless.radio$1.htmode=HT40+
	else
            ccc_uci set wireless.radio$1.htmode=HT40-
	fi
    fi  
}

chan5gauto() 
{
    echo "<--> Channel to auto"
    # no auto channel for unifi
    # set we set a random channel out of 36, 40, 44, 48, 149, 153, 157, 161, 165
    local randnum="$(($(($(hexdump -d -n 4 /dev/urandom | head -n1 | tr -s \ | cut -f2 -d\ | sed -e 's/^0*//') % 9 )) + 1))"
    debug_echo "Auto Channel got Band ${randnum}"
    case "$randnum" in
	1)
	    ccc_uci set wireless.radio$1.channel=36
	    curchannel=36
	    ;;
	2)
	    ccc_uci set wireless.radio$1.channel=40
	    curchannel=40
	    ;;
	3)
	    ccc_uci set wireless.radio$1.channel=44
	    curchannel=44
	    ;;
	4)
	    ccc_uci set wireless.radio$1.channel=48
	    curchannel=48
	    ;;
	5)
	    ccc_uci set wireless.radio$1.channel=149
	    curchannel=149
	    ;;
	6)
	    ccc_uci set wireless.radio$1.channel=153
	    curchannel=153
	    ;;
	7)
	    ccc_uci set wireless.radio$1.channel=157
	    curchannel=151
	    ;;
	8)
	    ccc_uci set wireless.radio$1.channel=161
	    curchannel=161
	    ;;
	9)
	    ccc_uci set wireless.radio$1.channel=165
	    curchannel=165
	    ;;
	*)
	# Just in case
            ccc_uci set wireless.radio$1.channel=44
            curchannel=44
            ;;
    esac	
}

chan5gmanual() 
{
    case "$2" in
	36|40|44|48|149|153|157|161|165)
            echo "<--> Channel to ${2}"
            ccc_uci set wireless.radio$1.channel=${2}
	    curchannel="${2}"
	    ;;
    esac
}

chan5g40() 
{
    if [ "$2" = "20" ]
    then
	ccc_uci set wireless.radio$1.htmode=HT20

    elif [ "$2" = "40" ]
    then
	case "$curchannel" in
	    36|44|149|157)
		ccc_uci set wireless.radio$1.htmode=HT40+
		;;
	    40|48|153|161)
		ccc_uci set wireless.radio$1.htmode=HT40-
		;;
	    165)
    	        # Channel 165 can't be use with HT40
		ccc_uci set wireless.radio$1.htmode=HT20
		;;
	    *)
	        # We don't know what this channel can
	        # can handle so do HT20
		ccc_uci set wireless.radio$1.htmode=HT20
		;;
	esac
    fi
}

wifi_channel()
{
    local onradio=0
    if [ "$1" = "channel2" ]; then
	onradio=1
    fi
    # radios must be brought down before they get brought back up
    wifi down
    # $2 is the network number
    # $3 is the channel number
    if [ "$3" = "auto2.4g" ]; then
	chan24gauto $onradio 
    elif [ "$3" = "auto5g" ]; then
	chan5gauto $onradio
    else
	if [ "$onradio" = "0" ]; then
	    chan24gmanual $onradio $3
	else
	    chan5gmanual $onradio $3
	fi
    fi
    
    if [ "$onradio" = "0" ]; then
	chan24g40 $onradio $4
    else
	chan5g40 $onradio $4
    fi
    
    return 0
}

wifi_channel2()
{
    wifi_channel "$@"
}

wifi_security()
{
    echo ___ SECURITY $* ____

    # Radio must be brought down before making certain changes and brought back up
    wifi down 
    
    # clear some values
    $CLOUD_RUN/ccc_cloud_conf.sh set "AP_ENABLED_$CCC_ifacekey" "0"
    $CLOUD_RUN/ccc_cloud_conf.sh set "AP_VLAN_$CCC_ifacekey" "0"
    $CLOUD_RUN/ccc_cloud_conf.sh set "AP_SSID_$CCC_ifacekey" ""
    
    # $2 is network number, but because we use shift, we must make a copy now
    # remaining parameters are security settings.
    while [ "$3" ]
    do
	param="${3#*=}"
	case "$3" in
            "enc="*)
                case $param in
		    open) 
			$CLOUD_RUN/ccc_cloud_conf.sh set "AP_KEYMGT_$CCC_ifacekey" "$param" 
			;; 
		    wpa-psk) 
			$CLOUD_RUN/ccc_cloud_conf.sh set "AP_KEYMGT_$CCC_ifacekey" "$param" 
			;; 
		    radius) 
			$CLOUD_RUN/ccc_cloud_conf.sh set "AP_KEYMGT_$CCC_ifacekey" "$param" 
			;;
		    *)
			$CLOUD_RUN/ccc_cloud_conf.sh set "AP_KEYMGT_$CCC_ifacekey" "" 
			;;
		esac
		;;
	    "psk="*) 
		$CLOUD_RUN/ccc_cloud_conf.sh set "AP_PSK_$CCC_ifacekey" "$param" 
		;; 
	    "acl="*) 
		$CLOUD_RUN/ccc_cloud_conf.sh set "AP_USEACL_$CCC_ifacekey" "$param" 
		;;
	    "wanOnly="*) 
		$CLOUD_RUN/ccc_cloud_conf.sh set "AP_WANONLY_$CCC_ifacekey" "$param" 
		$CLOUD_RUN/ccc_cloud_conf.sh set "AP_USEISOLATION_$CCC_ifacekey" "$param" 
		;;
	esac
	shift 1
    done
    
    return 0
}

wifi_security2() 
{
    wifi_security "$@"
}

wifi_radius()
{
    INDEX=$2
    
    echo ___ RADIUS ___ $*
    
    # Bring radio down before changes because up should 
    # only be done on a downed radio
    wifi down
    
    [ -e /etc/config/radius ] || {
	touch /etc/config/radius
        ccc_uci add radius defaults
	ccc_uci commit radius
    }
    
    if [ "$(uci -q get radius.profile$INDEX)" = "" ]
    then
        echo "=== created radius profile [$INDEX] ===="
        ccc_uci set radius.profile$INDEX=profile
    fi
    
    while [ "$3" ]
    do
	ccc_uci set "radius.profile$INDEX.$3"
	shift 1
    done

    return 0
}

wifi_update_corp()
{
    useacl="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_USEACL_0)"

    if [ "$useacl" = "1" ]
    then
        # flush the ebtables' list of authorized corp users, then re-load it from the file
	ebtables -t nat -F AUTHORIZE-CORP
	if [ -f $CLOUD_TMP/authorized-users ]
	then
	    md5sum $CLOUD_TMP/authorized-users | cut -f1 -d\  >$CLOUD_TMP/authorized-users.md5sum
            # the authorized users file isn't written in ebtables' required format.
            # transform the file before giving it to ebtables.
            # input format is x:psk:mmmmmmmmmmmm[,x:psk:mmmmmmmmmmmm] ...
            # required output format is mm:mm:mm:mm:mm:mm[,mm:mm:mm:mm:mm:mm] ...
	    sed -e 's/[^:,]*:[^:,]*://g; s/\(,\)\?\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2:\3:\4:\5:\6:\7/g' $CLOUD_TMP/authorized-users > $CLOUD_TMP/authorized-users-ebtables
	    ebtables -t nat -A AUTHORIZE-CORP --among-src-file $CLOUD_TMP/authorized-users-ebtables -j ACCEPT
            result=`ebtables -t nat -L AUTHORIZE-CORP | grep among-src`
            if [ "$result" = "" ]; then
                # --among-src-file failed
		maclist=`cat $CLOUD_TMP/authorized-users-ebtables`
		maclist=`echo $maclist | sed "s/,/ /g"`
		echo "===== CORP Individual MAC addition starts"
		for mac in $maclist
		do
		    ebtables -t nat -A AUTHORIZE-CORP --among-src $mac -j ACCEPT
                    #echo "MAC[$mac] added individually"
		done
		echo "===== CORP Individual MAC addition done"
            fi
	else
	    rm -f $CLOUD_TMP/authorized-users.md5sum
	fi
    fi
    return 0
}

wifi_update_guests()
{
    useacl_guest="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_USEACL_1)"
    
    if [ "$useacl_guest" = "1" ]
    then
        # flush the ebtables' list of authorized guests, then re-load it from the file
	ebtables -t nat -F AUTHORIZE-GUESTS
	if [ -f $CLOUD_TMP/authorized-guests ]
	then
	    md5sum $CLOUD_TMP/authorized-guests | cut -f1 -d\  >$CLOUD_TMP/authorized-guests.md5sum
            ebtables -t nat -A AUTHORIZE-GUESTS --among-src-file $CLOUD_TMP/authorized-guests -j ACCEPT
            result=`ebtables -t nat -L AUTHORIZE-GUESTS | grep among-src`
            if [ "$result" = "" ]; then
                # --among-src-file failed
		maclist=`cat $CLOUD_TMP/authorized-guests`
		maclist=`echo $maclist | sed "s/,/ /g"`
		echo "===== GUEST Individual MAC addition starts"
		for mac in $maclist
		do
                    ebtables -t nat -A AUTHORIZE-GUESTS --among-src $mac -j ACCEPT
                #echo "MAC[$mac] added individually"
		done
		echo "===== GUEST Individual MAC addition done"
            fi
	else
	    rm -f $CLOUD_TMP/authorized-guests.md5sum
	fi
    fi
    return 0
}

wifi_update_guestdmzhost()
{
    useacl_guest="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_USEACL_1)"

    ebtables -t nat -F LOCAL-NET-DMZ
    ebtables -t nat -F LOCAL-NET-DMZ-OUT
    if [ -f $CLOUD_TMP/guest-dmz-host ]
    then
        md5sum $CLOUD_TMP/guest-dmz-host | cut -f1 -d\  >$CLOUD_TMP/guest-dmz-host.md5sum
        ebtables -t nat -F LOCAL-NET-DMZ
        list=`cat $CLOUD_TMP/guest-dmz-host | sed "s/,/ /g"`
        echo $list
        
        for host in $list
        do
           echo $host
           if [ "$useacl_guest" = "1" ]; then
              # inbound (from radio to bridge)
              ebtables -t nat -A LOCAL-NET-DMZ -p 0x800 --pkttype-type otherhost --ip-dst $host -j AUTHORIZE-GUESTS   
              ebtables -t nat -A LOCAL-NET-DMZ -p 0x800 --pkttype-type host --ip-dst $host -j AUTHORIZE-GUESTS   
           else
              # inbound (from radio to bridge)
              ebtables -t nat -A LOCAL-NET-DMZ -p 0x800 --pkttype-type otherhost --ip-dst $host --j ACCEPT  
           fi

           # outbound (from bridge to radio)
           ebtables -t nat -A LOCAL-NET-DMZ-OUT -p 0x800 --ip-src $host -j ACCEPT
        done
    else
	rm -f $CLOUD_TMP/guest-dmz-host.md5sum
    fi
}

wifi_vlantag()
{
    debug_echo "======== VLAN == $1 ID of $2: $3"
    $CLOUD_RUN/ccc_cloud_conf.sh set "AP_VLAN_$CCC_ifacekey" "$3"
    return 0
}

wifi_vlantag2()
{
    wifi_vlantag "$@"
}

debug_echo()
{
    if [ "${DEBUG_FLAG}" = "1" ]; then
        echo "${1}"
    fi
}

wifi_secondradioexist() 
{
    $CLOUD_RUN/ccc_cloud_conf.sh set 'NUMRADIO' '2'
    local oldradio1_enabled="$($CLOUD_RUN/ccc_cloud_conf.sh get 'RADIO_ENABLED_radio1')"
    if [ -z "$oldradio1_enabled" ]
    then	
	$CLOUD_RUN/ccc_cloud_conf.sh set 'RADIO_ENABLED_radio1' '1'
    fi
    return 0
}

wifi_configvlan()
{
    echo " ___ CONFIG VLAN $* ___ "

    ethtag=eth0
    if [ "$MODEL" = "ubdevod" ] || [ "$MODEL" = "WAP224NOC" ] || [ "$MODEL" = "dlrtdev01" ] || [ "$MODEL" = "AP825" ]
    then
        ethtag=br-lan
    fi
    
    local j=0
    local TOTAL_VAPS=$($CLOUD_RUN/ccc_cloud_conf.sh get NUM_VAPS)
    local TOTAL_RADIO=$($CLOUD_RUN/ccc_cloud_conf.sh get NUMRADIO)

    local remove=
    for n in $(ccc_uci show network |grep 'network.vq'|grep =interface)
    do
	net=$(echo $n|cut -d= -f1|cut -d. -f2)
	remove="$net $remove"
    done

    while [ $j -lt "$TOTAL_RADIO" ]
    do
	local i=0
	while [ $i -lt "$TOTAL_VAPS" ]
	do
            echo wifi_configvlan: $j $i

	    local RADIONUM="$j"
	    local VAPNUM="$i"
	    local VARIDX=
	    if [ "$RADIONUM" = "0" ]
	    then
    		VARIDX="${VAPNUM}"
	    else
    		VARIDX="$((RADIONUM + 1))_${VAPNUM}"
	    fi
	    local INDEX="$((VAPNUM + $((TOTAL_VAPS * $RADIONUM))))"
	    local vlan="$($CLOUD_RUN/ccc_cloud_conf.sh get AP_VLAN_${VARIDX})"
	    local VLAN_NETWORKS=""

	    if [ "$vlan" != "" -a "$vlan" != "0" -a "$vlan" != "1" ]
	    then
		local network=vq$vlan
		VLAN_NETWORKS="$network $VLAN_NETWORKS"
		remove=$(echo "$remove"|sed s/$network//)
		if [ "$(uci -q get network.$network)" = "" ]
		then
                    ccc_uci set network.$network=interface
               	    ccc_uci set network.$network.ifname="$ethtag.$vlan"
                    ccc_uci set network.$network.type=bridge
                    ccc_uci set network.$network.ipaddr=0.0.0.0
                    ccc_uci set network.$network.gateway=0.0.0.0
                    ccc_uci set network.$network.proto=dhcp
                    ccc_uci set network.$network.peerdns=0
                    ccc_uci set network.$network.stp=1
		fi

                ccc_uci set wireless.@wifi-iface[$INDEX].network=$network
	    else
                ccc_uci set wireless.@wifi-iface[$INDEX].network=lan
	    fi
	    
	    i=$((i + 1))
	done
	j=$((j + 1))
    done

    if [ "$remove" != "" ]
    then
	for net in $remove
	do
	    ccc_uci delete network.$net
	done
    fi

    if [ "$(uci -q changes network)" != "" ]
    then
        ccc_uci commit
	sync
        debug_echo "===========> reboot"
	sleep 2
        $CLOUDDIR/ccc_platform.sh reboot
	#vconfig set_name_type DEV_PLUS_VID_NO_PAD
	#/etc/init.d/network restart
    fi
}

create_vlan()
{
    dev=eth0
    if [ "$MODEL" = "ubdevod" ] || [ "$MODEL" = "WAP224NOC" ] || [ "$MODEL" = "AP825" ] || [ "$MODEL" = "dlrtdev01" ]
    then
	dev=br-lan
    fi

    # Setup necessary rules for each VLAN.
    # Determine if there are unused VLANs to purge.

    local remove=
    for n in $(uci -q show network |grep 'network.vq'|grep =interface)
    do
	local net=$(echo $n|cut -d= -f1|cut -d. -f2)
	if [ "$(grep "'$net'" /etc/config/wireless 2>/dev/null)" != "" ]
	then
	    local id=${net#vq}
	    
	    echo ___ VLAN Setup ___ $net $dev $id ____
	    
            echo ebtables -t broute -A BROUTING -i $dev --proto 802_1Q --vlan-id $id -j DROP 
            ebtables -t broute -A BROUTING -i $dev --proto 802_1Q --vlan-id $id -j DROP 
	else
	    echo ___ Removing VLAN Setup ___ $net $dev $id ____
	    remove="$net $remove"
	fi
    done

    if [ "$remove" != "" ]
    then
	for net in $remove
	do
	    ccc_uci delete network.$net
	    ccc_uci commit network
	    sync
            debug_echo "===========> reboot"
	    sleep 2
            $CLOUDDIR/ccc_platform.sh reboot
	done
    fi
    
    return 0
}

wifi_prepare()
{
    local j=0
    local TOTAL_VAPS=$($CLOUD_RUN/ccc_cloud_conf.sh get NUM_VAPS)
    local TOTAL_RADIO=$($CLOUD_RUN/ccc_cloud_conf.sh get NUMRADIO)

    while [ $j -lt "$TOTAL_RADIO" ]
    do
	local i=0
	local RADIONUM="$j"
	$CLOUD_RUN/ccc_cloud_conf.sh set RADIO_ENABLED_radio$RADIONUM 0
	while [ $i -lt "$TOTAL_VAPS" ]
	do
            echo wifi_prepare: $j $i
	    local VAPNUM="$i"
	    local VARIDX=
	    if [ "$RADIONUM" = "0" ]
	    then
    		VARIDX="${VAPNUM}"
	    else
    		VARIDX="$((RADIONUM + 1))_${VAPNUM}"
	    fi
	    $CLOUD_RUN/ccc_cloud_conf.sh set AP_ENABLED_${VARIDX} 0
	    i=$((i + 1))
	done
	j=$((j + 1))
    done
}

if [ "$CCC_INCLUDE" = "1" ]; then
	return 0
fi

if [ "$CLOUD_TMP" = "" ]
then
    echo "ccc_wifi.sh: fatal: \$CLOUD_TMP is not set; cloudconf will not be found."
    exit 120
fi
if [ -f $CLOUD_CONF_UCI_CONFIG_DIR/cloudconf ]
then
    . $CLOUD_RUN/ccc_cloud_conf.src
    ccc_cloud_conf_eval
else
    echo "ccc_wifi.sh: fatal: $CLOUD_CONF_UCI_CONFIG_DIR/cloudconf wasn't found.."
    exit 120
fi

RELATIVE_DIR=`dirname $0`
cd $RELATIVE_DIR
. ./ccc_functions.sh

CLOUDDIR=`pwd`
PARAMTYPE=`type wifi_$1`
if [ "$PARAMTYPE" = "wifi_$1 is a shell function" ]
then
    debug_echo "========================> ccc_wifi.sh $@ <========="
    netnum=$2
    if [ ${netnum:-0} -gt 0 ]
    then
	case "$1" in
	    *2)
		CCC_ifacekey="2_$((netnum - 1))"
		netifkey="2_$netnum"
		;;
	    *)
		CCC_ifacekey="$((netnum - 1))"
		netifkey="_$netnum"
		;;
	esac
	eval CCC_ifacenum=\${NETIF$netifkey}
    fi
    wifi_$1 "$@"
else
    echo "ccc_wifi.sh: command not recognized: $1"
fi


