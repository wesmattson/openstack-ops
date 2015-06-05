#
# For use by Private Cloud team.  May safely be removed.
#
#

# Executing over ssh, don't be so noisy or needy
[ $TERM == "dumb" ] && S=1 Q=1

if [  ! "$OS_USERNAME" ]; then
  echo "Source your credentials first."
  return
fi

[ ${Q=0} -eq 0 ] && echo
[ ${Q=0} -eq 0 ] && echo "Importing Private Cloud Common Functions..."

HZ=`getconf CLK_TCK`

################
[ ${Q=0} -eq 0 ] && echo "  - ix() - Quickly post things to ix.io"
function ix() { curl -F 'f:1=<-' http://ix.io < "${1:-/dev/stdin}"; }

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-hypervisor-vms() - Display all hypervisors and associated instances"
function rpc-hypervisor-vms {

which mysql > /dev/null 2>&1

if [ $? -eq 0 ]; then
  mysql -te 'select host as "Hypervisor", instances.display_name as "Instance Name",image_ref as "Image", vm_state as State, vcpus as "VCPUs", memory_mb as "RAM", root_gb as "Root", ephemeral_gb as "Ephem" from instance_system_metadata left join instances on instance_system_metadata.instance_uuid=instances.uuid where instance_uuid in (select uuid from instances where deleted = 0) and `key` = "instance_type_name" order by host,display_name' nova 
else
  echo "'mysql' not found.  Go to there."
fi

}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-hypervisor-free() - Display free resources on each Hypervisor, as reported by MySQL"
function rpc-hypervisor-free {

if [ ! -s /etc/nova/nova.conf ]; then
  NOVACONTAINER=`lxc-ls | grep nova | tail -1`

  if [ "$NOVACONTAINER" ]; then
    LXC="lxc-attach -n $NOVACONTAINER -- "
  else
    LXC=
  fi
fi

CPU_RATIO=`$LXC awk -F= '/^cpu_allocation_ratio/ {print $2}' /etc/nova/nova.conf`
RAM_RATIO=`$LXC awk -F= '/^ram_allocation_ratio/ {print $2}' /etc/nova/nova.conf`
DISK_RATIO=`$LXC awk -F= '/^disk_allocation_ratio/ {print $2}' /etc/nova/nova.conf`

[ ! "$CPU_RATIO" ] && CPU_RATIO=1 && echo "Unable to find cpu_allocation_ratio in nova.conf.  Using 1.0"
[ ! "$RAM_RATIO" ] && RAM_RATIO=1 && echo "Unable to find ram_allocation_ratio in nova.conf.  Using 1.0"
[ ! "$DISK_RATIO" ] && DISK_RATIO=1 && echo "Unable to find disk_allocation_ratio in nova.conf.  Using 1.0"

which mysql > /dev/null 2>&1

if [ $? -eq 0 ]; then
  mysql -te "select hypervisor_hostname as Hypervisor,((memory_mb*${RAM_RATIO})-memory_mb_used)/1024 as FreeMemGB,(vcpus*${CPU_RATIO})-vcpus_used as FreeVCPUs, (free_disk_gb*${DISK_RATIO}) as FreeDiskGB,running_vms ActiveVMs from compute_nodes where deleted = 0;" nova
else
  echo "'mysql' not found.  Go to there."
fi

unset CPU_RATIO RAM_RATIO
}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-filter() - Replace stinky UUIDs with refreshing descriptive names inline"
function rpc-filter {
  replist=`echo ${tenant_repl}${host_repl}${net_repl}${flav_repl}${img_repl}${user_repl} | tr -d "\n"`

  OLDIFS=$IFS
  IFS=''

  while read inputs; do
    echo $inputs | sed -e "${replist}"
  done

  IFS=$OLDIFS

  unset replist
}
################
[ ${Q=0} -eq 0 ] && echo "  - rpc-iscsi-generate-sessions() - Generate list of commands to re-initiate currently open iscsi sessions"
function rpc-iscsi-generate-sessions() {
  iscsiadm --mode session | awk '{split($3, a, ":"); print "iscsiadm -m node -T " $4 " -p " a[1] " -l"}'
}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-common-errors-scan() - Pretty much what it sounds like"
function rpc-v4-common-errors-scan() {
  echo "Checking for common issues..."

  echo -n "  - MySQL Replication "
  MYSQL_SLAVE=`mysql -e "show slave status"`
  if [ "$MYSQL_SLAVE" ]; then
    mysql -e "show slave status \G" | egrep 'Slave_(IO|SQL)_Running' | wc -l | grep 2 > /dev/null 2>&1
    [ $? -ne 0 ] && echo -n "Local Slave Broken"
    # check remote slave, too - steal from rpchousecall
  fi

  unset MYSQL_SLAVE

  echo "  - OpenVSwitch"
  # Networks without dhcp agents
  for net in `$OS_NETCMD net-list | awk '/[0-9]/ {print $2}'`; do $OS_NETCMD dhcp-agent-list-hosting-net $net | grep True > /dev/null 2>&1; [ $? -eq 0 ] && echo "        [OK] `echo $net | rpc-filter`"; done  

  # Dead taps
  ovs-vsctl show | grep -A1 \"tap | egrep "tag: 4095" > /dev/null 2>&1
  [ $? -eq 0 ] && echo "Dead Taps Detected." || echo "[OK]"

  # Network namespaces that don't exist
  # fill me in laterz

  # bridges with less than 2 ports
  for bridge in `ovs-vsctl list-br | egrep 'eth|bond'`; do 
    PORTS=`ovs-vsctl list-ports $bridge | wc -l`
    if [ $PORTS -lt 2 ]; then
      echo "  $bridge has less than two ports attached:"
      ovs-vsctl list-ports $bridge
    fi
  done

  unset PORTS

  echo "  - Operating System:"
  echo -n "  -   Disk: "
  df -P -t ext2 -t ext3 -t ext4 -t xfs -t nfs | awk '{print $5}' | tr -d \% | egrep '^[0-9]+$' | egrep '^9[0-9]' > /dev/null 2>&1
  [ $? -eq 0 ] && echo "Disk reaching capacity.  Investigate" || echo "[OK]"
  echo "Done!"

}
################
[ ${Q=0} -eq 0 ] && echo "  - rpc-bondflip() - Change given bondX to backup NIC"
function rpc-bondflip() {
  if [ $# -ne 1 ]; then
    echo "Usage: rpc-bondflip <bond>"
    return 1
  fi

  if [ ! -f /proc/net/bonding/$1 ]; then
    echo "No such bond: $1"
    return 1
  fi

  ACTIVESLAVE=`awk '/Active Slave/ { print $4 }' /proc/net/bonding/$1`
  #ifenslave -c $1 $(egrep 'Slave Interface' /proc/net/bonding/$1 | awk '{print $3}' | grep -v $ACTIVESLAVE | head -1)
  ifdown $ACTIVESLAVE > /dev/null 2>&1
  ifup $ACTIVESLAVE > /dev/null 1>&1
  NEWACTIVE=`awk '/Active Slave/ { print $4 }' /proc/net/bonding/$1`

  echo "$1 was active on $ACTIVESLAVE, now $NEWACTIVE"

  unset ACTIVESLAVE NEWACTIVE
}

################
#[ ${Q=0} -eq 0 ] && echo "  - rpc-port-stats() - Show live interface usage by port"
function rpc-port-stats() {
  echo "Don't use this yet.  Fixing it to be awesome"
  return

  if [ $# -ne 1 ]; then
    echo "Usage: rpc-port-stats <port-id>"
    return
  fi

  port=tap${1:0:11}

  if [ ! "$( echo $port | egrep '^[0-9a-z]{8}-[0-9a-z]{2}$' )" ]; then
    echo "Inavlid port: $1"
    echo "Usage: rpc-port-stats <port-id>"
    return
  fi

  echo "Using $1($port)"

  CTR=0
  while [ 1 ]; do
    br_int_port=`ovs-vsctl list-ports br-int | grep $port`
    ovs-ofctl dump-ports br-int $br_int_port > $tmpfile
    [ $? -ne 0 ] && echo "Error reading stats from OVS for $br_int_port in br-int" && return

    RX_pkts=`grep rx $tmpfile | egrep -o "pkts=[0-9]+" | cut -d= -f2`
    RX_bytes=`grep rx $tmpfile | egrep -o "bytes=[0-9]+" | cut -d= -f2`
    RX_drop=`grep rx $tmpfile | egrep -o "drop=[0-9]+" | cut -d= -f2`
    RX_errs=`grep rx $tmpfile | egrep -o "errs=[0-9]+" | cut -d= -f2`
    RX_frame=`grep rx $tmpfile | egrep -o "frame=[0-9]+" | cut -d= -f2`
    RX_over=`grep rx $tmpfile | egrep -o "over=[0-9]+" | cut -d= -f2`
    RX_crc=`grep rx $tmpfile | egrep -o "crc=[0-9]+" | cut -d= -f2`

    RX_pkts_DELTA=$(( $RX_pkts - ${RX_pkts_OLD=0} ))
    RX_bytes_DELTA=`humanize_kb $(( $RX_bytes - ${RX_bytes_OLD=0} ))`
    RX_drop_DELTA=$(( $RX_drop - ${RX_drop_OLD=0} ))
    RX_errs_DELTA=$(( $RX_errs - ${RX_errs_OLD=0} ))
    RX_frame_DELTA=$(( $RX_frame - ${RX_frame_OLD=0} ))
    RX_over_DELTA=$(( $RX_over - ${RX_over_OLD=0} ))
    RX_crc_DELTA=$(( $RX_crc  - ${RX_crc_OLD=0} ))

    RX_pkts_OLD=$RX_pkts
    RX_bytes_OLD=$RX_bytes
    RX_drop_OLD=$RX_drop
    RX_errs_OLD=$RX_errs
    RX_frame_OLD=$RX_frame
    RX_over_OLD=$RX_over
    RX_crc_OLD=$RX_crc

    TX_pkts=`grep tx $tmpfile | egrep -o "pkts=[0-9]+" | cut -d= -f2`
    TX_bytes=`grep tx $tmpfile | egrep -o "bytes=[0-9]+" | cut -d= -f2`
    TX_drop=`grep tx $tmpfile | egrep -o "drop=[0-9]+" | cut -d= -f2`
    TX_errs=`grep tx $tmpfile | egrep -o "errs=[0-9]+" | cut -d= -f2`
    TX_coll=`grep tx $tmpfile | egrep -o "coll=[0-9]+" | cut -d= -f2`

    TX_pkts_DELTA=$(( $TX_pkts - ${TX_pkts_OLD=0} ))
    TX_bytes_DELTA=`humanize_kb $(( $TX_bytes - ${TX_bytes_OLD=0} ))`
    TX_drop_DELTA=$(( $TX_drop - ${TX_drop_OLD=0} ))
    TX_errs_DELTA=$(( $TX_errs - ${TX_errs_OLD=0} ))
    TX_coll_DELTA=$(( $TX_coll - ${TX_coll_OLD=0} ))

    TX_pkts_OLD=$TX_pkts
    TX_bytes_OLD=$TX_bytes
    TX_drop_OLD=$TX_drop
    TX_errs_OLD=$TX_errs
    TX_coll_OLD=$TX_coll

    [ $(( $CTR % 5 )) -eq 0 ] && printf "%12s %12s %12s %12s\n" "RXpps" "RXBps" "TXpps" "TXBps"
    printf "%12s %12s %12s %12s\n" "$RX_pkts_DELTA" "$RX_bytes_DELTA" "$TX_pkts_DELTA" "$TX_bytes_DELTA "
    sleep 2
    CTR=$(( $CTR + 1 ))
  done

  rm $tmpfile
  unset CTR tmpfile port br_int_port 
  # Come back some day and clean up all the TX_ RX_ vars :/
  for x in RX TX; do
    for v in pkts bytes drop errs frame over crc coll; do
      for t in OLD DELTA; do
        echo unset ${x}_${v} ${x}_${v}_${t}
      done
    done
  done
}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-environment-scan() - Update list of internal filters"
function rpc-environment-scan() {
  `which keystone` > /dev/null 2>&1
  [ $? -ne 0 ] && echo "Missing local openstack binaries.  Not scanning environment." && return

  echo "Scanning environment.  Please hold..."
  echo -n "  - RPC Version "
  if [ "$( egrep DISTRIB_RELEASE /etc/rpc-release 2> /dev/null)" ]; then
    source /etc/rpc-release
    OS_VERSION=`echo $DISTRIB_RELEASE | cut -d. -f1 `
  else
    OS_VERSION="4"
  fi
  echo $OS_VERSION

  echo "  - Keystone"
  tenant_repl=`keystone tenant-list | awk '/[0-9]/ {print "s/"$2"/[[Tenant: "$4"]]/g;"}'`
  user_repl=`keystone user-list | awk '/[0-9]/ {print "s/"$2"/[[User: "$4"]]/g;"}'`

  `which neutron > /dev/null`
  if [ $? -eq 0 ]; then
    OS_NETCMD="neutron"
  else
    `which quantum > /dev/null`
    if [ $? -eq 0 ]; then
      OS_NETCMD="quantum"
    else
      OS_NETCMD="nova"
    fi
  fi

  echo "  - Networking ($OS_NETCMD)"

  net_repl=`$OS_NETCMD net-list | awk '/[0-9]/ {print "s/"$2"/[[Network: "$4"]]/g;"}'`

  echo "  - Nova"
  host_repl=`nova list | awk '/[0-9]/ {print "s/"$2"/[[Instance: "$4"]]/g;"}' 2> /dev/null`
  flav_repl=`nova flavor-list | awk -F\| '/[0-9]/ {print "s/"$3"/[[Flavor: "$8"v,"$4"M,"$5"\/"$6"G,"$7"swap]]/g;"}' | tr -d " "`

  echo "  - Glance"
  img_repl=`nova image-list | awk -F\| '/[0-9]/ {gsub(/[ ]+/, "", $2);gsub(/^ /, "", $3);print "s/"$2"/[[Img: "$3"]]/g;"}'`

  echo "Done!"
}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-os-version-check() - Are we running latest availble version?"
function rpc-os-version-check() {
  apt-cache policy nova-common | egrep 'Installed|Candidate' | cut -d: -f3 | sort -ur | wc -l | egrep 1 > /dev/null 2>&1
  [ $? -eq 0 ] && echo -n "Running Latest Available Version: " || echo -n "NOT Running Latest Available Version: "
  apt-cache policy nova-common | egrep 'Installed|Candidate' | cut -d: -f3 | sort -ur | head -1
}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-instance-test-networking() - Test instance networking."
function rpc-instance-test-networking() {
  if [ ! "$1" ]; then
    echo "Must pass instance UUID or Name"
    return
  fi

  ID=$1

  [ -s $HOME/.ssh/rpc_support ] && KEY="-i $HOME/.ssh/rpc_support"

  IP=`nova show $ID | awk -F\| '/ network / { print $3 }' | tr -d ' '`
  NETNAME=`nova show $ID | awk '/ network / { print $2 }'`

  eval `neutron net-show -Fid -f shell $NETNAME`
  NETID=$id
  unset id

  echo -ne "$NETNAME\t$IP\t"
  CMD="nc -w1 $IP 22 | grep SSH"
  NSWRAP="ip netns exec qdhcp-$NETID"
  #echo $NSWRAP $CMD
  $NSWRAP $CMD > /dev/null 2>&1 

  if [ $? -eq 0 ]; then
    echo -n "[SSH PORT: SUCCESS] "

    eval `neutron net-show -Fsubnets -f shell $NETID`
    eval `neutron subnet-show -Fgateway_ip -f shell $( echo $subnets | cut -d\  -f1)`

    if [ "$gateway_ip" ]; then
      # If we can SSH, let's ping out...
      CMD="ping -c1 -w2 8.8.8.8"
      NSWRAP="ip netns exec qdhcp-$NETID ssh -q -o StrictHostKeyChecking=no $KEY ubuntu@$IP"
      $NSWRAP $CMD > /dev/null 2>&1

      if [ $? -eq 0 ]; then
        echo "[PING GOOGLE: SUCCESS]"
        RET=0
      else
        echo "[PING GOOGLE: FAILURE]"
        RET=1
      fi
    else
      echo "[PING GOOGLE: No Gateway - SKIPPING]"
      RET=1
    fi
  else
    echo "[SSH PORT: FAILED]"
    RET=1
  fi
  unset KEY IP NETNAME NETID CMD NSWRAP
  return $RET
}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-instance-per-network() - Per network, spin up an instance on given hypervisor, ping, and tear down"
function rpc-instance-per-network() {
  UUID_LIST=""
  if [ $OS_VERSION -ge 9 ]; then 
    if [ ! "$( hostname | grep neutron_agents)" ]; then
      echo "Must be run from Neutron Agents container in order to access appropriate network namespace"
      return
    fi
  fi

  if [ ! "$1" ]; then
    echo "Must pass a compute or AZ:Compute combo."
    return
  fi

  if [ "$( echo $1 | grep : )" ]; then
    AZ=`echo $1 | cut -d: -f1`
    COMPUTE=`echo $1 | cut -d: -f2`
  else
    AZ="nova"
    COMPUTE=$1
  fi

  case $OS_VERSION in
    4) VALID_COMPUTE=`nova service-list --binary nova-compute | awk '/[0-9]/ {print $4}' | grep $COMPUTE`
    ;;
    *) VALID_COMPUTE=`nova service-list --binary nova-compute | awk '/[0-9]/ {print $6}' | grep $COMPUTE`
    ;;
  esac

  if [ ! "$VALID_COMPUTE" ]; then
    echo "Compute node $COMPUTE doesn't exist."
    unset VALID_COMPUTE AZ COMPUTE
    return
  else
    unset VALID_COMPUTE
  fi

  IMAGE=`glance image-list | awk 'tolower($4) ~ /ubuntu/ {print $2}' | tail -1`

  case $OS_VERSION in
    4)  KEYNAME="controller-id_rsa"
    ;;
    *)  KEYNAME="rpc_support"
  esac

  nova flavor-create --is-public 0 rpctest-$$-flavor rpctest-$$-flavor 512 10 1 > /dev/null 2>&1

  for NET in `$OS_NETCMD net-list | awk -F\| '$2 ~ /[0-9]+/ { print $2 }'`; do
    unset router_external
    eval `neutron net-show -Frouter:external -f shell $NET | tr : _`
    if [ "$router_external" == "True" ]; then
      echo "Skipping $NET due to router:external tag"
      continue
    fi

    echo "Spinning up instance on network $NET"
    INSTANCE_NAME="rpctest-$$-NET-${NET}"

    NEWID=`nova boot --image $IMAGE \
      --flavor ${FLAVOR=rpctest-$$-flavor} \
      --security-group rpc-support \
      --key-name $KEYNAME \
      --nic net-id=$NET \
      --availability-zone $AZ:$COMPUTE \
      $INSTANCE_NAME | awk '/ id / { print $4 }'`

    UUID_LIST="${NEWID} ${UUID_LIST}"
    unset INSTANCE_NAME
  done
  unset IMAGE router_external

  nova flavor-delete rpctest-$$-flavor > /dev/null 2>&1

  unset SPAWNED_UUID_LIST
  for UUID in $UUID_LIST; do 
    rpc-instance-waitfor-spawn $UUID 60
    SPAWNED_UUID_LIST="$UUID $SPAWNED_UUID_LIST"
  done

  unset BOOTED_UUID_LIST
  for UUID in $SPAWNED_UUID_LIST; do 
    rpc-instance-waitfor-boot $UUID 180
    BOOTED_UUID_LIST="$UUID $BOOTED_UUID_LIST"
  done
  unset SPAWNED_UUID_LIST

  echo "Testing Instances..."
  for ID in $BOOTED_UUID_LIST; do 
    rpc-instance-test-networking $ID
  done
  unset BOOTED_UUID_LIST

  echo -n "Deleting instances..."
  for ID in $UUID_LIST; do 
    echo -n "."
    nova delete $ID > /dev/null
    sleep 1
  done
  echo
  unset UUID_LIST
}

################
[ ${Q=0} -eq 0 ] && echo "  - rpc-instance-per-network-per-hypervisor() - Per network, spin up an instance on each hypervisor, ping, and tear down"
function rpc-instance-per-network-per-hypervisor() {
  if [ $OS_VERSION -ge 9 ]; then 
    if [ ! "$( hostname | grep neutron_agents)" ]; then
      echo "Must be run from Neutron Agents container in order to access network namespaces"
      return
    fi
  fi

  IMAGE=`glance image-list | awk 'tolower($4) ~ /ubuntu/ {print $2}' | tail -1`

  case $OS_VERSION in
    4)  KEYNAME="controller-id_rsa"
    ;;
    *)  KEYNAME="rpc_support"
  esac

  nova flavor-create --is-public 0 rpctest-$$-flavor rpctest-$$-flavor 512 10 1 > /dev/null 2>&1

  for NET in `$OS_NETCMD net-list | awk -F\| '$4 ~ /[0-9]+/ { print $2 }' | sort -R`; do
    unset router_external
    eval `neutron net-show -Frouter:external -f shell $NET | tr : _`
    if [ "$router_external" == "True" ]; then
      echo "Skipping $NET due to router:external tag"
      continue
    fi

    echo -n "Spinning up instance per hypervisor on network $NET..."
    UUID_LIST=""
    for COMPUTE in `nova service-list --binary nova-compute | awk '/[0-9]/ {print $4}'`; do 
      case $OS_VERSION in
        4) AZ=`nova service-list --binary nova-compute --host $COMPUTE | awk '/[0-9]/ {print $6}'`
        ;;
        *) AZ=`nova service-list --binary nova-compute --host $COMPUTE | awk '/[0-9]/ {print $8}'`
      esac 

      echo -n "."
      INSTANCE_NAME="rpctest-$$-${COMPUTE}-${NET}"

      NEWID=`nova boot --image $IMAGE \
      --flavor ${FLAVOR=rpctest-$$-flavor} \
      --security-group rpc-support \
      --key-name $KEYNAME \
      --nic net-id=$NET \
      --availability-zone ${AZ}:${COMPUTE} \
      $INSTANCE_NAME | awk '/ id / { print $4 }'`

      UUID_LIST="${NEWID} ${UUID_LIST}"
    done;
    echo

    nova flavor-delete rpctest-$$-flavor > /dev/null 2>&1

    for UUID in $UUID_LIST; do
      rpc-instance-waitfor-spawn $UUID 30
    done;

    for UUID in $UUID_LIST; do
      rpc-instance-waitfor-boot $UUID 120
    done

    for UUID in $UUID_LIST; do
      rpc-instance-test-networking $UUID
    done

    echo
    echo -n "Deleting instances..."
    for ID in $UUID_LIST; do 
      echo -n "."
      nova delete $ID > /dev/null
      sleep 1
    done
    echo;echo
    unset UUID_LIST NEWID INSTANCE_NAME TIMEOUT CTR DONE UUID
  done
  unset UUID_LIST NEWID IMAGE INSTANCE_NAME TIMEOUT CTR DONE KEY UUID
}


################
[ ${Q=0} -eq 0 ] && echo "  - rpc-sg-rules() - Makes security groups easier to read.  Pass it a Security Group ID (not name)"
function rpc-sg-rules () {
  if [ ! "$1" ]; then
    echo "Usage: rpc-sg-rules <securityGroupID>"
    return 1
  fi

  if [ "$( echo $OS_NETCMD | egrep '(neutron|quantum)')" ]; then
    RULES=`mysql -BN -e "select remote_group_id,direction,ethertype,protocol,port_range_min,port_range_max,remote_ip_prefix from securitygrouprules where security_group_id = '$1' order by direction desc,port_range_min asc" $OS_NETCMD | tr '\t' ,`
  else
    echo crap
  fi

  echo
  echo -e "Dir\tType\tProto\tPortMin\tPortMax\tRemoteIP\t\tRemoteGroupID"
  echo -e "-----------------------------------------------------------------------------------------"

  for RULE in $RULES; do
    RGID=`echo $RULE | cut -d, -f1 | sed 's/NULL/       /g'`
    DIR=`echo $RULE | cut -d, -f2 |  sed 's/NULL/_______/g'`
    ETHER=`echo $RULE | cut -d, -f3 |  sed 's/NULL/_______/g'`
    PROT=`echo $RULE | cut -d, -f4 | sed 's/NULL/_______/g'`
    PMIN=`echo $RULE | cut -d, -f5 | sed 's/NULL/_______/g'`
    PMAX=`echo $RULE | cut -d, -f6 | sed 's/NULL/_______/g'`
    RIP=`echo $RULE | cut -d, -f7 | sed 's/NULL/_______/g'`

    if [ "$RIP" == "_______" ]; then 
      RIP="$RIP\t\t"
    fi

    echo -e "$DIR\t$ETHER\t$PROT\t$PMIN\t$PMAX\t$RIP\t$RGID"
  done

  unset RULES RULE RGID DIR ETHER PROT PMIN PMAX RIP
}

[ ${Q=0} -eq 0 ] && echo "  - rpc-image-check() - Shows all running instances and the state of their base images (active/deleted)"
function rpc-image-check () {
  printf "%-37s:: %-39s:: Img State\n" "Instance ID" "Image ID"
  for i in `nova list --all- | awk '/[0-9]/ {print $2}'`; do echo -n "$i :: "; IMG=`nova show $i | awk -F\| '$2 ~ /image/ {print $3}' | egrep -o '\([0-9a-z-]+\)\s*$' | tr -d ' '`; echo -n "$IMG :: "; glance image-show ` echo $IMG | tr -d '()'` | awk '$2 ~ /status/ {print $4}'; done
}

[ ${Q=0} -eq 0 ] && echo "  - rpc-update-pccommon() - Grabs the latest version of pccommon.sh if there is one"
function rpc-update-pccommon () {
  GITHUB="https://raw.githubusercontent.com/rsoprivatecloud/pubscripts/master/pccommon.sh"

  [ !"$1" ] && PCCOMMON="./pccommon.sh" || PCCOMMON=$1
  if [ -s "$PCCOMMON" ]; then

    TMPFILE="/tmp/$$.pccommon.upgrade"
    curl -s $GITHUB > $TMPFILE 2>&1
    if [ $? -ne 0 ]; then
      echo "Error connecting to github - not attempting pccommon upgrade."
      rm -f $TMPFILE 
      return 1
    fi

    EXISTING_SUM=`md5sum  $PCCOMMON | cut -d\  -f1`
    GITHUB_SUM=`md5sum $TMPFILE | cut -d\  -f1`

    if [ "$EXISTING_SUM" != "$GITHUB_SUM" ]; then
      echo
      echo "**********************************************"
      echo "New Version available, upgrading and executing"
      echo "**********************************************"
      mv $TMPFILE $PCCOMMON
      . $PCCOMMON
    else
      echo "Running latest available version of pccommon"
    fi
  fi
}

# Shows swap usage per process
[ ${Q=0} -eq 0 ] && echo "  - swap-usage() - Shows current usage of swap memory, by process"
function swap-usage
{
  if [ $UID -ne 0 ]; then
    echo "Must be run as root"
    return
  fi

  for PID in `ps -A -o \%p --no-headers | egrep -o '[0-9]+'` ; do
    if [ -d /proc/$PID ]; then
      PROGNAME=`cat /proc/$PID/cmdline | tr '\000' '\t'  | cut -f1`
      for SWAP in `grep Swap /proc/$PID/smaps 2>/dev/null| awk '{ print $2 }'`; do
        SUM=$(( $SUM+$SWAP ))
      done
      [ $SUM -ne 0 ] && echo "PID=$PID - Swap used: ${SUM}kb - ( $PROGNAME )"
      OVERALL=$(( $OVERALL+$SUM ))
      SUM=0
    fi
  done

  if [ $OVERALL -gt $(( 1024 * 1024 )) ]; then
    HUMAN="$( echo 2 k $OVERALL 1024 /  1024 / p | dc )GB"
  else
    if [ $OVERALL -gt 1024 ]; then
      HUMAN="$( echo 2 k $OVERALL 1024 / p | dc )MB"
    else
      HUMAN="${OVERALL}KB"
    fi
  fi

  echo "Overall swap used: ${HUMAN}"

  unset HUMAN OVERALL SUM PID
}

################
# Unlisted helper functions

function rpc-instance-waitfor-spawn() {
  if [ $# -ne 2 ]; then
    echo -e "Usage: rpc-instance-waitfor-spawn <instance> <timeout>"
    return
  fi
 
  ID=$1
  SPAWN_TIMEOUT=$2
 
  echo -n "-- Waiting up to $SPAWN_TIMEOUT seconds for $ID to spawn..."
  CTR=0
  STATE=`nova show $ID | awk '/status/ { print $4 }'`
  while [ "${STATE="BUILD"}" == "BUILD" -a $CTR -lt $SPAWN_TIMEOUT ]; do
    STATE=`nova show $ID | awk '/status/ { print $4 }'`
    CTR=$(( $CTR + 2 ))
    echo -n "."
    sleep 2
  done
  unset DONE ID 

  if [ $CTR -ge $SPAWN_TIMEOUT ]; then
    echo "Timed out"
    RET=1
  else
    if [ "$STATE" != "ACTIVE" ]; then
      echo "*ERROR*"
      RET=2
    else
      echo "Done"
      RET=0
    fi
  fi
  
  unset STATE
  return $RET
}

function rpc-instance-waitfor-boot() {
  if [ $# -ne 2 ]; then
    echo -e "Usage: rpc-instance-waitfor-boot <instance> <timeout>"
    return 1
  fi

  ID=$1
  BOOT_TIMEOUT=$2

  echo -n "-- Waiting up to $BOOT_TIMEOUT seconds for $ID to boot..."

  nova show $ID > /dev/null 2>&1
  [ $? -gt 0 ] && echo "$ID Broken somehow.  Giving Up." && return 3

  CTR=0
  nova console-log $ID 2> /dev/null | egrep -i '^cloud-init .* finished' > /dev/null 2>&1
  R=$?
  while [ ${R} -gt 0 -a $CTR -lt $BOOT_TIMEOUT ]; do
    CTR=$(( $CTR + 5 ))
    sleep 5
    echo -n "."
    nova console-log $ID 2> /dev/null | egrep -i '^cloud-init .* finished' > /dev/null 2>&1
    R=$?
  done
  unset NEWID

  if [ $CTR == $BOOT_TIMEOUT ]; then
    echo "Timed out"
    RET=1
  else
    echo "Done"
    RET=0
  fi

  unset BOOT_TIMEOUT SPAWN_TIMEOUT CTR
  return $RET
}

function pid_start {
	SYS_START=`cat /proc/uptime | cut -d\  -f1 | cut -d. -f1`
	PROC_START=`cat /proc/$1/stat | cut -d\  -f22`
	PROC_START=$(( $PROC_START / $HZ ))
	PROC_UPTIME=$(( $SYS_START - $PROC_START ))
	PROC_START=`date -d "-${PROC_UPTIME} seconds"`
	echo "$PROC_START"
}

function pid_age {
	SYS_START=`cat /proc/uptime | cut -d\  -f1 | cut -d. -f1`
	PROC_START=`cat /proc/$1/stat | cut -d\  -f22`
	PROC_START=$(( $PROC_START / $HZ ))
	UPSEC=$(( $SYS_START - $PROC_START ))
	UPMIN=$(( $UPSEC / 60 ))
	UPHR=$(( $UPSEC / 60 / 60 ))
	UPDAY=$(( $UPSEC / 60 / 60 / 24 ))
	DAYHR=$(( $UPDAY * 24 )); UPHR=$(( $UPHR - $DAYHR ))
	HRMIN=$(( $UPHR * 60 )); UPMIN=$(( $UPMIN - $HRMIN ))
	MINSEC=$(( $UPDAY * 24 * 60 * 60 + $UPHR * 60 * 60 + $UPMIN * 60 )); UPSEC=$(( $UPSEC - $MINSEC ))
	echo "${UPDAY}d, ${UPHR}h, ${UPMIN}m, ${UPSEC}s"
}

function humanize_kb () {

  scale=( K M G T P E )

  if [ $# -ne 1 ]; then
    echo "Usage: humanize_kb <value>"
    return
  fi

  val=$1

  while [ $val -gt $(( 1024  * 1024 )) ]; do
    val=$( echo $val 1024 / p | dc )
    power=$(( ${power=0} + 1 ))
  done

  final=`echo 3 k $val 1024 / p | dc`

  echo "$final${scale[${power=0}]}"

  unset power final val
}

[ ${Q=0} -eq 0 ] && echo "Done!"

ip netns | grep '^vips$' > /dev/null 2>&1
[ $? -eq 0 ] && HA=1

if [ ${S=0} -eq 0 ]; then
  rpc-environment-scan
fi

#rpc-update-pccommon
