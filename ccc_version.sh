#!/bin/sh
#
# Author: Daniel Dickinson <daniel@powercloudsystems.com>
# Created: 2011-08-26
#
# Copyright 2011 PowerCloud Systems, All Rights Reserved
#

# NOTE: Because we use the output of this script all output 
# besides what we want should go to stderr

# ccc_version.sh encapsulates the commands needed to determine
# version (currently client) of some Cloud Command Client, 
# whether embedded in the firmware or only temporary.

# The tree below describes operation of and optional and required
# parameters for each function offered by ccc_version.sh. Parameters
# are described with angle or square brackets to indicate <required>
# or [optional] status.
#
# ccc_version.sh
#   +--version_from_startup <path-to-bundle>
#   +--get_client_version <path-to-bundle>
#   +--get_client_build <path-to-bundle>
#   +--get_client_time <path-to-bundle>
#   +--fw_client_ver 
#   +--cur_client_ver
#   +--fw_client_build
#   +--cur_client_build
#   +--fw_client_time
#   +--cur_client_time

# Use this where you want messages to be output when DEBUG_FLAG=1
# NB: It only takes a single parameter to you must ensure any
#  arguments with spaces are quoted.

. /etc/functions.sh
config_load thirdparty
config_get_bool script_debug ccclient_debug script_debug 0

DEBUG_FLAG="$script_debug"

# For previous versions of the bundle we need to parse ccc_startup.sh
# to determine the bundle (client) version.  In that case there is
# a variable assign and export 'export CLIENTVER="X.X.XX"'.
# To get rid of the quotes we cheat and assume the version will not have
# quotes in the version string
ccc_version_from_startup() {
	local path="$2"
	grep "export CLIENTVER" "$path"/ccc_startup.sh | cut -f2 -d= | tr -d \"	
}

# For all versions from this version of the bundle on the client
# version is in ccc_version.txt of the bundle dir.
ccc_version_get_client_version() {
	local vdir="$2"
	if [ ! -s "$vdir"/ccc_version.txt ]; then
		$CLOUDDIR/ccc_version.sh from_startup "$vdir"
	else
		cat "$vdir"/ccc_version.txt
	fi
}

ccc_version_get_client_build() {
	local vdir="$2"
	cat "$vdir"/ccc_build.txt
}

ccc_version_get_client_time() {
	local vdir="$2"
	cat "$vdir"/ccc_ccagent_time.txt
}

# To determine the version of the client embedded in the firmware
# we untar the bundle into a temporary directory and then 
# check the bundle version as usual.  Then we delete the temp dir.
ccc_version_fw_client_ver() {
	local tdir="$(mktemp -d)"
	tar -C "$tdir" -xzf /usr/cloud/CloudCommand.tar.gz >&2
	$CLOUDDIR/ccc_version.sh get_client_version "$tdir"
	rm -rf "$tdir" >&2
}

ccc_version_fw_client_build() {
	local tdir="$(mktemp -d)"
	tar -C "$tdir" -xzf /usr/cloud/CloudCommand.tar.gz >&2
	$CLOUDDIR/ccc_version.sh get_client_build "$tdir"
	rm -rf "$tdir" >&2
}

ccc_version_fw_client_time() {
	local tdir="$(mktemp -d)"
	tar -C "$tdir" -xzf /usr/cloud/CloudCommand.tar.gz >&2
	$CLOUDDIR/ccc_version.sh get_client_time "$tdir"
	rm -rf "$tdir" >&2
}

# The current client's firmware version can be determined by
# examining the bundle in the same location as this script.
ccc_version_cur_client_ver() {
	$CLOUDDIR/ccc_version.sh get_client_version "$CLOUDDIR"
}

ccc_version_cur_client_build() {
	$CLOUDDIR/ccc_version.sh get_client_build "$CLOUDDIR"
}

ccc_version_cur_client_time() {
	$CLOUDDIR/ccc_version.sh get_client_time "$CLOUDDIR"
}

if [ "$CLOUD_TMP" = "" ]
then
	CLOUD_TMP=/tmp/cloud
fi

RELATIVE_DIR=`dirname $0`
cd $RELATIVE_DIR
CLOUDDIR=`pwd`
PARAMTYPE=`type ccc_version_$1`
if [ "$PARAMTYPE" = "ccc_version_$1 is a shell function" ]
then
   ccc_version_$1 "$@"
else
   echo "ccc_version.sh: command not recognized: $1" >&2
fi

