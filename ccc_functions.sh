#!/bin/sh
#
. /etc/functions.sh
include /lib/config

[ -z "$CLOUD_RUN" ] && CLOUD_RUN=/tmp/cloud
[ -z "$CLOUD_TMP" ] && CLOUD_TMP=/tmp

export CLOUD_RUN
export CLOUD_TMP

config_load thirdparty
config_get_bool script_debug ccclient_debug script_debug 0

[ -z "$UCICMD" ] && UCICMD="/sbin/uci"

ccc_uci() {
    local show_uci="$(${UCICMD} -q get thirdparty.ccclient_debug.show_uci)"
    if [ "$show_uci" = "1" ]; then 
	logger -t ccc_uci "${UCICMD} -q $@"
    fi
    ${UCICMD} -q "$@"
}

if [ -n "$UCI" ] && [ "$UCI" != "ccc_uci" ]; then
    UCICMD="$UCI"
fi

UCI="ccc_uci"

fmt_mac() 
{
    echo $1 | sed 's/[:-]//g' | tr '[a-z]' '[A-Z]'
}

getmac_raw() 
{
    local content=$(ifconfig $1)
    local mac=${content#*$1}
    mac=${mac#*HWaddr }
    echo ${mac%% *}
}

getmac() 
{
    fmt_mac $(getmac_raw $1)
}

get_wan_device()
{
   (
    	. /lib/functions/network.sh
    	network_get_device ifname wan
    	echo $ifname
   )
}

ccc_run() {
    local command="$1"
    shift
    export CLOUD_RUN
    export CLOUD_TMP
    echo $CLOUD_RUN/$command $@
    $CLOUD_RUN/$command "$@"
}

ccc_run_quiet() {
    local command="$1"
    shift
    export CLOUD_RUN
    export CLOUD_TMP
    $CLOUD_RUN/$command "$@"
}

ccc_run_uci() {
    if [ "$CCC_INCLUDE" = "1" ]
    then
	ccc_uci_$1 "$@"
    else
	ccc_run ccc_uci.sh "$@"
    fi
}

ccc_run_router() {
    if [ "$CCC_INCLUDE" = "1" ]
    then
	router_$1 "$@"
    else
	ccc_run ccc_router.sh "$@"
    fi
}

ccc_run_wifi() {
    if [ "$CCC_INCLUDE" = "1" ]
    then
	wifi_$1 "$@"
    else
	ccc_run ccc_2.0_wifi.sh "$@"
    fi
}

ccc_bool() {
    local t=0
    [ "$2" != "" ] && t=$2
    [ "$1" = "true" -o "$1" = "1" ] && t=1
    echo $t
}

ccc_notbool() {
    local t=1
    [ "$2" != "" ] && t=$2
    [ "$1" = "true" -o "$1" = "1" ] && t=0
    echo $t
}

ccc_lsort() {
    eval echo "\$$1" | tr ' ' '\n' | sort
}

ccc_nsort() {
    eval echo "\$$1" | tr ' ' '\n' | while read l
    do
	case "$l" in
	    [0-9]*)
		echo $l
		;;
	esac
    done | sort -n
}

ccc_v() {
    eval echo \$$1
}

ccc_comma() {
    local has
    while [ "$1" != "" ]
    do
	[ "$has" = "1" ] && echo -n ", "
	echo -n "$1"
	has=1
	shift
    done
}

ccc_append_uniq() {
	local var="$1"
	local val="$2"

	local var_val="$(eval "echo \$$var")"
	local ret
	echo "$var_val" | grep -q "$val"
	ret=$?
	if [ -z "$var_val" ] || [ "$ret" = "1" ]; then
		append $var "$val"
	fi
}

debug_echo() {
    if [ "${DEBUG_FLAG}" = "1" ]
    then
        echo "$@"
    fi
}

