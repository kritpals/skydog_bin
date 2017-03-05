#!/bin/sh
#
# ccc_router.sh encapsulates platform-specific operations needed
# by the Cloud Command Client. This script must be stored in the
# CloudCommand.tar.gz at $CLOUD_ROOT (see rc.cloud).
#
# Modify as needed to implement platform-specific support for
# the various functions.
#
# The tree below describes operation of and optional and required
# parameters for each function offered by ccc_router.sh. Parameters
# are described with angle or square brackets to indicate <required>
# or [optional] status.
#
# ccc_router.sh
#   +--enable_lan
#   |  <num><enabled>
#   +--lan_ip
#   |  <num><proto><ipaddress><netmask><gateway><dns1><dns2>
#   +--network_opt
#   |  <net><mtu><stp>
#   +--network_mac
#   |  <net><macaddr>
#   +--dhcp
#   |  <num><start><limit><leasetime><dns-list><wins-list>
#   +--dhcp_static
#   |  <num><mac>:<ip>[:<hostname>][,<mac>:<ip>[:<hostname>]]
#   +--configure_vlan
#   |  <num> "<port>[ <port>]..."
#   |  ports are a single quoted string (e.g. a single parameter with spaces)
#   +--wan_ip
#   |  <proto=static><ipaddress><netmask><gateway><dns1><dns2>
#   | or <proto=dhcp>[<gateway><dns1><dns2>]
#   | or <proto=pppoe><username><password><ac><service_name>
#   +--fw_zone
#   |  <num>
#   +--fw_wan
#   |  <masq><multicast><icmp><ident><tcp-ports><udp-ports>
#   +--fw_wan_redirect
#   |  <dmzhost><port-forward-list>
#   +--set_upnp
#   |  <lan1 lan2 lan3, etc>
#   +--setup_openvpn 
#   |  <server-port> <client-port> <listen-address> <client-address>

. /lib/ar71xx.sh

# internal: set_netopt <config> <option> <value> <section_type> <default_value> <state_dir>
set_netopt() {
    ccc_run_uci set_option network "$@"
}

# enable_vlan <num><enabled>
# where num is the lan number (LANDevice.X) and Enabled is 0 for disabled 
# and 1 for enabled.
router_enable_lan() {
    local lannum="${2}"
    local enabled="${3}"

    set_netopt lan${lannum} auto ${enabled} interface 1
}

# set_upnp <lan1 lan2 lan3, etc>
# Configurations involving all the configured LANs
router_set_upnp() {
    ccc_run_uci set_option upnpd config internal_iface "$2"
    ccc_run_uci set_option upnpd config enable_upnp "1"
    ccc_run_uci set_option upnpd config enable_natpmp "1"
    local iface
    if [ -n "$2" ]; then
	/etc/init.d/miniupnpd enable
    	for iface in $2; do
	    	[ -z "$iface" ] && continue
		fw_rule ACCEPT "rule_upnp_ssdp_from_${iface}" $iface udp 1900
		fw_rule ACCEPT "rule_upnp_http_from_${iface}" $iface tcp 5000
		fw_rule ACCEPT "rule_upnp_natpmp_from_${iface}" $iface udp 5351
		# Enable multicast registrations (for UPnP)
		local rule="rule_igmp_from_${iface}"
		ccc_run_uci set_option firewall $rule src "$iface" rule
		ccc_run_uci set_option firewall $rule proto igmp rule
		ccc_run_uci set_option firewall $rule dest_ip 224.0.0.1 rule
		ccc_run_uci set_option firewall $rule target ACCEPT rule
		SeenFWRule="$SeenFWRule.${rule}."
    	done
    else
	/etc/init.d/miniupnpd stop && /etc/init.d/miniupnpd disable
    fi
}

# lan_ip <num><proto><ipaddress><netmask>[<gateway><dns1><dns2>]
# Set lan IP configuration - default is static with ipaddress netmask and
# no gateway or dns
router_lan_ip() {
    local lannum="$2"
    local proto="$3"
    local ipaddr="$4"
    local netmask="$5"
    local gateway="$6"
    local dns1="$7"
    local dns2="$8"

    set_netopt lan${lannum} "type" "bridge" interface 
    set_netopt lan${lannum} proto ${proto} interface 
    
    if [ "$proto" = "static" ]; then
	set_netopt lan${lannum} ipaddr "${ipaddr}" interface
	set_netopt lan${lannum} netmask "${netmask:-255.255.255.0}" interface
    else
	set_netopt lan${lannum} ipaddr "" interface
	set_netopt lan${lannum} netmask "" interface
    fi

    set_netopt lan${lannum} gateway "${gateway}" interface

    if [ -n "$dns" ] || [ -n "$dns2" ]; then
	set_netopt lan${lannum} dns "$dns1 $dns2" interface
    else
	set_netopt lan${lannum} dns "" interface	
    fi
}

# network_opt <net><mtu><stp>
router_network_opt() {
    local net="$2"
    local mtu="$3"
    local stp="$4"

     if [ -n "$mtu" ]; then
         if [ "$mtu" = "default" ]; then
            set_netopt $net mtu "" interface
         else
            set_netopt $net mtu "$mtu" interface
         fi
    fi
      
    set_netopt $net stp "$stp" interface
}

router_network_mac() {
    local net="$2"
    local mac="$3"

    if [ "$mac" != "" ]
    then
	mac=$(echo "$mac"|sed 's/[:-]//g'|tr 'a-z' 'A-Z')
	mac="${mac:0:2}:${mac:2:2}:${mac:4:2}:${mac:6:2}:${mac:8:2}:${mac:10:2}"
    fi

    set_netopt $net macaddr "$mac" interface
}

fw_remove() {
    local rule="$1"
    ccc_run_uci delete_section firewall $rule 
}

fw_rule() {
    local target="$1"
    local rule="$2"
    local src="$3"
    local proto="$4"
    local type_port="$5"
    local dest="$6"

    ccc_run_uci set_option firewall $rule src "$src" rule
    ccc_run_uci set_option firewall $rule dest "$dest" rule
    ccc_run_uci set_option firewall $rule proto "$proto" rule
    case "$proto" in
	icmp)
	    ccc_run_uci set_option firewall $rule icmp_type "$type_port" rule
	    ;;
	*)
	    ccc_run_uci set_option firewall $rule dest_port "$type_port" rule
	    ;;
    esac
    ccc_run_uci set_option firewall $rule target $target rule
    ccc_run_uci set_option firewall $rule family ipv4 rule

    SeenFWRule="$SeenFWRule.${rule}."
}

router_fw_allow_torouter() {
    local zone="$2"
    local tcp_ports="$3"
    local udp_ports="$4"
    local list="$5"
    local port

    if [ -n "$tcp_ports" ]; then
	for port in $(echo "$tcp_ports" | tr ',' ' '); do
	    list="$list tcp:$(echo "$port"|tr -d ' ')"
	done
    fi
    
    if [ -n "$udp_ports" ]; then
	for port in $(echo "$udp_ports" | tr ',' ' '); do
	    list="$list udp:$(echo "$port"|tr -d ' ')"
	done
    fi
    
    local prefix=rule_${zone}_
    for desc in $list; do
	local proto=$(echo "$desc"|tr -d ' '|cut -f1 -d:)
	local port=$(echo "$desc"|tr -d ' '|cut -f2- -d:)
	local portname="_$(echo "$port" | tr '[:\-]' '_')"
	
	if [ -z "$proto" ]; then
            continue
        fi

	if [ "$proto" != "icmp" -a -z "$port" ]; then
	    return 0
	elif [ "$proto" = "icmp" ]; then
	    if [ "$port" = "icmp" ]; then
	        port=""
	    fi		
	fi
	local n="${prefix}${proto}${portname}"

	fw_rule ACCEPT $n $zone $proto $port
    done
}

router_fw_zone() {
    local lannum="$2"
    local tcp_ports="$3"
    local udp_ports="$4"

    ccc_run_uci set_option firewall zone_lan${lannum} name lan${lannum} zone
    ccc_run_uci set_option firewall zone_lan${lannum} network lan${lannum} zone
    ccc_run_uci set_option firewall zone_lan${lannum} input REJECT zone
    ccc_run_uci set_option firewall zone_lan${lannum} output ACCEPT zone
    ccc_run_uci set_option firewall zone_lan${lannum} forward REJECT zone
    ccc_run_uci set_option firewall zone_lan${lannum} log 0 zone
    ccc_run_uci set_option firewall zone_lan${lannum} conntrack 1 zone
    
    ccc_run_uci set_option firewall fw_lan${lannum} src lan${lannum} forwarding
    ccc_run_uci set_option firewall fw_lan${lannum} dest wan forwarding

    local list=""

    # DHCP
    list="$list udp:67:68"    

    # Local GUI & Redirect
    list="$list tcp:80 tcp:8080"

    # Ping (request)
    list="$list icmp:echo-request"

    router_fw_allow_torouter fw_allow_torouter lan${lannum} "$tcp_ports" "$udp_ports" "$list"
}

router_fw_zone_extender() {
   local wannets="$2"
   local default="${9:-REJECT}"

    ccc_run_uci set_option firewall defaults syn_flood '1' defaults
    ccc_run_uci set_option firewall defaults input 'ACCEPT' defaults
    ccc_run_uci set_option firewall defaults output 'ACCEPT' defaults
    ccc_run_uci set_option firewall defaults forward "$default" defaults
    ccc_run_uci set_option firewall defaults drop_invalid 1 defaults

    ccc_run_uci set_option firewall zone_wan name wan zone
    ccc_run_uci set_option firewall zone_wan network $wannets zone
    ccc_run_uci set_option firewall zone_wan input ACCEPT zone
    ccc_run_uci set_option firewall zone_wan output ACCEPT zone
    ccc_run_uci set_option firewall zone_wan forward ACCEPT zone
    ccc_run_uci set_option firewall zone_wan masq 0 zone
    ccc_run_uci set_option firewall zone_wan mtu_fix 0 zone
    ccc_run_uci set_option firewall zone_wan log 0 zone

}

router_fw_wan() {
    local wannets="$2"
    local masq="$3"
    local multicast="$4"
    local icmp="$5"
    local ident="$6"
    local tcp_ports="$7"
    local udp_ports="$8"
    local default="${9:-DROP}"
    
    ccc_run_uci set_option firewall defaults syn_flood '1' defaults
    ccc_run_uci set_option firewall defaults input 'ACCEPT' defaults
    ccc_run_uci set_option firewall defaults output 'ACCEPT' defaults
    ccc_run_uci set_option firewall defaults forward "$default" defaults
    ccc_run_uci set_option firewall defaults drop_invalid 1 defaults
    
    ccc_run_uci set_option firewall zone_wan name wan zone
    ccc_run_uci set_option firewall zone_wan network $wannets zone
    ccc_run_uci set_option firewall zone_wan input "$default" zone
    ccc_run_uci set_option firewall zone_wan output ACCEPT zone
    ccc_run_uci set_option firewall zone_wan forward "$default" zone
    ccc_run_uci set_option firewall zone_wan masq ${masq:-1} zone
    ccc_run_uci set_option firewall zone_wan mtu_fix 1 zone
    ccc_run_uci set_option firewall zone_wan log 0 zone

    # ccc_run_uci set_option firewall include path "/etc/firewall.user" include

    local port

    local list=""
    
    if [ "$ident" = "1" ]
    then
	list="$list tcp:113"
    fi
    
    # FilterICMP = false means allow *all* ICMP to the router
    if [ "$icmp" = "1" ]
    then
	list="$list icmp"
    fi
    
    router_fw_allow_torouter fw_allow_torouter wan "$tcp_ports" "$udp_ports" "$list"
}

router_fw_wan_redirect() {
    local dmzhost="$2"
    local dmzhostreflect="$3"
    local port_forward="$4"
    local port_forward_range="$5"
    local pf
    local dmz_ip
    local dmz_zone

    if [ -n "$port_forward" ]; then
	pf="$port_forward"
    elif [ -n "$port_forward_range" ]; then
	pf="$port_forward_range"
    fi

    if [ -n "$dmzhost" ]; then
	dmz_ip="$dmzhost"
	dmz_zone=""
    else
	dmz_ip="$(echo "$dmzhostreflect" | cut -f1 -d:)"
	dmz_zone="$(echo "$dmzhostreflect" | cut -f2 -d:)"
	if [ "$dmz_zone" = "$dmz_ip" ]; then
		dmz_zone=""
	fi
	if [ -n "$dmz_zone" ]; then
		dmz_zone="lan${dmz_zone}"
	fi
    fi

    if [ -n "$pf" ]; then
	for desc in $(echo "$pf"|tr ',' ' '); do
	    local proto=$(echo "$desc"|cut -f1 -d:)
	    local port_value=$(echo "$desc"|cut -f2 -d:)
	    local to_ip=$(echo "$desc"|cut -f3 -d:)
	    local to_port=$(echo "$desc"|cut -f4 -d:)
	    local to_zone=$(echo "$desc"|cut -f5 -d:)

	    local in_range_start=$(echo "$port_value"|cut -f1 -d-)
	    local in_range_end=$(echo "$port_value"|cut -f2 -d-)
	    local to_range_end
	    local inportt
	    local destport

  	    if [ "$in_range_start" = "$in_range_end" ]; then
		inport="$in_range_start"
		destport="$to_port"		
	    else
		to_range_end="$(($to_port + $(($in_range_end - $in_range_start))))"
		inport="${in_range_start}:${in_range_end}"
		destport="${to_port}-${to_range_end}"
	    fi

	    if [ -n "$to_zone" ]; then
		to_zone=lan"${to_zone}"
	    fi

	    port=$in_range_start
	    
	    if [ "$proto" != "" -a "$port" != "" -a "$to_ip" != "" ]; then
		local n=redirect_wan_$proto$port
		
		ccc_run_uci set_option firewall $n src wan redirect
		ccc_run_uci set_option firewall $n src_dport "$inport" redirect
		ccc_run_uci set_option firewall $n proto "$proto" redirect
		ccc_run_uci set_option firewall $n dest_ip "$to_ip" redirect
		ccc_run_uci set_option firewall $n dest_port "$destport" redirect
		ccc_run_uci set_option firewall $n dest "$to_zone" redirect

		SeenDMZ="$SeenDMZ.$n."
	    fi
	done
    fi
    if [ -n "$dmz_ip" ]; then
	local n=zzzz_redirect_wan_dmz
	# If dmzhost other redirect or rule changed (and therefore potentially added after
	# dmzhost rule), move the dmzhost rule below it so it occurs last in the firewall
	# setting
	if [ "$(uci_get firewall $n)" != "redirect" ] || \
	    [ "$(uci_get firewall $n src)" != "wan" ] || \
	    [ "$(uci_get firewall $n proto)" != "all" ] || \
	    [ "$(uci_get firewall $n dest)" != "$dmz_zone" ] || \
	    [ "$(uci_get firewall $n dest_ip)" != "$dmz_ip" ] || \
	    [ "$(ccc_run_uci is_ischanged firewall redirect)" = "1" ] || \
            [ "$(ccc_run_uci is_ischanged firewall rule)" = "1" ]; then 
	    
		# remove so when set below it's added last
	    ccc_run_uci delete_section firewall $n redirect
	fi
	
	ccc_run_uci set_option firewall $n src wan redirect
	ccc_run_uci set_option firewall $n proto all redirect
	ccc_run_uci set_option firewall $n dest_ip "$dmz_ip" redirect
	ccc_run_uci set_option firewall $n dest "$dmz_zone" redirect
	SeenDMZ="$SeenDMZ.$n."
    fi
}

router_fw_wan_redirect_11() {
    local publicIP="$2"
    local privateIP="$3"
    local port_forward_range="$4"
    local full_access="$5"
    local private_ip
    local private_zone

    private_ip="$(echo "$privateIP" | cut -f1 -d:)"
    private_zone="$(echo "$privateIP" | cut -f2 -d:)"

    if [ -z "$private_ip" ] || [ -z "$publicIP" ] || [ -z "$private_zone" ]; then
	return
    fi

    n=redirect_nat11_snat_"$(echo "$private_ip" | tr '.' '_')"_to_"$(echo "$publicIP" | tr '.' '_')"
    ccc_run_uci set_option firewall $n src "lan${private_zone}" redirect
    ccc_run_uci set_option firewall $n proto all redirect
    ccc_run_uci set_option firewall $n src_ip "$private_ip" redirect
    ccc_run_uci set_option firewall $n src_dip "$publicIP" redirect
    ccc_run_uci set_option firewall $n dest "wan" redirect
    ccc_run_uci set_option firewall $n target "SNAT" redirect
    SeenNat11="$SeenNat11.$n."

    local pf="${port_forward_range}"

    if [ -n "$pf" ]; then
	for desc in $(echo "$pf"|tr ',' ' '); do
	    local proto=$(echo "$desc"|cut -f1 -d:)
	    local port_value=$(echo "$desc"|cut -f2 -d:)
	    local to_ip=$(echo "$desc"|cut -f3 -d:)
	    local to_port=$(echo "$desc"|cut -f4 -d:)
	    local to_zone=$(echo "$desc"|cut -f5 -d:)

	    local in_range_start=$(echo "$port_value"|cut -f1 -d-)
	    local in_range_end=$(echo "$port_value"|cut -f2 -d-)
	    local to_range_end
	    local inportt
	    local destport

  	    if [ "$in_range_start" = "$in_range_end" ]; then
		inport="$in_range_start"
		destport="$to_port"		
	    else
		to_range_end="$(($to_port + $(($in_range_end - $in_range_start))))"
		inport="${in_range_start}:${in_range_end}"
		destport="${to_port}-${to_range_end}"
	    fi

	    if [ -n "$to_zone" ]; then
		to_zone=lan"${to_zone}"
	    fi

	    port=$in_range_start
	    
	    if [ "$proto" != "" -a "$port" != "" -a "$to_ip" != "" ]; then
		local n=redirect_nat11_${proto}${port}_"$(echo "$publicIP" | tr '.-' '_')"
		
		ccc_run_uci set_option firewall $n src wan redirect
		ccc_run_uci set_option firewall $n src_dport "$inport" redirect
		ccc_run_uci set_option firewall $n proto "$proto" redirect
		ccc_run_uci set_option firewall $n src_dip "$publicIP" redirect
		ccc_run_uci set_option firewall $n dest_ip "$to_ip" redirect
		ccc_run_uci set_option firewall $n dest_port "$destport" redirect
		ccc_run_uci set_option firewall $n dest "$to_zone" redirect
    		SeenNat11="$SeenNat11.$n."
	    fi
	done
    fi

    if [ "$full_access" = "true" ]; then
	local n=zzzm_nat11_dmz_"$(echo "$publicIP" | tr '.-' '_')"    
	if [ "$(uci_get firewall $n)" != "redirect" ] || \
	    [ "$(uci_get firewall $n src)" != "wan" ] || \
	    [ "$(uci_get firewall $n proto)" != "all" ] || \
	    [ "$(uci_get firewall $n dest)" != "$private_zone" ] || \
	    [ "$(uci_get firewall $n dest_ip)" != "$destip" ] || \
	    [ "$(uci_get firewall $n src_dip)" != "$publicIP" ] || \
	    [ "$(ccc_run_uci is_ischanged firewall redirect)" = "1" ] || \
            [ "$(ccc_run_uci is_ischanged firewall rule)" = "1" ]; then 
	    
		# remove so when set below it's added last
	    ccc_run_uci delete_section firewall $n redirect
	fi
	
	ccc_run_uci set_option firewall $n src wan redirect
	ccc_run_uci set_option firewall $n proto all redirect
	ccc_run_uci set_option firewall $n dest_ip "$private_ip" redirect
	ccc_run_uci set_option firewall $n src_dip "$publicIP" redirect
	ccc_run_uci set_option firewall $n dest "lan${private_zone}" redirect
	SeenNat11="$SeenNat11.$n."
    fi
}

router_dhcp() {
    local lannum="$2"
    local start="$3"
    local limit="$4"
    local leasetime="$5"
    local dns_list="$6"
    local wins_list="$7"
    local no_wins="$8"
    local dhcp_options=""
    local host

    add_option() {
	local entry="$1"
	if [ -n "$dhcp_options" ]
	then
	    dhcp_options="$dhcp_options $entry"
	else
	    dhcp_options="$entry"
	fi
    }

    if [ -n "$dns_list" ]; then
	add_option "6,$(echo "$dns_list" | tr ' ' ',')"
    fi

    if [ -n "$wins_list" ]; then
	add_option "44,$(echo "$wins_list" | tr ' ' ',')"
    fi

    # If no external WINS servers specified be the primary WINS server on all networks
    # This enables NetBIOS over tCP which is necessary for windows browsing to work
    if [ -z "$wins_list" ] && [ "$no_wins" != "1" ]; then
	add_option "44,0.0.0.0"
    fi

    ccc_run_uci set_option dhcp lan${lannum} interface lan${lannum} dhcp
    ccc_run_uci set_option dhcp lan${lannum} start "${start}" dhcp
    ccc_run_uci set_option dhcp lan${lannum} limit "${limit}" dhcp
    ccc_run_uci set_option dhcp lan${lannum} leasetime "${leasetime}" dhcp
    ccc_run_uci set_option dhcp lan${lannum} dhcp_option "${dhcp_options}" dhcp
    ccc_run_uci set_option dhcp lan${lannum} ignore "0" dhcp
}

router_dhcp_static() {
    local lannum="$2"
    local data="$3"
    local seen
    
    if [ -n "$data" ]
    then
	for entry in $(echo "$data"|sed 's/,/ /g')
	do
	    local mac=$(echo "$entry"|cut -f1 -d:)
	    local ip=$(echo "$entry"|cut -f2 -d:)
	    local hostname=$(echo "$entry"|cut -f3 -d:)
	    
	    mac=$(echo "$mac"|sed 's/[:-]//g'|tr 'a-z' 'A-Z')
	    local name="${lannum}_$mac"

	    mac="${mac:0:2}:${mac:2:2}:${mac:4:2}:${mac:6:2}:${mac:8:2}:${mac:10:2}"

	    ccc_run_uci set_option dhcp $name mac "$mac" host
	    ccc_run_uci set_option dhcp $name ip "$ip" host
	    ccc_run_uci set_option dhcp $name name "$hostname" host

	    seen="$seen.$name."
	done
    fi

    ccc_run_uci delete_unseen dhcp host "$seen" "" ${lannum}_
}

# internal: set_switch_vlan <lannum> <device> <inerface> <vlan> <ports> <cpu_port>
# Configure switch as needed for setting up the wired portion of a lanX
set_switch_vlan() {
    local lannum="$1"
    local device="$2"
    local interface="$3"
    local vlan="$4"
    local ports="$5"
    local cpu_port="$6"
    local trunklannum="$7"
    local tunnellan="$8"
    local vlantrunkid="$9"
    shift 2>/dev/null || true
    local lanwanbridge="$9" 

    if [ -z "$ports" ]; then
	if [ -n "$trunklannum" ]; then
	    set_netopt lan${lannum} ifname br-lan${trunklannum}.${vlan} interface
	    if [ "$lanwanbridge" = "1" ]; then
	    	ccc_run_uci set_list_item network wan ifname br-lan${trunklannum}.${vlan} interface
	    fi
	elif [ -n "$tunnellan" ]; then
	    set_netopt lan${lannum} ifname br-${tunnellan}.${vlan} interface
	    if [ "$lanwanbridge" = "1" ]; then
	    	ccc_run_uci set_list_item network wan ifname br-${tunnellan}.${vlan} interface
	    fi
	else
	    ccc_run_uci delete_section network switch_lan${lannum}
	    set_netopt lan${lannum} ifname "" interface
        fi
    else
	if [ -n "$trunklannum" ]; then
	   ccc_run_uci start_list network lan${lannum} ifname interface
           ccc_run_uci set_list_item network lan${lannum} ifname ${interface}.${vlan} interface
           ccc_run_uci set_list_item network lan${lannum} ifname br-lan${trunklannum}.${vlan} interface
	   if [ "$lanwanbridge" = "1" ]; then
	       ccc_run_uci set_list_item network wan ifname ${interface}.${vlan} interface
	       ccc_run_uci set_list_item network wan ifname br-lan${trunklannum}.${vlan} interface
	   fi
	elif [ -n "$tunnellan" ]; then
	   ccc_run_uci start_list network lan${lannum} ifname interface
           ccc_run_uci set_list_item network lan${lannum} ifname ${interface}.${vlan} interface
           ccc_run_uci set_list_item network lan${lannum} ifname br-${tunnellan}.${vlan} interface
	   if [ "$lanwanbridge" = "1" ]; then
	       ccc_run_uci set_list_item network wan ifname ${interface}.${vlan} interface
	       ccc_run_uci set_list_item network wan ifname br-${tunnellan}.${vlan} interface
	   fi
        else
	    set_netopt lan${lannum} ifname ${interface}.${vlan} interface
	    if [ "$lanwanbridge" = "1" ]; then
               ccc_run_uci set_list_item network wan ifname ${interface}.${vlan} interface
            fi
        fi
	set_netopt switch_lan${lannum} device ${device} switch_vlan
	set_netopt switch_lan${lannum} vlan ${vlan} switch_vlan
	if [ "$cpu_port" != "0" ]; then
	    local realports
	    local port
	    for port in $ports; do
		if [ -z "$realports" ]; then
		    if [ -n "$vlantrunkid" ]; then
			realports="$((port - 1))t"
		    else
			realports="$((port - 1))"
		    fi
		else
		    if [ -n "$vlantrunkid" ]; then
			realports="$realports $((port - 1))t"
		    else		
			realports="$realports $((port - 1))"
		    fi
		fi
	    done
	    if [ -n "$vlantrunkid" ]; then
		set_netopt switch_lan${lannum} ports "$realports ${cpu_port}" switch_vlan
	    else
		set_netopt switch_lan${lannum} ports "$realports ${cpu_port}t" switch_vlan
	    fi
            SeenVLAN="$SeenVLAN.switch_lan${lannum}."
	else
	    if [ -n "$vlantrunkid" ]; then
		local realports
		local port
		for port in $ports; do
		    if [ -z "$realports" ]; then
			realports="${port}t"
		    else
			realports="${realports} ${port}t"
		    fi
		done
		set_netopt switch_lan${lannum} ports "0 $realports" switch_vlan
                SeenVLAN="$SeenVLAN.switch_lan${lannum}."
            else
		set_netopt switch_lan${lannum} ports "0t $ports" switch_vlan
                SeenVLAN="$SeenVLAN.switch_lan${lannum}."
	    fi
	fi
    fi
}

# CR3000 physical port mapping is not in increasing order.
# logical  physical      
#    1	  1
#    2	  4
#    3	  3
#    4	  2
convert_port_cr3000() {
    local ports="$1"
    local result

    for port in $ports;
    do
	if [ "$port" = "2" ]; then
	    port="4"
	elif [ "$port" = "4" ]; then
	    port="2"
	fi
	result="$result $port"
    done

    result=`echo $result | tr ' ' '\n' | sort`
    echo $result
}

router_configure_switch() {
    local wanvlanid="$2"

    local board=$(ar71xx_board_name)
    local device
    case "$board" in
	dir-825-b1 )
	    device=rtl8366s	    
	    ccc_run_uci set_list_item network wan ifname eth1${wanvlanid:+.$wanvlanid} interface
	    ;;
	db120 |\
	cr3000 )
	    ccc_run_uci set_list_item network wan ifname eth0${wanvlanid:+.$wanvlanid} interface
	    device=eth1
	    ;;
	cr5000 )
	    device=eth0
	    if [ -n "$wanvlanid" ]; then
		set_netopt switch_wan device eth0 switch_vlan
		set_netopt switch_wan vlan ${wanvlanid} switch_vlan
		set_netopt switch_wan ports "0 5t" switch_vlan
                ccc_run_uci set_list_item network wan ifname "eth0.${wanvlanid}" interface
                SeenVLAN="$SeenVLAN.switch_wan."
	    else
		set_netopt switch_wan device eth0 switch_vlan
		set_netopt switch_wan vlan 2 switch_vlan
		set_netopt switch_wan ports "0t 5" switch_vlan
		ccc_run_uci set_list_item network wan ifname "eth0.2" interface
                SeenVLAN="$SeenVLAN.switch_wan."
            fi
 	    ;;
    esac
    if [ "$device" != "" ]; then
	set_netopt lanswitch name ${device} switch 
	set_netopt lanswitch reset 1 switch 
	set_netopt lanswitch enable_vlan 1 switch 
	set_netopt lanswitch enable 1 switch 
    fi
}

# configure_vlan
#   <num> "<port>[ <port>]..."
# Add vlan to lan<num> and create switch config for vlan

router_configure_vlan() {
    local lannum="$2"
    local ports="$3"
    local trunklannum="$4"
    local tunnellan="$5"
    local vlantrunkid="$6"
    local lanwanbridge="$7"

    board=$(ar71xx_board_name)

    # For a lanX we use vlan X + 2.  Vlan 0 and 1 are reserved by various network
    # equipment and Vlan 2 we use for the Wan on Senao WBR2100

    case "$board" in
    dir-825-b1 )
	    local revports port
	    for port in $ports
	    do
		append revports "$((5 - $port))"
	    done
	    set_switch_vlan $lannum rtl8366s eth0 $((lannum + 2)) "$revports" 5 "$trunklannum" "$tunnellan" "$vlantrunkid" "$lanwanbridge"
	    ;;
    db120 )
	    set_switch_vlan $lannum eth1 eth1 $((lannum + 2)) "$ports" 0 "$trunklannum" "$tunnellan" "$vlantrunkid" "$lanwanbridge"
	    ;;
    cr5000 )
	    set_switch_vlan $lannum eth0 eth0 $((lannum + 2)) "$ports" 0 "$trunklannum" "$tunnellan" "$vlantrunkid" "$lanwanbridge"
 	    ;;
    cr3000 )
	    # CR3000 physical port mapping is not in increasing order.
	    ports=$(convert_port_cr3000 "$ports")
	    set_switch_vlan $lannum eth1 eth1 $((lannum + 2)) "$ports" 0 "$trunklannum" "$tunnellan" "$vlantrunkid" "$lanwanbridge"
 	    ;;
    esac
}

#  wan_ip
#   |  <proto=static><ipaddress><netmask>[<gateway><dns1><dns2>]
#   | or <proto=dhcp>[<gateway><dns1><dns2>]
#   | or <proto=pppoe><username><password>[<access_concentrator>,<service_name>]
router_wan_ip() {
    shift # function-name

    local proto="$1"
    local wifiwan="$2"
    shift 2 # proto & wifiwan

    local gateway
    wannet=wan

    if [ -n "$wifiwan" ]; then
	wannet="$wifiwan"
    fi
    set_netopt $wannet proto "${proto}" interface 

    case "$proto" in
	static)
	    local ipaddr="$1"
	    shift
	    local netmask="$1"
	    shift
	    gateway="$1"
	    shift
	    
    	    set_netopt $wannet ipaddr "${ipaddr}" interface
	    set_netopt $wannet netmask "${netmask}" interface
	    set_netopt $wannet username "" interface
	    set_netopt $wannet password "" interface
	    set_netopt $wannet ac "" interface
	    set_netopt $wannet service "" interface
	    ;;
	pppoe)
	    local username="$1"
	    shift
	    local password="$1"
	    shift
	    local concentrator="$1"
	    shift
	    local service="$1"
	    shift
            local attempts="$1"
            shift
	    local between="$1"
	    shift


	    if [ -z "$attempts" ]; then
	        attempts=10
            fi

	    if [ -z "$between" ]; then
 	        between=5
            fi
	    
	    set_netopt $wannet username "${username}" interface
	    set_netopt $wannet password "${password}" interface
	    set_netopt $wannet ac "${concentrator}" interface
	    set_netopt $wannet service "${service}" interface
            set_netopt $wannet keepalive "${attempts} ${between}"
    	    set_netopt $wannet ipaddr "" interface
	    set_netopt $wannet netmask "" interface
	    ;;
	dhcp)
	    gateway="$1"
	    shift
	    
	    set_netopt $wannet ipaddr "" interface
	    set_netopt $wannet netmask "" interface
	    set_netopt $wannet username "" interface
	    set_netopt $wannet password "" interface
	    set_netopt $wannet ac "" interface
	    set_netopt $wannet service "" interface
	    ;;
    esac

    set_netopt $wannet gateway "${gateway}" interface

    local dns_list="$1"
    shift
    while [ "$1" != "" ]
    do
	dns_list="$dns_list $1"
	shift
    done
    set_netopt $wannet dns "${dns_list}" interface
}

# setup_openvpn <local-port> <remote-port> <listen-address> <client-address>
router_setup_openvpn() {
    shift # function-name
    local tunnelnum="$1"
    local localport="$2"
    local remoteport="$3"
    local listenaddress="$4"
    local remoteaddress="$5"
    local proto="$6"
    local bind="$7"
    local newmac="$8"

    ccc_run_uci set_option openvpn tunnel${tunnelnum} lladdr "$newmac" openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} enabled 1 openvpn
    if [ -n "$remoteaddress" ] || [  "$bind" = "1" ]; then
        ccc_run_uci set_option openvpn tunnel${tunnelnum} remote "$remoteaddress" openvpn
    fi
    if [ -z "$localport" ]; then	
	ccc_run_uci set_option openvpn tunnel${tunnelnum} port "$remoteport" openvpn
	ccc_run_uci set_option openvpn tunnel${tunnelnum} lport "" openvpn
	ccc_run_uci set_option openvpn tunnel${tunnelnum} rport "" openvpn
    elif [ -z "$remoteport" ]; then
	ccc_run_uci set_option openvpn tunnel${tunnelnum} port "$localport" openvpn
	ccc_run_uci set_option openvpn tunnel${tunnelnum} lport "" openvpn
	ccc_run_uci set_option openvpn tunnel${tunnelnum} rport "" openvpn
    fi
    if [ -n "$bind" ]; then
	if [ "$bind" = "1" ]; then
	    ccc_run_uci set_option openvpn tunnel${tunnelnum} bind 1 openvpn
	    ccc_run_uci set_option openvpn tunnel${tunnelnum} nobind "" openvpn
            ccc_run_uci set_option openvpn tunnel${tunnelnum} local "${listenaddress}" openvpn
	    if [ -n "$localport" ] && [ -n "$remoteport" ]; then
                ccc_run_uci set_option openvpn tunnel${tunnelnum} lport "$localport" openvpn
            fi
        elif [ "$bind" = "0" ]; then
	    ccc_run_uci set_option openvpn tunnel${tunnelnum} nobind 1 openvpn
	    ccc_run_uci set_option openvpn tunnel${tunnelnum} bind "" openvpn
	    if [ -n "$localport" ] && [ -n "$remoteport" ]; then
                ccc_run_uci set_option openvpn tunnel${tunnelnum} rport "$remoteport" openvpn
            fi
        fi
    else
	if [ -n "$localport" ] && [ -n "$remoteport" ]; then
            ccc_run_uci set_option openvpn tunnel${tunnelnum} lport "$localport" openvpn
            ccc_run_uci set_option openvpn tunnel${tunnelnum} rport "$remoteport" openvpn
        fi
        ccc_run_uci set_option openvpn tunnel${tunnelnum} local "${listenaddress}" openvpn
    fi

    ccc_run_uci set_option openvpn tunnel${tunnelnum} proto $proto openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} float 1 openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} dev tap$((50 + $tunnelnum)) openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} keepalive "10 120" openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} comp_lzo 0 openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} persist_key 1 openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} persist_tun 1 openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} user nobody openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} group nogroup openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} status /tmp/openvpn-status-tunnel${tunnelnum}.log openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} verb 3 openvpn
    ccc_run_uci set_option openvpn tunnel${tunnelnum} mute 20 openvpn

    SeenOpenVPN="$SeenOpenVPN.tunnel${tunnelnum}."
}

router_fw_tunnel() {
    local tunnelnum="$2"
    ccc_run_uci set_option firewall zone_tunnel${tunnelnum} name tunnel${tunnelnum} zone
    ccc_run_uci set_option firewall zone_tunnel${tunnelnum} network tunnel${tunnelnum} zone
    ccc_run_uci set_option firewall zone_tunnel${tunnelnum} input REJECT zone
    ccc_run_uci set_option firewall zone_tunnel${tunnelnum} output REJECT zone
    ccc_run_uci set_option firewall zone_tunnel${tunnelnum} forward REJECT zone
    ccc_run_uci set_option firewall zone_tunnel${tunnelnum} log 0 zone
    ccc_run_uci set_option firewall zone_tunnel${tunnelnum} conntrack 1 zone    
}

router_dhcp_tunnel() {
    local tunnelnum="$2"
    ccc_run_uci set_option dhcp tunnel${tunnelnum} interface tunnel dhcp
    ccc_run_uci set_option dhcp tunnel${tunnelnum} ignore "1" dhcp
}

[ "$CCC_INCLUDE" = "1" ] && return

cd $(dirname $0)
. ./ccc_functions.sh

CLOUDDIR=`pwd`
DEBUG_FLAG='1'
FUNC="router_$1"
PARAMTYPE=$(type $FUNC)
if [ "$PARAMTYPE" = "$FUNC is a shell function" ]
then
    $FUNC "$@"
else
    echo "ccc_router.sh: command not recognized: $1"
fi
