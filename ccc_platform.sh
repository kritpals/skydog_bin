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
# parameters for each function offered by ccc_platfor.sh. Parameters
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
#   +--state

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
   debug_echo "traceroute -q 1 -m 15 $2 | sed -n -e '/^ /!d; s/^ *//g; s/(//; s/).*$//p'"
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

    fixstat="state=0,rssi=$rssi,rate=$rate,rx_data=$rx_packets,rx_bytes=$rx_bytes,tx_data=$tx_packets,tx_bytes=$tx_bytes"

    echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.AssociatedDevice.${i}.AssociatedDeviceMACAddress=$mac"
    echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.AssociatedDevice.${i}.AssociatedDeviceIPAddress=$ip"
    echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.AssociatedDevice.${i}.AssociatedDeviceStatistics=$fixstat"
}

platform_platforminfo()
{
   TOTAL_VAPS=$($CLOUD_RUN/ccc_cloud_conf.sh get NUM_VAPS)
   TOTAL_RADIO=$($CLOUD_RUN/ccc_cloud_conf.sh get NUMRADIO)

   # use ifconfig to learn eth0 mac address and br0 ip+netmask.
   content=`ifconfig`
   ethmac=${content#*eth0}; ethmac=${ethmac#*HWaddr }; ethmac=${ethmac%% *}
   myip=${content#*br-lan}; myip=${myip#*inet addr:}; myip=${myip%% *}
   myMask=${content#*br-lan}; myMask=${myMask#*Mask:}; myMask=${myMask%% *}

   echo "Device.DeviceInfo.SerialNumber=$SERIALNUM"
   
   echo "Device.DeviceInfo.MacAddress=${ethmac}"
   echo "Device.DeviceInfo.Model=$MODEL"
   echo "Device.DeviceInfo.HardwareVersion=$HARDWAREVER"
   echo "Device.DeviceInfo.SoftwareVersion=$FIRMWAREVER"
   # echo "Device.DeviceInfo.SoftwareBuild=$FIRMWAREBUILD"
   # echo "Device.DeviceInfo.SoftwareTime=$FIRMWARETIME"
   echo "Device.DeviceInfo.ClientVersion=$CLIENTVER"
   # echo "Device.DeviceInfo.ClientBuild=$CLIENTBUILD"
   # echo "Device.DeviceInfo.ClientCCagentTime=$CLIENTTIME"
   #wlstatus=`rgdb -i -g /runtime/wireless/setting/status`
   #echo "Device.DeviceInfo.WirelessStatus=$wlstatus"

   echo "Device.LANDevice.1.LANHostConfigManagement.IPInterface.1.IPInterfaceAddress=${myip}"
   echo "Device.LANDevice.1.LANHostConfigManagement.IPInterface.1.IPInterfaceSubnetMask=${myMask}"

   read_mode=`uci show network.lan.proto | cut -f2 -d'='`
   if [ "$read_mode" = "dhcp" ]; then 
      read_mode_str="dynamic"
   else
      read_mode_str="static"
   fi
   read_ip=$myip
   read_mask=`echo $myMask`
   read_gw=`route | grep default | sed -e 's/  */ /g;s/^ //g' | cut -f2 -d" "`
   read_dns1=`cat /etc/resolv.conf | grep nameserver | sed -n "1p;1q" | cut -f2 -d" "`
   read_dns2=`cat /etc/resolv.conf | grep nameserver | sed -n "2p;2q" | cut -f2 -d" "`
   echo "Device.LANDevice.1.LANHostConfigManagement.IPInterface.1.IPStatus=mode:${read_mode_str},address:${read_ip},mask:${read_mask},gateway:${read_gw},dns1:${read_dns1},dns2:${read_dns2}"

   Rl=`cat /proc/net/wireless | sed -n '3,$p' | cut -f1 -d':' | grep -v 'mon'`

   for ath in $Rl
   do
       local vap_id=${ath#ath}
       local vap_id_uci=${vap_id}
       local lan_dev=1
       let vap_id++
       
       athmac=$(getmac $ath)
       
       while [ $vap_id -gt $TOTAL_VAPS ] 
       do
	   vap_id=$((vap_id - $TOTAL_VAPS))
	   lan_dev=$((lan_dev + 1))
       done
       
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.MacAddress=${athmac}" 
       ssid=`uci get wireless.@wifi-iface[${vap_id_uci}].ssid`
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.SSID=${ssid}" 
       
       conf="$(iwinfo $ath freqlist | grep '^\* ')"
       freq="$(echo "$conf" | cut -f2 -d\ )"
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.Radio=${freq}"
       
       chan="$(echo "$conf" | cut -f5 -d\ )"
       chan="${chan%%)*}"
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.Channel=${chan}"
       
       # Find current txpower level in mW
       txpower=`iwinfo $ath txpowerlist 2>/dev/null | grep '\*' | tr -s \  | cut -f5 -d\ `
       if [ "$txpower" = "1" ]
       then
	   txpower=0	
       else
           # iwinfo reports wrong max txpower so we using CCC_MAXTXPOWER defined in 
           # ccc_startup.sh.  CCC_MAXTXPOWER is in dBm so convert to mW
	   maxmwpower="$(iwinfo $ath txpowerlist 2>/dev/null | grep " $CCC_MAXTXPOWER dBm (" | tr -s \  | cut -f5 -d\ )"
	   
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
       
       htmode=`uci -q get wireless.radio0.htmode`
       ht40=${htmode%%+}
       ht40=${ht40%%-}
       bandwidth='0'
       if [ "$htmode" = "" -o "$htmode" = "HT20" ];
       then
           bandwidth='20'
       elif [ "$ht40" = 'HT40' ];
       then
           bandwidth='40'
       fi
       echo "Device.LANDevice.${lan_dev}.WLANConfiguration.${vap_id}.Bandwidth=${bandwidth}" 
       
       local i=0
       local stat=""
       local thismac=""
       local thisip=""
       
       iw dev $ath station dump | sed "s/Station//g" | $CLOUD_RUN/arpsnoop -m > $CLOUD_TMP/sta_stats
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
   done
   
   [ -f /tmp/ccc-error.log ] && { 
       echo "Device.Status.Watchdog=`cat /tmp/ccc-error.log | tr -d '\n'`" 
       touch /tmp/watchdog-report-pending
   }   
   return 0
}

platform_factoryreset()
{
   firstboot
   echo "=============================== reboot ================================="
   reboot
   return 0
}

platform_checkcert()
{
   local CLOUDDIR=$CLOUD_TMP/cloud2dir
   target=`echo $2 | sed "s:$ClOUD_TMP/:$CLOUD2DIR/:"` # use : instead of / to delimit the sed cmd because directories have / in them

   # if new file doesn't exist then there's nothing to do
   if [ ! -f $2 ]
   then
      echo "ccc_platform.sh: platform_checkcert: $2 not found!"
      exit 1
   fi

   # if comparison target doesn't exist then skip calling md5sum and set m1 and
   # m2 different so that the following block will happily copy $2 to $target.
   mkdir -p $CLOUD2DIR/cert-mtd
   tar -C $CLOUD2DIR/cert-mtd -xf /dev/$(grep \"certs\" /proc/mtd | cut -f1 -d:) >/dev/null 2>&1
   tar -C $CLOUD2DIR/cert-mtd -cf $target $(ls -a $CLOUD2DIR/cert-mtd)
   if [ -f $target ]
   then
      m1=`md5sum < $target`
      m2=`md5sum < $2`
   else
      m1="a"
      m2="b"
   fi

   if [ "$m1" = "$m2" ]; then
      echo "$2 and $target are the same"
      exit 0
   else
      mtd write $2 certs
      rm -rf $CLOUD2DIR
      echo "certs partition is updated"
      exit 1
   fi
}

download_file()
{
    local url=$1
    local out=$2
    local md5=$3
    local tmp=/tmp/dl.$$
    wget -q -O $tmp "$url" || { rm -f $tmp; exit 10; }
    local check=$(md5sum $tmp | cut -f1 -d' ')
    if [ "$md5" = "" -o "$check" = "$md5" ]
    then
	mkdir -p $(dirname $out)
	mv -f $tmp $out
	[ -e "$out" ] || { rm -f $tmp; exit 11; }
    else
	echo "Invalid MD5 downloaded $check, expected $md5, for $url"
	rm -f $tmp
	exit 12
    fi
    rm -f $tmp
}

platform_updatepackage()
{
  local url=$2
  local md5=$3

  echo "About to download package from $url with MD5 $md5"
  download_file "$url" "/tmp/package.ipk" "$md5"
  if [ -e /tmp/package.ipk ]
  then
      opkg install --force-downgrade --force-overwrite /tmp/package.ipk || exit 13
      exit 0
  fi
  exit 1
}

platform_updatefw()
{
# Assume that $2 is the location/name firmware file to be downloaded and that $3 is the MD5SUM specified by VMC
# The binary is downloaded and then we compare md5sum of firmware_update.bin (downloaded binary) with $3.
# If the sums match then apply firmware with existing scripts.
  local url=$2
  local md5=$3

  echo "About to download updated firmware from $url with MD5 $md5"
  download_file "$url" "/tmp/firmware_update.bin" "$md5"
  if [ -e /tmp/firmware_update.bin ]
  then
      sysupgrade /tmp/firmware_update.bin
      if [ "$?" = "1" ]; then
  	  echo "firmware update fail"
	  exit 13
      else
  	  exit 0
      fi
  else
      echo "checksum wrong"
  fi
  exit 1
}

platform_updateclient()
{
# $2 is the URL of the CCClient package to be downloaded
# and $3 is the MD5SUM specified by VMC. The binary is downloaded
# and then we compare md5sum of CloudCommand.tar.gz (downloaded binary)
# with $3. If the sums match then allow rc.cloud to unpack the update
# and run it with existing scripts.
  local url=$2
  local md5=$3

  # if wireless is already running, reboot instead of downloading.
  if [ -f $CLOUD_TMP/cloudup ]
  then
     echo "ccc_platform.sh: new client is available, but wifi is already running. Reboot now."
     platform_reboot
  fi

  echo "About to download updated ccclient from $url"

  download_file "$url" "$CLOUD_TMP/CloudCommand.tar.gz" "$md5"
  if [ -e $CLOUD_TMP/CloudCommand.tar.gz ]
  then
    echo "ccclient update md5sums match, proceeding with ccclient update"
    exit 0
  else
    echo "cclient update md5sum does not match, aborting ccclient update"
    exit 1
  fi
}

platform_setvlanstate()
{
  # set vlan state

   debug_echo "ccc_platform.sh: enable/disable vlan state to $2"
   debug_echo "================================================================"
   debug_echo "System vlan state: $2"
   debug_echo "================================================================"
   $CLOUD_RUN/ccc_cloud_conf.sh set "VLAN_ENABLED" "$2"

   return 0
}

platform_setsystemvlan()
{
  # set system(management) vlan

   debug_echo "ccc_platform.sh: set system vlan to $2"
   debug_echo "================================================================"
   debug_echo "System vlan ID: $2"
   debug_echo "================================================================"
   $CLOUD_RUN/ccc_cloud_conf.sh set "SYSTEM_VLAN" "$2"

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

         	debug_echo "$CLOUD_RUN/ccc_failover.sh maybe_copy_acl CERR $ACL_COPY_WAIT_COUNT" 
         	$CLOUD_RUN/ccc_failover.sh maybe_copy_acl CERR $ACL_COPY_WAIT_COUNT || {
         		done=0
         		ccc_state_val=OERR
         	}
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
 
         	debug_echo "$CLOUD_RUN/ccc_failover.sh maybe_copy_acl RERR $ACL_COPY_WAIT_COUNT"
         	$CLOUD_RUN/ccc_failover.sh maybe_copy_acl RERR $ACL_COPY_WAIT_COUNT || {
         		done=0
         		ccc_state_val=OERR
         	}
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

         	debug_echo "$CLOUD_RUN/ccc_failover.sh maybe_copy_acl OERR $ACL_COPY_WAIT_COUNT"
         	$CLOUD_RUN/ccc_failover.sh maybe_copy_acl OERR $ACL_COPY_WAIT_COUNT
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
		# ACL_COPY_WAIT_COUNT is the number of calls between check if copy needed
        	debug_echo "$CLOUD_RUN/ccc_failover.sh maybe_copy_acl DONE $ACL_COPY_WAIT_COUNT"
        	$CLOUD_RUN/ccc_failover.sh maybe_copy_acl DONE "$ACL_COPY_WAIT_COUNT" || {
			done=0
			ccc_state_val=OERR
		}
		if [ ! -e /tmp/cloud/.dateset ]; then
			/etc/init.d/storedate stop
			touch /tmp/cloud/.dateset
		fi
		[ -f /tmp/watchdog-report-pending ] && {
			rm /tmp/ccc-error.log
			rm /tmp/watchdog-report-pending
		}
		;;
	esac
  done
}

platform_userpassword_change() {
    # $2 is username
    # $3 is password
    # $4 is uid
    # $5 is gid 
    [ "$2" = "" -o "$3" = "" ] && return 1

    local newname="$2"
    local newpwd="$3"
    local uid="$4"
    local gid="$5"
    
    local pwdline="$(grep -E "^.*:.*:${uid}:${gid}:.*:.*:" /etc/passwd  | head -n1)" 
    local oldname="$(echo "$pwdline" | cut -f1 -d:)" 
    local oldpwd="$(echo "$pwdline" | cut -f2 -d:)" 

    if [ "$newname" != "$oldname" -o "$newpwd" != "$oldpwd" ]
    then
	rm -f /etc/group+
   	touch /etc/group+
   	chmod 644 /etc/group+
	rm -f /etc/passwd+
   	touch /etc/passwd+
   	chmod 644 /etc/passwd+
   	debug_echo "* Backing up group and passwd files"
   	cp -a /etc/group /etc/group-
   	cp -a /etc/passwd /etc/passwd-

	if [ "$newname" != "$oldname" ]
	then
   	    debug_echo "* Old root username was $oldname"
   	    if [ -e /etc/crontabs/"$oldname" ]
	    then 
		debug_echo "* Rename files whose name depend on root username"
		mv -f /etc/crontabs/"$oldname" /etc/crontabs/"$newname"; 
   	    fi
	fi

   	debug_echo "* Creating new group file with $newname replacing $oldname"
   	sed -e "s,^$oldname:\(.*\):${gid}:\(.*\),$newname:\1:${gid}:\2," /etc/group >>/etc/group+
   	debug_echo "* Creating new passwd file with $newname replacing $oldname"
   	debug_echo "Resetting password"
   	sed -e "s,^$oldname:.*:${uid}:${gid}:$oldname:\(.*\):\(.*\),$newname:$newpwd:${uid}:${gid}:$newname:\1:\2," /etc/passwd >>/etc/passwd+
   	debug_echo "* Making new group and passwd files active" 
   	mv -f /etc/group+ /etc/group
   	mv -f /etc/passwd+ /etc/passwd
    fi
    return 0
}

platform_shelluserpassword()
{
    # $2 is username
    # $3 is password
    local newname="$2"
    local newpwd="$3"

    platform_userpassword_change userpassword_change "$newname" "$newpwd" 0 0
}

platform_localuserpassword()
{
    # $2 is username
    # $3 is password
    local newname="$2"
    local newpwd="$3"

    if ! platform_userpassword_change userpassword_change "$newname" "$newpwd" 202 202; then
	return
    fi

    echo "/:$newname:\$p\$$newname" > /etc/httpd.conf 
    /etc/init.d/uhttpd restart
    return 0
}

if [ "$CCC_INCLUDE" = "1" ]; then
	return 0
fi

RELATIVE_DIR=`dirname $0`
cd $RELATIVE_DIR
. ./ccc_functions.sh
CLOUDDIR=`pwd`
PARAMTYPE=`type platform_$1`
if [ "$PARAMTYPE" = "platform_$1 is a shell function" ]; then
   case "$1" in
   localuserpassword | \
   userpassword_change | \
   shelluserpassword)
	echo "ccc_platform.sh \"$1\" <hidden parameters>"
	;;
   *)
	echo "ccc_platform.sh \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\""
	;;
   esac
   platform_$1 "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
else
   echo "ccc_platform.sh: command not recognized: $1"
fi
