#!/bin/sh
CCC_INCLUDE=1
cd $(dirname $0)
. ./ccc_functions.sh
. ./ccc_2.0_wifi.sh
. ./ccc_router.sh
. ./ccc_uci.sh
. ./ccc_platform.sh
. ./ccc_2.0_platform.sh
. ./ccc_tc.sh
. ./ccc_txpower.src

echo Running $0 $*
#env|grep CCC_|sort

#start_sec=$(date +%s)

ccc_configType=${CCC_DeviceConfigurationType:-AP}
ccc_protocol=${CCC_ProtocolInfoProtocolVersion:-1.0}
ccc_rate=kbit
UCIListsCheck=

wifi_device_name() {
    local deviceName=$1
    local wlanId=$2
    if [ "$deviceName" = "" ]
    then
	case "$wlanId" in
	    1)
		deviceName=${WIFI_2G_RADIO:-radio0}
		;;
	    2)
		deviceName=${WIFI_5G_RADIO:-radio1}
		;;
	esac
    fi
    echo $deviceName
}

ccc_radioConfig() {
    local id=$1
    local rc=$2

    local Enabled=$(ccc_v ${rc}Enabled)
    local DeviceName=$(ccc_v ${rc}DeviceName)
    local SelectChannel=$(ccc_v ${rc}SelectChannel)
    local Channel=$(ccc_v ${rc}Channel)
    local Bandwidth=$(ccc_v ${rc}Bandwidth)
    local TxPower=$(ccc_v ${rc}TxPower)
    local RogueAPDetection=$(ccc_v ${rc}RogueAPDetection)
    local RogueAPDetectionFrequency=$(ccc_v ${rc}RogueAPDetectionFrequency)
    local Presence=$(ccc_v ${rc}Presence)
    local HWMode=$(ccc_v ${rc}HWMode)
    local BasicRates=$(ccc_v ${rc}BasicRates | tr ',' ' ')
    local BeaconInterval=$(ccc_v ${rc}BeaconInterval)

    # Capabilities
    local ShortGI20=$(ccc_v ${rc}CapabilityShortGI20)
    local ShortGI40=$(ccc_v ${rc}CapabilityShortGI40)
    local LDPC=$(ccc_v ${rc}CapabilityLDPC)
    local TXSTBC=$(ccc_v ${rc}CapabilityTXSTBC)
    local RXSTBC=$(ccc_v ${rc}CapabilityRXSTBC)
    local DSSSCCK40=$(ccc_v ${rc}CapabilityDSSSCCK40)
    local Other=$(ccc_v ${rc}CapabilityOther)

    local ht_capab=""
    [ "${ShortGI20}" = "true" ]        && ht_capab="$ht_capab SHORT-GI-20"
    [ "${ShortGI40:-true}" = "true" ]  && ht_capab="$ht_capab SHORT-GI-40"
    [ "${LDPC}" = "true" ]             && ht_capab="$ht_capab LDPC"
    [ "${TXSTBC:-true}" = "true" ]     && ht_capab="$ht_capab TX-STBC"
    [ "${RXSTBC:-true}" = "true" ]     && ht_capab="$ht_capab RX-STBC1"
    [ "${RXSTBC}" = "1" -o "${RXSTBC}" = "12" -o \
      "${RXSTBC}" = "123" ] 	       && ht_capab="$ht_capab RX-STBC$RXSTBC"
    [ "${DSSSCCK40:-true}" = "true" ]  && ht_capab="$ht_capab DSSS_CCK-40"
    [ "${Other}" != "" ]               && ht_capab="$ht_capab $Other"

    DeviceName=$(wifi_device_name "$DeviceName" "$id")
    
    case "$ccc_protocol" in
	2.0)
	    ccc_run_wifi enable 0 "$DeviceName" 0 "" "" "$(ccc_bool $Enabled)"
	    case "$SelectChannel" in
		auto2.4g | auto5g)
	    	    ccc_run_wifi channel "$DeviceName" "$SelectChannel" "$Bandwidth"
		    ;;
		*)
	    	    ccc_run_wifi channel "$DeviceName" "$Channel" "$Bandwidth"
		    ;;
	    esac
	    ccc_run_wifi txpower "$DeviceName" "$TxPower" "$RegulatoryDomain"
	    
	    set_wifiopt "$DeviceName" ht_capab "$ht_capab" wifi-device 
	    if [ -n "$HWMode" ]; then
		set_wifiopt "$DeviceName" hwmode "$HWMode" wifi-device
	    fi
	    set_wifiopt "$DeviceName" basic_rate "$BasicRates" wifi-device
	    set_wifiopt "$DeviceName" beacon_int "$BeaconInterval" wifi-device

	    if [ "$(ccc_bool $Presence)" = "1" ]
	    then
		local monname="${DeviceName}_mon"
		ccc_run_uci set_option wireless $monname mode monitor wifi-iface
		ccc_run_uci set_option wireless $monname ifname mon-$DeviceName wifi-iface
		ccc_run_uci set_option wireless $monname device $DeviceName wifi-iface
		SeenWLAN="$SeenWLAN.$monname."
	    fi

#	    ccc_run_uci set_option thirdparty global_radio rogue_detection "$(ccc_bool "$RogueAPDetection")" rogue_detection
#	    ccc_run_uci set_option thirdparty global_radio rogue_detection_interval "$RogueAPDectionFrequency" rogue_detection
	    ;;
	*)
	    ;;
    esac
}

ccc_lanDevice() {
    local net=$1 
    local b=$2 
    local uamType=$3
    
    local Enabled="$(ccc_v ${b}Enabled)"
    local IPAddress=$(ccc_v ${b}IPAddress)
    local Netmask=$(ccc_v ${b}Netmask)
    local STP=$(ccc_v ${b}STP)
    local MTU=$(ccc_v ${b}MTU)
    local MacAddress=$(ccc_v ${b}MacAddress)
    local DNS=$(ccc_v ${b}DNS | tr ',' ' ')
    local SwitchPorts=$(ccc_v ${b}SwitchPorts | tr ',' ' ')

    local AcceptTcpDestPorts="$(ccc_v ${b}FirewallAcceptTcpDestPorts)"
    local AcceptUdpDestPorts="$(ccc_v ${b}FirewallAcceptUdpDestPorts)"
    local InternetOnly="$(ccc_v ${b}FirewallInternetOnly)"
    local ACLMacListType="$(ccc_v ${b}ACLMacListType)"
    local ACLMacAddressList="$(ccc_v ${b}ACLMacAddressList)"
    
    echo "$IPAddress router $RouterHostname" >> /tmp/hosts
    
    if [ "$Extender" != "true" ]; then
        if [ "$uamType" = "CoovaChilli" ]; then
	    ccc_UAM $net "$IPAddress" "$Netmask" $DNS
	    IPAddress="0.0.0.0"
        fi
    fi

    if [ "$Extender" = "true" ] && [ "${net}" != "$trunklannum" ]; then
        if [ "$TunnelType" != "zone" ]; then
	    set_netopt lan${net} "type" "bridge" interface
        fi
	set_netopt lan${net} proto none interface
	set_netopt lan${net} auto 1 interface
	set_netopt lan${net} ipaddr "" interface
	set_netopt lan${net} netmask "" interface
	set_netopt lan${net} stp 0
    else
	ccc_run_router lan_ip $net static "$IPAddress" "$Netmask" "" $DNS
    fi

    ccc_run_router network_opt lan$net "$MTU" "$(ccc_bool $STP)"
    ccc_run_router network_mac lan$net "$MacAddress"

    if [ "$(ccc_v ${b}DNSProxyEnabled)" = "true" ]; then
	fw_rule DROP rule_dnsproxy_lan${net} lan${net} udp 53 "*"
	fw_rule DROP rule_dnsdrop_lan${net} lan${net} udp 53 
    else
	AcceptUdpDestPorts="$AcceptUdpDestPorts 53"
        ccc_run_uci delete_section firewall rule_dnsproxy_lan${net} rule
        ccc_run_uci delete_section firewall rule_dnsdrop_lan${net} rule
    fi

    baseG="CCC_DeviceXGateway"
    baseX="CCC_DeviceExtender"

    TunnelType=""

    if [ "$XGateway" = "true" ]; then
	TunnelType="$(ccc_v ${baseG}TunnelType)"
    elif [ "$Extender" = "true" ]; then
	TunnelType="$(ccc_v ${baseX}TunnelType)"
    fi
    
    if [ "$XGateway" = "true" ] && [ "$trunklannum" != "${net}" ] && [ -z "$TunnelType" ]; then
	ccc_run_router configure_vlan $net "$SwitchPorts" "$trunklannum" "" "" ""
    elif [ "$XGateway" = "true" ] && [ "$trunklannum" = "${net}" ] && [ -z "$TunnelType" ]; then
	ccc_run_router configure_vlan $net "$SwitchPorts" "" "" 4094 ""
    elif [ "$XGateway" = "true" -o "$Extender" = "true" ] && [ -n "$TunnelType" ] && [ "$trunklannum" != "${net}" ]; then
        if [ "$TunnelType" != "zone" ]; then
	    ccc_run_router configure_vlan $net "$SwitchPorts" "" "tunnel" "" ""
        elif [ "$Extender" = "true" ]; then
            if [ "$Enabled" = "true" ]; then
	        ccc_run_router configure_vlan $net "$SwitchPorts" "" "" "" "1"
	        ccc_run_uci set_option system xgtype xglannet $lan${net} xgtype
            fi
        elif [ "$XGateway" = "true" ]; then
	    ccc_run_router configure_vlan $net "$SwitchPorts" "" "" "" ""
        fi
    else
	ccc_run_router configure_vlan $net "$SwitchPorts" "" "" "" ""
    fi	

    if [ "$XGateway" = "true" -o "$Extender" = "true" ] && [ "${net}" = "${trunklannum}" ]; then

	set_netopt lan${net} trunk 1 interface

    	ccc_run_uci set_option firewall zone_lan${net} internetonly "false" zone
    	ccc_run_uci set_option firewall zone_lan${net} nointernet "0" zone
        baseD=""

	if [ "$XGateway" = "true" ]; then
  	    baseD="${baseG}"
        elif [ "$Extender" = "true" ]; then
            baseD="${baseX}Daisychain"
        fi

	for Tunnel in $(ccc_nsort ${baseD}Tunnel_n); do
	    if [ "$TunnelType" = "openvpn" ]; then
	        ServerPort="$(ccc_v ${baseD}Tunnel${Tunnel}ServerPort)"
	        ClientPort="$(ccc_v ${baseD}Tunnel${Tunnel}ClientPort)"
		if [ -n "${ServerPort:-$ClientPort}" ]; then
		    AcceptUdpDestPorts="$AcceptUdpDestPorts ${ServerPort:-$ClientPort}"
		fi          		    
	    elif [ "$TunnelType" = "openvpntcp" ]; then
	        ServerPort="$(ccc_v ${baseD}Tunnel${Tunnel}ServerPort)"
		ClientPort="$(ccc_v ${baseD}Tunnel${Tunnel}ClientPort)"
		if [ -n "${ServerPort:-$ClientPort}" ]; then
		    AcceptTcpDestPorts="$AcceptTcpDestPorts ${ServerPort:-$ClientPort}"
	        fi          		    
           fi
	done

        ccc_run_router fw_zone $net \
	    "$AcceptTcpDestPorts" "$AcceptUdpDestPorts"
    else
    	ccc_run_uci set_option firewall zone_lan${net} internetonly "$InternetOnly" zone
    	ccc_run_uci set_option firewall zone_lan${net} nointernet "0" zone

	tmp="$(mktemp -d)"
	ccc_run_uci set_option firewall zone${net}_maclist maclist_type "$ACLMacListType" zone_maclist

	if [ "$ACLMacListType" != "none" ]; then
	    if [ -n "$seenMacListFiles" ]; then
		seenMacListFiles="$seenMacListFiles
pcs.zone${net}.maclist"
	    else
		seenMacListFiles="pcs.zone${net}.maclist"
            fi
	    echo "$ACLMacAddressList" >$tmp/pcs.zone${net}.maclist
	else
	    rm -f $tmp/pcs.zone${net}.maclist
	fi

	if [ -s $tmp/pcs.zone${net}.maclist ]; then
	    if ! [ -s /etc/pcs.zone${net}.maclist ] || ! cmp -s $tmp/pcs.zone${net}.maclist /etc/pcs.zone${net}.maclist; then
  		/bin/cp $tmp/pcs.zone${net}.maclist /etc/pcs.zone${net}.maclist 
		ccc_run_uci set_ischanged firewall maclist
            fi
	else
	    if [ -s /etc/pcs.zone${net}.maclist ]; then
		rm -f /etc/pcs.zone${net}.maclist
		touch /etc/pcs.zone${net}.maclist
   		ccc_run_uci set_ischanged firewall maclist
	    fi
	fi
	rm -rf $tmp

        ccc_run_router fw_zone $net \
	    "$AcceptTcpDestPorts" "$AcceptUdpDestPorts"
    fi
}

ccc_logging() {
   local b=$1

   local SyslogRemoteEnabled=$(ccc_bool $(ccc_v ${b}SyslogRemoteEnabled))
   local SyslogRemoteServerIP=$(ccc_v ${b}SyslogRemoteServerIP)
   local SyslogRemoteProtocol=$(ccc_v ${b}SyslogRemoteProtocol)
   local SyslogRemoteFiltered=$(ccc_bool $(ccc_v ${b}SyslogRemoteFiltered))
   local CCClientLogEnabled=$(ccc_v ${b}CCClientLogEnabled)

   if [ "$SyslogRemoteEnabled" = "1" ] && [ "$SyslogRemoteProtocol" = "udp" ] && [ "$SyslogRemoteFiltered" = "0" ]; then
   	ccc_run_uci set_option system system log_ip "$SyslogRemoteServerIP" system
   else
   	ccc_run_uci set_option system system log_ip "" system
   fi

    if [ "$CCClientLogEnabled" = "true" ]; then
	ccc_run_uci set_option thirdparty ccclient_debug script_debug 1 ccclient_debug
	ccc_run_uci set_option thirdparty ccclient_debug ccclient_debug 5 ccclient_debug
    elif [ "$CCClientLogEnabled" = "false" ]; then
	ccc_run_uci set_option thirdparty ccclient_debug script_debug 0 ccclient_debug
	ccc_run_uci set_option thirdparty ccclient_debug ccclient_debug 0 ccclient_debug
    fi
}

ccc_wanDevice() {
    local b=$1

    local Type=$(ccc_v ${b}Type)
    local Protocol=$(ccc_v ${b}Protocol)
    local IPAddress=$(ccc_v ${b}IPAddress)
    local Netmask=$(ccc_v ${b}Netmask)
    local Gateway=$(ccc_v ${b}Gateway)
    local MacAddress=$(ccc_v ${b}MacAddress)
    local STP=$(ccc_v ${b}STP)
    local MTU=$(ccc_v ${b}MTU)
    local DNS=$(ccc_v ${b}DNS | tr ',' ' ')
    local SetClientId=$(ccc_v ${b}SetClientId)

    local Hostname=$(ccc_v ${b}Hostname | sed 's/[^a-zA-Z0-9_-]/_/g')
    local Domain=$(ccc_v ${b}Domain) # not used

    echo "____ WAN ____ -${Protocol}-${IPAddress}-${Netmask}-${Gateway}-${DNS}- <-- "

    if [ "$Extender" = "true" ] && [ "$Protocol" = "pppoe" ]; then
	Protocol=dhcp
    fi

    local WifiWan=""

    case "$Type" in
	wifi)
	    WifiWan=wan
	    local Radio=$(ccc_v ${b}WifiRadio)
	    local SSID=$(ccc_v ${b}WifiSSID)
	    local PSK=$(ccc_v ${b}WifiPSK)

	    ccc_run_wifi ssid "" "${Radio##radio}" "1" "wan" "$SSID"
	    ccc_run_wifi security "" "${Radio##radio}" "1" "wan" \
		"enc=wpa-psk" "psk=$PSK" "wanOnly=0"
	    ccc_run_wifi enable "" "$DeviceName" "1" "wan" "" "1"

	    SeenWLAN="$SeenWLAN.ath${WifiWan}_${Radio##radio}_1."
	    ;;
	*)
	    ;;
    esac

    if [ -z "$WifiWan" ]; then
	wannet=wan
    else
	wannet="$WifiWan"
    fi

    set_netopt $wannet wan_type "$Type" interface

    if [ "$TunnelType" = "zone" ] && [ "$Extender" = "true" ]; then
	set_netopt $wannet type bridge interface
    else
	# Clear out old br-wan from previous firmware
	set_netopt $wannet type "" interface
    fi

    case "${Protocol}" in
	static)
	    ccc_run_router wan_ip static "$WifiWan" "$IPAddress" "$Netmask" "$Gateway" $DNS
	    ccc_run_router network_mac wan "$MacAddress"
	    ;;
	dhcp)
	    ccc_run_router wan_ip dhcp "$WifiWan" "$Gateway" $DNS
	    ccc_run_router network_mac wan "$MacAddress"
	    if [ "$SetClientId" = "true" ]
	    then
	        ccc_run_uci set_option network $wannet clientid "01:${MacAddress:-$(getmac_raw eth0)}"
	    else
	        ccc_run_uci set_option network $wannet clientid ""
	    fi
	    ;;
	pppoe)
	    local Username=$(ccc_v ${b}PPPUsername)
	    local Password=$(ccc_v ${b}PPPPassword)
	    local AccessConcentrator=$(ccc_v ${b}PPPoEAccessConcentrator)
	    local Service=$(ccc_v ${b}PPPoEService)

	    local ConnectStrategy=$(ccc_v ${b}PPPConnectStrategy)
	    local AfterNumLCPAttempts="$(ccc_v ${b}PPPRedialAfterNumLCPAttempts)"
	    local LCPAttemptWait="$(ccc_v ${b}PPPRedialNumLCPAttemptWait)"

	    ccc_run_router wan_ip pppoe "" "$Username" "$Password" "$AccessConcentrator" "$Service" "$AfterNumLCPAttempts" "$LCPAttemptWait"

	    ccc_run_router network_mac $wannet "$MacAddress"
	    ;;
	*)
	    echo "No changes for WAN"
	    ;;
    esac

    ccc_run_uci set_option network $wannet hostname "$Hostname"
    ccc_run_uci set_option system @system[0] hostname "$Hostname"

    RouterHostname="$Hostname"

    ccc_run_router network_opt $wannet "$MTU" "$STP" 

    if [ "$Extender" != "true" ]; then
    	ccc_run_router fw_wan "$wannet" \
		"$(ccc_bool "$(ccc_v ${b}FirewallEnableMasquerading)" 1)" \
		"$(ccc_notbool "$(ccc_v ${b}FirewallFilterMulticastInbound)" 1)" \
		"$(ccc_notbool "$(ccc_v ${b}FirewallFilterICMPInbound)" 1)" \
		"$(ccc_notbool "$(ccc_v ${b}FirewallFilterIDENTInbound)" 1)" \
		"$(ccc_v ${b}FirewallAcceptTcpDestPorts)" \
		"$(ccc_v ${b}FirewallAcceptUdpDestPorts)" \
		"$(ccc_v ${b}FirewallDefaultPolicy)" 

    	local PortForward=$(ccc_v ${b}PortForward)
    	local PortForwardRange=$(ccc_v ${b}PortForwardRange)
    	local DMZHost=$(ccc_v ${b}DMZHost)
    	local DMZHostReflect=$(ccc_v ${b}DMZHostReflect)

    	ccc_run_router fw_wan_redirect "${DMZHost}" "${DMZHostReflect}" "${PortForward}" "${PortForwardRange}"

    	for Nat11 in $(ccc_nsort ${b}1to1NAT_n); do
		local nb=${b}1to1NAT${Nat11}
		local publicIP=$(ccc_v ${nb}PublicIP)
		local privateIP=$(ccc_v ${nb}PrivateIP)
		local n11PortForwardRange=$(ccc_v ${nb}PortForwardRange)
		local fullAccess=$(ccc_v ${nb}FullAccess)

      	        ccc_run_router fw_wan_redirect_11 "${publicIP}" "${privateIP}" "${n11PortForwardRange}" "$fullAccess"
    	done
    else
        baseX="CCC_DeviceExtender"

	TunnelType="$(ccc_v ${baseX}TunnelType)"
	TunnelClientPort="$(ccc_v ${baseX}TunnelClientPort)"
	TunnelServerPort="$(ccc_v ${baseX}TunnelServerPort)"
	

	FirewallAcceptTcpDestPorts="$(ccc_v ${b}FirewallAcceptTcpDestPorts)"
	FirewallAcceptUdpDestPorts="$(ccc_v ${b}FirewallAcceptUdpDestPorts)"

	if [ "$TunnelType" = "openvpn" ]; then
	    if [ -n "$TunnelClientPort" ]; then
		FirewallAcceptUdpDestPorts="$FirewallAcceptUdpAcceptDestPorts $TunnelClientPort 68"
	    fi
	elif [ "$TunnelType" = "openvpntcp" ]; then
	    FirewallAcceptTcpDestPorts="$FirewallAcceptTcpAcceptDestPorts $TunnelClientPort"
        fi
	
        if [ "$TunnelType" != "zone" ] || [ "$Extender" != "true" ]; then
    	    ccc_run_router fw_wan "$wannet" \
	        1 0 0 0 \
	        "$FirewallAcceptTcpDestPorts" \
	        "$FirewallAcceptUdpDestPorts" \
	        "REJECT"
         else
             ccc_run_router fw_zone_extender "$wannet"
         fi
    fi
}

ccc_expand_radius() {
    local rid="$1"
    local ri="CCC_DeviceRADIUSINFO"
    local has_server=0
    local i=1
    if [ "$rid" = "" ]
    then
	echo -n "auth1name= auth1port= auth1secret= acct1name= acct1port= acct1secret= "
	echo -n "auth2name= auth2port= auth2secret= acct2name= acct2port= acct2secret= "
    else
	for id in $rid
	do
	    local b="$ri$id"
	    local server="$(ccc_v ${b}RADIUS_AUTH_SERVER)"
	    [ "$server" != "" ] && has_server=1
	    echo -n \
		"auth${i}name=\"$server\" "\
	        "auth${i}port=\"$(ccc_v ${b}RADIUS_AUTH_PORT)\" "\
	        "auth${i}secret=\"$(ccc_v ${b}RADIUS_AUTH_SECRET)\" "\
	        "acct${i}name=\"$(ccc_v ${b}RADIUS_ACCOUNTING_SERVER)\" "\
	        "acct${i}port=\"$(ccc_v ${b}RADIUS_ACCOUNTING_PORT)\" "\
	        "acct${i}secret=\"$(ccc_v ${b}RADIUS_ACCOUNTING_SECRET)\" "
	    i=$((i + 1))
	done
	if [ "$has_server" = "1" ]
	then
	    echo -n \
		"identifier=\"$(ccc_v ${ri}RADIUS_AP_IDENTIFIER)\" "\
  	        "acctupdate=\"$(ccc_v ${ri}RADIUS_ACCOUNTING_UPDATE_INTERVAL)\" "\
	        "retry=\"$(ccc_v ${ri}RADIUS_RETRY_INTERVAL)\" "
	else
	    echo -n identifier= acctupdate= retry=
	fi 
    fi
}

ccc_wlanConfig() {
    local lannum=$1
    local device=$2
    local wlannum=$3
    local base=$4

    local SSID=$(ccc_v ${base}SSID)
    local HideSSID=$(ccc_v ${base}HideSSID)
    local WPAAuthenticationMode=$(ccc_v ${base}WPAAuthenticationMode)
    local PreSharedKey1KeyPassphrase=$(ccc_v ${base}PreSharedKey1KeyPassphrase)
    local InternetOnly=$(ccc_v ${base}InternetOnly)
    local RADIUSINFO=$(ccc_v ${base}RADIUSINFO | tr ',' ' ')

    InternetOnly=${InternetOnly:-$(ccc_v CCC_DeviceLANDevice${lannum}FirewallInternetOnly)}

    ccc_run_wifi ssid "$lannum" "$device" "$wlannum" "" "$SSID"

    ccc_run_wifi hidessid "$lannum" "$device" "$wlannum" "" \
	$(ccc_bool ${HideSSID:-false})

    ccc_run_wifi security "$lannum" "$device" "$wlannum" "" \
	"enc=${WPAAuthenticationMode:-open}" "psk=$PreSharedKey1KeyPassphrase" \
	"wanOnly=$(ccc_bool ${InternetOnly:-false})"

    ccc_run_wifi radius "$lannum" "$device" "$wlannum" "" \
	$(ccc_expand_radius "$RADIUSINFO")
}

ccc_trafficControl() {
    local RateUp=$CCC_DeviceTrafficControlRateUp
    local RateDown=$CCC_DeviceTrafficControlRateDown
    
    if [ "$RateUp" != "" ] && [ "$RateDown" != "" ]
    then
	ccc_run ccc_tc.sh load_modules
	
	local Burst=${CCC_DeviceTrafficControlBurst:-5000}
	local Priority=${CCC_DeviceTrafficControlPriority:-1}

	local zone sta cls
	
	ccc_run ccc_tc.sh start \
	    "${RateDown}$ccc_rate" "${RateUp}$ccc_rate" \
	    "$Burst" "$Priority"
	
	for zone in $(ccc_nsort CCC_DeviceTrafficControl_n)
	do
	    local zbase="CCC_DeviceTrafficControl${zone}"
	    local Interfaces=$(ccc_v ${zbase}Interfaces)
	    local RateUp=$(ccc_v ${zbase}RateUp)
	    local RateDown=$(ccc_v ${zbase}RateDown)
	    local CeilUp=$(ccc_v ${zbase}CeilUp)
	    local CeilDown=$(ccc_v ${zbase}CeilDown)
	    local Burst=$(ccc_v ${zbase}Burst)
	    local Priority=$(ccc_v ${zbase}Priority)

	    tc_saveInterfaceLimit "$Interfaces" $zbase
	    
	    ccc_run ccc_tc.sh setup_iface $zone "$Interfaces" \
		"${RateDown}$ccc_rate" "${RateUp}$ccc_rate" \
		"${CeilDown:-$RateDown}$ccc_rate" "${CeilUp:-$RateUp}$ccc_rate" \
		"${Burst}" "$Priority"

	    local last_cls
	    for cls in $(ccc_nsort ${zbase}_n)
	    do
		local cbase="${zbase}${cls}"
		local Name=$(ccc_v ${cbase}Name)
		local RateUp=$(ccc_v ${cbase}RateUp)
		local RateDown=$(ccc_v ${cbase}RateDown)
		local CeilUp=$(ccc_v ${cbase}CeilUp)
		local CeilDown=$(ccc_v ${cbase}CeilDown)
		local Burst=$(ccc_v ${cbase}Burst)
		local Priority=$(ccc_v ${cbase}Priority)
		local TcpPorts=$(ccc_v ${cbase}TcpPorts)
		local UdpPorts=$(ccc_v ${cbase}UdpPorts)
		local Protocols=$(ccc_v ${cbase}Protocols)
		local Interfaces=$(ccc_v ${cbase}Interfaces)

		tc_saveInterfaceLimit "$Interfaces" $cbase
		
		ccc_run ccc_tc.sh cls_create $zone $cls "$Name" \
		    "${RateDown}$ccc_rate" "${RateUp}$ccc_rate" \
		    "${CeilDown:-$RateDown}$ccc_rate" "${CeilUp:-$RateUp}$ccc_rate" \
		    "${Burst}" "$Priority"
		
		[ "$TcpPorts" = "" ] || ccc_run ccc_tc.sh cls_add $zone $cls tcp "$TcpPorts"
		[ "$UdpPorts" = "" ] || ccc_run ccc_tc.sh cls_add $zone $cls udp "$UdpPorts"

		[ "$Protocols" = "" ]  || ccc_run ccc_tc.sh cls_add $zone $cls layer7 "$Protocols"
		[ "$Interfaces" = "" ] || ccc_run ccc_tc.sh cls_add $zone $cls ifaces "$Interfaces"

		last_cls=$cls
	    done
	    [ "$last_cls" != "" ] && ccc_run ccc_tc.sh cls_end $zone $last_cls 
	done

	tc_updateStations

    else
	ccc_run ccc_tc.sh stop
    fi
}

ccc_UAM() 
{
    local uam=$1
    local ip=$2
    local mask=$3
    local dns1=$4
    local dns2=$5
    local base="CCC_DeviceLANDevice${uam}UAMCoovaChilli"

    eval "$(ipcalc.sh $ip $mask)"

    ccc_run_uci set_option chilli uam$uam "network" "lan$uam" chilli
    ccc_run_uci set_option chilli uam$uam "tundev" "tun$uam" chilli
    ccc_run_uci set_option chilli uam$uam "uamlisten" "$IP" chilli
    ccc_run_uci set_option chilli uam$uam "net" "$NETWORK/$NETMASK" chilli

    if [ "$(ccc_v CCC_DeviceLANDevice${uam}DNSProxyDNS)" != "" ]
    then
	ccc_run_uci set_option chilli uam$uam "uamui" "/tmp/cloud/ccc_redir.sh" chilli
	ccc_run_uci set_option chilli uam$uam "forcedns1port" "53053" chilli
    else
	ccc_run_uci set_option chilli uam$uam "uamui" "" chilli
	ccc_run_uci set_option chilli uam$uam "forcedns1port" "0" chilli
    fi

    for n in $(ccc_lsort ${base}_n)
    do
	if [ "$(ccc_v ${base}${n}_n)" = "Enabled" ]
	then
	    if [ "$(ccc_v ${base}${n}Enabled)" = "true" ]
	    then
		ccc_run_uci set_option chilli uam$uam "$n" "1"
	    fi
	else
	    ccc_run_uci set_option chilli uam$uam "$n" "$(ccc_v ${base}${n})"
	fi
    done
}

ccc_localUserPassword() 
{
    local LocalUserPassword=$(ccc_v CCC_DeviceSecurityLocalUserPassword)
    if [ "$LocalUserPassword" != "" ]
    then
	local user=$(echo "$LocalUserPassword"|cut -f1 -d:)
	local pass=${LocalUserPassword#$user:}
	ccc_run_quiet ccc_platform.sh localuserpassword "$user" "$pass"
    fi
}

ccc_shellUserPassword() 
{
    local ShellUserPassword=$(ccc_v CCC_DeviceSecurityShellUserPassword)
    if [ "$ShellUserPassword" != "" ]
    then
	local user=$(echo "$ShellUserPassword"|cut -f1 -d:)
	local pass=${ShellUserPassword#$user:}
	ccc_run_quiet ccc_platform.sh shelluserpassword "$user" "$pass"
    fi
}

ccc_station() {
    local b=$1
    local n

    local tmp=/tmp/.$$
    rm -rf $tmp; mkdir -p $tmp
    
    for n in $(ccc_nsort ${b}_n)
    do
	local base="${b}${n}"
	local MacAddress=$(ccc_v ${base}MacAddress | sed 's/[ :-]//g')

	[ -z "$MacAddress" ] && continue
	
	echo "Station $MacAddress"

	if [ "$(ccc_v ${base}InternetOnlyEnabled)" = "true" ]
	then
	    echo "$MacAddress" >> $tmp/internetonly
	fi
	
	if [ "$(ccc_v ${base}RestrictInternetEnabled)" = "true" ]
	then
	    echo "$MacAddress" >> $tmp/nointernet
	fi

	if  [ "$(ccc_v ${base}InternetOnlyEnabled)" = "true" ] && [ "$(ccc_v ${base}RestrictInternetEnabled)" = "true" ]; then
	    echo "${MacAddress:0:2}:${MacAddress:2:2}:${MacAddress:4:2}:${MacAddress:6:2}:${MacAddress:8:2}:${MacAddress:10:2}" >>$tmp/connkill
        fi

        if [ "$(ccc_v ${base}ConnectionKillEnabled)" = "true" ]; then
	    echo "${MacAddress:0:2}:${MacAddress:2:2}:${MacAddress:4:2}:${MacAddress:6:2}:${MacAddress:8:2}:${MacAddress:10:2}" >>$tmp/connkill
        fi

	tc_saveStationLimit "$MacAddress" $base
    done
    
    ccc_run_uci set_option firewall defaults internetonly \
	"$(cat $tmp/internetonly 2>/dev/null | sort | tr '\n' ' ')" defaults
    
    ccc_run_uci set_option firewall defaults nointernet \
	"$(cat $tmp/nointernet 2>/dev/null | sort | tr '\n' ' ')" defaults
    

    local connkillmacs

    if [ -s $tmp/connkill ]; then
       KillMACs="$(cat $tmp/connkill 2>/dev/null | sort | tr '\n' '|'|sed -e 's/\(.*\)|$/\1/')"
    fi

    rm -rf $tmp
}

ccc_kill_connections() {

    local tp_script_debug="$(uci_get "thirdparty" "ccclient_debug" "script_debug")"

    if [ -n "$tp_script_debug" ] && [ "$tp_script_debug" -gt 0 ]; then
	echo "Killing connections for MACs: ($KillMACs)"
    fi

    if [ -n "$KillMACs" ]; then
        local noaccessips="$($CLOUD_RUN/ccc-cmd stations|grep -E "mac=($KillMACs)"|awk -F = '{ print $4 ; }'|awk '{ print $1 ; }'|tr '\n' ' '|sed -e 's/\(.*\) $/\1/')"
        if [ -n "$tp_script_debug" ] && [ "$tp_script_debug" -gt 0 ]; then
	    echo "For connection-kill MACs found IPs: '$noaccessips'"
        fi
        do_connkill() {
           if [ -n "$tp_script_debug" ] && [ "$tp_script_debug" -gt 0 ]; then
	       echo "Doing conntrack -D $@"
           fi
           conntrack -D "$@" 
        }

        local station
        for station in $noaccessips; do
            local ip_type
	    for ip_type in '--orig-src' '--orig-dst' '--reply-src' '--reply-dst'; do
	       do_connkill conntrack "$ip_type" "$station"
            done
        done 
    fi
}

###############################################################################
# main

echo "--- Protocol $ccc_protocol ---"

#batchfile=/tmp/.batch.$$
#exec 3>$batchfile

#  Unconfigured (by protocol) WLAN and LAN settings are deleted
#  controlled by these these lists.
SeenDHCP=
SeenLAN=
SeenVLAN=
SeenWLAN=
SeenRule=
EnableUPNP=
SeenUAM=
SeenOpenVPN=
SeenDMZ=
SeenNAT11=

ccc_localUserPassword
ccc_shellUserPassword

case "$ccc_protocol" in
    2.0)
	if [ "$CCC_DeviceRadioConfig_n" != "" ] && [ -f /etc/dnsmasq.conf ]
	then
	        # With VMC communication (not in SETUP), remove the DNS
	        # spoofing used only during SETUP
		rm -f /etc/dnsmasq.conf
		/etc/init.d/dnsmasq restart
	fi

	local firstconfig="$(uci get thirdparty.global.setupmode)"
	ccc_run_uci set_option thirdparty global setupmode 0 global 
        if [ "$firstconfig" = "1" ]; then
	    ccc_run_uci set_ischanged require_reboot require_reboot
        fi

  	local RegulatoryDomainType=$(ccc_v CCC_DeviceRadioConfigRegulatoryDomainType)
    	local RegulatoryDomain=$(ccc_v CCC_DeviceRadioConfigRegulatoryDomain)

	ccc_run_wifi regdomain "$RegulatoryDomainType" "$RegulatoryDomain"

	for RadioConfig in $(ccc_nsort CCC_DeviceRadioConfig_n)
	do
	    ccc_radioConfig $RadioConfig CCC_DeviceRadioConfig${RadioConfig}
	done
	;;

    *)
	for LANDevice in 1 2
	do
	    ccc_radioConfig $LANDevice "CCC_DeviceLANDevice${LANDevice}WLANConfigurationRadioConfig"
	done
	;;
esac

echo "--- Device Configuration Type $ccc_configType ---"

case "$ccc_configType" in
    Router)
	seenMacListFiles=""
	trunklannum=""
	masterBlacklistEnable=0
	masterWhitelistEnable=0

        baseG="CCC_DeviceXGateway"
        baseX="CCC_DeviceExtender"
	XGateway="$(ccc_v ${baseG}Enabled)"
	Extender="$(ccc_v ${baseX}Enabled)" 
        TunnelType=""

	if [ "$XGateway" = "true" ]; then
	    echo "XGateway: Router is an XGateway"
        elif [ "$Extender" = "true" ]; then
	    echo "XGateway: Router is an Extender"
        else
	    echo "XGateway: Router is a standard router"
        fi

	# Reset TCTMP (in ccc_tc.sh) before processing stations and interfaces
	if [ "$Extender" != "true" ]; then
	    tc_resetTcTmp
        fi

	WANType="$(ccc_v CCC_DeviceWANDevice1Type)"
	WANVlanId="$(ccc_v CCC_DeviceWANDevice1VlanId)"

	ccc_run_uci start_list network wan ifname interface
        # Clean out wanif option no longer used (from previous firmware)
	set_netopt wan wanif "" interface

	if [ "$WANType" = "vlan" ] && [ -n "$WANVlanId" ]; then
	    ccc_run_router configure_switch "$WANVlanId"
        else
	    ccc_run_router configure_switch ""
        fi

	ccc_logging CCC_DeviceLogging

	echo "127.0.0.1 localhost" > /tmp/hosts

	# Set Serial number for UPnPd
	ccc_run_uci set_option upnpd config serial_number "$(cat $CLOUD_RUN/config.txt|grep SERIALNUM|cut -f2 -d=)"  upnpd 
	for LANDevice in $(ccc_lsort CCC_DeviceLANDevice_n); do
	    base1="CCC_DeviceLANDevice${LANDevice}"
	    ACLMacListType=$(ccc_v ${base1}ACLMacListType)
	    Trunk="$(ccc_v ${base1}Trunk)"
	
	    if [ "$Trunk" = "true" ]; then
		trunklannum="$LANDevice" 
	    else
	    	if [ "$ACLMacListType" = "blacklist" ]; then
			masterBlacklistEnable=1;
	    	elif [ "$ACLMacListType" = "whitelist" ]; then
			masterWhitelistEnable=1;
	    	fi	
            fi
        done

        if [ "$XGateway" = "true" ] && [ -n "$trunklannum" ]; then
	    echo "XGateway: Found Trunk on Lan${trunklannum}"
        elif [ "$Extender" = "true" ] && [ -n "$trunklannum" ]; then
	    echo "Extender Daisychain: Found Trunk on Lan${trunklannum}"
        fi

	numTunnels=0

        ccc_run_uci set_option firewall defaults drop_invalid 1 defaults
	
	tunmacbase="$(getmac_raw eth0)"
	local xgServerPorts

	if [ "$XGateway" = "true" ]; then
	    ccc_run_uci set_option system xgtype xgtype xgateway xgtype
	    TunnelType="$(ccc_v ${baseG}TunnelType)"
	    if [ -z "$TunnelType" ]; then
	        ccc_run_uci set_option system xgtype xgtuntype "vlan" xgtype
	    	echo "XGateway-Extender uses a wired vlan to join zones"
	    elif [ "$TunnelType" = "zone" ]; then
	        ccc_run_uci set_option system xgtype xgtuntype "zone" xgtype
	        echo "XGateway-Extender is a single zone extender"
            else
	        ccc_run_uci set_option system xgtype xgtuntype "${TunnelType}" xgtype
	    	echo "XGateway-Extender uses a ${TunnelType} tunnel to join zones"
	    fi

            local newmac
	    local oIFS="$IFS"
	    IFS=":"
	    set -- $tunmacbase
	    IFS="$oIFS"
            newmac="$(printf "%s:%s:%s:%02X:%s:%s\n" $1 $2 $3 \
	    $(( ( 0x$4 & 0xf0 ) | 15)) \
		    $5 $6)"

	    if [ "$TunnelType" = "openvpn" ] || [ "$TunnelType" = "openvpntcp" ]; then
		set_netopt tunnel type bridge interface
		set_netopt tunnel proto none interface
		set_netopt tunnel auto 1 interface
		set_netopt tunnel stp 0 interface		
		set_netopt tunnel macaddr "$newmac" interface
		ccc_run_router fw_tunnel ""
		ccc_run_router dhcp_tunnel ""
	    	SeenLAN="$SeenLAN.tunnel."
		SeenDHCP="$SeenDHCP.tunnel."
            fi

	    for Tunnel in $(ccc_nsort ${baseG}Tunnel_n); do
		ServerPort="$(ccc_v ${baseG}Tunnel${Tunnel}ServerPort)"
		ClientPort="$(ccc_v ${baseG}Tunnel${Tunnel}ClientPort)"
		ListenAddress="$(ccc_v ${baseG}Tunnel${Tunnel}ListenAddress)"
		ClientAddress="$(ccc_v ${baseG}Tunnel${Tunnel}ClientAddress)"

		numTunnels=$(($numTunnels + 1))		

		append xgServerPorts "${Tunnel}.${ServerPort}"

		if [ -z "$ServerPort" ]; then
		    ServerPort=$ClientPort
 		elif [ -z "$ClientPort" ]; then
		    ClientPort=$ServerPort
                fi
		oIFS="$IFS"
		IFS=":"
		set -- $tunmacbase
		IFS="$oIFS"
         	newmac="$(printf "%s:%s:%s:%02X:%s:%s\n" $1 $2 $3 \
		    $(( ( 0x$4 & 0xf0 ) | $((16 - $Tunnel)))) \
			    $5 $6)"

		if [ "$TunnelType" = "openvpn" ]; then
		    ccc_run_router setup_openvpn "$numTunnels" "$ServerPort" "$ClientPort" "${ListenAddress:-0.0.0.0}" "$ClientAddress" "udp" "1" "$newmac"
		elif [ "$TunnelType" = "openvpntcp" ]; then
		    ccc_run_router setup_openvpn "$numTunnels" "$ServerPort" "$ClientPort" "${ListenAddress:-0.0.0.0}" "$ClientAddress" "tcp" "1" "$newmac"
		fi
            done
	    if [ "$TunnelType" = "openvpn" ] || [ "$TunnelType" = "openvpntcp" ] && [ $numTunnels -gt 0 ]; then
		local tapnum
		ccc_run_uci start_list network tunnel ifname interface
  
		for tapnum in $(seq 1 $numTunnels); do
		    ccc_run_uci set_list_item network tunnel ifname tap$((50 + $tapnum)) interface
		done
		if ! /etc/init.d/openvpn enabled; then
		    /etc/init.d/openvpn enable
		    ccc_run_uci set_ischanged openvpn openvpn		    
		fi
	    else
		if /etc/init.d/openvpn enabled; then
		    ccc_run_uci set_ischanged openvpn openvpn		    
		    /etc/init.d/openvpn stop
		    /etc/init.d/openvpn disable
                fi
	    fi
	    if ! /etc/init.d/chilli enabled; then
		/etc/init.d/chilli enable
		ccc_run_uci set_ischanged chilli chilli		
            fi
	    if ! /etc/init.d/dnsmasq enabled; then
		/etc/init.d/dnsmasq enable
		ccc_run_uci set_ischanged dhcp dhcp
	    fi
        elif [ "$Extender" = "true" ]; then
	    ccc_run_uci set_option system xgtype xgtype extender xgtype
	    TunnelType="$(ccc_v ${baseX}TunnelType)"
	    ServerPort="$(ccc_v ${baseX}TunnelServerPort)"
	    ClientPort="$(ccc_v ${baseX}TunnelClientPort)"
	    ListenAddress="$(ccc_v ${baseX}TunnelListenAddress)"
	    ServerAddress="$(ccc_v ${baseX}TunnelServerAddress)"

	    if [ -z "$TunnelType" ]; then
	        ccc_run_uci set_option system xgtype xgtuntype "vlan" xgtype
	    	echo "XGateway-Extender uses a wired vlan to join zones"
	    elif [ "$TunnelType" = "zone" ]; then
	        ccc_run_uci set_option system xgtype xgtuntype "zone" xgtype
	        echo "XGateway-Extender is a single zone extender"
            else
	        ccc_run_uci set_option system xgtype xgtuntype "${TunnelType}" xgtype
	    	echo "XGateway-Extender uses a ${TunnelType} tunnel to join zones"
	    fi

            if [ -z "$ServerPort" ]; then
	        ServerPort=$ClientPort
 	    elif [ -z "$ClientPort" ]; then
	        ClientPort=$ServerPort
            fi

	    append xgServerPorts "$ServerPort"

            oIFS="$IFS"
	    IFS=":"
	    set -- $tunmacbase
            IFS="$oIFS"
            local newmac="$(printf "%s:%s:%s:%02X:%s:%s\n" $1 $2 $3 \
		    $(( ( 0x$4 & 0xf0 ) | 15)) \
			    $5 $6)"
		
	    if [ "$TunnelType" = "openvpn" ] || [ "$TunnelType" = "openvpntcp" ]; then
		set_netopt tunnel type bridge interface
		set_netopt tunnel proto none interface
		set_netopt tunnel auto 1 interface
		set_netopt tunnel stp 0 interface
		set_netopt tunnel ifname tap51 interface
		set_netopt tunnel macaddr "$newmac" interface
		ccc_run_router fw_tunnel ""
		ccc_run_router dhcp_tunnel ""
	    	SeenLAN="$SeenLAN.tunnel."
		SeenDHCP="$SeenDHCP.tunnel."

		if ! /etc/init.d/openvpn enabled; then
		    /etc/init.d/openvpn enable
		    ccc_run_uci set_ischanged openvpn openvpn
		fi
	    else
		if /etc/init.d/openvpn enabled; then
		    /etc/init.d/openvpn stop
		    /etc/init.d/openvpn disable
		    ccc_run_uci set_ischanged openvpn openvpn
                fi
            fi

	    if [ "$TunnelType" = "openvpn" ]; then
		    ccc_run_router setup_openvpn 1  "$ClientPort" "$ServerPort" "${ListenAddress:-0.0.0.0}" "$ServerAddress" "udp" "0" "$newmac"
	    elif [ "$TunnelType" = "openvpntcp" ]; then
		    ccc_run_router setup_openvpn 1 "$ClientPort" "$ServerPort" "${ListenAddress:-0.0.0.0}" "$ServerAddress" "tcp" "0" "$newmac"
	    fi
	else
	    ccc_run_uci set_option system xgtype xgtype "" xgtype
	    if /etc/init.d/openvpn enabled; then
	    	/etc/init.d/openvpn stop
	    	/etc/init.d/openvpn disable
		ccc_run_uci set_ischanged openvpn openvpn
            fi
	fi

	if [ "$Extender" = "true" ]; then
	    if /etc/init.d/chilli enabled; then
	    	/etc/init.d/chilli stop
		/etc/init.d/chilli disable
		ccc_run_uci set_ischanged chilli chilli
            fi
            if /etc/init.d/dnsmasq enabled; then
	    	/etc/init.d/dnsmasq stop
		/etc/init.d/dnsmasq disable
		ccc_run_uci set_ischanged dhcp dhcp
            fi
	    #if /etc/init.d/uhttpd enabled; then
	    # 	/etc/init.d/uhttp stop
	    #	/etc/init.d/uhttpd disable
	    #	ccc_run_uci set_ischanged network network
            #fi
	    if /etc/init.d/miniupnpd enabled; then
	    	/etc/init.d/miniupnpd stop
		/etc/init.d/miniupnpd disable
		ccc_run_uci set_ischanged upnpd upnpd
            fi
        else
	    #if ! /etc/init.d/uhttpd enabled; then
	    #	/etc/init.d/uhttpd enable
	    #	/etc/init.d/uhttpd start
            #fi
	    if ! /etc/init.d/chilli enabled; then
		/etc/init.d/chilli enable
		ccc_run_uci set_ischanged chilli chilli		
            fi
	    if ! /etc/init.d/dnsmasq enabled; then
		/etc/init.d/dnsmasq enable
		ccc_run_uci set_ischanged dhcp dhcp
	    fi
        fi
	ccc_run_uci set_option system xgtype xgserverports "$xgServerPorts" xgtype

    	ccc_run_uci set_option firewall master_maclist blackist_enable "$masterBlacklistEnable" master_maclist
    	ccc_run_uci set_option firewall master_maclist whitelist_enable "$masterWhitelistEnable" master_maclist
	ccc_wanDevice CCC_DeviceWANDevice1

	for LANDevice in $(ccc_lsort CCC_DeviceLANDevice_n); do
	    base1="CCC_DeviceLANDevice${LANDevice}"
	    Enabled=$(ccc_v ${base1}Enabled)
	    Trunk=$(ccc_v ${base1}Trunk)
	 	
	    Enabled=${Enabled:-true}

	    if [ "$trunklannum" != "${LANDevice}" ] && [ "$Extender" != "true" ]; then
	    	UAMType=$(ccc_v ${base1}UAMType)
	    else
		UAMType=""
            fi

	    echo LANDevice $LANDevice / Enabled = $Enabled / UAM = ${UAMType:-None} / Trunk = ${Trunk:-false}
	    if [ "$Enabled" = "true" ]; then
		if [ "$trunklannum" != "${LANDevice}" ]; then
		    if [ "$Extender" = "true" ]; then
			DHCPServerType=ignore
                    else
	    		DHCPServerType=$(ccc_v ${base1}DHCPServerType)

			if [ "$UAMType" = "CoovaChilli" ]; then
	    	    		SeenUAM="$SeenUAM.uam$LANDevice."
		    		DHCPServerType=ignore
			fi
		    fi
                elif [ "$XGateway" = "true" ] || [ "$Extender" = "true" ]; then
	   		DHCPServerType=server
                fi

	    	ccc_run_router enable_lan $LANDevice $(ccc_bool $Enabled)

		ccc_lanDevice "$LANDevice" "${base1}" "$UAMType"

		if [ "$trunklannum" != "${LANDevice}" ] && [ "$(ccc_v ${base1}UPnPEnabled)" = "true" ] && [ "$Extender" != "true" ]; then
		    EnableUPNP="$EnableUPNP lan$LANDevice"
		fi
	    	SeenLAN="$SeenLAN.lan$LANDevice."

	    	case "$DHCPServerType" in
		    server)
		    	PoolStart=$(ccc_v ${base1}DHCPServerPoolStart)
		    	MaxClients=$(ccc_v ${base1}DHCPServerMaxClients)
		    	LeaseTime=$(ccc_v ${base1}DHCPServerLeaseTime)
			if [ "$trunklannum" != "${LANDevice}" ]; then
		    		DNS=$(ccc_v ${base1}DHCPServerDNS | tr ',' ' ')
		    		WINS=$(ccc_v ${base1}DHCPServerWINS | tr ',' ' ')
		    		ccc_run_router dhcp $LANDevice "$PoolStart" "$MaxClients" "$LeaseTime" "$DNS" "$WINS" ""
			else
		    	    ccc_run_router dhcp $LANDevice "$PoolStart" "$MaxClients" "$LeaseTime" "" "" 1
			fi			
			
		    	ccc_run_router dhcp_static $LANDevice $(ccc_v ${base1}DHCPServerStaticAssignments)
			
		    	SeenDHCP="$SeenDHCP.lan$LANDevice."
		    	;;
		    ignore)
			ccc_run_uci set_option dhcp lan${LANDevice} ignore "1" dhcp
		    	SeenDHCP="$SeenDHCP.lan$LANDevice."
			;;
		    *)
		    	echo "Nothing to do for $DHCPServerType"
		    	;;
	    	esac

	    	for WLANConfiguration in $(ccc_nsort "${base1}WLANConfiguration_n"); do
			base2="${base1}WLANConfiguration${WLANConfiguration}"
			Enabled=$(ccc_v ${base2}Enabled)
			DeviceName=$(ccc_v ${base2}DeviceName)

			if [ "$TunnelType" != "zone" ] || [ "$Extender" != "true" ]; then
			    echo LANDevice $LANDevice / WLANConfiguration $WLANConfiguration / Enabled = $Enabled
                        else
			    echo  WANBridge for Zone $LANDevice / WLANConfiguration $WLANConfiguration / Enabled = $Enabled
                        fi

			DeviceName=$(wifi_device_name "$DeviceName" "$WLANConfiguration")

			radio=0
			[ "$DeviceName" = "radio1" ] && radio=1	
			SeenWLAN="$SeenWLAN.ath${LANDevice}_${radio}_$WLANConfiguration."

			if [ "$TunnelType" != "zone" ] || [ "$Extender" != "true" ]; then
			    ccc_run_wifi enable "$LANDevice" "$DeviceName" \
			        "$WLANConfiguration" "" "" "$(ccc_bool $Enabled)"
                        else
			    ccc_run_wifi enable "$LANDevice" "$DeviceName" \
			        "$WLANConfiguration" "" "wan" "$(ccc_bool $Enabled)"
                        fi

			[ "$Enabled" = "true" ] && \
			    ccc_wlanConfig "$LANDevice" "$DeviceName" "$WLANConfiguration" "${base2}"
		done
	    fi	
	done

	cmp -s /tmp/hosts /etc/hosts || cp /tmp/hosts /etc/hosts
	rm -f /tmp/hosts

	ccc_run_router set_upnp "$EnableUPNP"

        unset KillMACs
	if [ "$Extender" != "true" ]; then
		ccc_station CCC_DeviceStation
        fi

	# Delete (in reverse order because of indexes) unseen (in configuration) 
	ccc_run_uci delete_unseen wireless wifi-iface "$SeenWLAN"
	ccc_run_uci delete_unseen network interface ".wan..loopback.$SeenLAN" 
	ccc_run_uci delete_unseen dhcp dhcp ".wan.$SeenDHCP" 
	ccc_run_uci delete_unseen firewall zone ".wan.$SeenLAN" zone_
	ccc_run_uci delete_unseen firewall forwarding ".wan.$SeenLAN" fw_
	ccc_run_uci delete_unseen network switch ".lanswitch."
	ccc_run_uci delete_unseen network switch_vlan "$SeenVLAN"
	ccc_run_uci delete_unseen chilli chilli "$SeenUAM"
	ccc_run_uci delete_unseen openvpn openvpn "$SeenOpenVPN"

	ccc_run_uci delete_unseen dhcp domain 

    	ccc_run_uci delete_unseen firewall rule "$SeenFWRule" "" ""

	ccc_run_uci delete_unseen firewall defaults "" "" "@"
	ccc_run_uci delete_unseen firewall include ".include." 

	ccc_run_uci delete_unseen firewall redirect "$SeenDMZ" "" redirect_wan_
	ccc_run_uci delete_unseen firewall redirect "$SeenDMZ" "" zzzz_redirect_wan_dmz
	ccc_run_uci delete_unseen firewall redirect "$SeenNat11" "" redirect_nat11_
	ccc_run_uci delete_unseen firewall redirect "$SeenNat11" "" zzzm_nat11_dmz_

	if [ "$trunklannum" != "${LANDevice}" ]; then
	    tmp="$(mktemp -d)"
	    cd /etc && find pcs.zone?.maclist -type f 2>/dev/null >$tmp/pcsmaclistfiles
	    echo "$seenMacListFiles" >$tmp/seenmaclist
	    cat $tmp/pcsmaclistfiles $tmp/seenmaclist | sort | uniq -d >$tmp/bothmac	
	    cat $tmp/bothmac $tmp/pcsmaclistfiles | sort | uniq -u >$tmp/rmmac
	    if [ -s "$tmp/rmmac" ]; then
	   	ccc_run_uci set_ischanged firewall maclist
		cd /etc && rm -f $(cat $tmp/rmmac)
            fi	
	    rm -rf $tmp
        fi
	;;


    *)
	for LANDevice in 1 2
	do
	    base1="CCC_DeviceLANDevice${LANDevice}WLANConfiguration"
	    
	    for WLANConfiguration in $(ccc_nsort "${base1}_n")
	    do
		base2="${base1}${WLANConfiguration}"
		Enabled=$(ccc_v ${base2}Enabled)
		SSID=$(ccc_v ${base2}SSID)

		echo LANDevice $LANDevice / WLANConfiguration $WLANConfiguration Enabled=$Enabled SSID=$SSID
	    done
	done
	;;
esac

case "$ccc_configType" in
    Router)
	echo "--- Commit and Apply Changes ---"
	ccc_run_uci commit all
	ccc_run_uci apply_changes | logger -t dispatch-apply-"${SERIALNUM:-missing-serialnum}"
 
        # Kill connections if necessary *after* new firewall rules applied
        ccc_kill_connections 2>&1 | logger -t dispatch-connkill-"${SERIALNUM:-missing-serialnum}"
	
	# Is this the best place for this?
	if [ "$Extender" != "true" ]; then
		ccc_trafficControl
        fi
	;;
    *)
	;;
esac

if [ -e .config ]
then
    cmp -s .config /etc/ccconfig || \
	cp .config /etc/ccconfig
fi


#exec 3>&-
#uci batch < $batchfile
#end_sec=$(date +%s)
#echo $((end_sec - $start_sec)) >> /tmp/dispatch.time
