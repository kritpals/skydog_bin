#!/bin/sh
#
# ccc_uci.sh encapsulate the setting of uci config parameters as used
# by the Cloud Command Client.  This script must be stored in the 
# CloudCommand.tar.gz at $CLOUD_ROOT (see rc.cloud)
#
# ccc_uci.sh
#   +--set_option		- Set an option and ask if changed
#   |  <package> <config> <option> <value> <section_type> <default_value> <state_dir>
#   +--set_isschanged		- Make a note of a changed section for processing
#   |  <package> <config> <section_type>
#   +--delete_section		- Delete a config section
#   |  <package> <config>
#   +--commit 			- Commit changes to config files
#   |  <what>			- Config package (/etc/config/file) name

# set_ischanged <package> <config> <section_type>
# record that fact that a configuration section in configuration file package
# of config-section-type has changed

. ./ccc_functions.sh

CHANGED_STATE_DIR="/var/.cloudchange/state"
CHANGED_UCI_DIR="/var/.cloudchange/current"

UCICHANGED="${UCICMD} -q -c ${CHANGED_UCI_DIR} -P $CHANGED_STATE_DIR"

ccc_uci_is_ischanged() {
    local package="$2"
    local section_type="$3"

    if [ "$(${UCICHANGED} get ischanged.${package}_${section_type} 2>/dev/null)" = "ischanged" ] 
    then
	echo 1
    else
	echo 0
    fi
}

ccc_uci_set_ischanged() {
    local package="$2"
    local config="$3"
    local section_type="$4"

    section_type="$(echo ${section_type} | tr '\-'@[] _)"

    mkdir -p $CHANGED_STATE_DIR
    mkdir -p $CHANGED_UCI_DIR
    touch $CHANGED_STATE_DIR/ischanged
    touch $CHANGED_UCI_DIR/ischanged
    
    if [ "$(${UCICHANGED} get ischanged.${package}_${section_type})" != "ischanged" ]; then
	echo "set_ischanged $package $config $section_type"
	${UCICHANGED} set ischanged.${package}_${section_type}="ischanged"
    fi
}

# set_option <package> <config> <option> <value> <section_type> <default_value> <state_dir>
# Set an option, creating the config section if necessary.
# Emits 0 on stdout for no change, 1 on stdout for changed
ccc_uci_set_option() {
    local package="$2"
    local config="$3"
    local option="$4"
    local value="$5"
    local section_type="$6" 
    local default_value="$7"
    local state_dir="$8"
    local testval

    # Acquiring Lock for Exclusive Config Access 
    # mkdir -p /tmp/cloud
    # lock /tmp/cloud/.cloudconfig.lck

    #. /etc/functions.sh
    #include /lib/config
    touch /etc/config/$package

    testval="$(uci_get "$package" "$config")"

    if [ -z "$testval" ]; then
	${UCI} set "$package"."$config"="$section_type"
	${UCI} set "$package"."$config"."$option"="$value"
    else
        testval="$(uci_get "$package" "$config" "$option" "$default_value" "$state_dir" 2>/dev/null)"
	${UCI} set "$package"."$config"."$option"="$value"
    fi

    if [ "$testval" != "$value" ]; then
	ccc_uci_set_ischanged set_ischanged "$package" "$config" "$section_type"
    fi
    # Releasing Lock for Exclusive Config Access 
    # lock -u /tmp/cloud/.cloudconfig.lck
}

ccc_uci_start_list() {
    local package="$2"
    local config="$3"
    local option="$4" 
    local section_type="$5" 

    append UCIListsCheck "${package}.${config}.${option}"

    mkdir -p $CHANGED_STATE_DIR
    mkdir -p $CHANGED_UCI_DIR
    touch $CHANGED_STATE_DIR/${package}
    touch $CHANGED_UCI_DIR/${package}
    
    ${UCICHANGED} delete ${package}.${config}.${option} 2>/dev/null
    ${UCICHANGED} set ${package}.${config}="${section_type}"

    (
        UCI_CONFIG_DIR=
        LOAD_STATE_DIR=
        LOAD_STATE=

        export UCI_CONFIG_DIR LOAD_STATE_DIR LOAD_STATE
     
	saveoldlist() {
            local value="$1"
            if [ -n "$value" ]; then
 		${UCICHANGED} add_list ${package}.${config}.${option}="${value}"
            fi
        }
	config_load ${package}
	config_list_foreach "$config" "$option" saveoldlist

	if [ -z "$(${UCICHANGED} get ${package}.${config}.${option})" ]; then
	    local value
	    config_get value "${config}" ${option}
            if [ -n "$value" ]; then
		${UCICHANGED} add_list ${package}.${config}.${option}="${value}"
            fi
        fi
    )
    
    ${UCI} delete ${package}.${config}.${option} 2>/dev/null
}

ccc_uci_set_list_item() {
    local package="$2"
    local config="$3"
    local option="$4"
    local value="$5"
    local section_type="$6" 

    if [ -n "$value" ]; then
	${UCI} set ${package}.${config}="$section_type"
	${UCI} add_list ${package}.${config}.${option}="${value}"
    fi
}

# delete_section <package> <config> <state_dir>
ccc_uci_delete_section() {
    local package="$2"
    local config="$3"
    local section_type="$4"
    local state_dir="$5"
    # mkdir -p /tmp/cloud
    # lock /tmp/cloud/.cloudconfig.lck
    touch /etc/config/$package

    testval="$(uci_get "$package" "$config")"

    ${UCI} delete ${package}.${config} 2>/dev/null
    if [ -n "$testval" ]; then
    	ccc_uci_set_ischanged set_ischanged "$package" "$config" ""
    fi
    # lock -u /tmp/cloud/.cloudconfig.lck
}

# Delete (in reverse order because of possible indexes in names) 
# unseen (unseen in CC protocol configuration) objects.
# When building the "seenList", do list="$list.$seen." to
# separate new entries. 
ccc_uci_delete_unseen() {

    [ "$ONLINE" = "1" ] || return

    local package=$2
    local config=$3
    local seenList=$4
    local prefix=$5
    local match=$6
    local obj=
    local delete=

    for obj in $(${UCICMD} show $package|grep "=$config\$"|cut -f2 -d.|cut -f1 -d=)
    do
	local g="$obj"
	[ -n "$prefix" ] && g=${g#$prefix}
	if [ -n "$match" ]
	then
	    case "$g" in
		"$match"*) 
		    ;; 
		*) 
		    continue; 
		    ;; 
	    esac
	fi
	if [ "$(echo $seenList|grep "\.${g}\.")" = "" ]
	then
	    delete="$obj $delete"
	fi
    done
    if [ "$delete" != "" ]
    then
	echo "Deleting $package [$delete]"
	for obj in $delete
	do
	    ccc_uci_delete_section delete_section $package $obj
	done
    fi
}

# commit <what> <state_dir>
ccc_uci_commit() {
    local what="$2"
    local commit_what
    if [ "$what" = "all" ]; then
	commit_what=
    else
	commit_what="$what"
    fi
    # Acquiring Lock for Exclusive Config Access 
    # mkdir -p /tmp/cloud
    # lock /tmp/cloud/.cloudconfig.lck
    ${UCI} commit $commit_what
    # Releasing Lock for Exclusive Config Access 
    # lock -u /tmp/cloud/.cloudconfig.lck
}

perform_reboot() {
    reboot -f
    exit 0
}

apply_change() {
    local cfg="$1"

    echo "apply_change for $cfg"

    case "${cfg%%_*}" in
	require)
            if [ "$cfg" = "require_reboot_" ]; then
	       do_reboot=1
            fi
	    ;;
	firewall)
	    do_firewall_restart=1	
	    ;;
	network)
	    case "${cfg#*_}" in
		interface)
		    do_network_restart=1
		    do_dnsmasq_restart=1
		    do_chilli_restart=1
		    ;;
		alias)
		    do_network_restart=1
		    do_dnsmasq_restart=1
		    ;;
		switch)
		    do_network_restart=1
		    do_dnsmasq_restart=1
		    do_chilli_restart=1
		    ;;
		switch_vlan)
		    do_network_restart=1
		    do_dnsmasq_restart=1
		    do_chilli_restart=1
		    ;;
	    esac
	    ;;
	wireless)
	    do_network_restart=1
	    do_dnsmasq_restart=1
	    do_chilli_restart=1
	    ;;
	dhcp)
	    do_dnsmasq_restart=1
	    ;;
	upnpd)
	    do_miniupnpd_restart=1
	    ;;
	chilli)
	    do_chilli_restart=1
	    do_firewall_restart=1
	    ;;
	thirdparty)
	    case "${cfg#*_}" in
		ccclient_debug)
		    do_reboot=1
		    ;;
            esac
       	    ;;
	system)
	    case "${cfg#*_}" in
		system)
		    do_syslog_restart=1
		    ;;
            esac
	    ;;
	openvpn)
	    do_openvpn_restart=1
	    ;;
    esac
}

ccc_do_syslog_restart() {
    local cfg="$1"

    . /lib/functions.sh
    . /lib/functions/service.sh
    service_stop /sbin/syslogd
    local args log_ip log_port log_size
    config_get log_ip "$cfg" log_ip
    config_get log_port "$cfg" log_port 514
    config_get log_size "$cfg" log_size 16
    config_get
    args="${log_ip:+-L -R ${log_ip}:${log_port}} ${conloglevel:+l $conloglevel} -C${log_size}"
    service_start /sbin/syslogd $args
}

check_list_changed() {
    package="$1"
    config="$2"
    option="$3"

    tmpdir="$(mktemp -d)"
    
    touch $tmpdir/oldlist.orig
    touch $tmpdir/newlist.orig

    listtofile() {
	local val="$1"
        local file="$2"

        if [ -n "$val" ]; then
	    echo "$val" >>$file
        fi
    }

    local old_section_type="$(
	UCI_CONFIG_DIR=$CHANGED_UCI_DIR
	LOAD_STATE_DIR=$CHANGED_STATE_DIR
	LOAD_STATE=1
	
	export UCI_CONFIG_DIR LOAD_STATE_DIR LOAD_STATE
	
	config_load $package
	config_list_foreach "$config" "$option" listtofile $tmpdir/oldlist.orig

        local old_section_type="$(${UCICMD} get ${package}.${config} 2>/dev/null)"

        if [ ! -s $tmpdir/oldlist.orig ]; then
	    local val
            config_get val "$config" $option 
	    if [ -n "$val" ]; then
		echo "$val" >>$tmpdir/oldlist.orig
            fi
        fi
	echo "$old_section_type"
    )"

    UCI_CONFIG_DIR=
    LOAD_STATE_DIR=
    LOAD_STATE=

    export UCI_CONFIG_DIR LOAD_STATE_DIR LOAD_STATE

    config_load $package
    config_list_foreach "$config" "$option" listtofile $tmpdir/newlist.orig
    
    if [ ! -s $tmpdir/newlist.orig ]; then
        local val
        config_get val "$config" $option 
        if [ -n "$val" ]; then
	    echo "$val" >>$tmpdir/newlist.orig
        fi
    fi
    
    sort $tmpdir/oldlist.orig >$tmpdir/oldlist.sorted
    sort $tmpdir/newlist.orig >$tmpdir/newlist.sorted

    local section_type="$(${UCICMD} get ${package}.${config} 2>/dev/null)"
    if [ -z "$section_type" ]; then
	section_type="$old_section_type"
    fi

    if ! cmp $tmpdir/oldlist.sorted $tmpdir/newlist.sorted; then
    	ccc_uci_set_ischanged set_ischanged "$package" "$config" "$section_type"
    fi

    if [ "$(wc -l $tmpdir/newlist.sorted|cut -f1 -d\ )" = "1" ]; then
	$UCI delete ${package}.${config}.${option} 2>/dev/null
	$UCI set ${package}.${config}="$section_type"
	$UCI set ${package}.${config}.${option}="$(echo -n "$(cat $tmpdir/newlist.sorted)")"
    fi

    rm -rf $tmpdir
   
    ${UCI} commit ${package}
}

check_lists_changed() {
    if [ -n "$UCIListsCheck" ]; then
        for list in $UCIListsCheck; do
	    check_list_changed $(echo $list|tr '.' ' ')
        done
    fi
}

# apply_changes 
ccc_uci_apply_changes() {
    check_lists_changed
    UCIListsCheck=

    (
	UCI_CONFIG_DIR=$CHANGED_UCI_DIR
	LOAD_STATE_DIR=$CHANGED_STATE_DIR
	LOAD_STATE=1
	export UCI_CONFIG_DIR LOAD_STATE_DIR LOAD_STATE

	#. /etc/functions.sh
	#include /lib/config
	
	do_reboot=0
	do_network_restart=0
	do_firewall_restart=0
	do_dnsmasq_restart=0
	do_miniupnpd_restart=0
	do_chilli_restart=0
	do_syslog_restart=0
	do_openvpn_restart=0

	config_load ischanged

	UCI_CONFIG_DIR=
	LOAD_STATE_DIR=
	LOAD_STATE=
	export UCI_CONFIG_DIR LOAD_STATE_DIR LOAD_STATE

	config_foreach apply_change ischanged 

    	rm -f $CHANGED_STATE_DIR/*
    	rm -f $CHANGED_UCI_DIR/*

	if [ "$do_reboot" = "1" ]; then
	    perform_reboot
	fi

	if [ "$do_syslog_restart" = "1" ]; then
	    (
		. /lib/functions.sh
		config_load system
		config_foreach ccc_do_syslog_restart system
	    )
	fi

	if [ "$do_network_restart" = "1" ]; then
	    /etc/init.d/network restart
	    if /etc/init.d/firewall enabled; then
		/etc/init.d/firewall restart
            else
		/etc/init.d/firewall stop
            fi
	    if /etc/init.d/dnsmasq enabled; then
		/etc/init.d/dnsmasq restart
            else
		/etc/init.d/dnsmasq stop
            fi
	    do_dnsmasq_restart=0
	    do_firewall_restart=0
	fi

	if [ "$do_chilli_restart" = "1" ]; then
	        if /etc/init.d/chilli enabled; then
		    /etc/init.d/chilli restart 
                else
		    /etc/init.d/chilli stop
                fi
	fi

	if [ "$do_openvpn_restart" = "1" ]; then
	    if /etc/init.d/openvpn enabled; then
		/etc/init.d/openvpn stop
		sleep 5
		/etc/init.d/openvpn start
            else
		/etc/init.d/openvpn stop
            fi
        fi

	if [ "$do_firewall_restart" = "1" ]; then
	    if /etc/init.d/firewall enabled; then
                /etc/init.d/firewall restart
            else
		/etc/init.d/firewall stop
            fi
	fi

	if [ "$do_dnsmasq_restart" = "1" ]; then
	    if /etc/init.d/dnsmasq enabled; then
		/etc/init.d/dnsmasq restart
            else
		/etc/init.d/dnsmasq stop
            fi
	fi

	if [ "$do_miniupnpd_restart" = "1" ]; then
	    /etc/init.d/miniupnpd stop
	    sleep 2
	    /etc/init.d/miniupnpd enabled && /etc/init.d/miniupnpd start
	fi
    )
}

[ "$CCC_INCLUDE" = "1" ] && return

cd $(dirname $0)
. ./ccc_functions.sh

CLOUDDIR=`pwd`
DEBUG_FLAG='1'
FUNC="ccc_uci_$1"
PARAMTYPE=$(type $FUNC)
if [ "$PARAMTYPE" = "$FUNC is a shell function" ]
then
    $FUNC "$@"
else
    echo "ccc_uci.sh: command not recognized: $1"
fi
