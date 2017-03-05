#!/bin/sh
#
#   Copyright (c) 2012 PowerCloud Systems, Inc.
#
cd $(dirname $0)

dl_server=$CCC_DeviceBWTestDownloadServer
dl_port=${CCC_DeviceBWTestDownloadPort:-80}
dl_uri=$CCC_DeviceBWTestDownloadURI
dl_time=${CCC_DeviceBWTestDownloadDuration:-20}

ul_server=$CCC_DeviceBWTestUploadServer
ul_port=${CCC_DeviceBWTestUploadPort:-80}
ul_uri=$CCC_DeviceBWTestUploadURI
ul_time=${CCC_DeviceBWTestUploadDuration:-20}

run_bwtest() {
    sh ./ccc_tc.sh stop
    rm -f /tmp/bwtest.*
    /usr/cloud/bwtest get "$dl_server" $dl_port $dl_uri $dl_time > /tmp/bwtest.down
    if [ "$?" = "0" ]
    then
	/usr/cloud/bwtest post "$ul_server" $ul_port $ul_uri $ul_time > /tmp/bwtest.up
	if [ "$?" = "0" ]
	then
	    cat<<EOF>/tmp/bwtest.result
Device.BWTest.Download.Statistics=$(cat /tmp/bwtest.down)
Device.BWTest.Upload.Statistics=$(cat /tmp/bwtest.up)
EOF
	else
	    mv /tmp/bwtest.up /tmp/bwtest.failed
	fi
    else
	mv /tmp/bwtest.down /tmp/bwtest.failed
    fi
}

if [ "$dl_server" != "" -a "$dl_uri" != "" -a "$ul_server" != "" -a "$ul_uri" != "" ]
then
    run_bwtest
fi
