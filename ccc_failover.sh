#!/bin/sh
#
# Author: Daniel Dickinson <daniel@powercloudsystems.com>
# Copyright 2011 PowerCloud Systems, All Rights Reserved
# Created: 2011-07-28
#
. /etc/functions.sh
include /lib/config

[ -z "$occc_corp_acl_files" ] && occc_corp_acl_files="authorized-users .cloudconf/current/cloudconf"
[ -z "$occc_guest_acl_files" ] && occc_guest_acl_files="authorized-guests guest-dmz-host .cloudconf/current/cloudconf"
[ -z "$occc_flashpath" ] && occc_flashpath="$CLOUD_ACL_FLASH"
[ -z "$occc_tmppath" ] && occc_tmppath="$CLOUD_TMP"

. /etc/functions.sh
config_load thirdparty
config_get_bool script_debug ccclient_debug script_debug 0

DEBUG_FLAG="$script_debug"

debug_echo()
{
    if [ "${DEBUG_FLAG}" = "1" ]; then
        echo "${1}"
    fi
}

cp_from() {
	local src="$1"
	[ -z "$src" ] && return 1
	[ -d "$src" ] || return 1
	shift
	local dst="$1"
	[ -z "$dst" ] && return 1
	[ -d "$dst" ] || mkdir -p "$dst"
	shift
	while [ -n "$1" ]; do
		if [ -s "$src"/"$1" ] && [ -s "$src"/"${1}.md5sum" ]; then
			debug_echo "Maybe copying $src/$1"
			local m1="$(md5sum "$src"/"$1" | cut -f1 -d\ )"
			local do_copy=1
			[ -s "$dst"/"$1" ] && [ -s "$dst"/"${1}.md5sum" ] && {
				# Don't copy if duplicate
				debug_echo "comparing $dst/$1 $src/$1"
				if [ "$m1" = "$(cat "$src"/"${1}.md5sum")" ] &&
					[ "$m1" = "$(cat "$dst"/"${1}.md5sum")" ] &&
					[ "$m1" = "$(md5sum "$dst"/"${1}" | cut -f1 -d\ )" ]; then
						echo "No copying; $src/$1 identical to $dst/$1"
						do_copy=0
				fi
					
			}
			if [ "$m1" != "$(cat "$src"/"${1}.md5sum")" ]; then
				do_copy=0
				echo "Source ACL corrupt: ${src}/${1} doesn't match md5sum"
			fi
			[ "$do_copy" = "1" ] && {
				debug_echo "mkdir -p $(dirname $dst/$1)"
				mkdir -p "$(dirname "$dst"/"$1")"
				debug_echo "cp $src/$1 $dst/$1"
				cp "$src"/"$1" "$dst"/"$1" || return 1
				cp "$src"/"${1}.md5sum" "$dst"/"${1}.md5sum" || return 1
			}
		else
			# Only delete src if state is coherent (i.e. also no md5sum)
			[ -e "$dst"/"$1" ] && [ ! "$src"/"${1}.md5sum" ] && {
				debug_echo "rm -rf $dst/$1" 
				rm -rf "$dst"/"$1"  || return 1
				debug_echo "rm -rf $dst/${1}.md5sum" 
				rm -rf "$dst"/"${1}.md5sum"  || return 1
			}
		fi
		shift
	done
	return 0
}

copy_acl()
{
	local status_code="$1"
	local nettype="$2"
	debug_echo "O possibly copying acl files"
	case "$status_code" in
	CERR|RERR|OERR)
		debug_echo "CERR|RERR|OERR so copying ACL files from flash to temp"
		debug_echo "( cd $occc_tmppath && rm -f $occc_guest_acl_files $occc_corp_acl_files )"
		( cd "$occc_tmppath" && rm -f $occc_guest_acl_files $occc_corp_acl_files )
		debug_echo "cp_from $occc_flashpath $occc_tmppath $occc_guest_acl_files $occc_corp_acl_files"
		cp_from $occc_flashpath $occc_tmppath $occc_corp_acl_files $occc_guest_acl_files || return 1
		didaclapply="$(uci_get_state thirdparty.ccc_state.didaclapply)"
		haddone="$(uci_get_state thirdparty.ccc_state.haddone)"
		if [ "$didaclapply" != "1" ] && [ "$haddone" != "1" ] && [ "$haddone" != "2" ]; then
			# we only really care about this on reboot with no cloud, otherwise the latest ACL has
			# already been applied
			debug_echo "Copied ACL from flash and never applied, so applying"
			debug_echo "Stopping wifi"
			debug_echo "O $CLOUD_RUN/ccc_wifi.sh stop"
			$CLOUD_RUN/ccc_wifi.sh stop
			debug_echo "Reading config"
			. $CLOUD_RUN/config.txt
			debug_echo "Restarting wifi (which should reset firewall)"
			debug_echo "O $CLOUD_RUN/ccc_wifi.sh start"
			$CLOUD_RUN/ccc_wifi.sh start
			debug_echo "Allowing authorized corporate users"
			debug_echo "O $CLOUD_RUN/ccc_wifi.sh update_corp"
			$CLOUD_RUN/ccc_wifi.sh update_corp
			debug_echo "Allowing authorized guest users"
			debug_echo "O $CLOUD_RUN/ccc_wifi.sh update_guests"
			$CLOUD_RUN/ccc_wifi.sh update_guests
			debug_echo "O $CLOUD_RUN/ccc_wifi.sh update_guestdmzhost"
			$CLOUD_RUN/ccc_wifi.sh update_guestdmzhost
			debug_echo "O uci_set_state thirdparty ccc_state didaclapply 1"
			uci_set_state thirdparty ccc_state didaclapply 1 || return 1
		fi
		;;
	DONE|ERRBAK)
		debug_echo "DONE or first CERR|RERR|OERR so copying temporary ACL files to flash"
		local different=0
		local acl_files="$occc_corp_acl_files"
		if [ "$nettype" = "guest" ]; then
			acl_files="$acl_files $occc_guest_acl_files"
		fi
		debug_echo "O cp_from $occc_tmppath $occc_flashpath $acl_files"
		cp_from $occc_tmppath $occc_flashpath $acl_files 
		;;
	*)
		debug_echo "status '$status_code' not final; not syncing acl files"
		return 0
		;;
	esac
	return 0
}

ccc_failover_maybe_copy_acl()
{
	local count
	local haddone=0
	maxcount="$3"
	[ -z "$3" ] && {
		debug_echo "O maxcount for acl_maybe_count not specified"
		maxcount=10
	}
	haddone="$(uci_get_state thirdparty.ccc_state.haddone)"
	count="$(uci_get_state thirdparty.ccc_state.acl_maybe_count)"
	[ -z "$count" ] && {
		debug_echo "O no uci state for acl_maybe_count"
		count="$maxcount"
	}
	debug_echo "O acl_maybe_count detected as '$count'"
	case "$2" in
	DONE)
		copy_acl "$2" corp
		[ "$count" -le "$maxcount" ] && count="$(($count + 1))"	
		[ "$count" -gt "$maxcount" ] && {
			debug_echo "O maxcount of acl_maybe_count exceeded - copying ACL" 
			count=1
			debug_echo "O copy_acl $2" 
			copy_acl "$2" guest || return 1
			debug_echo "O uci_set_state thirdparty ccc_state haddone 1"
			uci_set_state thirdparty ccc_state haddone 1 || return 1
		}
		;;
	CERR|RERR|OERR)
		if [ "$count" -ge $maxcount ]; then
			if [ -n  "$haddone" ]; then
				if [ "$haddone" = "1" ]; then
					debug_echo "O copy_acl ERRBAK $2"
					copy_acl ERRBAK both
					# only copy from tmppath to flash on fail once
					debug_echo "O uci_set_state thirdparty ccc_state haddone 2"
					uci_set_state thirdparty ccc_state haddone 2 || return 1
					debug_echo "O acl_maybe_count: reset count to 1"
					count=1
				fi
			else
				debug_echo "O do copy_acl: maxcount ($maxcount), no haddone"
				debug_echo "O copy_acl $2" 
				copy_acl "$2" both || return 1
				debug_echo "O acl_maybe_count: reset count to 1"
				count=1
			fi
			debug_echo "O acl_maybe_count: reset count to 1"
			count=1
		else
			[ "$count" -le "$maxcount" ] && count="$(($count + 1))"	
			[ "$count" -gt "$maxcount" ] && {
				debug_echo "O maxcount of acl_maybe_count exceeded - copying ACL" 
				count=1
				debug_echo "O copy_acl $2" 
				copy_acl "$2" both || return 1
			}
		fi
		;;
	*)
		debug_echo "status '$status_code' not final; not syncing acl files"
		return 0
		;;
	esac
	debug_echo "O uci_set_state thirdparty ccc_state acl_maybe_count $count" 
	uci_set_state thirdparty ccc_state acl_maybe_count "$count" || return 1
	return 0
}

ccc_failover_set_failover_state()
{
	[ -z "$2" ] && return 1
	case "$2" in
	CERR|RERR)
		local prevfailover="$(uci_get_state thirdparty.ccc_state.failover)"
		[ "$prevfailover" != "1" ] && {
			debug_echo "O uci_set_state thirdparty ccc_state failover 1"
			uci_set_state thirdparty ccc_state failover 1 || return 1
			maxcount="$3"
			[ -z "$3" ] && {
				debug_echo "O maxcount for acl_maybe_count not specified"
				maxcount=10
			}
			debug_echo "O uci_set_state thirdparty ccc_state acl_maybe_count $maxcount"
			uci_set_state thirdparty ccc_state acl_maybe_count "$maxcount" || return 1
			rm -f /tmp/luci-indexcache
		}
		;;
	DONE)
		local prevfailover="$(uci_get_state thirdparty.ccc_state.failover)"
		if [ "$prevfailover" != "0" ]; then
			debug_echo "O uci_set_state thirdparty ccc_state failover 0"
			uci_set_state thirdparty ccc_state failover 0 || return 1
			rm -f /tmp/luci-indexcache
		fi
		;;
	*)
		debug_echo "O state $2 not final; not changing failover status"
		;;
	esac
	return 0
}

if [ "$CLOUD_TMP" = "" ]
then
   echo "ccc_failover.sh: fatal: \$CLOUD_TMP is not set; cloud.conf will not be found."
   exit 120
fi

RELATIVE_DIR=`dirname $0`
cd $RELATIVE_DIR
CLOUDDIR=`pwd`

if [ "$(uci_get_state thirdparty.ccc_state)" != "ccc_state" ] ; then
	debug_echo "O /sbin/uci ${UCI_CONFIG_DIR:+-c $UCI_CONFIG_DIR} -P /var/state set thirdparty.ccc_state=ccc_state"
	/sbin/uci ${UCI_CONFIG_DIR:+-c $UCI_CONFIG_DIR} -P /var/state set "thirdparty.ccc_state=ccc_state" || exit 1
fi

PARAMTYPE=`type ccc_failover_$1`
if [ "$PARAMTYPE" = "ccc_failover_$1 is a shell function" ]
then
   echo "ccc_failover.sh $@"
   ccc_failover_$1 "$@"
else
   echo "ccc_failover.sh: command not recognized: $1"
fi
