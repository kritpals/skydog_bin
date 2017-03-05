#!/bin/sh
. /tmp/cloud/config.txt
export REDIR_URL=`echo $ACS_URL | sed 's/router\/ccc/router\/auth\/login/'`
export DNS_REDIR_URL=`echo $ACS_URL | sed 's/router\/ccc/router\/dns\/restricted/'`
exec /tmp/cloud/cccredir
