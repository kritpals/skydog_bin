#!/bin/sh
#
# Author: Daniel Dickinson <daniel@powercloudsystems.com>
# Created: 2011-07-30
#
# Copyright 2011-2012 PowerCloud Systems
# All Rights Reserved
#


ccc_cloud_conf_set() 
{
    uci -q -c ${CLOUD_CONF_UCI_CONFIG_DIR} set cloudconf.cloudconf.${2}="${3}"
    uci -q -c ${CLOUD_CONF_UCI_CONFIG_DIR} commit cloudconf
    md5sum ${CLOUD_CONF_UCI_CONFIG_DIR}/cloudconf | cut -f1 -d\  >${CLOUD_CONF_UCI_CONFIG_DIR}/cloudconf.md5sum
}

ccc_cloud_conf_get() 
{
    uci -q -c ${CLOUD_CONF_UCI_CONFIG_DIR} get cloudconf.cloudconf.${2}
}

if [ -z "$CLOUD_TMP" ]; then
   echo "ccc_cloud_conf.sh: fatal: \$CLOUD_TMP is not set; cloudconf will not be found."
   exit 120
fi

mkdir -p $CLOUD_TMP/.cloudconf

RELATIVE_DIR=`dirname $0`
cd $RELATIVE_DIR
CLOUDDIR=`pwd`
PARAMTYPE=`type ccc_cloud_conf_$1`
if [ "$PARAMTYPE" = "ccc_cloud_conf_$1 is a shell function" ]
then
   ccc_cloud_conf_$1 "$@"
else
   echo "ccc_cloud_conf.sh: command not recognized: $1"
fi
