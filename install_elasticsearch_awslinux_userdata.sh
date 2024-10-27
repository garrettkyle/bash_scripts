#!/bin/bash
set -x

# Script assumes that AWS CLI is installed as part of the base AMI and that the desired EBS volume and ENI have been created in the same
# AZ as the instance

##################################   VARIABLES     #################################################
# ================================================================================================================

# General/Shared
ES_DATA_1_ENI_IP_ADDRESS="10.0.1.15"
ES_DATA_2_ENI_IP_ADDRESS="10.0.1.16"
ES_INGEST_1_ENI_IP_ADDRESS="10.0.1.13"
ES_INGEST_2_ENI_IP_ADDRESS="10.0.1.14"
ES_MASTER_1_ENI_IP_ADDRESS="10.0.1.10"
ES_MASTER_2_ENI_IP_ADDRESS="10.0.1.11"
ES_MASTER_3_ENI_IP_ADDRESS="10.0.1.12"
SERVERNAME="es-data-1"
WORKING_DIR="/tmp"

# ElasticSearch
EBS_VOLUME_NAME="es_data_1_data_volume"
ELASTICSEARCH_BINARY_FILENAME="elasticsearch-7.0.0-x86_64.rpm"
ELASTICSEARCH_CLUSTER_NAME="testcluster"
ELASTICSEARCH_CONFIG_DIRECTORY="/elasticsearch/es-data-1/config"
ELASTICSEARCH_DATA_DIRECTORY="/elasticsearch/es-data-1/data"
ELASTICSEARCH_DATA_NODE="true"
ELASTICSEARCH_DOWNLOAD_URL="https://foo.com/misc/elasticco"
ELASTICSEARCH_FOLDER="/elasticsearch/es-data-1"
ELASTICSEARCH_INGEST_NODE="false"
ELASTICSEARCH_LOG_DIRECTORY="/elasticsearch/es-data-1/logs"
ELASTICSEARCH_MASTER_NODE="false"
ELASTICSEARCH_PORT="9200"
ENI_NAME="es_data_1_eni"

##################################   DEPENDENCY INSTALLATION    #################################################
# ================================================================================================================

# Set SERVERNAME
echo "127.0.0.1 $SERVERNAME" >> /etc/hosts
echo "$ES_DATA_1_ENI_IP_ADDRESS $SERVERNAME" >> /etc/hosts
rm -f /etc/hostname
echo "$SERVERNAME" >> /etc/hostname
hostname "$SERVERNAME"

# Install dependencies
yum install wget -y

# Make directory for ElasticSearch data volume to mount to
mkdir -p /elasticsearch

#######################  EBS VOLUME MOUNTING, FORMATTING AND CONFIGURATION ################################

# Attach the ElasticSearch EBS volume
INSTANCEID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
EBS_DATA_VOLUME=$(aws ec2 --region ca-central-1 describe-volumes --filters Name=tag-key,Values="Name" Name=tag-value,Values="$EBS_VOLUME_NAME" --query 'Volumes[*].{ID:VolumeId}' --output text)

aws ec2 --region ca-central-1 attach-volume --volume-id "$EBS_DATA_VOLUME" --instance-id $INSTANCEID --device "/dev/xvdf"
aws ec2 --region ca-central-1 wait volume-in-use --volume-id "$EBS_DATA_VOLUME"
sleep 30 # allows time for volume to be attached

# Format the volume (force if volume already formatted due to previous tests,
# this script should never be used as an ASG userdata script)
mkfs -t xfs -f /dev/xvdf

# Mount the volume
mount /dev/xvdf /elasticsearch

# Create the ElasticSearch data folder
mkdir -p "$ELASTICSEARCH_DATA_DIRECTORY"

# Create the ElasticSearch log folder
mkdir -p "$ELASTICSEARCH_LOG_DIRECTORY"

# Create the ElasticSearch config folder
mkdir -p "$ELASTICSEARCH_CONFIG_DIRECTORY"

#######################  ENI INTERFACE ATTACHMENT/CONFIGURATION ################################

# Obtain ENI id number for the network interface
ENI_ID=$(aws ec2 --region ca-central-1 describe-network-interfaces --filters Name=description,Values=$ENI_NAME --query '"NetworkInterfaces"[*].[NetworkInterfaceId]' --output text)

# Attach the ENI to the instance
aws ec2 --region ca-central-1 attach-network-interface --device-index 1 --instance-id "$INSTANCEID" --network-interface-id "$ENI_ID"

# Sleep for 30s otherwise eth1 is not available before the commands below are processed
sleep 30

# Perform various steps outlined here to bring external NIC online
# https://aws.amazon.com/premiumsupport/knowledge-center/ec2-centos-rhel-secondary-interface/
echo "NM_CONTROLLED=no" >> /etc/sysconfig/network-scripts/ifcfg-eth0
MAC_ADDRESS=$(ifconfig eth1 | grep ether | awk '{ print $2 }')

# Create ethernet interface config file for ENI
touch "$WORKING_DIR"/ifcfg-eth1
cat << EOF > "$WORKING_DIR"/ifcfg-eth1
DEVICE=eth1
NAME=eth1
HWADDR=$MAC_ADDRESS
BOOTPROTO=dhcp
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
NM_CONTROLLED=no
EOF
mv "$WORKING_DIR"/ifcfg-eth1 /etc/sysconfig/network-scripts/ifcfg-eth1

# Set eth0 as the gateway device
echo "GATEWAYDEV=eth0" >> /etc/sysconfig/network

# Prevent cloud-init from reversing these changes
echo "network:
 ; config: disabled" >>  /etc/cloud/cloud.cfg 

# Prevent network manager from reverting these changes
systemctl stop NetworkManager
systemctl disable NetworkManager

# Restart network
systemctl restart network

# Obtain default gateway IP
GATEWAY=$(ip route | grep default | awk '{ print $3 }')

# Add required routing table entries
ip route add default via "$GATEWAY" dev eth1 table 1000
ip route add "$ES_DATA_1_ENI_IP_ADDRESS" dev eth1 table 1000
ip rule add from "$ES_DATA_1_ENI_IP_ADDRESS" lookup 1000

# Create secondary static route file for interface
touch "$WORKING_DIR"/route-eth1
cat << EOF > "$WORKING_DIR"/route-eth1
default via $GATEWAY dev eth1 table 1000
$ES_DATA_1_ENI_IP_ADDRESS dev eth1 table 1000
EOF
mv "$WORKING_DIR"/route-eth1 /etc/sysconfig/network-scripts/route-eth1

# Create rule file for interface
touch "$WORKING_DIR"/rule-eth1
cat << EOF > "$WORKING_DIR"/rule-eth1
from $ES_DATA_1_ENI_IP_ADDRESS lookup 1000
EOF
mv "$WORKING_DIR"/rule-eth1 /etc/sysconfig/network-scripts/rule-eth1

# Bring the eth1 online
ifup eth1

##################################   ELASTICSEARCH INSTALLATION    #################################################
# ================================================================================================================

# Install ElasticSearch
yum install "$ELASTICSEARCH_DOWNLOAD_URL"/"$ELASTICSEARCH_BINARY_FILENAME" -y

# Backup original ElasticSearch config file (/etc/sysconfig/elasticsearch) installed by the RPM
mv /etc/sysconfig/elasticsearch /etc/sysconfig/elasticsearch.backup

# Create and configure new elasticsearch configuration file
touch "$WORKING_DIR"/elasticsearch
cat << EOF > "$WORKING_DIR"/elasticsearch
# Elasticsearch home directory
#ES_HOME=/usr/share/elasticsearch
#JAVA_HOME=
# Elasticsearch configuration directory
ES_PATH_CONF=$ELASTICSEARCH_CONFIG_DIRECTORY
# Elasticsearch PID directory
#PID_DIR=/var/run/elasticsearch
# Additional Java OPTS
#ES_JAVA_OPTS=
# The number of seconds to wait before checking if Elasticsearch started successfully as a daemon process
ES_STARTUP_SLEEP_TIME=5
EOF
mv "$WORKING_DIR"/elasticsearch /etc/sysconfig/elasticsearch

# Set permissions on config file
chmod 644 /etc/sysconfig/elasticsearch

# Copy various config files from ddefault location to location ElasticSearch expects
cp /etc/elasticsearch/* /usr/share/elasticsearch/
cp /etc/elasticsearch/* "$ELASTICSEARCH_CONFIG_DIRECTORY"/

# Create and configure elasticsearch.yml configuration file
touch "$WORKING_DIR"/elasticsearch.yml
cat << EOF > "$WORKING_DIR"/elasticsearch.yml
cluster.name: $ELASTICSEARCH_CLUSTER_NAME
node.name: $SERVERNAME
#node.attr.rack: r1
path.data: $ELASTICSEARCH_DATA_DIRECTORY
path.logs: $ELASTICSEARCH_LOG_DIRECTORY
network.host: $ES_DATA_1_ENI_IP_ADDRESS
http.port: $ELASTICSEARCH_PORT
# Specify which nodes are configured to be master nodes in the cluster (required to join cluster)
discovery.seed_hosts: [$ES_MASTER_1_ENI_IP_ADDRESS, $ES_MASTER_2_ENI_IP_ADDRESS, $ES_MASTER_3_ENI_IP_ADDRESS,$ES_INGEST_1_ENI_IP_ADDRESS,$ES_INGEST_2_ENI_IP_ADDRESS,$ES_DATA_1_ENI_IP_ADDRESS,$ES_DATA_2_ENI_IP_ADDRESS]
# Specify which nodes are eligible to be master nodes in the cluster
cluster.initial_master_nodes: [$ES_MASTER_1_ENI_IP_ADDRESS, $ES_MASTER_2_ENI_IP_ADDRESS, $ES_MASTER_3_ENI_IP_ADDRESS]
#
# Block initial recovery after a full cluster restart until N nodes are started:
#gateway.recover_after_nodes: 3
node.master: $ELASTICSEARCH_MASTER_NODE
node.data: $ELASTICSEARCH_DATA_NODE
node.ingest: $ELASTICSEARCH_INGEST_NODE
EOF
mv -f "$WORKING_DIR"/elasticsearch.yml "$ELASTICSEARCH_CONFIG_DIRECTORY"/elasticsearch.yml

# Backup original ElasticSearch service file (/usr/lib/systemd/system/elasticsearch.service) installed by the RPM
mv /usr/lib/systemd/system/elasticsearch.service /usr/lib/systemd/system/elasticsearch.service.backup

# Create and configure new ElasticSearch service file
touch "$WORKING_DIR"/elasticsearch.service
cat << EOF > "$WORKING_DIR"/elasticsearch.service
[Unit]
Wants=network-online.target
After=network-online.target
[Service]
RuntimeDirectory=elasticsearch
PrivateTmp=true
Environment=ES_HOME=/usr/share/elasticsearch
Environment=ES_PATH_CONF=$ELASTICSEARCH_CONFIG_DIRECTORY
Environment=PID_DIR=/var/run/elasticsearch
EnvironmentFile=-/etc/sysconfig/elasticsearch
WorkingDirectory=/usr/share/elasticsearch
User=elasticsearch
Group=elasticsearch
ExecStart=/usr/share/elasticsearch/bin/elasticsearch -p /var/run/elasticsearch/elasticsearch.pid --quiet
StandardOutput=journal
StandardError=inherit
LimitNOFILE=65535
LimitNPROC=4096
LimitAS=infinity
LimitFSIZE=infinity
TimeoutStopSec=0
KillSignal=SIGTERM
KillMode=process
SendSIGKILL=no
SuccessExitStatus=143
[Install]
WantedBy=multi-user.target
EOF
mv "$WORKING_DIR"/elasticsearch.service /usr/lib/systemd/system/

# Configure permissions on service file
chmod 644 /usr/lib/systemd/system/elasticsearch.service

# Allow ElasticSearch traffic through the firewall
iptables -I INPUT -j ACCEPT
iptables-save > /etc/sysconfig/iptables

# Make ElasticSearch user the owner of the folders
chown -R elasticsearch:elasticsearch /elasticsearch

# Enable OS to pick up on the addition of the elasticsearch service
systemctl daemon-reload

# Enable the ElasticSearch service to start at boot
systemctl enable elasticsearch.service

# Remount /tmp with exec permissions
mount /tmp -o remount,exec

# Start the ElasticSearch service
systemctl start elasticsearch.service

# Test the service locally
# curl -X GET "$ES_MASTER_3_ENI_IP_ADDRESS:9200/" > "$WORKING_DIR"/local_elasticsearch_healthcheck.txt

# Test cluster health
#curl -X GET "$ES_MASTER_3_ENI_IP_ADDRESS:9200/_cluster/health" > "$WORKING_DIR"/local_elasticsearch_healthcheck.txt