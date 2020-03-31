#!/bin/bash

###################################
# Saltified, don't edit by hand ! #
###################################
set -e

trap "echo killed" SIGHUP SIGINT SIGTERM

VERSION=3.1


###############################################################################
# Return code                                                                 #
###############################################################################
ERROR_INSTANCE_DOES_NOT_EXIST=172
ERROR_INCORRECT_PARAM=173
ERROR_INVALID_FUNCTIONAL_STATE=174
ERROR_INFRA=175
ERROR_SNAPSHOT_NOT_FOUND=176


###############################################################################
# Globals                                                                     #
###############################################################################

OLDLANG=$LANG
LANG=en_us_8859_1

MY_PATH="`dirname \"$0\"`"              # relative
MY_PATH="`( cd \"$MY_PATH\" && pwd )`"  # absolutized and normalized
if [ -z "$MY_PATH" ] ; then
	# error; for some reason, the path is not accessible
	exit $ERROR_INFRA  # fail
fi

CMD=''
INSTANCE=''
FROMIP=''
METAS='{metas}'
VERB='verbose'       # default verbosity level (verbose or empty for quiet)
OUTPUT='stdout'      # default output mode (stdout|json)
JSONFORMAT='pretty'  # generated json format (pretty|lean)
OUT='{'

BACKUPNUM=3
BASEPORT=4000
BASEPROCESSPORT=3307
MEMPERINSTANCE=2
SERVERMODE='SLAVE'
ZFSPOOL='myzpool'
ZFSDATASET='mysql-data'
ZFSSNAPSET='mysql-snapshots'
DATADIR='/mnt/mysql-data'
SNAPDIR='/mnt/mysql-snapshots'
CONFDIR='/etc/mysql/snapshots.d'
CONFTPL='00-snapshots.tpl'
DBUSER='mysnapshoteruser'
DBPASS='mysuperpassword'

[[ -f /etc/replikator.conf ]] && source /etc/replikator.conf

FSTYPE=`mount | grep $DATADIR | awk '{ print $5 }'`
if [[ $FSTYPE != 'zfs' ]]; then
	echo "Unsupported fs type (must be zfs) !"
	exit $ERROR_INFRA
fi

###############################################################################
# Functions                                                                   #
###############################################################################
Usage() {
	echo
	echo -e "Replication snaphots manager ${VERSION}"
	echo -e "Author: Walid Moghrabi <w.moghrabi@servicemagic.eu>"
	echo
	echo -e "This script ease the creation and management of database snapshoted instances"
	echo
	echo -e "Usage: \e[1m$1 [OPTION]\e[0m"
	echo
	echo -e "\e[1mOptions\e[0m"
	echo -e " -h, --help                            Show this help"
	echo -e " -v, --verbose                         Increase verbosity"
	echo -e " -q, --quiet                           Disable output completely"
	echo -e " -c, --create <NAME>:<MEM>:<PORT>      Create a snapshot"
	echo -e "                                       (optionnal) <MEM> sets memory size limit for instance (default $MEMPERINSTANCE GB)"
	echo -e "                                       (optionnal) <PORT> define fixed port for instance"
	echo -e " -b, --backup                          Create a backup snapshot"
	echo -e " -e, --exec                            Execute a post replica hook script"
	echo -e "                                       (replica's port will be given as hook script parameter)"
	echo -e " -f, --from-ip <IPADDR>                IP address for source IP based port redirect (3306 to running instance port)"
	echo -e " -F, --from-replica <SOURCE>           If you want to create a replica based on another specific one"
	echo -e " -l, --list                            List all created instances"
	echo -e " -L, --list-backups                    List all created backups"
	echo -e " -g, --get-status <NAME>               Get detailed instance informations"
	echo -e " -d, --delete <NAME>                   Delete an instance"
	echo -e " -p, --purge                           Delete every declared instances (running or not)"
	echo -e " -P, --purge-all                       Delete every declared instances (running or not), including backups"
	echo -e " -r, --run <NAME>                      Start an instance"
	echo -e " -R, --refresh <NAME>                  Refresh an existing instance"
	echo -e " -x, --stop <NAME>                     Stop an instance"
	echo -e " -w, --add-redirect <NAME>             Add IP based redirect (3306 to running instance port)"
	echo -e " -y, --del-redirect <NAME>             Delete IP based redirect (3306 to running instance port)"
	echo -e " -z, --purge-redirects                 Delete every IP based redirects"
	echo -e " -m, --add-metas <NAME>:<JSON>         Add metas informations in JSON format"
	echo -e " -t, --stop-replication                Stop the replication process"
	echo -e " -T, --start-replication               Start the replication process"
	echo -e " -o, --output <FORMAT>                 Define output format (stdout|json), stdout is default"
	echo -e " -n, --noconfirm                       Assume Yes to all queries and do not prompt"
	echo -e " -M, --monitor                         Autorefresh with <DELAY> seconds"
	echo -e
}

CheckIP() {
	local ip=$1

	if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		OIFS=$IFS
		IFS='.'
		rip=($ip)
		IFS=$OIFS
		[[ ${rip[0]} -le 255 && ${rip[1]} -le 255 && ${rip[2]} -le 255 && ${rip[3]} -le 255 ]]
		res=$?
	fi

	if [[ $res ]]; then
		FROMIP=$ip
	else
		[[ -n $VERB ]] && echo -e "Malformed IP : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Malformed IP"
		exit $ERROR_INCORRECT_PARAM
	fi
}

CheckSlotAvail() {
	local poolsize=`zpool get -Hp size $ZFSPOOL | awk '{print $3}'`
	local available=`zpool get -Hp free $ZFSPOOL | awk '{print $3}'`
	local percentfree=$(( available * 100 / poolsize ))

	# we set a 10% threshold limit to make sure we don't break existing replicas
	if [[ $available -lt 10 ]]; then
		[[ -n $VERB ]] && echo -e "Not enough space available for snapshot (`NumFmt $percentfree`% free space available !) : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INFRA $LINENO "Not enough space available for snapshot (`NumFmt $percentfree`% free space available !)"
		exit $ERROR_INFRA
	fi
}

CheckBaseProcess() {
	local port=$1
	if [[ `ps aux | grep 'mysqld.pid' | grep -v 'grep' | awk '{print $2}' 2> /dev/null` ]]; then
		if [[ $OUTPUT = 'stdout' ]]; then
			STATUS='\e[32mRUNNING\e[0m'
		else
			STATUS='RUNNING'
		fi
	else
		if [[ $OUTPUT = 'stdout' ]]; then
			STATUS='\e[91mSTOPPED\e[0m'
		else
			STATUS='STOPPED'
		fi
	fi
	echo $STATUS
}

CheckReplicationStatus() {
	if [[ $SERVERMODE = 'SLAVE' ]]; then
		if [[ `CheckBaseProcess $BASEPROCESSPORT | grep 'RUNNING' | grep -v 'grep'` ]]; then
			local status=`mysql -u$DBUSER -p$DBPASS -h127.0.0.1 -P$BASEPROCESSPORT -e "SHOW SLAVE STATUS\G" 2> /dev/null | grep "Slave_SQL_Running:"  | grep -v 'grep' | tr -d ' ' | cut -d ':' -f2`
			if [[ "$status" = "Yes" ]]; then
				if [[ $OUTPUT = 'stdout' ]]; then
					STATUS='\e[32mRUNNING\e[0m'
				else
					STATUS='RUNNING'
				fi
			else
				if [[ $OUTPUT = 'stdout' ]]; then
					STATUS='\e[91mSTOPPED\e[0m'
				else
					STATUS='STOPPED'
				fi
			fi
		else
			if [[ $OUTPUT = 'stdout' ]]; then
				STATUS='\e[91mSTOPPED\e[0m'
			else
				STATUS='STOPPED'
			fi
		fi
	else
		if [[ $OUTPUT = 'stdout' ]]; then
			STATUS='\e[94mMASTER MODE\e[0m'
		else
			STATUS='MASTER MODE'
		fi
	fi
	echo $STATUS
}

CheckReplicationLag() {
	echo `mysql -u$DBUSER -p$DBPASS -h127.0.0.1 -P$BASEPROCESSPORT -e "SHOW SLAVE STATUS\G" 2> /dev/null| grep "Seconds_Behind_Master:" | tr -d ' ' | cut -d ':' -f2`
}

CheckStatus() {
	local instance=$1

	if [[ `ls $SOCKDIR/mysqld-snap-$instance.pid 2> /dev/null` ]]; then
		if [[ $OUTPUT = 'stdout' ]]; then
			if [[ `ps aux | grep snap-$instance.cnf | grep -v grep 2> /dev/null` ]]; then
				STATUS='\e[32mRUNNING\e[0m'
			else
				STATUS='\e[91mSTOPPED (PID stalled)\e[0m'
			fi
		else
			if [[ `ps aux | grep snap-$instance.cnf | grep -v grep 2> /dev/null` ]]; then
				STATUS='RUNNING'
			else
				STATUS='STOPPED (PID stalled)'
			fi
		fi
	else
		if [[ $OUTPUT = 'stdout' ]]; then
			if [[ `ps aux | grep "snap-$instance.cnf" | grep -v "grep" 2> /dev/null` ]]; then
				STATUS='\e[32mRUNNING (PID missing)\e[0m'
			else
				STATUS='\e[91mSTOPPED\e[0m'
			fi
		else
			if [[ `ps aux | grep "snap-$instance.cnf" | grep -v "grep" 2> /dev/null` ]]; then
				STATUS='RUNNING (PID missing)'
			else
				STATUS='STOPPED'
			fi
		fi
	fi
	echo $STATUS
}

GetVolumeStatus() {
	local dbdataused=`zfs get -Hp referenced $DATADIR | awk '{print $3}'`
	local dbdatalogicalused=`zfs get -Hp logicalreferenced $DATADIR | awk '{print $3}'`
	local dbdatacompressratio=`zfs get -Hp refcompressratio $DATADIR | awk '{print $3}'`
	local datasize=$dbdataused
	local usedspace=`zfs get -Hp usedbysnapshots $DATADIR | awk '{ print $3 }'`
	local logicalusedspace=`zfs get -Hp logicalused $SNAPDIR | awk '{ print $3 }'`
	local compressratio=`zfs get -Hp compressratio $SNAPDIR | awk '{ print $3 }'`
	local freespace=`zfs get -Hp available $ZFSPOOL | awk '{ print $3 }'`
	local volused=`zfs get -Hp used $ZFSPOOL | awk '{ print $3 }'`
	local volsize=$(($freespace + $volused))

	local datasizepc=$(($datasize * 100 / $volsize))
	local freespacepc=$(($freespace * 100 / $volsize))
	local usedspacepc=$(($usedspace * 100 / $volsize))

	local datasizebar=$(($datasizepc / 2))
	local freespacebar=$(($freespacepc / 2))
	local usedspacebar=$(($usedspacepc / 2))

	OUT="${OUT}\"sTotalStorageCapacity\": \"$volsize\","
	OUT="${OUT}\"sAllocatedForDb\": \"$datasize\","
	OUT="${OUT}\"sPercentAllocatedForDb\": \"$datasizepc\","
	OUT="${OUT}\"sDbDataUsed\": \"$dbdataused\","
	OUT="${OUT}\"sDbDataLogicalUsed\": \"$dbdatalogicalused\","
	OUT="${OUT}\"sDbDataCompressRatio\": \"$dbdatacompressratio\","
	OUT="${OUT}\"sAllocatedForInstances\": \"$usedspace\","
	OUT="${OUT}\"sAllocatedForInstancesLogical\": \"logicalusedspace\","
	OUT="${OUT}\"sAllocatedForInstancesCompressRatio\": \"$compressratio\","
	OUT="${OUT}\"sPercentAllocatedForInstances\": \"$usedspacepc\","
	OUT="${OUT}\"sFree\": \"$freespace\","
	OUT="${OUT}\"sPercentFree\": \"$freespacepc\""

	if [[ -n $VERB ]]; then
		echo -e "   Total storage capacity: \e[1m`NumFmt $volsize`\e[0m"
		echo -ne "Allocated for replication: \e[1m`NumFmt $datasize` \t(`printf '%2s' $datasizepc`%)\e[0m"
		echo -ne "[\e[94m`NumFmt $dbdatalogicalused`  @$dbdatacompressratio\e[0m]"
		echo
		echo -ne "  Allocated for instances: \e[1m`NumFmt $usedspace` \t(`printf '%2s' $usedspacepc`%)\e[0m"
		echo -ne "[\e[94m`NumFmt $logicalusedspace`  @$compressratio\e[0m]"
		echo
		echo -e "               Free space: \e[1m`NumFmt $freespace` \t(`printf '%2s' $freespacepc`%)\e[0m"
		echo
		echo -n " "; for i in {1..49}; do echo -ne "\e[1m-\e[0m"; done
		echo
		echo -ne "\e[1m|\e[0m"
		title="Replication data ($datasizepc%)"
		if [[ ${#title} -le $datasizebar ]]; then
			echo -ne "\e[30m\e[104m$title\e[0m"
			for i in $(seq 1 $(($datasizebar - ${#title}))); do
				echo -ne "\e[30m\e[104m \e[0m"
			done
		else
			for i in $(seq 1 $datasizebar); do
				echo -ne "\e[30m\e[104m \e[0m"
			done
		fi

		title="Used ($usedspacepc%)"
		if [[ ${#title} -le $usedspacebar ]]; then
			echo -ne "\e[30m\e[101m$title\e[0m"
			for i in $(seq 1 $(($usedspacebar - ${#title}))); do
				echo -ne "\e[30m\e[101m \e[0m"
			done
		else
			for i in $(seq 1 $usedspacebar); do
				echo -ne "\e[30m\e[101m \e[0m"
			done
		fi

		title="Free ($freespacepc%)"
		if [[ ${#title} -le $freespacebar ]]; then
			echo -ne "\e[30m\e[102m$title\e[0m"
			for i in $(seq 1 $(($freespacebar - ${#title}))); do
				echo -ne "\e[30m\e[102m \e[0m"
			done
		else
			for i in $(seq 1 $freespacebar); do
				echo -ne "\e[30m\e[102m \e[0m"
			done
		fi

		echo -e "\e[1m|\e[0m"
		echo -ne " "; for i in {1..49}; do echo -ne "\e[1m-\e[0m"; done
		echo
	fi

}

GetMemoryStatus() {
	local systotalmem=`GetMemInfo | awk -F ":" '{print $1}'`
	local systotalmem=$(( $systotalmem * 1024 * 1024 * 1024 ))
	local allocinstancesmem=`GetMemInfo | awk -F ":" '{print $2}'`
	local allocinstancesmem=$(( $allocinstancesmem * 1024 * 1024 * 1024 ))
	local sysavailablemem=`GetMemInfo | awk -F ":" '{print $3}'`
	local sysavailablemem=$(( $sysavailablemem * 1024 * 1024 * 1024 ))

	local datasizepc=$(($allocinstancesmem * 100 / $systotalmem))
	local freespacepc=$(($sysavailablemem * 100 / $systotalmem))

	local datasizebar=$(($datasizepc / 2))
	local freespacebar=$(($freespacepc / 2))

	OUT="${OUT}\"sTotalMemCapacity\": \"$systotalmem\","
	OUT="${OUT}\"sAllocatedMemForInstances\": \"$allocinstancesmem\","
	OUT="${OUT}\"sPercentAllocatedMemForInstances\": \"$datasizepc\","
	OUT="${OUT}\"sFreeMem\": \"$sysavailablemem\","
	OUT="${OUT}\"sPercentFreeMem\": \"$freespacepc\""

	if [[ -n $VERB ]]; then
		echo -e "         Total Memory capacity: \e[1m`NumFmt $systotalmem`\e[0m"
		echo -ne "Allocated Memory for instances: \e[1m`NumFmt $allocinstancesmem` \t(`printf '%2s' $datasizepc`%)\e[0m"
		echo
		echo -e "                    Free space: \e[1m`NumFmt $sysavailablemem` \t(`printf '%2s' $freespacepc`%)\e[0m"
		echo
		echo -n " "; for i in {1..49}; do echo -ne "\e[1m-\e[0m"; done
		echo
		echo -ne "\e[1m|\e[0m"
		title="Allocated ($datasizepc%)"
		if [[ ${#title} -le $datasizebar ]]; then
			echo -ne "\e[30m\e[104m$title\e[0m"
			for i in $(seq 1 $(($datasizebar - ${#title}))); do
				echo -ne "\e[30m\e[104m \e[0m"
			done
		else
			for i in $(seq 1 $datasizebar); do
				echo -ne "\e[30m\e[104m \e[0m"
			done
		fi

		title="Free ($freespacepc%)"
		if [[ ${#title} -le $freespacebar ]]; then
			echo -ne "\e[30m\e[102m$title\e[0m"
			for i in $(seq 1 $(($freespacebar - ${#title}))); do
				echo -ne "\e[30m\e[102m \e[0m"
			done
		else
			for i in $(seq 1 $freespacebar); do
				echo -ne "\e[30m\e[102m \e[0m"
			done
		fi

		echo -e "\e[1m|\e[0m"
		echo -ne " "; for i in {1..49}; do echo -ne "\e[1m-\e[0m"; done
		echo
	fi
}

GetInstancePort() {
	local instance=$1
	local port=`egrep -w '^port\s+=' $CONFDIR/snap-$instance.cnf | cut -d '=' -f2 | tr -d ' ' | uniq`

	echo "$port"
}

GetInstanceDate() {
	local instance=$1
	local cdate=`grep '###cdate' $CONFDIR/snap-$instance.cnf | cut -d '=' -f 2 | sed -e 's/^ *//g'`

	echo "$cdate"
}

GetInstanceTime() {
	local instance=$1
	local ctime=`grep '###ctime' $CONFDIR/snap-$instance.cnf | cut -d '=' -f 2 | sed -e 's/^ *//g'`

	echo "$ctime"
}

GetInstanceOrigin() {
	local instance=$1
	local origin=`zfs get origin -H -o value myzpool/mysql-snapshots/$instance | sed -e 's/@.*//' | sed -e "s/$ZFSPOOL\/$ZFSSNAPSET\///"`

	if [[ "$origin" = "$ZFSPOOL/$ZFSDATASET" ]]; then
		origin="root"
	fi

	echo "$origin"
}

GetInstanceMetas() {
	local instance=$1
	local metas=`grep '###metas' $CONFDIR/snap-$instance.cnf | cut -d '=' -f 2- | sed -e 's/^ *//g'`

	echo "$cmetas"
}

GetInstanceIpRedirects() {
	local instance=$1
	local port=`GetInstancePort $instance`
	local ipsrc=`iptables -L -n -t nat | grep $port | tr -s ' ' | cut -d ' ' -f 4 | sort | grep -v "10.90.[123456789]"`

	echo $ipsrc
}

GetInstanceSize() {
	local instance=$1

	if [[ `echo $instance | grep 'backup'` ]]; then
		local size=`zfs get -Hp used $ZFSPOOL/$ZFSDATASET@snap-$instance | awk '{ print $3 }'`
	else
		local size=`zfs get -Hp used $ZFSPOOL/$ZFSSNAPSET/$instance | awk '{ print $3 }'`
	fi

	echo "$size"
}

GetInstanceSizeFmt() {
	local value=`GetInstanceSize $1`
	echo `NumFmt $value`
}

GetInstanceVolumeUsage() {
	local instance=$1
	local volfree='n/a'

	echo "$volfree%"
}

GetInstanceMemUsage() {
	local instance=$1
	local pid=`ps aux | grep -w snap-$instance.cnf | grep mysqld | grep -v 'grep' | awk '{print $2}'`

	if [[ $pid ]]; then
		local memused=`ps -o rss --noheaders $pid`
		echo "$(( $memused * 1024 ))"
	else
		echo "---"
	fi
}

GetInstanceMemAlloc() {
	local instance=$1
	local allocated=`grep innodb_buffer_pool_size $CONFDIR/snap-$instance.cnf | cut -d 'M' -f 1 | awk '{print $3}'`

	echo "$(( $allocated * 1024 * 1024 ))"
}

GetMemInfo() {
	if [[ $MEMLIMIT -gt 0 ]]; then
		SYSTOTALMEM=$MEMLIMIT
	else
		SYSTOTALMEM=$((`free -m | grep Mem | awk '{print $2}'` / 1024 * 0.7 ))
		SYSTOTALMEM=${SYSTOTALMEM%.*}
	fi
	ALLOCINSTANCESMEM=0
	if [[ `(ls $CONFDIR/snap-* | grep -v 'backup') 2> /dev/null` ]]; then
		for allocmem in `ls $CONFDIR/snap-* | grep -v 'backup'`; do
			ALLOCINSTANCESMEM=$(($ALLOCINSTANCESMEM + `grep innodb_buffer_pool_size $allocmem | cut -d "M" -f1 | awk '{print $3}'`))
		done
		ALLOCINSTANCESMEM=$(($ALLOCINSTANCESMEM / 1024))
	fi
	SYSAVAILABLEMEM=$(($SYSTOTALMEM - $ALLOCINSTANCESMEM))

	echo "$SYSTOTALMEM:$ALLOCINSTANCESMEM:$SYSAVAILABLEMEM"
}

AddIpRedirect() {
	local ip=$1
	local instance=$2
	local port=`GetInstancePort $instance`

	if [[ `iptables -L -n -t nat | grep -w $ip | cut -d ' ' -f8 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -e "Source IP port redirect already present : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Source IP port redirect already present"
		exit $ERROR_INVALID_FUNCTIONAL_STATE
	else
		[[ -n $VERB ]] && echo -ne "Adding port redirection for source IP \e[1m$FROMIP:3306\e[0m to local instance \e[1m$instance ($port)\e[0m : "
		iptables -A PREROUTING -t nat -p tcp -s $ip --dport 3306 -j REDIRECT --to-ports $port
		[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
		iptables-save > /etc/iptables.up.rules
	fi
}

DelIpRedirect() {
	local ip=$1

	if [[ `iptables -L -n -t nat | grep "$ip" | cut -d ' ' -f8` ]]; then
		local port=`iptables -L -n -t nat | grep -w "$ip" | tr -s ' ' | cut -d ' ' -f10`
		[[ -n $VERB ]] && echo -ne "Removing port redirection for source IP \e[1m$ip:3306\e[0m : "
		iptables -D PREROUTING -t nat -p tcp -s $ip --dport 3306 -j REDIRECT --to-ports $port
		[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
		iptables-save > /etc/iptables.up.rules
	else
		[[ -n $VERB ]] && echo -e "Source IP port redirect absent : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Source IP port redirect absent"
		exit $ERROR_INCORRECT_PARAM
	fi
}

PurgeIpRedirects() {
	[[ -n $VERB ]] && echo -ne "Flushing IP based redirections : "
	iptables -F
	iptables -F -t nat
	iptables-save > /etc/iptables.up.rules
	[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
}

AddMetas() {
	local instance=$1
	local metas="$2"

	[[ -n $VERB ]] && echo -ne "Adding metas informations to instance \e[1m$instance\e[0m: "
	sed -i "/###metas/c\###metas = $metas" $CONFDIR/snap-$instance.cnf
	[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
}

NumFmt() {
        b=${1:-0}; d=''; s=0; S=(Bytes {K,M,G,T,E,P,Y,Z}B)
        while ((b > 1023)); do
                d=$((b % 1024 * 100 / 1024))
                [[ $d -gt 0 ]] && d="$(printf ".%02d" $((b % 1024 * 100 / 1024)))"
                b=$((b / 1024))
                let s++
        done
        if [[ $d = .* ]]; then
                echo "$b$d ${S[$s]}"
        else
                echo "$b ${S[$s]}"
        fi
}

List() {
	local mode=$1

	[[ -n $VERB ]] && clear
	[[ -n $VERB ]] && echo
	[[ -n $VERB ]] && echo -e "##############################################################################"
	[[ -n $VERB ]] && echo -e "##"
	[[ -n $VERB ]] && echo -e "##  MySQL Snapshots Manager"
	[[ -n $VERB ]] && echo -e "##  Host: \e[1m`hostname -f` (`hostname --ip-address | awk '{print $1}'`)\e[0m"
	[[ -n $VERB ]] && echo -e "##  Filesystem : \e[1m$FSTYPE\e[0m"
	[[ -n $VERB ]] && echo -e "##"
	[[ -n $VERB ]] && echo -e "##############################################################################"
	OUT="${OUT}\"DatabaseGlobalState\": {"
	OUT="${OUT}\"sFqdn\": \"`hostname -f`\","
	OUT="${OUT}\"sIp\": \"`hostname --ip-address | awk '{print $1}'`\","
	OUT="${OUT}\"sFs\": \"$FSTYPE\","

	[[ -n $VERB ]] && echo
	[[ -n $VERB ]] && echo -e "MySQL Main process status: [`CheckBaseProcess $BASEPROCESSPORT` / \e[1m$BASEPROCESSPORT\e[0m]"
	[[ -n $VERB ]] && echo -e "MySQL Replication status: [`CheckReplicationStatus`]"
	if [[ -n `CheckReplicationStatus | grep 'RUNNING'` ]]; then
		if [[ `CheckReplicationLag` > 0 ]]; then
			[[ -n $VERB ]] && echo -e "MySQL Replication Lag: [\e[91m`CheckReplicationLag` seconds behind Master\e[0m]"
		else
			[[ -n $VERB ]] && echo -e "MySQL Replication Lag: [\e[32m`CheckReplicationLag` seconds behind Master\e[0m]"
		fi
	fi
	OUT="${OUT}\"iReplicationPort\": $BASEPROCESSPORT,"
	OUT="${OUT}\"eBaseProcessState\": \"`CheckBaseProcess $BASEPROCESSPORT`\","
	OUT="${OUT}\"eReplicationState\": \"`CheckReplicationStatus`\","
	if [[ -n `CheckReplicationStatus | grep 'RUNNING'` ]]; then
		OUT="${OUT}\"iReplicationLag\": \"`CheckReplicationLag`\","
	else
		OUT="${OUT}\"iReplicationLag\": \"n/a\","
	fi

	[[ -n $VERB ]] && echo
	[[ -n $VERB ]] && echo -e "Memory capacity:"
	[[ -n $VERB ]] && echo -e "================"
	GetMemoryStatus
	OUT="${OUT},"

	[[ -n $VERB ]] && echo
	[[ -n $VERB ]] && echo -e "Storage capacity:"
	[[ -n $VERB ]] && echo -e "================="
	GetVolumeStatus
	OUT="${OUT},"

	[[ -n $VERB ]] && echo
	[[ -n $VERB ]] && echo -e "Existing instances:"
	[[ -n $VERB ]] && echo -e "==================="
	OUT="${OUT}\"DatabaseInstanceState\": ["

	if [[ $mode = 'BACKUP' ]]; then
		local nbinstances=`zfs list -t snapshot | grep 'backup' | awk '{print $1}' | cut -d '@' -f2 | cut -c 6- | wc -l`
		local instances=`zfs list -t snapshot | grep 'backup' | awk '{print $1}' | cut -d '@' -f2 | cut -c 6-`
	else
		local nbinstances=`ls $SNAPDIR/ | grep -v 'backup' | wc -l`
		local instances=`ls $SNAPDIR/ | grep -v 'backup'`
	fi
	local nbrunning=0
	local cnt=0

	if [[ $nbinstances -gt 0 ]]; then
		for instance in $instances; do
			local cdate=`GetInstanceDate $instance | cut -d ' ' -f1`
			local origin=`GetInstanceOrigin $instance`

			if [[ -n `GetInstanceIpRedirects $instance` ]]; then
				nbredirects=`GetInstanceIpRedirects $instance | sed 's/ /\n/g' | wc -l`
			else
				nbredirects=0
			fi

			local tmpmemusage=`GetInstanceMemUsage $instance`
			if [[ "$tmpmemusage" != "---" ]]; then
				local memusage=$tmpmemusage
				local memusagefmt=`NumFmt $memusage`
			else
				local memusage=$tmpmemusage
				local memusagefmt=$memusage
			fi
			local memalloc=`GetInstanceMemAlloc $instance`
			local memallocfmt=`NumFmt $memalloc`

			[[ -n $VERB ]] && echo -e "    ------------------------------------------------------------------------------ "
			[[ -n $VERB ]] && echo -ne "   \e[1m`printf '%-36s' "$instance [$cdate]"`\e[0m (port: "
			if [[ $nbredirects -gt 1 ]]; then
				[[ -n $VERB ]] && echo -ne "\e[93m[$nbredirects redirects]\e[0m \e[1m-> `GetInstancePort $instance`"
			elif [[ $nbredirects -eq 1 ]]; then
				[[ -n $VERB ]] && echo -ne "\e[93m`GetInstanceIpRedirects $instance`\e[0m \e[1m-> `GetInstancePort $instance`"
			else
				[[ -n $VERB ]] && echo -ne "\e[1m`GetInstancePort $instance`"
			fi
			[[ -n $VERB ]] && echo -ne "\e[0m)\n"

			[[ -n $VERB ]] && echo -ne "        => "
			[[ -n $VERB ]] && echo -e "replicated from: $origin"

			[[ -n $VERB ]] && echo -ne "        => "
			[[ -n $VERB ]] && echo -ne "size: \e[94m`GetInstanceSizeFmt $instance`\e[0m \t"
			[[ -n $VERB ]] && echo -ne "\t"
			[[ -n $VERB ]] && echo -ne "memory used: \e[94m$memusagefmt / $memallocfmt\e[0m \t"
			[[ -n $VERB ]] && echo -e  " : `CheckStatus $instance`"
			[[ `CheckStatus $instance | grep "RUNNING"` ]] && nbrunning=$(( nbrunning + 1 ))
			OUT="${OUT}{"
			[[ $OUTPUT = 'json' ]] && GetStatus $instance
			OUT="${OUT}}"
			cnt=$(($cnt + 1))
			[[ $cnt -lt $nbinstances ]] && OUT="${OUT},"
		done
	else
		[[ -n $VERB ]] && echo -e "    ------------------------------------------------------------------------------ "
		[[ -n $VERB ]] && echo -e "    \e[1m< no instance created >\e[0m"
	fi

	[[ -n $VERB ]] && echo -e "    ------------------------------------------------------------------------------ "
	[[ -n $VERB ]] && echo -e "Total: \e[1m$nbinstances\e[0m instances created, $nbrunning running\n"
	OUT="${OUT}]}"
}

GetStatus() {
	local instance=$1
	local origin=`GetInstanceOrigin $1`

	if [[ -f $CONFDIR/snap-$instance.cnf ]]; then
		local cdate=`GetInstanceDate $instance`
		local ctime=`GetInstanceTime $instance`
		local metas=`GetInstanceMetas $instance`

		local tmpmemusage=`GetInstanceMemUsage $instance`
		if [[ "$tmpmemusage" != "---" ]]; then
			local memusage=$tmpmemusage
			local memusagefmt=`NumFmt $memusage`
		else
			local memusage=$tmpmemusage
			local memusagefmt=$memusage
		fi
		local memalloc=`GetInstanceMemAlloc $instance`
		local memallocfmt=`NumFmt $memalloc`

		[[ -n $VERB ]] && clear
		[[ -n $VERB ]] && echo -e "Detailed informations:"
		[[ -n $VERB ]] && echo -e "======================"
		[[ -n $VERB ]] && echo -e "Instance name : \e[1m$instance\e[0m [`CheckStatus $instance`]"
		[[ -n $VERB ]] && echo -e "Creation date : \e[1m$cdate\e[0m"
		[[ -n $VERB ]] && echo
		[[ -n $VERB ]] && echo -e "Port : \e[1m`GetInstancePort $instance`\e[0m"
		OUT="${OUT}\"DatabaseProperties\": {"
		OUT="${OUT}\"sInstanceId\": \"$instance\","
		OUT="${OUT}\"sOrigin\": \"$origin\","
		OUT="${OUT}\"iPort\": `GetInstancePort $instance`,"
		OUT="${OUT}\"sIP\": \"`hostname --ip-address | awk '{print $1}'`\""
		OUT="${OUT}},"
		OUT="${OUT}\"eState\": \"`CheckStatus $instance`\","
		OUT="${OUT}\"dCreationDate\": \"$ctime\","

		if [[ -n `GetInstanceIpRedirects $instance` ]]; then
			nbredirects=`GetInstanceIpRedirects $instance | sed 's/ /\n/g' | wc -l`
		else
			nbredirects=0
		fi
		local cnt=0

		OUT="${OUT}\"aFromIpPortRedirects\": ["
		if [[ $nbredirects -gt 1 ]]; then
			[[ -n $VERB ]] && echo -e "Source based IP redirections: "
			for line in `GetInstanceIpRedirects $instance`; do
				[[ -n $VERB ]] && echo -e "\t\e[93m$line\e[0m"
				OUT="${OUT}\"$line\""
				cnt=$(($cnt + 1))
				[[ $cnt -lt $nbredirects ]] && OUT="${OUT},"
			done
		elif [[ $nbredirects -eq 1 ]]; then
			[[ -n $VERB ]] && echo -e "Source based IP redirections: \e[93m`GetInstanceIpRedirects $instance`\e[0m"
			OUT="${OUT}\"`GetInstanceIpRedirects $instance`\""
		else
			[[ -n $VERB ]] && echo -e "Source based IP redirections: \e[1m<none>\e[0m"
		fi
		OUT="${OUT}],"

		[[ -n $VERB ]] && echo
		[[ -n $VERB ]] && echo -e "Memory usage: \e[94m$memusagefmt / $memallocfmt\e[0m"
		OUT="${OUT}\"sMemUsed\": \"$memusage\","
		OUT="${OUT}\"sMemAllocated\": \"$memalloc\","

		[[ -n $VERB ]] && echo
		[[ -n $VERB ]] && echo -ne "Storage capacity: "
		[[ -n $VERB ]] && echo -ne "\e[1m`GetInstanceSizeFmt $instance`\e[0m"

		OUT="${OUT}\"sSizeTotal\": \"`GetInstanceSize $instance`\","

		[[ -n $VERB ]] && echo
		if [[ -n $metas ]]; then
			if [[ $metas = "{metas}" ]]; then
				[[ -n $VERB ]] && echo -e "Metas : \e[1m<none>\e[0m"
				OUT="${OUT}\"sMetas\": {}"
			else
				[[ -n $VERB ]] && echo -e "Metas :"
				[[ -n $VERB ]] && echo -e "\e[1m`echo $metas | python -m json.tool`\e[0m"
				OUT="${OUT}\"sMetas\": $metas"
			fi
		else
			[[ -n $VERB ]] && echo -e "Metas : \e[1m<none>\e[0m"
			OUT="${OUT}\"sMetas\": {}"
		fi
	else
		[[ -n $VERB ]] && echo -e "Instance \e[1m$instance\e[0m does not exist : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INSTANCE_DOES_NOT_EXIST $LINENO "Instance $instance does not exist"
		exit $ERROR_INSTANCE_DOES_NOT_EXIST
	fi
}

Start() {
	local instance=$1

	if [[ -f $CONFDIR/snap-$instance.cnf ]]; then
		if [[ `CheckStatus $instance | grep "RUNNING" | grep -v "PID" 2> /dev/null` ]]; then
			[[ -n $VERB ]] && echo -e "Instance already running : \e[91mERROR\e[0m"
			[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Instance already running"
			exit $ERROR_INVALID_FUNCTIONAL_STATE
		else
			if [[ -n $FROMIP ]]; then
				AddIpRedirect $FROMIP $instance
			fi

			if [[ `echo $instance | grep 'backup'` ]]; then
				[[ -n $VERB ]] && echo -n "Mounting snapshot ... "
				zfs clone $ZFSPOOL/$ZFSDATASET@snap-$instance $ZFSPOOL/$ZFSSNAPSET/$instance
				if [[ $? ]]; then
					[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
				else
					[[ -n $VERB ]] && echo -e "Unable to mount snapshot : \e[91mERROR\e[0m"
					[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INFRA $LINENO "Unable to mount snapshot"
					exit $ERROR_INFRA
				fi
			fi

			[[ -n $VERB ]] && echo -ne "Starting instance \e[1m$instance\e[0m : "
			mysqld --defaults-file=$CONFDIR/snap-$instance.cnf 2> /dev/null &
			while true; do
				if [[ `CheckStatus $instance | grep "PID\|STOPPED" 2> /dev/null` ]]; then
					[[ -n $VERB ]] && echo -ne ". "
				else
					break
				fi
				#sleep 1
			done
			[[ -n $VERB ]] && echo -e "\nInstance \e[1m$instance (`GetInstancePort $instance`)\e[0m : `CheckStatus $instance`"
			return 0
		fi
	else
		[[ -n $VERB ]] && echo -e "Instance \e[1m$instance\e[0m does not exist : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INSTANCE_DOES_NOT_EXIST $LINENO "Instance $instance does not exist"
		exit $ERROR_INSTANCE_DOES_NOT_EXIST
	fi
}

Refresh() {
	local instance=$1

	if [[ -f $CONFDIR/snap-$instance.cnf ]]; then
		local instancePort=`egrep -w '^port\s+=' $CONFDIR/snap-$instance.cnf | awk '{print $3}'`
		local instanceMemSize=$((`grep innodb_buffer_pool_size $CONFDIR/snap-$instance.cnf | cut -d 'M' -f 1 | awk '{print $3}'`/ 1024))
		Delete $instance
		Create $instance $instanceMemSize $instancePort
	else
		[[ -n $VERB ]] && echo -e "Instance \e[1m$instance\e[0m does not exist : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INSTANCE_DOES_NOT_EXIST $LINENO "Instance $instance does not exist"
		exit $ERROR_INSTANCE_DOES_NOT_EXIST
	fi
}

Stop() {
	local instance=$1

	if [[ `CheckStatus $instance | grep "STOPPED" 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -e "Instance already stopped : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Instance already stopped"
		exit $ERROR_INVALID_FUNCTIONAL_STATE
	else
		if [[ -n $FROMIP ]]; then
			DelIpRedirect $FROMIP $instance
		fi
		kill `cat $SOCKDIR/mysqld-snap-$instance.pid`
		[[ -n $VERB ]] && echo -ne "Stopping instance \e[1m$instance (`GetInstancePort $instance`)\e[0m : "
		while true; do
			if [[ `CheckStatus $instance | grep "RUNNING" 2> /dev/null` ]]; then
				[[ -n $VERB ]] && echo -ne ". "
			else
				break
			fi
			#sleep 1
		done

		if [[ `echo $instance | grep 'backup'` ]]; then
			sleep 3
			zfs destroy -R $ZFSPOOL/$ZFSSNAPSET/$instance
		fi

		[[ -n $VERB ]] && echo -e "[`CheckStatus $instance`]"
	fi
}

Kill() {
	local instance=$1

	if [[ `CheckStatus $instance | grep "STOPPED" 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -e "Instance already stopped : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Instance already stopped"
		exit $ERROR_INVALID_FUNCTIONAL_STATE
	else
		if [[ -n $FROMIP ]]; then
			DelIpRedirect $FROMIP $instance
		fi
		kill -9 `cat $SOCKDIR/mysqld-snap-$instance.pid`
		rm -f $SOCKDIR/mysqld-snap-$instance.pid
		rm -f $SOCKDIR/mysqld-snap-$instance.sock
		rm -f $SOCKDIR/mysqld-snap-$instance.sock.lock
		#sleep 1

		[[ -n $VERB ]] && echo -ne "Stopping instance \e[1m$instance (`GetInstancePort $instance`)\e[0m : "
		while true; do
			if [[ `CheckStatus $instance | grep "RUNNING" 2> /dev/null` ]]; then
				[[ -n $VERB ]] && echo -ne ". "
			else
				break
			fi
			#sleep 1
		done

		if [[ `echo $instance | grep 'backup'` ]]; then
			sleep 3
			zfs destroy -R $ZFSPOOL/$ZFSSNAPSET/$instance
		fi

		[[ -n $VERB ]] && echo -e "[`CheckStatus $instance`]"
		return 0
	fi
}

StartReplication() {
	if [[ `CheckReplicationStatus | grep "STOPPED" 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -ne "Starting replication process ... "
		mysql -u$DBUSER -p$DBPASS -e 'START SLAVE;' 2> /dev/null
		#sleep 1
		[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
	else
		[[ -n $VERB ]] && echo -e "Replication process already running : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Replication process already running"
		exit $ERROR_INVALID_FUNCTIONAL_STATE
	fi
}

StopReplication() {
	if [[ `CheckReplicationStatus | grep "RUNNING" 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -ne "Stopping replication process ... "
		mysql -u$DBUSER -p$DBPASS -e 'STOP SLAVE;' 2> /dev/null
		#sleep 1
		[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
	else
		[[ -n $VERB ]] && echo -e "Replication process already stopped : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Replication process already stopped"
		exit $ERROR_INVALID_FUNCTIONAL_STATE
	fi
}

CreateBackup() {
	local now=`date +"%Y%m%d-%H%M"`
	local instance="backup-$now"

	Create "$instance" "x" "x" "BACKUP"
}

ClearBackups() {
	local i=0
	for backup in `ls $CONFDIR/ | grep 'backup' | cut -c 6- | sed 's/.\{4\}$//' | sort -r`; do
		existingbackups[$i]=$backup
		i=$(( $i + 1 ))
	done
	local existingbackupsnum=${#existingbackups[@]}

	if [[ $existingbackupsnum -ge $BACKUPNUM ]]; then
		echo "Max number of backups reached, rotating ..."
		x=$existingbackupsnum
		while [[ $x -ge $BACKUPNUM ]]; do
			x=$(( $x - 1 ))
			Delete ${existingbackups[$x]}
		done
	fi
}

Create() {
	local instance=$1
	[[ $2 != 'x' ]] && local instancemem=$2
	[[ $3 != 'x' ]] && local port=$3
	local mode=$4

	CheckSlotAvail

	if [[ -n $EXEC ]]; then
		if [[ ! -x $EXEC ]]; then
			[[ -n $VERB ]] && echo -e "Post-create script \e[1m$EXEC\e[0m does not exist or is not executable : \e[91mERROR\e[0m"
			[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Post-create script $EXEC does not exist or is not executable"
			exit $ERROR_INVALID_FUNCTIONAL_STATE
		fi
	fi

	if [[ `ls $CONFDIR/snap-$instance.cnf 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -e "Instance \e[1m$instance\e[0m already exists : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INVALID_FUNCTIONAL_STATE $LINENO "Instance $instance already exists"
		exit $ERROR_INVALID_FUNCTIONAL_STATE
	fi

	if [[ $mode = "BACKUP" ]]; then
		ClearBackups
	fi

	[[ -n $VERB ]] && echo -e "Creating new instance : \e[1m$instance\e[0m ..."

	[[ -n $VERB ]] && echo -n "  ==> Locking database replication ..."
	if [[ $mode = "BACKUP" ]]; then
		( mysqladmin -u$DBUSER -p$DBPASS -h127.0.0.1 -P$BASEPROCESSPORT shutdown &> /dev/null ) &
		sleep 2
		while true; do
			if [[ `ps aux | grep 'mysqld.pid' | grep -v 'grep' | awk '{print $2}' 2> /dev/null` -gt 0 ]]; then
				[[ -n $VERB ]] && echo -ne "."
			else
				break
			fi
			sleep 1
		done
	fi
	[[ -n $VERB ]] && echo -e " [\e[32mdone\e[0m]"

	[[ -n $VERB ]] && echo -ne "  ==> Allocating new snapshot \e[1msnap-$instance\e[0m ... "
	zfs snapshot $ZFSPOOL/$ZFSDATASET@snap-$instance > /dev/null
	if [[ `zfs list -t snapshot | grep snap-$instance 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
	else
		[[ -n $VERB ]] && echo -e "Unable to create snapshot : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INFRA $LINENO "Unable to create snapshot"
		exit $ERROR_INFRA
	fi

	[[ -n $VERB ]] && echo -n "  ==> Unlocking database replication ... "
	if [[ $mode == "BACKUP" ]]; then
		( systemctl start mysql &> /dev/null & )
	fi
	[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"

	if [[ $mode != "BACKUP" ]]; then
		[[ -n $VERB ]] && echo -n "  ==> Mounting snapshot ... "
		zfs clone $ZFSPOOL/$ZFSDATASET@snap-$instance $ZFSPOOL/$ZFSSNAPSET/$instance
		if [[ $? ]]; then
			[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
		else
			[[ -n $VERB ]] && echo -e "Unable to mount snapshot : \e[91mERROR\e[0m"
			[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INFRA $LINENO "Unable to mount snapshot"
			exit $ERROR_INFRA
		fi
	fi

	[[ -n $VERB ]] && echo -ne "  ==> Acquiring new port for instance \e[1m$instance\e[0m ... "

	if [[ -z $port ]]; then
		provports=`egrep -w '^port\s+=' $CONFDIR/* | grep -v "{port}" | awk '{print $3}' | uniq | sort`
		provports=($provports)
		firstport=`egrep -w '^port\s+=' $CONFDIR/* | grep -v "{port}" | awk '{print $3}' | uniq | sort | head -n1`
		lastport=`egrep -w '^port\s+=' $CONFDIR/* | grep -v "{port}" | awk '{print $3}' | uniq | sort | tail -n1`
		i=1

		if [[ $firstport -gt $BASEPORT ]]; then
			port=$BASEPORT
		elif [[ $lastport -ge $BASEPORT ]]; then
			for j in ${provports[@]}; do
				current=$j
				next=${provports[$i]}
				expected=$(($current + 1))
				if [[ $next -ne $expected ]]; then
					port=$expected
					break
				fi
				i=$(($i + 1))
			done
		else
			port=$BASEPORT
		fi
	fi

	[[ -n $VERB ]] && echo -e "port: \e[1m$port\e[0m [\e[32mdone\e[0m]"

	[[ -n $VERB ]] && echo -ne "  ==> Generating configuration file ... "
	if [[ -f $CONFDIR/$CONFTPL ]]; then
		cp $CONFDIR/$CONFTPL $CONFDIR/snap-$instance.cnf
		now=$(date +"%Y-%m-%d %H:%M")
		now2=$(date +"%s")
		sed -i "s/{instance}/$instance/g" $CONFDIR/snap-$instance.cnf
		sed -i "s/{port}/$port/g" $CONFDIR/snap-$instance.cnf
		sed -i "s={snapdir}=$SNAPDIR=g" $CONFDIR/snap-$instance.cnf
		sed -i "/###cdate/c\###cdate = $now" $CONFDIR/snap-$instance.cnf
		sed -i "/###ctime/c\###ctime = $now2" $CONFDIR/snap-$instance.cnf
		if [[ $instancemem ]]; then
			allocmem=$(( $instancemem * 1024 ))
		else
			allocmem=$(( $MEMPERINSTANCE * 1024 ))
		fi
		nbmempools=$(( $allocmem / 1024 ))
		sed -i "s/{nbmempools}/$nbmempools/g" $CONFDIR/snap-$instance.cnf
		sed -i "s/{allocmem}/$allocmem/g" $CONFDIR/snap-$instance.cnf
		if [[ `ls $CONFDIR/snap-$instance.cnf 2> /dev/null` ]]; then
			[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
		else
			[[ -n $VERB ]] && echo -e "Unable to generate configuration file : \e[91mERROR\e[0m"
			[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INFRA $LINENO "Unable to generate configuration file"
			exit $ERROR_INFRA
		fi
	else
		[[ -n $VERB ]] && echo -e "Template file $CONFDIR/$CONFTPL does not exist : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INFRA $LINENO "Template file $CONFDIR/$CONFTPL does not exist"
		exit $ERROR_INFRA
	fi

	[[ $mode != "BACKUP" ]] && Start $instance

	# Execute post-create script
	if [[ -n $EXEC ]]; then
		sleep 2
		[[ -n $VERB ]] && echo -e "  ==> Applying Post-create script \e[1m$EXEC\e[0m on instance \e[1m$instance\e[0m ... "
		dbgPrt 'rgrey' "    $( $EXEC $port )"
	fi

	[[ $OUTPUT = 'json' ]] && GetStatus $instance
	return 0
}

Delete() {
	local instance=$1

	if [[ ! -f $CONFDIR/snap-$instance.cnf ]]; then
		[[ -n $VERB ]] && echo -e "Instance $INSTANCE does not exist : \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INSTANCE_DOES_NOT_EXIST $LINENO "Instance $INSTANCE does not exist"
		exit $ERROR_INVALID_FUNCTIONAL_STATE
	fi

	local port=`egrep -w '^port\s+=' $CONFDIR/snap-$instance.cnf | cut -d '=' -f2 | sed -e 's/^[ \t]*//'`
	local ipsrc=`GetInstanceIpRedirects $instance`

	[[ -n $VERB ]] && echo -e "Deleting instance : \e[1m$instance ($port)\e[0m ..."

	if [[ `CheckStatus $instance | grep "RUNNING" 2> /dev/null` ]]; then
		[[ -n $VERB ]] && echo -e "  Instance \e[1m$instance\e[0m is running ..."
		[[ -n $VERB ]] && echo -ne "  ==> "
		Kill $instance
	fi
	#sleep 2
	sleep 1

	if [[ $ipsrc ]]; then
		[[ -n $VERB ]] && echo -e "  IP based redirection found ..."
		for ip in $ipsrc; do
			[[ -n $VERB ]] && echo -ne "  ==> "; DelIpRedirect $ip
		done
	fi

	if [[ `echo $instance | grep -v 'backup'` ]]; then
		[[ -n $VERB ]] && echo -ne "  ==> Unmounting snapshot : "
		zfs destroy -R $ZFSPOOL/$ZFSSNAPSET/$instance
		[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"
	fi

	[[ -n $VERB ]] && echo -ne "  ==> Destroying snapshot : "
	local snapshot=$(zfs list -t snapshot | awk '{ print $1 }' | egrep "@snap-$instance$")

	if [[ -z "$snapshot" ]]; then
		[[ -n $VERB ]] && echo -e "Snapshot not found for Instance $INSTANCE: \e[91mERROR\e[0m"
		[[ $OUTPUT = 'json' ]] && JsonError $ERROR_SNAPSHOT_NOT_FOUND $LINENO "Snapshot not found for Instance $INSTANCE"
		exit $ERROR_SNAPSHOT_NOT_FOUND
	fi

	zfs destroy -R "$snapshot" > /dev/null
	[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"

	[[ -n $VERB ]] && echo -ne "  ==> Purging configuration file : "
	rm -f $CONFDIR/snap-$instance.cnf
	[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"

	[[ -n $VERB ]] && echo -ne "  ==> Cleaning up logs : "
	rm -f /var/log/mysql/mysql-snap-$instance.err
	[[ -n $VERB ]] && echo -e "[\e[32mdone\e[0m]"

	[[ -n $VERB ]] && echo -e "\nInstance \e[1m$instance ($port)\e[0m deleted : [\e[32mdone\e[0m]"
	return 0
}

Purge() {
	[[ -n $VERB ]] && echo -e "Purging instances ..."
	[[ -n $VERB ]] && echo -e "====================="
	for instance in `ls $SNAPDIR/`; do
		[[ -n $VERB ]] && echo -e "\n=============================================================\n"
		Delete $instance
	done
}

PurgeAll() {
	[[ -n $VERB ]] && echo -e "Purging instances ..."
	[[ -n $VERB ]] && echo -e "====================="
	for instance in `ls $CONFDIR | grep '.cnf' | cut -c 6- | sed 's/.\{4\}$//'`; do
		[[ -n $VERB ]] && echo -e "\n=============================================================\n"
		Delete $instance
	done
}

JsonOutput() {
	OUT="${OUT}}"
	if [[ $JSONFORMAT = 'pretty' ]]; then
		echo $OUT | python -m json.tool
	else
		echo $OUT
	fi
	exit 0
}

JsonError() {
	script=$0
	code=$1
	line=$2
	message=$3
	server="`hostname`"

	OUT="${OUT}\"Exception\": {"
	OUT="${OUT}\"message\": \"$message\","
	OUT="${OUT}\"code\": $code,"
	OUT="${OUT}\"line\": $line,"
	OUT="${OUT}\"script\": \"$script\","
	OUT="${OUT}\"server\": \"$server\""
	OUT="${OUT}}"

	JsonOutput
}

dbgPrt() {
    # only 1 argument ? then its the message
    if [[ $# -lt 2 ]]; then
        local message=$1
    else
        local message=$2
        local color=$1
    fi

    [[ -z $color ]] && color="\e[39m"
    [[ $color = 'bold' ]] && color="\e[1m"
    [[ $color = 'red' ]] && color="\e[91m"
    [[ $color = 'green' ]] && color="\e[92m"
    [[ $color = 'yellow' ]] && color="\e[93m"
    [[ $color = 'blue' ]] && color="\e[94m"
    [[ $color = 'magenta' ]] && color="\e[95m"
    [[ $color = 'cyan' ]] && color="\e[96m"
    [[ $color = 'rred' ]] && color="\e[41m\e[30m"
    [[ $color = 'rgreen' ]] && color="\e[42m\e[30m"
    [[ $color = 'ryellow' ]] && color="\e[103m\e[30m"
    [[ $color = 'rblue' ]] && color="\e[44m\e[30m"
    [[ $color = 'rmagenta' ]] && color="\e[45m\e[30m"
    [[ $color = 'rcyan' ]] && color="\e[46m\e[30m"
    [[ $color = 'rgrey' ]] && color="\e[100m"

    echo -e "${color}${message}\e[0m"
}


###############################################################################
# Various checks                                                              #
###############################################################################
# Check for run as zimbra user
ID=`id -u -n`
if [ x$ID != "xroot" ]; then
	echo "Please run as ROOT user"
	echo "Exiting..."
	exit $ERROR_INCORRECT_PARAM
fi


# no arguments, leave
if [[ $# -lt 1 ]]; then
	Usage $0
	exit $ERROR_INCORRECT_PARAM
fi


###############################################################################
# Main loop                                                                   #
###############################################################################
# Execute getopt on the arguments passed to this program, identified by the special character $@
PARSED_OPTIONS=$(getopt -n "$0"  -o hvqo:c:be:f:F:lLg:d:pPr:R:x:w:yzm:tTnM:Z --long "help,verbose,quiet,output:,create:,backup,exec:,from-ip:,from-replica:,list,list-backups,get-status:,delete:,purge,purge-all,run:,refresh:,stop:,add-redirect:,del-redirect,purge-redirects,add-metas:,stop-replication,start-replication,noconfirm"  -- "$@")

#Bad arguments, something has gone wrong with the getopt command.
if [ $? -ne 0 ] ; then
	Usage $0
	exit $ERROR_INCORRECT_PARAM
fi

# A little magic, necessary when using getopt.
eval set -- "$PARSED_OPTIONS"

# Now goes through all the options with a case and using shift to analyse 1 argument at a time.
while true ; do
	case "$1" in

		-h|--help)
			Usage $0
			exit 0
			shift;;

		-v|--verbose)
			VERB='verbose'
			shift;;

		-F|--from-replica)
			ZFSDATASET="${ZFSSNAPSET}/$2"
			shift 2;;

		-q|--quiet)
			VERB=''
			shift;;

		-o|--output)
			if [[ $2 = 'stdout' ]]; then
				OUTPUT=$2
				VERB='verbose'
			elif [[ $2 = 'json' ]]; then
				OUTPUT=$2
				VERB=''
			else
				echo -e "Output format not supported or misspelled (possible values \e[1mstdout\e[0m|\e[1mjson\e[0m) :  \e[91mERROR\e[0m"
				exit $ERROR_INCORRECT_PARAM
			fi
			shift 2;;

		-b|--backup)
			CMD='CREATEBACKUP'
			shift;;

		-c|--create)
			CMD='CREATE'
			INSTANCE=`echo $2 | awk -F ":" '{print $1}'`
			INSTANCEMEM=`echo $2 | awk -F ":" '{print $2}'`
			INSTANCEPORT=`echo $2 | awk -F ":" '{print $3}'`
			[[ -z "$INSTANCEMEM" ]] && INSTANCEMEM=$MEMPERINSTANCE

			SYSTOTALMEM=`GetMemInfo | awk -F ":" '{print $1}'`
			ALLOCINSTANCESMEM=`GetMemInfo | awk -F ":" '{print $2}'`
			SYSAVAILABLEMEM=`GetMemInfo | awk -F ":" '{print $3}'`

			if [[ $INSTANCEMEM ]]; then
				if ! [[ $INSTANCEMEM =~ ^[0-9]+$ ]] ; then
					[[ -n $VERB ]] && echo -e "Wrong memory size parameter, must be an integer between \e[1m$MEMPERINSTANCE GB\e[0m and \e[1m$SYSAVAILABLEMEM GB\e[0m :  \e[91mERROR\e[0m"
					[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Wrong memory size parameter, must be an integer between $MEMPERINSTANCE GB and $SYSAVAILABLEMEM GB"
					exit $ERROR_INCORRECT_PARAM
				fi

				if [[ $INSTANCEMEM -lt $MEMPERINSTANCE ]] ; then
					[[ -n $VERB ]] && echo -e "Wrong memory size parameter, must be \e[1m>=$MEMPERINSTANCE GB\e[0m :  \e[91mERROR\e[0m"
					[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Wrong memory size parameter, must be >=$MEMPERINSTANCE GB"
					exit $ERROR_INCORRECT_PARAM
				fi

				if [[ $INSTANCEMEM -gt $SYSAVAILABLEMEM ]] ; then
					[[ -n $VERB ]] && echo -e "Wrong memory size parameter, \e[1m$SYSAVAILABLEMEM GB\e[0m memory available :  \e[91mERROR\e[0m"
					[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Wrong memory size parameter, $SYSAVAILABLEMEM GB memory available"
					exit $ERROR_INCORRECT_PARAM
				fi
			fi

			if [[ $INSTANCEPORT ]]; then
				if ! [[ $INSTANCEPORT =~ ^[0-9]+$ ]] ; then
					[[ -n $VERB ]] && echo -e "Wrong port parameter, must be an integer \e[1m>$BASEPORT\e[0m :  \e[91mERROR\e[0m"
					[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Wrong port parameter, must be an integer >$BASEPORT"
					exit $ERROR_INCORRECT_PARAM
				fi

				if [[ $INSTANCEPORT -lt $BASEPORT ]] ; then
					[[ -n $VERB ]] && echo -e "Wrong port parameter, must be \e[1m>$BASEPORT\e[0m :  \e[91mERROR\e[0m"
					[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Wrong port parameter, must be >$BASEPORT"
					exit $ERROR_INCORRECT_PARAM
				fi

				if [[ `ls $CONFDIR/snap-* 2> /dev/null` ]]; then
					allocatedports=( $(egrep -w '^port\s+=' $CONFDIR/snap-* | awk '{print $3}' | sort) )
					for allocport in ${allocatedports[@]}; do
						if [[ $INSTANCEPORT -eq $allocport ]]; then
							[[ -n $VERB ]] && echo -e "Wrong port parameter, port \e[1m$INSTANCEPORT\e[0m already in use:  \e[91mERROR\e[0m"
							[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Wrong port parameter, port $INSTANCEPORT already in use"
							exit $ERROR_INCORRECT_PARAM
						fi
					done
				fi
			fi
			shift 2;;

		-e|--exec)
			EXEC=$2
			shift 2;;

		-f|--from-ip)
			FROMIP=$2
			shift 2;;

		-l|--list)
			CMD='LIST'
			shift;;

		-L|--list-backups)
			CMD='LISTBACKUPS'
			shift;;

		-g|--get-status)
			CMD='GET-STATUS'
			INSTANCE=$2
			shift 2;;

		-d|--delete)
			CMD='DELETE'
			INSTANCE=$2
			shift 2;;

		-p|--purge)
			CMD='PURGE'
			shift;;

		-P|--purge-all)
			CMD='PURGEALL'
			shift;;

		-r|--run)
			CMD='START'
			INSTANCE=$2
			shift 2;;

		-R|--refresh)
			CMD='REFRESH'
			INSTANCE=$2
			shift 2;;

		-x|--stop)
			CMD='STOP'
			INSTANCE=$2
			shift 2;;

		-w|--add-redirect)
			CMD='ADD-REDIRECT'
			INSTANCE=$2
			shift 2;;

		-y|--del-redirect)
			CMD='DEL-REDIRECT'
			shift;;

		-z|--purge-redirects)
			CMD='PURGE-REDIRECTS'
			shift;;

		-m|--add-metas)
			CMD='ADD-METAS'
			INSTANCE=`echo $2 | cut -d ':' -f1`
			METAS=`echo $2 | cut -d ':' -f 2-`
			shift 2;;

		-t|--stop-replication)
			CMD='STOP-REPLICATION'
			shift;;

		-T|--start-replication)
			CMD='START-REPLICATION'
			shift;;

		-n|--noconfirm)
			NOCONFIRM='yes'
			shift;;

		-M|--monitor)
			while true; do $0 -l; sleep $2; done
			shift 2;;

				--)
			shift
			break;;
	esac
done

case $CMD in
	'CREATE' )
		Create $INSTANCE $INSTANCEMEM $INSTANCEPORT
	;;

	'CREATEBACKUP' )
		CreateBackup
	;;

	'DELETE' )
		if [[ -n $VERB ]]; then
			if [[ -z $NOCONFIRM ]]; then
				echo -e "WARNING : instance \e[1m$INSTANCE\e[0m will be destroyed, this operation cannot be undone !"
				read -p "Continue ? y/N " -n 1 -r
				echo
				if [[ ! $REPLY =~ ^[Yy]$ ]]; then
					echo -e "bye bye coward !\n"
					exit 0
				fi
			fi
		fi
		Delete $INSTANCE
	;;

	'PURGE' )
		if [[ -n $VERB ]]; then
			if [[ -z $NOCONFIRM ]]; then
				echo -e "WARNING : All instances will be destroyed, this operation cannot be undone !"
				read -p "Continue ? y/N " -n 1 -r
				echo
				if [[ ! $REPLY =~ ^[Yy]$ ]]; then
					echo -e "bye bye coward !\n"
					exit 0
				fi
			fi
		fi
		Purge
	;;

	'PURGEALL' )
		if [[ -n $VERB ]]; then
			if [[ -z $NOCONFIRM ]]; then
				echo -e "WARNING : All instances and backups will be destroyed, this operation cannot be undone !"
				read -p "Continue ? y/N " -n 1 -r
				echo
				if [[ ! $REPLY =~ ^[Yy]$ ]]; then
					echo -e "bye bye coward !\n"
					exit 0
				fi
			fi
		fi
		PurgeAll
	;;

	'LIST' )
		List
	;;

	'LISTBACKUPS' )
		List 'BACKUP'
	;;

	'GET-STATUS' )
		GetStatus $INSTANCE
	;;

	'START' )
		Start $INSTANCE
	;;

	'REFRESH' )
		Refresh $INSTANCE
	;;

	'STOP' )
		Stop $INSTANCE
	;;

	'ADD-REDIRECT' )
		if [[ -n $FROMIP ]]; then
			CheckIP $FROMIP
			AddIpRedirect $FROMIP $INSTANCE
		else
			[[ -n $VERB ]] && echo -e "Missing -f|--from-ip parameter : \e[91mERROR\e[0m"
			[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Missing -f|--from-ip parameter"
			exit $ERROR_INCORRECT_PARAM
		fi
	;;

	'DEL-REDIRECT' )
		if [[ -n $FROMIP ]]; then
			if [[ -n $VERB ]]; then
				if [[ -z $NOCONFIRM ]]; then
					echo -e "WARNING : Port redirect for ip \e[1m$FROMIP\e[0m will be removed, this operation cannot be undone !"
					read -p "Continue ? y/N " -n 1 -r
					echo
					if [[ ! $REPLY =~ ^[Yy]$ ]]; then
						echo -e "bye bye\n"
						exit 0
					fi
				fi
			fi
			CheckIP $FROMIP
			DelIpRedirect $FROMIP
		else
			[[ -n $VERB ]] && echo -e "Missing -f|--from-ip parameter : \e[91mERROR\e[0m"
			[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Missing -f|--from-ip parameter"
			exit $ERROR_INCORRECT_PARAM
		fi
	;;

	'PURGE-REDIRECTS' )
		if [[ -n $VERB ]]; then
			if [[ -z $NOCONFIRM ]]; then
				echo "WARNING : All port redirects will be removed, this operation cannot be undone !"
				read -p "Continue ? y/N " -n 1 -r
				echo
				if [[ ! $REPLY =~ ^[Yy]$ ]]; then
					echo -e "bye bye\n"
					exit 0
				fi
			fi
		fi
		PurgeIpRedirects
	;;

	'ADD-METAS' )
		if [[ -f $CONFDIR/snap-$INSTANCE.cnf ]]; then
			if [[ `echo "$METAS" | python -m json.tool 2> /dev/null` ]]; then
				AddMetas $INSTANCE "$METAS"
			else
				[[ -n $VERB ]] && echo -e "Something is wrong with your metas informations (absent or wrong json construct) : \e[91mERROR\e[0m"
				[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INCORRECT_PARAM $LINENO "Something is wrong with your metas informations (absent or wrong json construct)"
				exit $ERROR_INCORRECT_PARAM
			fi
		else
			[[ -n $VERB ]] && echo -e "Instance \e[1m$INSTANCE\e[0m does not exist :  \e[91mERROR\e[0m"
			[[ $OUTPUT = 'json' ]] && JsonError $ERROR_INSTANCE_DOES_NOT_EXIST $LINENO "Instance $INSTANCE does not exist"
			exit $ERROR_INSTANCE_DOES_NOT_EXIST
		fi
	;;

	'STOP-REPLICATION' )
		StopReplication
	;;

	'START-REPLICATION' )
		StartReplication
	;;

esac

[[ $OUTPUT = 'json' ]] && JsonOutput

LANG=$OLDLANG
exit 0
