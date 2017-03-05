#!/bin/sh
#
# Copyright 2010-2011 PowerCloud Systems, All Rights Reserved
#
# ccc_platform.sh encapsulates platform-specific operations needed
# by the Cloud Command Client. This script must be stored in the
# CloudCommand.tar.gz at $CLOUD_ROOT (see rc.cloud).
#
# Modify as needed to implement platform-specific support for
# the various functions.
#
# The tree below describes operation of and optional and required
# parameters for each function offered by ccc_platform.sh. Parameters
# are described with angle or square brackets to indicate <required>
# or [optional] status.
#
# ccc_platform.sh
#   +--settime
#   +--reboot
#   +--traceroute
#   +--platforminfo
#   +--factoryreset
#   +--checkcert
#   +--updatefw
#   +--updateclient
#   +--setip
#   +--ipmode
#   +--state
#   +--poll_station

[ -z "$ACL_COPY_WAIT_COUNT" ] && ACL_COPY_WAIT_COUNT=10

DEBUG_FLAG="$script_debug"

platform_settime()
{
   # argument is server's date/time formatted as YYYY.MM.DD-HH:MM:SS. Compare
   # against local time; if different, then adjust local time.
   localtime=`date -Iseconds | sed 's/-....$//g' | sed 's/-/\./g; s/T/-/g; s/:[0-9][0-9]$//g'`
   servertime=`echo $2 | sed 's/:[0-9][0-9]$//g'`
   if [ "$servertime" != "$localtime" ]
   then
      echo "local system time $localtime differs from server. Resetting to $servertime"
      date -s $2
   else
      echo "local system time matches server. no adjustment made. $2"
   fi

   return 0
}

platform_reboot()
{
   echo "=============================== reboot ================================="
   reboot
   return 0
}

platform_traceroute()
{
   # manipulate output of traceroute so that it matches this format:
   # 1 host.name.domain 1.2.3.4
   # 2 another.host.domain 192.168.1.2
   # ...
   echo "traceroute -q 1 -m 15 $2 | sed -n -e '/^ /!d; s/^ *//g; s/(//; s/).*$//p'"
   traceroute -q 1 -m 15 $2 | sed -n -e '/^ /!d; s/^ *//g; s/(//; s/).*$//p'

   return 0
}

print_sta_stat()
{
    local i=$1
    local lan_dev=$2
    local vap_id=$3
    local mac=$4
    local ip=$5
    local stats=$6

    # remove leading space from stat var
    stats=${stats##\ }
    # format stat var: = between param and value; , between sets;
    # drop trailing spaces
    rx_bytes=${stats#*rx bytes:}
    rx_bytes=`echo $rx_bytes | cut -f1 -d" "`

    rx_packets=${stats#*rx packets:}
    rx_packets=`echo $rx_packets | cut -f1 -d" "`
    
    tx_bytes=${stats#*tx bytes:}
    tx_bytes=`echo $tx_bytes | cut -f1 -d" "`

    tx_packets=${stats#*tx packets:}
    tx_packets=`echo $tx_packets | cut -f1 -d" "`

    rssi=${stats#*signal:}
    rssi=`echo $rssi | cut -f1 -d" "`

    rate=${stats#*rate:}
    rate=`echo $rate | cut -f1 -d" "`

    fixstat="state:0,rssi:$rssi,rate:$rate,rx_data:$rx_packets,rx_bytes:$rx_bytes,tx_data:$tx_packets,tx_bytes:$tx_bytes"

    echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.AssociatedDevice.${i}.MacAddress=$(fmt_mac $mac)"
    # echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.AssociatedDevice.${i}.IPAddress=$ip"
    echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.AssociatedDevice.${i}.Statistics=$fixstat"
}

platform_platforminfo()
{
   # use ifconfig to learn eth0 mac address and br0 ip+netmask.
   content="$(ifconfig eth0)"
   ethmac="${content##*HWaddr }"; ethmac="${ethmac%% *}"

   echo "Device.DeviceInfo.SerialNumber=$SERIALNUM"
   echo "Device.DeviceInfo.MacAddress=$(fmt_mac $ethmac)"
   echo "Device.DeviceInfo.Model=$MODEL"
   echo "Device.DeviceInfo.HardwareVersion=$HARDWAREVER"
   echo "Device.DeviceInfo.SoftwareVersion=$FIRMWAREVER"
   # echo "Device.DeviceInfo.SoftwareBuild=$FIRMWAREBUILD"
   # echo "Device.DeviceInfo.SoftwareTime=$FIRMWARETIME"
   echo "Device.DeviceInfo.ClientVersion=$CLIENTVER"
   # echo "Device.DeviceInfo.ClientBuild=$CLIENTBUILD"
   # echo "Device.DeviceInfo.ClientCCagentTime=$CLIENTTIME"
   local xgtype="$(uci get system.xgtype.xgtype 2>/dev/null)"
   local xgtuntype="$(uci get system.xgtype.xgtuntype 2>/dev/null)"
   local xgserverports="$(uci get system.xgtype.xgserverports 2>/dev/null)"
   if [ "$xgtype" = "xgateway" ]; then
       echo "Device.XGateway.Enabled=true"
       echo "Device.Extender.Enabled=false"
       echo "Device.XGateway.TunnelType=$xgtuntype"
       local tunport
       for tunport in $xgserverports; do
           echo "Device.XGateway.Tunnel.$tunport"
       done
    elif [ "$xgtype" = "extender" ]; then
       echo "Device.XGateway.Enabled=false"
       echo "Device.Extender.Enabled=true"
       echo "Device.Extender.TunnelType=$xgtuntype"
       echo "Device.Extender.Tunnel.ServerPort=$xgserverports"
   else
       echo "Device.XGateway.Enabled=false"
       echo "Device.Extender.Enabled=false"
   fi

   . /etc/functions.sh
   include /lib/config

   . $CLOUD_RUN/ccc_txpower.src

   restart_uam=
   stations_tmpfile=/tmp/.cccs.$$
   stations_sortfile=/tmp/.cccsort.$$
   interfaces_tmpfile=/tmp/.ccci.$$
   ./ccc-cmd stations > $stations_tmpfile 2>/dev/null
   ./ccc-cmd interfaces > $interfaces_tmpfile 2>/dev/null

   report_wifi_config() {
       local cfg="$1"
       local lan_dev="$2"
       local reallan="$3"
       
       local disable ifname ssid vap_id conf freq network

       vap_id="${cfg##ath*_*_}"
       radio="${cfg#ath*_}"
       radio="${radio%%_*}"
      
       config_get_bool disabled "$cfg" disabled 0
       [ "$disabled" = "1" ] && return 0
       
       config_get ifname "$cfg" ifname
       config_get ssid "$cfg" ssid
       config_get network "$cfg" network
       
       # Only show WLAN for the current LANDevice
       if [ "$network" != "lan${lan_dev}" ] && [ "$reallan" = "1" ]; then
	   return 0
       fi
       if [ "$network" != "wan" ] && [ "$reallan" != "1" ]; then
           return 0
       fi
       
       local athmac="$(getmac $ifname)"
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.MacAddress=${athmac}" 
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.SSID=${ssid}" 
       
       conf="$(iwinfo $ifname freqlist | grep '^\* ')"
       freq="$(echo "$conf" | cut -f2 -d\ )"
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.Radio=${freq}"
       chan="$(echo "$conf" | cut -f5 -d\ )"
       chan="${chan%%)*}"
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.Channel=${chan}"

       determine_txpower_levels "$regdomain" >/dev/null 2>&1
       
       # Find current txpower level in mW
       txpower=`iwinfo $ifname txpowerlist 2>/dev/null | grep '\*' | tr -s \  | cut -f5 -d\ `
       if [ "$txpower" = "1" ]
       then
	   txpower=0	
       else
           # iwinfo reports wrong max txpower so we using CCC_MAXTXPOWER defined in 
           # ccc_startup.sh.  CCC_MAXTXPOWER is in dBm so convert to mW
           local tmpmax
           if [ "$radio" = "0" ]; then
          	tmpmax=$CCC_MAXTXPOWER
           else
           	tmpmax=$CCC_MAXTXPOWER2
           fi 
	   maxmwpower="$(iwinfo $ifname txpowerlist 2>/dev/null | grep " $tmpmax dBm (" | tr -s \  | cut -f5 -d\ )"
	   
	   # To avoid any arithmetic bail-out error
	   maxmwpower=${maxmwpower:-0}
	   txpower=${txpower:--1}
	   
	   if [ "$txpower" -ge "$maxmwpower" ]; then
	       txpower=1
	   elif [ "$txpower" -ge "$(($maxmwpower / 2))" ] ; then
	       txpower=2
	   elif [ "$txpower" -ge "$(($maxmwpower / 4))" ]; then
	       txpower=3
	   elif [ "$txpower" -ge 1 ]; then
	       txpower=4
	   else
               # This is an error condition
	       txpower=-1 
	   fi
       fi

       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.TxPower=${txpower}" 
       
       htmode=$(uci -q get wireless.radio0.htmode 2>/dev/null)
       ht40=${htmode%%+}
       ht40=${ht40%%-}
       bandwidth='0'
       if [ "$htmode" = "" -o "$htmode" = "HT20" ]
       then
           bandwidth='20'
       elif [ "$ht40" = 'HT40' ]
       then
       	   bandwidth='40'
       fi

       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.Bandwidth=${bandwidth}" 

       local i=0
       local stat=""
       local thismac=""
       local thisip=""
       
       iw dev $ifname station dump | sed "s/Station//g" > $CLOUD_TMP/sta_stats
       while read j
       do
	   mac=`expr match "$j" '[ \\t]*\(\([0-9a-fA-F]\{1,2\}:\)\{5\}[0-9a-fA-F]\{1,2\}\).*'`
	   mac_match="$?"
	   ip=`expr match "$j" '.*ipaddr=\([0-9.]*\).*'`
	   ip_match="$?"
	   if [ "$mac_match" = "0" ]
	   then
               # if this line contains a mac address then print the current
               # accumulated line and start a new line
	       if [ "$thismac" != "" ]
	       then 
		   print_sta_stat $i ${lan_dev} ${vap_id} "$thismac" "$thisip" "$stat"
	       fi
	       thismac=${mac%:} # drop the trailing : char
	       thisip=""
	       stat=""
	       i=$((i+1))
	   elif [ "$ip_match" = "0" ]
	   then
	       thisip="$ip"
	   else
	       # else append this stuff and keep going
	       stat="$stat $j"
	   fi
       done < $CLOUD_TMP/sta_stats
       rm $CLOUD_TMP/sta_stats
       if [ "$thismac" != "" ]
       then
	   print_sta_stat $i ${lan_dev} ${vap_id} "$thismac" "$thisip" "$stat"
       fi

       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.AssociatedDeviceNumberOfEntries=${i}"
   } 

   report_ip_stat() {
	local cfg="$1"
        local ifname ipaddr netmask gateway proto subnet dns_list macaddr

	network_get_ipaddr ipaddr "$cfg" 
	network_get_subnet subnet "$cfg" 
	netmask="$(ipcalc.sh $subnet|grep NETMASK|cut -f2 -d=)"
	network_get_gateway gateway "$cfg"
	network_get_dnsserver dns_list "$cfg"
	network_get_physdev ifname "$cfg"
	
	config_get proto "$cfg" proto
	config_get clientid "$cfg" clientid 
	config_get wan_type "$cfg" wan_type wired
	config_get clonemac "$cfg" macaddr
	
        [ "$clientid" = "" ] && clientid="false" || clientid="true"

	mtu="$(
		. /lib/functions/network.sh
		network_get_device ifname $cfg
		content="$(ifconfig $ifname)"
		mtu="${content##*MTU:}"
		mtu="${mtu%% *}"
		echo "$mtu"
        )"

        macaddr="$(
	    . /lib/functions/network.sh
	    network_get_device ifname $cfg
	    content="$(ifconfig $ifname)"
   	    ethmac="${content##*HWaddr }"; ethmac="${ethmac%% *}"
 	    echo "$ethmac"
        )"

	case "$cfg" in
	    loopback)
		;;
	    wan)
   		echo "Device.WANDevice.1.Protocol=${proto}"
   		echo "Device.WANDevice.1.IPAddress=${ipaddr}"
   		echo "Device.WANDevice.1.Netmask=${netmask}"
   		echo "Device.WANDevice.1.Gateway=${gateway}"
   		echo "Device.WANDevice.1.MacAddress=$(fmt_mac ${macaddr})"
   		echo "Device.WANDevice.1.SetClientId=$clientid"
		echo "Device.WANDevice.1.MTU=${mtu}"
                echo "Device.WANDevice.1.CloneMacAddress=$(fmt_mac ${clonemac})"

		case "$wan_type" in
		    wifi)
			(
			    wanwifi() {
				local cfg="$1"
				config_get network "$cfg" network
				config_get mode "$cfg" mode
				if [ "$network" = "$cfg" ] && [ "$mode" = "sta" ]; then
				    config_get ssid "$cfg" ssid
				    config_get key "$cfg" key
				    config_get device "$cfg" device
				    echo "Device.WANDevice.1.Wifi.Radio=$device"
				    echo "Device.WANDevice.1.Wifi.SSID=$ssid"
				    echo "Device.WANDevice.1.Wifi.PSK=$key"
				fi
			    }
			    . /lib/functions.sh
			    config_load wireless
			    config_foreach wanwifi wifi-iface
			)
			;;
		    vlan)
			local ifname
			config_get ifname "$cfg" ifname
			echo "Device.WANDevice.1.VlanId=$(echo "$ifname" | cut -f2 -d.)"		;;
		    *)
			;;
		esac

		echo "Device.WANDevice.1.Type=${wan_type}"
		local dns_wan="$(uci -q get network.wan.dns 2>/dev/null)"
		local dns_dyn=""
		local dns_sta=""
		local dns_hl dns_hw is_static
		for dns_hl in $dns_list
		do
		    is_static=0
		    for dns_hw in $dns_wan
		    do
			[ "$dns_hw" = "$dns_hl" ] && is_static=1
		    done
		    case "$is_static" in
			1) dns_sta="$dns_hl $dns_sta" ;;
			0) dns_dyn="$dns_hl $dns_dyn" ;;
		    esac
		done
		
   		echo "Device.WANDevice.1.DhcpDNS=$(ccc_comma ${dns_dyn})"
   		echo "Device.WANDevice.1.DNS=$(ccc_comma ${dns_sta})"

		case "$proto" in
		    pppoe)
			config_get username "$cfg" username
			config_get password "$cfg" password
			config_get ac "$cfg" ac
			config_get demand "$cfg" demand
			config_get service "$cfg" service
			config_get pppd_options "$cfg" pppd_options
			config_get keeplalive "$cfg" keepalive
   			echo "Device.WANDevice.1.PPPoE.Service=${service}"
   			echo "Device.WANDevice.1.PPPoE.AccessConcentrator=${ac}"
   			echo "Device.WANDevice.1.PPP.Username=${username}"
   			echo "Device.WANDevice.1.PPP.Password=${password}"
			echo "Device.WANDevice.1.PPP.AfterNumLCPAttempts=${keepalive%% *}"
			echo "Device.WANDevice.1.PPP.LCPAttempWait=${keepalive##* }"
			;;
		esac

		#eval $(grep "^dev=$ifname " $interfaces_tmpfile)
   		#echo "Device.WANDevice.1.Statistics=in-pkts:$in_pkts,out-pkts:$out_pkts,in-bytes:$in_bytes,out-bytes:$out_bytes,in-local-bytes:$in_local_bytes,out-local-bytes:$out_local_bytes"
		;;
	esac

	local showlan=0
        local reallan=0
        local lan
        local lan_dev
        case $cfg in
	    lan*)
		showlan=1
		lan="$cfg"
		lan_dev="${cfg##lan}"
                reallan=1
		local uam

		if [ "$xgtype" = "extender" ] && [ "$xgtuntype" = "zone" ]; then
		    continue
                fi

   		echo "Device.LANDevice.${lan_dev}.IPAddress=${ipaddr}"
   		echo "Device.LANDevice.${lan_dev}.Netmask=${netmask}"

		local ip mac in_pkts out_pkts in_bytes out_bytes in_local_bytes out_local_bytes
		local netname workgroup useragent

		uam=$(uci -q show chilli 2>/dev/null|grep "network=$cfg")

		if [ "$uam" != "" ]
		then
		    chilli_query /var/run/chilli_uam${lan_dev}.sock procs 2>/dev/null >/dev/null || restart_uam="$restart_uam ${lan_dev}"
		fi
		eval $(grep "^dev=br-$lan " $interfaces_tmpfile)

   		echo "Device.LANDevice.${lan_dev}.Statistics=in-pkts:$in_pkts,out-pkts:$out_pkts,in-bytes:$in_bytes,out-bytes:$out_bytes,in-local-bytes:$in_local_bytes,out-local-bytes:$out_local_bytes,since:$since,last:$last"

		local stations=0
		grep "^dev=br-$lan " $stations_tmpfile | sort > $stations_sortfile
		while read line
		do
		    stations=$((stations + 1))
		    eval "$line"
   		    echo "Device.LANDevice.${lan_dev}.AssociatedStations.${stations}.IPAddress=$ip"
   		    echo "Device.LANDevice.${lan_dev}.AssociatedStations.${stations}.MacAddress=$(fmt_mac $mac)"
   		    echo "Device.LANDevice.${lan_dev}.AssociatedStations.${stations}.Statistics=in-pkts:$in_pkts,out-pkts:$out_pkts,in-bytes:$in_bytes,out-bytes:$out_bytes,in-local-bytes:$in_local_bytes,out-local-bytes:$out_local_bytes,since:$since,last:$last"
		    [ "$netname" = "" ] || \
   			echo "Device.LANDevice.${lan_dev}.AssociatedStations.${stations}.Netname=$netname"
		    [ "$workgroup" = "" ] || \
   			echo "Device.LANDevice.${lan_dev}.AssociatedStations.${stations}.Workgroup=$workgroup"
                    [ "$useragent" = "" ] || \
			echo "Device.LANDevice.${lan_dev}.AssociatedStations.${stations}.UserAgent=$useragent"


		    if [ "$uam" != "" ]
		    then
			uam_status=$(chilli_query /var/run/chilli_uam${lan_dev}.sock list mac $mac | awk '
BEGIN { OFS = ""; ORS = "" }
{
  print "sessionid=" $4
  print ",auth=" $5
  if ($5 == 1) {
    vin="down"
    vout="up"
    if ($12 == 1) {
      vin="up"
      vout="down"
    }
    print ",user=" $6
    print ",time=" $7
    print ",idle=" $8
    print "," in "=" $9
    print "," out "=" $10
    print ",max_bytes=" $11
    print ",bw_up=" $13
    print ",bw_down=" $14
  }
}')
			echo "Device.LANDevice.${lan_dev}.AssociatedStations.${stations}.UAM=$uam_status"
		    fi
		    
 		done < $stations_sortfile

   		echo "Device.LANDevice.${lan_dev}.AssociatedStations.NumberOfEntries=${stations}"

		;;
       esac

        local xglannet
	if [ "$cfg" = "wan" ] && [ "$xgtype" = "extender" ] && [ "$xgtuntype" = "zone" ]; then
            showlan=1
	    xglannet="$(uci get system.xgtype.xglannet 2>/dev/null)" 
	    lan_dev="$xglannet"
	    lan=lan"${lan_dev}"
            reallan=0
	fi

	if [ "$showlan" = "1" ]; then
	        # report regulatory domain
       		regdomain=`iw reg get | grep country | sed "s/://g" | cut -f2 -d" "`
		if [ "$regdomain" != "" ]; then
		    echo "Device.LANDevice.1.WLANConfiguration.RegulatoryDomainType=ISO3166-1-alpha-2"
		    echo "Device.LANDevice.1.WLANConfiguration.RegulatoryDomain=${regdomain}"
		fi

   		config_load wireless
   		config_foreach report_wifi_config wifi-iface "$lan_dev" "$reallan"

       fi
       if [ "$showlan" = "1" ] && [ "$reallan" = "1" ]; then
		local leases=0
		local exp mac ip host clid iface
		while read exp mac ip host clid iface
		do
		    if [ "$iface" = "br-$lan" ]
		    then
			leases=$((leases + 1))
			mac=$(echo "$mac"|sed 's/[:-]//g'|tr '[a-z]' '[A-Z]')
			host=$(echo "$host"|sed 's/://g')
   			echo "Device.LANDevice.${lan_dev}.DHCPServer.DHCPClient.${leases}.DeviceInfo=$mac:$ip:$host:$exp"
		    fi
		done < /tmp/dhcp.leases
   		echo "Device.LANDevice.${lan_dev}.DHCPServer.DHCPClient.NumberOfEntries=${leases}"
	fi
   }

   export LOAD_STATE=1
   config_load network
   config_foreach report_ip_stat interface

   rm -f $stations_tmpfile $stations_sortfile
   rm -f $interfaces_tmpfile

   [ "$restart_uam" != "" ] && /etc/init.d/chilli restart $restart_uam

   # DNSData dump
   dnsdata_tmpfile=/tmp/.dnsdata.$$
   ./ccc-cmd dnsdata > $dnsdata_tmpfile 2>/dev/null
   if ! grep -q 'usage: ./ccc-cmd' $dnsdata_tmpfile; then
   	local lines=0
   	local line mac time q res_name res_ip
   	while read line
   	do
       		lines=$((lines + 1))
       		eval "$line"
       		echo "Device.LANDevice.DNSData.${lines}.Timestamp=${time}"
       		echo "Device.LANDevice.DNSData.${lines}.MacAddress=$(fmt_mac $mac)"
       		echo "Device.LANDevice.DNSData.${lines}.QueryName=${q}"
       		echo "Device.LANDevice.DNSData.${lines}.ResIPAddress=${res_ip}"
       		echo "Device.LANDevice.DNSData.${lines}.ResName=${res_name}"
   	done < $dnsdata_tmpfile
   fi
   echo "Device.LANDevice.DNSData.NumberOfEntries=${lines}"
   rm -f $dnsdata_tmpfile

   # Watchlist dump
   watchlist_tmpfile=/tmp/.watchlist.$$
   ./ccc-cmd watchlist | sort > $watchlist_tmpfile 2>/dev/null
   local lines=0
   local lastdev=
   local line dev mac list host address up down since last
   while read line
   do
       eval "$line"
       if [ "$lastdev" != "$dev" ]
       then
	   lines=0 
	   lastdev=$dev
       fi
       lines=$((lines + 1))
       echo "Device.LANDevice.${dev##br-lan}.DNSWatch.${lines}.Stats=$(fmt_mac $mac), $list, $host, $address, $down, $up, $since, $last"
   done < $watchlist_tmpfile
   rm -f $watchlist_tmpfile

   # Presence dump
   presence_tmpfile=/tmp/.presence.$$
   ./ccc-cmd presence | sort > $presence_tmpfile 2>/dev/null
   local lines=0
   local lastdev=
   # dev=mon-radio0 mac=00:xx:xx:xx:xx:xx since=1328 last=1329 chan=5180 rssi=-40 ssid_cnt=0 ssids=""
   local line dev mac since last chan rssi ssid_cnt ssids freq
   while read line
   do
       eval "$line"
       if [ "$lastdev" != "$dev" ]
       then
	   lines=0 
	   lastdev=$dev
       fi
       lines=$((lines + 1))
       freq="2.4"
       [ "$chan" -gt 4900 -a "$chan" -lt 6000 ] && freq="5"
       echo "Device.Presence.${lines}.Radio=$freq"
       echo "Device.Presence.${lines}.MacAddress=$(fmt_mac $mac)"
       echo "Device.Presence.${lines}.RSSI=$rssi"
       echo "Device.Presence.${lines}.SSID=$ssids"
       echo "Device.Presence.${lines}.FirstSeen=$since"
       echo "Device.Presence.${lines}.LastSeen=$last"
   done < $presence_tmpfile
   rm -f $presence_tmpfile

   # BWTest results
   if [ -e /tmp/bwtest.failed ]
   then
       echo "Device.BWTest.Failure=$(cat /tmp/bwtest.failed | tr '\n' ' ')"
       rm -f /tmp/bwtest.*
   else
       if [ -e /tmp/bwtest.result ]
       then
	   cat /tmp/bwtest.result
	   rm -f /tmp/bwtest.*
       fi
   fi

   return 0
}

platform_factoryreset()
{
   firstboot
   echo "=============================== reboot ================================="
   reboot
   return 0
}

platform_state()
{
  local ccc_state_val
  local done=0
  
  ccc_state_val="$2"
  
  debug_echo "$CLOUD_RUN/ccc_failover.sh set_failover_state $ccc_state_val $ACL_COPY_WAIT_COUNT"
  $CLOUD_RUN/ccc_failover.sh set_failover_state "$ccc_state_val" "$ACL_COPY_WAIT_COUNT" || ccc_state_val="OERR"

  while [ "$done" = "0" ]; do
  	done=1
  	case "$ccc_state_val" in
      	"CERR")
		# error connecting to VMC
          	echo none > /sys/class/leds/${ledgoodname}/trigger
          	echo 0 > /sys/class/leds/${ledgoodname}/brightness
	
		echo $ledbadtrigger >/sys/class/leds/${ledbadname}/trigger

		if [ "$ledbadtrigger" = "timer" ]; then
			echo $ledbadon >/sys/class/leds/${ledbadname}/delay_on
			echo $ledbadoff >/sys/class/leds/${ledbadname}/delay_off
		else
          		echo 1 > /sys/class/leds/$ledbadname/brightness
		fi

		;;
      	"RERR")
	  	# connected but turned away.. (probably not registered)
          	echo none > /sys/class/leds/${ledgoodname}/trigger
          	echo 0 > /sys/class/leds/${ledgoodname}/brightness
	
		echo $ledbadtrigger >/sys/class/leds/${ledbadname}/trigger

		if [ "$ledbadtrigger" = "timer" ]; then
			echo $ledbadon >/sys/class/leds/${ledbadname}/delay_on
			echo $ledbadoff >/sys/class/leds/${ledbadname}/delay_off
		else
         		echo 1 > /sys/class/leds/$ledbadname/brightness
		fi
 
		;;
	"OERR")
		# openwrt state err
          	echo none > /sys/class/leds/${ledgoodname}/trigger
          	echo 0 > /sys/class/leds/${ledgoodname}/brightness
	
		echo $ledbadtrigger >/sys/class/leds/${ledbadname}/trigger

		if [ "$ledbadtrigger" = "timer" ]; then
			echo $ledbadon >/sys/class/leds/${ledbadname}/delay_on
			echo $ledbadoff >/sys/class/leds/${ledbadname}/delay_off
		else
         		echo 1 > /sys/class/leds/$ledbadname/brightness
		fi

		;;
      	"DONE")
		# finished successful connection to VMC
          	echo none > /sys/class/leds/${ledbadname}/trigger
          	echo 0 > /sys/class/leds/${ledbadname}/brightness
	
		echo $ledgoodtrigger >/sys/class/leds/${ledgoodname}/trigger

		if [ "$ledgoodtrigger" = "timer" ]; then
			echo $ledgoodon >/sys/class/leds/${ledgoodname}/delay_on
			echo $ledgoodoff >/sys/class/leds/${ledgoodname}/delay_off
		else
          		echo 1 > /sys/class/leds/$ledgoodname/brightness
		fi
		# Done should only happen after an Inform and reply with no SetParamValues so
		# there should only be outstanding commits if an event outside ccclient has occurred
		# (e.g. new DHCP address for a lan, if lans are served by DHCP)
		$CLOUD_RUN/ccc_uci.sh apply_changes
		;;
	esac
  done
}

platform_poll_station() {
	local oIFS="$IFS"
	IFS='
'
	for station in $CLOUD_RUN/ccc-cmd stations; do
		IFS="$oIFS"
		local sta_mac="${station##* mac=}"
		sta_mac="${sta_mac%% *}"
		sta_mac="$(echo $sta_mac | tr -d : | tr 'a-z' 'A-Z')"
		local sta_ip="${station##* ip=}"
		sta_ip="${sta_ip%% *}"
		ccc_run_router update_srz_device "$mac" "$sta_ip" 
		IFS='
'
	done
	IFS="$oIFS"
	ccc_run_uci commit all
	ccc_run_uci apply_changes
}

# platform_localuserpassword() ( in ccc_platform.sh )

if [ "$CCC_INCLUDE" = "1" ]; then
	return 0
fi

RELATIVE_DIR=`dirname $0`
cd $RELATIVE_DIR
. ./ccc_functions.sh
. /lib/functions/network.sh
CLOUDDIR=`pwd`
PARAMTYPE=`type platform_$1`
if [ "$PARAMTYPE" = "platform_$1 is a shell function" ]
then
   echo "ccc_platform.sh \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\""
   platform_$1 "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
else
   echo "ccc_2.0_platform.sh: command not recognized: $1"
fi
