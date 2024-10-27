#!/bin/bash
set -x

# Script assumes that AWS CLI is installed as part of the base AMI and that the desired EBS volume and ENI have been created in the same
# AZ as the instance

##################################   VARIABLES     #################################################
# ================================================================================================================

# General/Shared
WORKING_DIR="/tmp"
SERVERNAME="kafka-node-1"
KAFKA_NODE_1_ENI_IP_ADDRESS="10.21.130.184"
KAFKA_NODE_2_ENI_IP_ADDRESS="10.21.130.171"
KAFKA_NODE_3_ENI_IP_ADDRESS="10.21.130.174"
KAFKA_NODE_4_ENI_IP_ADDRESS="10.21.130.239"
KAFKA_NODE_5_ENI_IP_ADDRESS="10.21.130.220"
EBS_VOLUME_NAME="kafka_node_1_data_volume"
ENI_NAME="kafka_node_1_eni"

# Zookeeper
ZOOKEEPER_DOWNLOAD_URL="https://foo.com/misc/kafka"
ZOOKEEPER_BINARY_FILENAME="zookeeper-3.4.14.tar.gz"
ZOOKEEPER_DIRECTORY="/kafka/kafka-node-1/zookeeper"
ZOOKEEPER_USERNAME="zookeeper"
ZOOKEEPER_DATA_DIRECTORY="/kafka/kafka-node-1/zookeeper/data"

# Kafka
KAFKA_DOWNLOAD_URL="https://foo.com/misc/kafka"
KAFKA_BINARY_FILENAME="kafka_2.12-2.1.1.tgz"
KAFKA_DIRECTORY="/kafka/kafka-node-1/kafka"
KAFKA_USERNAME="kafka"
KAFKA_DATA_DIRECTORY="/kafka/kafka-node-1/kafka/data"
KAFKA_BROKER_ID_NUMBER="1"

# Filebeat
FILEBEAT_CONFIG_DIRECTORY="/kafka/kafka-node-1/filebeat/config"
FILEBEAT_LOG_DIRECTORY="/kafka/kafka-node-1/filebeat/logs"

##################################   DEPENDENCY INSTALLATION    #################################################
# ================================================================================================================

# Set SERVERNAME
echo "127.0.0.1 $SERVERNAME" >> /etc/hosts
echo "$KAFKA_NODE_1_ENI_IP_ADDRESS $SERVERNAME" >> /etc/hosts
rm -f /etc/hostname
echo "$SERVERNAME" >> /etc/hostname
hostname "$SERVERNAME"

# Install dependencies
yum install wget java-1.8.0-openjdk-devel -y

# Make directory for Kafka data volume to mount to
mkdir -p /kafka

#######################  EBS VOLUME MOUNTING, FORMATTING AND CONFIGURATION ################################

# Attach the ElasticSearch EBS volume
INSTANCEID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
EBS_DATA_VOLUME=$(aws ec2 --region ca-central-1 describe-volumes --filters Name=tag-key,Values="Name" Name=tag-value,Values="$EBS_VOLUME_NAME" --query 'Volumes[*].{ID:VolumeId}' --output text)

# Force Detach the EBS volume if already in use
aws ec2 --region ca-central-1 detach-volume --volume-id "$EBS_DATA_VOLUME" --force

# Attach EBS volume
aws ec2 --region ca-central-1 attach-volume --volume-id "$EBS_DATA_VOLUME" --instance-id $INSTANCEID --device "/dev/xvdf"

# Wait for EBS volume to be attached
aws ec2 --region ca-central-1 wait volume-in-use --volume-id "$EBS_DATA_VOLUME"
sleep 30 # allows time for volume to be attached

# Mount the volume
mount /dev/xvdf /kafka

# Mount the volume at boot
echo "/dev/xvdf       /kafka   xfs    defaults,nofail        0       2" >> /etc/fstab


#######################  ENI INTERFACE ATTACHMENT/CONFIGURATION ################################

# Obtain ENI id number for the network interface
ENI_ID=$(aws ec2 --region ca-central-1 describe-network-interfaces --filters Name=description,Values=$ENI_NAME --query '"NetworkInterfaces"[*].[NetworkInterfaceId]' --output text)

# Ensure the ENI is detached
ENI_ATTACHMENT_ID=$(aws ec2 --region ca-central-1 describe-network-interfaces --filters Name=description,Values=$ENI_NAME --query '"NetworkInterfaces"[*]."Attachment".[AttachmentId]' --output text)
aws ec2 --region ca-central-1 detach-network-interface --attachment-id "$ENI_ATTACHMENT_ID" --force

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
ip route add "$KAFKA_NODE_1_ENI_IP_ADDRESS" dev eth1 table 1000
ip rule add from "$KAFKA_NODE_1_ENI_IP_ADDRESS" lookup 1000

# Create secondary static route file for interface
touch "$WORKING_DIR"/route-eth1
cat << EOF > "$WORKING_DIR"/route-eth1
default via $GATEWAY dev eth1 table 1000
$KAFKA_NODE_1_ENI_IP_ADDRESS dev eth1 table 1000
EOF
mv "$WORKING_DIR"/route-eth1 /etc/sysconfig/network-scripts/route-eth1

# Create rule file for interface
touch "$WORKING_DIR"/rule-eth1
cat << EOF > "$WORKING_DIR"/rule-eth1
from $KAFKA_NODE_1_ENI_IP_ADDRESS lookup 1000
EOF
mv "$WORKING_DIR"/rule-eth1 /etc/sysconfig/network-scripts/rule-eth1

# Bring the eth1 online
ifup eth1

##################################   ZOOKEEPER INSTALLATION    #################################################
# ================================================================================================================

# Create zookeeper service user
useradd "$ZOOKEEPER_USERNAME"

# Add zookeeper service user to wheel group THIS LINE MIGHT BE ABLE TO BE REMOVED
usermod -aG wheel "$ZOOKEEPER_USERNAME"

# Edit sudoers to allow zookeeper to use systemctl to manipulate the service
echo '# Allow zookeeper user to start the zookeeper.service' | sudo EDITOR='tee -a' visudo
echo "$ZOOKEEPER_USERNAME ALL=NOPASSWD: /bin/systemctl start zookeeper.service" | sudo EDITOR='tee -a' visudo
echo "$ZOOKEEPER_USERNAME ALL=NOPASSWD: /bin/systemctl stop zookeeper.service" | sudo EDITOR='tee -a' visudo
echo "$ZOOKEEPER_USERNAME ALL=NOPASSWD: /bin/systemctl reload zookeeper.service" | sudo EDITOR='tee -a' visudo
echo "$ZOOKEEPER_USERNAME ALL=NOPASSWD: /bin/systemctl restart zookeeper.service" | sudo EDITOR='tee -a' visudo
echo "$ZOOKEEPER_USERNAME ALL=NOPASSWD: /bin/systemctl status zookeeper.service" | sudo EDITOR='tee -a' visudo

# Create zookeeper service
touch "$WORKING_DIR"/zookeeper.service
cat << EOF > "$WORKING_DIR"/zookeeper.service
[Unit]
Requires=network.target remote-fs.target
After=network.target remote-fs.target
[Service]
Type=forking
User=$ZOOKEEPER_USERNAME
ExecStart=$ZOOKEEPER_DIRECTORY/bin/zkServer.sh start $ZOOKEEPER_DIRECTORY/conf/zoo.cfg
ExecStop=$ZOOKEEPER_DIRECTORY/bin/zkServer.sh stop
ExecReload=$ZOOKEEPER_DIRECTORY/bin/zkServer.sh restart
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
EOF
mv "$WORKING_DIR"/zookeeper.service /etc/systemd/system/

# Configure permissions on service file
chmod 644 /etc/systemd/system/zookeeper.service

##################################   KAFKA INSTALLATION    #################################################
# ================================================================================================================

# Create kafka service user
useradd "$KAFKA_USERNAME"

# Add kafka service user to wheel group THIS LINE MIGHT BE ABLE TO BE REMOVED
usermod -aG wheel "$KAFKA_USERNAME"

# Edit sudoers to allow kafka to use systemctl to manipulate the service
echo '# Allow kafka user to start the kafka.service' | sudo EDITOR='tee -a' visudo
echo "$KAFKA_USERNAME ALL=NOPASSWD: /bin/systemctl start kafka.service" | sudo EDITOR='tee -a' visudo
echo "$KAFKA_USERNAME ALL=NOPASSWD: /bin/systemctl stop kafka.service" | sudo EDITOR='tee -a' visudo
echo "$KAFKA_USERNAME ALL=NOPASSWD: /bin/systemctl reload kafka.service" | sudo EDITOR='tee -a' visudo
echo "$KAFKA_USERNAME ALL=NOPASSWD: /bin/systemctl restart kafka.service" | sudo EDITOR='tee -a' visudo
echo "$KAFKA_USERNAME ALL=NOPASSWD: /bin/systemctl status kafka.service" | sudo EDITOR='tee -a' visudo

# Create kafka service
touch "$WORKING_DIR"/kafka.service
cat << EOF > "$WORKING_DIR"/kafka.service
[Unit]
Requires=network.target remote-fs.target
After=network.target remote-fs.target
[Service]
Type=simple
User=$KAFKA_USERNAME
ExecStart=$KAFKA_DIRECTORY/bin/kafka-server-start.sh $KAFKA_DIRECTORY/config/server.properties
ExecStop=$KAFKA_DIRECTORY/bin/kafka-server-stop.sh
ExecReload=$KAFKA_DIRECTORY/bin/kafka-server-stop.sh && $KAFKA_DIRECTORY/bin/kafka-server-start.sh $KAFKA_DIRECTORY/config/server.properties
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
EOF
mv "$WORKING_DIR"/kafka.service /etc/systemd/system/

# Configure permissions on service file
chmod 644 /etc/systemd/system/kafka.service

# Allow Kafka/Zookeeper traffic through the firewall
iptables -I INPUT -j ACCEPT
iptables-save > /etc/sysconfig/iptables

# Allow zookeeper to start at boot
systemctl enable zookeeper.service

# Allow kafka to start at boot
systemctl enable kafka.service

# Start zookeeper
systemctl start zookeeper.service

# Start kafka
systemctl start kafka.service

##################################   FILEBEAT INSTALLATION     #################################################
# Install filebeat
yum install filebeat-6.6.2 -y

# Backup original service file
mv /usr/lib/systemd/system/filebeat.service /usr/lib/systemd/system/filebeat.service.backup

# Create new filebeat service file
touch "$WORKING_DIR"/filebeat.service
cat << EOF > "$WORKING_DIR"/filebeat.service
[Unit]
Description=Filebeat sends log files to Logstash or directly to Elasticsearch.
Documentation=https://www.elastic.co/products/beats/filebeat
Wants=network-online.target
After=network-online.target
[Service]
ExecStart=/usr/share/filebeat/bin/filebeat -c $FILEBEAT_CONFIG_DIRECTORY/filebeat.yml -path.home /usr/share/filebeat -path.config /etc/filebeat -path.data /var/lib/filebeat -path.logs $FILEBEAT_LOG_DIRECTORY
Restart=always
[Install]
WantedBy=multi-user.target
EOF
mv "$WORKING_DIR"/filebeat.service /usr/lib/systemd/system

# Set permissions on service file
chmod 644 /usr/lib/systemd/filebeat.service

# Allow system to pick up on the addition of the new service
systemctl daemon-reload

# Start filebeat at boot
systemctl enable filebeat.service

# Start the filebeat service
systemctl start filebeat.service