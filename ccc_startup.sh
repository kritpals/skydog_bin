#!/bin/sh
#
# Copyright 2010-2013 PowerCloud Systems, All Rights Reserved

export HARDWAREVER=1
if [ -s /usr/cloud/fwversion ]; then
	export FIRMWAREVER=`cat /usr/cloud/fwversion`
#	export FIRMWAREBUILD=`cat /usr/cloud/fwbuild`
#	export FIRMWARETIME=`cat /usr/cloud/fwtime`
else
	export FIRMWAREVER=0.4
fi

export CLOUD_ROOT=/tmp/cloud

. /etc/functions.sh
config_load thirdparty
config_get ccclient_debug ccclient_debug ccclient_debug 0

if [ -z "$ccclient_debug" ]; then
    ccclient_debug=0
fi

if [ "$ccclient_debug" -le 0 ]; then
    ccclient_debug=0
fi

if [ "$ccclient_debug" -ge 10 ]; then
    ccclient_debug=10
fi

export CCCLIENT_DEBUG="$(
	yes d | tr -d '
' | dd bs=1 count="$ccclient_debug"
)"

[ -s /usr/cloud/model ] && {
	export MODEL="$(cat /usr/cloud/model)"
} || {
	export MODEL=ubdev01
}

export CLOUD_TMP=/tmp
export CLOUD_RUN=/tmp/cloud
export CLOUD_ACL_FLASH=/usr/cloud/acl
export REDIR_URL=`echo $ACS_URL | sed 's/router\/ccc/router\/auth\/login/'`
export DNS_REDIR_URL=`echo $ACS_URL | sed 's/router\/ccc/router\/dns\/restricted/'`

[ -s $CLOUD_ROOT/ccc_version.txt ] && {
	export CLIENTVER="$(cat $CLOUD_ROOT/ccc_version.txt)"
#	export CLIENTBUILD="$(cat $CLOUD_ROOT/ccc_build.txt)"
#	export CLIENTTIME="$(cat $CLOUD_ROOT/ccc_ccagent_time.txt)"
} || {
	CLIENTVER="1.3.32"
}

export TEST="apr19 1:40pm"

echo "Enable Networks Cloud Command Client version $CLIENTVER serial $SERIALNUM for $MODEL hardware"

echo 0 > /proc/sys/net/bridge/bridge-nf-call-arptables
echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables
echo 0 > /proc/sys/net/bridge/bridge-nf-call-ip6tables
echo 0 > /proc/sys/net/bridge/bridge-nf-filter-vlan-tagged

case "$MODEL" in
    ubdevod | WAP224NOC )
	export ledgoodname="ubnt:green:front"
	export ledbadname="ubnt:orange:front"
	export ledgoodtrigger="default-on"
	export ledbadtrigger="default-on"
	export ledstart1name="ubnt:green:front"
	export ledstart2name="ubnt:orange:front"
	export ledstarttrigger="timer"
	export ledstarton="100"
	export ledstartoff="100"
	;;
    dlrtdev01 | AP825 )
	export ledgoodname="d-link:blue:power"
	export ledbadname="d-link:orange:power"
	export ledgoodtrigger="default-on"
	export ledbadtrigger="default-on"
	export ledstart1name="d-link:blue:power"
	export ledstart2name="d-link:orange:power"
	export ledstarttrigger="timer"
	export ledstarton="100"
	export ledstartoff="100"
	;;
    cr5000 )
	export ledgoodname="cr5000:orange:power"
	export ledbadname="cr5000:orange:power"
	export ledgoodtrigger="default-on"
	export ledbadtrigger="timer"
	export ledbadon="50"
	export ledbadoff="150"
	export ledstart1name="cr5000:orange:power"
	export ledstart2name="cr5000:orange:power"
	export ledstarttrigger="timer"
	export ledstarton="100"
	export ledstartoff="100"
	;;
    cr3000 )
	export ledgoodname="cr3000:orange:power"
	export ledbadname="cr3000:orange:power"
	export ledgoodtrigger="default-on"
	export ledbadtrigger="timer"
	export ledbadon="50"
	export ledbadoff="150"
	export ledstart1name="cr3000:orange:power"
	export ledstart2name="cr3000:orange:power"
	export ledstarttrigger="timer"
	export ledstarton="100"
	export ledstartoff="100"
	;;
    CAP324* )
        export ledgoodname="cap324:green:power"
        export ledbadname="cap324:orange:power"
        export ledgoodtrigger="default-on"
        export ledbadtrigger="default-on"
        export ledstart1name="cap324:green:power"
        export ledstart2name="cap324:orange:power"
        export ledstarttrigger="timer"
        export ledstarton="100"
        export ledstartoff="100"
        ;;
    *)
	export ledgoodname="ubnt:green:dome"
	export ledbadname="ubnt:orange:dome"
	export ledgoodtrigger="default-on"
	export ledbadtrigger="default-on"
	export ledstart1name="ubnt:green:dome"
	export ledstart2name="ubnt:orange:dome"
	export ledstarttrigger="timer"
	export ledstarton="100"
	export ledstartoff="100"
	;;
esac

echo "$ledstarttrigger" > /sys/class/leds/$ledstart1name/trigger
echo "$ledstarttrigger" > /sys/class/leds/$ledstart2name/trigger

if [ "$ledstarttrigger" = "timer" ]; then
	echo "$ledstarton" > /sys/class/leds/$ledstart1name/delay_on
	echo "$ledstartoff" > /sys/class/leds/$ledstart1name/delay_off
	echo "$ledstarton" > /sys/class/leds/$ledstart2name/delay_on
	echo "$ledstartoff" > /sys/class/leds/$ledstart2name/delay_off
else
	echo 1 > /sys/class/leds/$ledstart1name/brightness
	echo 1 > /sys/class/leds/$ledstart2name/brightness
fi

mkdir -p $CLOUD_TMP/.cloudconf/current
mkdir -p $CLOUD_TMP/.cloudconf/state

export CLOUD_CONF_UCI_CONFIG_DIR=$CLOUD_TMP/.cloudconf/current

cp $CLOUD_RUN/ccc_default $CLOUD_TMP/.cloudconf/current/cloudconf
md5sum "$CLOUD_TMP"/.cloudconf/current/cloudconf | cut -f1 -d\ >"$CLOUD_TMP"/.cloudconf/current/cloudconf.md5sum
[ -s "$CLOUD_ACL_FLASH/.cloudconf/current/cloudconf" ] || {
	mkdir -p "$CLOUD_ACL_FLASH"/.cloudconf/current
	cp "$CLOUD_RUN"/ccc_default "$CLOUD_ACL_FLASH"/.cloudconf/current/cloudconf
	md5sum "$CLOUD_RUN"/ccc_default  | cut -f1 -d\  >"$CLOUD_ACL_FLASH"/.cloudconf/current/cloudconf.md5sum
}

check_date() {
	local date_now="$(date +%s)"

	if [ "$date_now" -lt "$(date -d 201207070600 +%s)" ] || [ "$date_now" -gt "$(date -d 201612311200 +%s)" ]; then
		return 1
        else 
		return 0
        fi
}	

if ! check_date; then
	date -s $(date -r /etc/init.d/storedate +%Y%m%d%H%M.%S)
	echo "Fallback to $(date) (from Last Known Good)"
fi

if ! check_date; then
	date 201207070600
	echo "Fallback to $(date) (Hardcoded in Firmware)"
fi

[ -e /etc/config/ccconfig ] && cp /etc/config/ccconfig $CLOUD_RUN/.config
$CLOUD_RUN/ccclient ${CCCLIENT_DEBUG:+-$CCCLIENT_DEBUG} "$@"
RET=$?
echo ccclient exited $RET
killall ccclient
exit $RET
