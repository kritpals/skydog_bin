#!/bin/sh
#
# Set up firewall rules for guest and corporate users
#
# Copyright 2010-2011 PowerCloud Systems, All Rights Reserved 
#

cd $(dirname $0)
. ./ccc_functions.sh

VAP_PRIMARY=ath0
VAP_PRIMARY2=ath4
VAP_GUEST=ath1
VAP_GUEST2=ath5
EBTABLES=/usr/sbin/ebtables
IPTABLES=/usr/sbin/iptables

if [ "$CLOUD_TMP" = "" ]
then
   echo "$0: fatal: \$CLOUD_TMP is not set; cloudconf will probably not be found."
   exit -1
fi

if [ -f ${CLOUD_CONF_UCI_CONFIG_DIR}/cloudconf ]
then
	. $CLOUD_RUN/ccc_cloud_conf.src
	ccc_cloud_conf_eval
else
   echo "$0: fatal: $CLOUD_CONF_UCI_CONFIG_DIR/cloudconf wasn't found.."
   exit -1
fi

# also configure the corp "authorized users" firewall
eval useacl=\${AP_USEACL_0}
eval useacl_guest=\${AP_USEACL_1}

# flush exiting rules
$EBTABLES -t nat -F
$IPTABLES -t nat -F
$EBTABLES -t nat -X GUEST-IN
if [ "$useacl_guest" = "1" ]
then
   $EBTABLES -t nat -X GUEST-REDIRECT
fi
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -X CORP-IN
   $EBTABLES -t nat -X CORP-REDIRECT
fi

# create new chain and have it receive all guest traffic coming in from wlan
# by default drop all this traffic
$EBTABLES -t nat -N GUEST-IN
$EBTABLES -t nat -P GUEST-IN DROP
$EBTABLES -t nat -A PREROUTING -i $VAP_GUEST -j GUEST-IN
$EBTABLES -t nat -A PREROUTING -i $VAP_GUEST2 -j GUEST-IN

# create new chain and have it receive all corp traffic coming in from wlan
# by default drop all this traffic
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -N CORP-IN
   $EBTABLES -t nat -P CORP-IN DROP
   $EBTABLES -t nat -A PREROUTING -i $VAP_PRIMARY -j CORP-IN
   $EBTABLES -t nat -A PREROUTING -i $VAP_PRIMARY2 -j CORP-IN
fi

# create a new chain for guest web requests we want to capture
if [ "$useacl_guest" = "1" ]
then
   $EBTABLES -t nat -N GUEST-REDIRECT
   $EBTABLES -t nat -A GUEST-REDIRECT -j mark --mark-set 1 --mark-target CONTINUE
   $EBTABLES -t nat -A GUEST-REDIRECT -j redirect
fi

# create a new chain for corp web requests we want to capture
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -N CORP-REDIRECT
   $EBTABLES -t nat -A CORP-REDIRECT -j mark --mark-set 2 --mark-target CONTINUE
   $EBTABLES -t nat -A CORP-REDIRECT -j redirect
fi

# iptables rule to send captured web requests to the local HTTP redirect server
if [ "$useacl_guest" = "1" ]
then
   $IPTABLES -t nat -A PREROUTING -p tcp -m mark --mark 1 -j REDIRECT --to-ports 8080
fi
if [ "$useacl" = "1" ]
then
   $IPTABLES -t nat -A PREROUTING -p tcp -m mark --mark 2 -j REDIRECT --to-ports 8081
fi

# create a separate chain for guest authorizations, so they can be updated separately
if [ "$useacl_guest" = "1" ]
then
   $EBTABLES -t nat -N AUTHORIZE-GUESTS
   $EBTABLES -t nat -P AUTHORIZE-GUESTS RETURN
   $EBTABLES -t nat -F AUTHORIZE-GUESTS
fi

# create a separate chain for corp user authorizations, so they can be updated separately
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -N AUTHORIZE-CORP
   $EBTABLES -t nat -P AUTHORIZE-CORP RETURN
   $EBTABLES -t nat -F AUTHORIZE-CORP
fi

# create a separate chain for guest authorizations, so they can be updated separately
$EBTABLES -t nat -N LOCAL-NET-DMZ
$EBTABLES -t nat -P LOCAL-NET-DMZ DROP
$EBTABLES -t nat -F LOCAL-NET-DMZ

# allow HTTP to the management server
ip_port=`echo $ACS_URL | cut -d/ -f3`
server=`echo $ip_port | cut -d: -f1`
port=`echo $ip_port | cut -d: -f2`
if [ $server = $port ]
then
   port=80
fi

# use ping+sed to get ip number for server's name
ping_server_ip=`ping -c 1 $server | sed -n -e "s/.*(\([[:digit:]\.]*\)).*/\1/p"`
ping_ca_ip=`ping -c 1 ocsp.godaddy.com | sed -n -e "s/.*(\([[:digit:]\.]*\)).*/\1/p"`

if [ -z $ping_server_ip ]
then
    echo "firewall-guest: failure: server ($server) not found"
    echo 1 > /tmp/.svrnotfound
    [ -n "$FALLBACK_SERVER_IP" ] && server_ip="$FALLBACK_SERVER_IP" || server_ip=50.16.89.13
    [ -n "$FALLBACK_CA_IP" ] && ca_ip="$FALLBACK_CA_IP" || ca_ip=72.167.239.239
else
    server_ip="$ping_server_ip"
    ca_ip="$ping_ca_ip"
    $CLOUD_RUN/ccc_cloud_conf.sh set "FALLBACK_SERVER_IP" "$server_ip"
    $CLOUD_RUN/ccc_cloud_conf.sh set "FALLBACK_CA_IP" "$ca_ip"
fi

$EBTABLES -t nat -I GUEST-IN -p 0x800 --pkttype-type otherhost \
    --ip-dst $server_ip --ip-proto 6 --ip-dport 443 -j ACCEPT
$EBTABLES -t nat -I GUEST-IN -p 0x800 --pkttype-type otherhost \
    --ip-dst $server_ip --ip-proto 6 --ip-dport 80 -j ACCEPT
$EBTABLES -t nat -I GUEST-IN -p 0x800 --pkttype-type otherhost \
    --ip-dst $server_ip --ip-proto 6 --ip-dport $port -j ACCEPT
#allow OCSP traffic to our certificate authority (currently godaddy)
$EBTABLES -t nat -I GUEST-IN -p 0x800 --pkttype-type otherhost \
    --ip-dst $ca_ip --ip-proto 6 --ip-dport 80 -j ACCEPT

if [ "$useacl" = "1" ]
then
    $EBTABLES -t nat -I CORP-IN -p 0x800 --pkttype-type otherhost \
	--ip-dst $server_ip --ip-proto 6 --ip-dport 443 -j ACCEPT
    $EBTABLES -t nat -I CORP-IN -p 0x800 --pkttype-type otherhost \
	--ip-dst $server_ip --ip-proto 6 --ip-dport 80 -j ACCEPT
    $EBTABLES -t nat -I CORP-IN -p 0x800 --pkttype-type otherhost \
	--ip-dst $server_ip --ip-proto 6 --ip-dport $port -j ACCEPT
    # allow OCSP traffic to our certificate authority (currently godaddy)
    $EBTABLES -t nat -I CORP-IN -p 0x800 --pkttype-type otherhost \
	--ip-dst $ca_ip --ip-proto 6 --ip-dport 80 -j ACCEPT
fi

# allow DNS (often DNS is on a private address)
$EBTABLES -t nat -A GUEST-IN -p 0x800 --pkttype-type otherhost \
    --ip-proto 17 --ip-dport 53 -j ACCEPT
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -A CORP-IN -p 0x800 --pkttype-type otherhost \
       --ip-proto 17 --ip-dport 53 -j ACCEPT
fi

# drop guest traffic to private IP addresses
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 192.168.0.0/16 -j LOCAL-NET-DMZ  
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 10.0.0.0/8 -j LOCAL-NET-DMZ  
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 172.16.0.0/12 -j LOCAL-NET-DMZ  
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 169.254.0.0/16 -j DROP 
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 224.0.0.0/4 -j ACCEPT

# allow DHCP requests
$EBTABLES -t nat -A GUEST-IN -p 0x800 --pkttype-type broadcast \
    --ip-proto 17 --ip-sport 68 --ip-dport 67 -j ACCEPT 

$EBTABLES -t nat -A GUEST-IN -p 0x800 --pkttype-type broadcast \
    --ip-proto 17 --ip-dst 255.255.255.255/32 --ip-dport 67 -j ACCEPT 

if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -A CORP-IN -p 0x800 --pkttype-type broadcast \
       --ip-proto 17 --ip-sport 68 --ip-dport 67 -j ACCEPT 

   $EBTABLES -t nat -A CORP-IN -p 0x800 --pkttype-type broadcast \
       --ip-proto 17 --ip-dst 255.255.255.255/32 --ip-dport 67 -j ACCEPT 

   # allow EAP traffic on corp 
   $EBTABLES -t nat -A CORP-IN -p 0x888E -j ACCEPT 
fi

# drop traffic to the IP broadcast address, or to 0.0.0.0, or to loopback network.
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 255.255.255.255/32 -j DROP
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 0.0.0.0/32 -j DROP
$EBTABLES -t nat -A GUEST-IN -p 0x800 --ip-dst 127.0.0.0/8 -j DROP

# allow unicast IP traffic from authorized guests
# Note: it would be more secure to only allow this traffic to the default
# gateway's MAC address. This will require us to discover that and update it.
if [ "$useacl_guest" = "1" ]
then
   $EBTABLES -t nat -A GUEST-IN -p 0x800 --pkttype-type otherhost -j AUTHORIZE-GUESTS
else
   $EBTABLES -t nat -A GUEST-IN -p 0x800 --pkttype-type otherhost -j ACCEPT
fi
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -A CORP-IN -p 0x800 -j AUTHORIZE-CORP
fi

# allow ARP requests for IPv4 addresses
# Note: It would be more secure to only allow ARPing for the default gateway.
$EBTABLES -t nat -A GUEST-IN -p 0x806 --pkttype-type broadcast \
    --arp-op Request --arp-htype 1 --arp-ptype 0x800 -j ACCEPT 
# allow the arp reply from the guest client
$EBTABLES -t nat -A GUEST-IN -p 0x806 --arp-op Reply --arp-htype 1 --arp-ptype 0x800 -j ACCEPT 
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -A CORP-IN -p 0x806 --pkttype-type broadcast \
       --arp-op Request --arp-htype 1 --arp-ptype 0x800 -j ACCEPT 
   # allow the arp reply from the corp client
   $EBTABLES -t nat -A CORP-IN -p 0x806 --arp-op Reply --arp-htype 1 --arp-ptype 0x800 -j ACCEPT 
fi

# redirect all HTTP requests from unauthorized MACs to the local HTTP server
if [ "$useacl_guest" = "1" ]
then
   $EBTABLES -t nat -A GUEST-IN -p 0x800 --pkttype-type otherhost \
    --ip-proto 6 --ip-dport 80 -j GUEST-REDIRECT
fi
if [ "$useacl" = "1" ]
then
   $EBTABLES -t nat -A CORP-IN -p 0x800 --pkttype-type otherhost \
       --ip-proto 6 --ip-dport 80 -j CORP-REDIRECT
fi

# add new rule for outbound packets toward ath1
$EBTABLES -t nat -N GUEST-OUT
$EBTABLES -t nat -P GUEST-OUT ACCEPT
$EBTABLES -t nat -A POSTROUTING -o $VAP_GUEST -j GUEST-OUT
$EBTABLES -t nat -A POSTROUTING -o $VAP_GUEST2 -j GUEST-OUT

# to add exception to GUEST-OUT chain
$EBTABLES -t nat -N LOCAL-NET-DMZ-OUT
$EBTABLES -t nat -P LOCAL-NET-DMZ-OUT DROP 
$EBTABLES -t nat -F LOCAL-NET-DMZ-OUT

# add restriction on multicast (224.0.0.0/4) toward guest radio i/f
$EBTABLES -t nat -A GUEST-OUT -p 0x800 --ip-dst 224.0.0.0/4 -j LOCAL-NET-DMZ-OUT

# Per SSID rules (InternetOnly)
$EBTABLES -X WAN-ONLY-OUT 2>/dev/null
$EBTABLES -N WAN-ONLY-OUT 2>/dev/null
$EBTABLES -P WAN-ONLY-OUT DROP 
$EBTABLES -F WAN-ONLY-OUT
$EBTABLES -A WAN-ONLY-OUT -p 0x800 --pkttype-type otherhost \
    --ip-proto 17 --ip-dport 53 -j ACCEPT
$EBTABLES -A WAN-ONLY-OUT -p 0x800 --pkttype-type broadcast \
    --ip-proto 17 --ip-sport 68 --ip-dport 67 -j ACCEPT 
$EBTABLES -A WAN-ONLY-OUT -p 0x800 --pkttype-type broadcast \
    --ip-proto 17 --ip-dst 255.255.255.255/32 --ip-dport 67 -j ACCEPT 
$EBTABLES -A WAN-ONLY-OUT -p 0x800 --ip-dst 192.168.0.0/16 -j DROP
$EBTABLES -A WAN-ONLY-OUT -p 0x800 --ip-dst 10.0.0.0/8     -j DROP
$EBTABLES -A WAN-ONLY-OUT -p 0x800 --ip-dst 172.16.0.0/12  -j DROP
$EBTABLES -A WAN-ONLY-OUT -p 0x800 --ip-dst 169.254.0.0/16 -j DROP 
$EBTABLES -A WAN-ONLY-OUT -o eth0 -j ACCEPT 
$EBTABLES -A WAN-ONLY-OUT -o eth1 -j ACCEPT 
$EBTABLES -L FORWARD | grep WAN-ONLY-OUT | while read line
do
    $EBTABLES -D FORWARD $line
done
local j=0
while [ $j -lt "$NUMRADIO" ]
do
    local i=0
    while [ $i -lt "$NUM_VAPS" ]
    do
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
	local wanOnly=$(eval echo \$AP_WANONLY_${VARIDX})
	case "$wanOnly" in
	    1|true)
		$EBTABLES -I FORWARD -i ath$INDEX -j WAN-ONLY-OUT
		;;
	esac
	i=$((i + 1))
    done
    j=$((j + 1))
done

