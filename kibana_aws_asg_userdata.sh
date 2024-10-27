#!/bin/bash
set -x

# Script assumes that AWS CLI is installed as part of the base AMI and that the desired EBS volume and ENI have been created in the same
# AZ as the instance

##################################   VARIABLES     #################################################
# ================================================================================================================

# General/Shared
ENI_IP_ADDRESS="10.0.1.10"
SERVERNAME="kibana-grafana"
WORKING_DIR="/tmp"

# Kibana
EBS_VOLUME_NAME="kibana_grafana_data_volume"
ENI_NAME="kibana_eni"
KIBANA_CONFIG_DIRECTORY="/kibana/config"
KIBANA_FOLDER="/kibana"


##################################   DEPENDENCY INSTALLATION    #################################################
# ================================================================================================================

# Set SERVERNAME
echo "127.0.0.1 $SERVERNAME" >> /etc/hosts
echo "$ENI_IP_ADDRESS $SERVERNAME" >> /etc/hosts
rm -f /etc/hostname
echo "$SERVERNAME" >> /etc/hostname
hostname "$SERVERNAME"

# Make directory for Kibana data volume to mount to
mkdir -p /kibana

#######################  EBS VOLUME MOUNTING, FORMATTING AND CONFIGURATION ################################

# Attach the Kibana EBS volume
INSTANCEID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
EBS_DATA_VOLUME=$(aws ec2 --region ca-central-1 describe-volumes --filters Name=tag-key,Values="Name" Name=tag-value,Values="$EBS_VOLUME_NAME" --query 'Volumes[*].{ID:VolumeId}' --output text)

aws ec2 --region ca-central-1 attach-volume --volume-id "$EBS_DATA_VOLUME" --instance-id $INSTANCEID --device "/dev/xvdf"
aws ec2 --region ca-central-1 wait volume-in-use --volume-id "$EBS_DATA_VOLUME"
sleep 30 # allows time for volume to be attached

# Mount the volume
mount /dev/xvdf /kibana

# Mount the volume at boot
echo "/dev/xvdf       /kibana   xfs    defaults,nofail        0       2" >> /etc/fstab

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
ip route add "$ENI_IP_ADDRESS" dev eth1 table 1000
ip rule add from "$ENI_IP_ADDRESS" lookup 1000

# Create secondary static route file for interface
touch "$WORKING_DIR"/route-eth1
cat << EOF > "$WORKING_DIR"/route-eth1
default via $GATEWAY dev eth1 table 1000
$ENI_IP_ADDRESS dev eth1 table 1000
EOF
mv "$WORKING_DIR"/route-eth1 /etc/sysconfig/network-scripts/route-eth1

# Create rule file for interface
touch "$WORKING_DIR"/rule-eth1
cat << EOF > "$WORKING_DIR"/rule-eth1
from $ENI_IP_ADDRESS lookup 1000
EOF
mv "$WORKING_DIR"/rule-eth1 /etc/sysconfig/network-scripts/rule-eth1

# Bring the eth1 online
ifup eth1

##################################   KIBANA INSTALLATION    #################################################
# ================================================================================================================

# Install Kibana
yum install kibana-6.6.2 -y

# Backup original Kibana config file installed by the RPM
mv /etc/kibana/kibana.yml /etc/kibana/kibana.yml.backup

# Backup original Kibana service file installed by the RPM
mv /etc/systemd/system/kibana.service /etc/systemd/system/kibana.service.backup

# Create and configure new Kibana service file
touch "$WORKING_DIR"/kibana.service
cat << EOF > "$WORKING_DIR"/kibana.service
[Unit]
Description=Kibana
StartLimitIntervalSec=30
StartLimitBurst=3
[Service]
Type=simple
User=kibana
Group=kibana
# Load env vars from /etc/default/ and /etc/sysconfig/ if they exist.
# Prefixing the path with '-' makes it try to load, but if the file doesn't
# exist, it continues onward.
EnvironmentFile=-/etc/default/kibana
EnvironmentFile=-/etc/sysconfig/kibana
ExecStart=/usr/share/kibana/bin/kibana -c $KIBANA_CONFIG_DIRECTORY/kibana.yml
Restart=always
WorkingDirectory=/
[Install]
WantedBy=multi-user.target
EOF
mv "$WORKING_DIR"/kibana.service /etc/systemd/system/kibana.service

# Configure permissions on service file
chmod 644 /etc/systemd/system/kibana.service

# Allow Kibana traffic through the firewall
iptables -I INPUT -j ACCEPT
iptables-save > /etc/sysconfig/iptables

# Make Kibana user the owner of the folders
chown -R kibana:kibana /kibana

# Enable OS to pick up on the addition of the Kibana service
systemctl daemon-reload

# Enable the Kibana service to start at boot
systemctl enable kibana.service

# Start the Kibana service
systemctl start kibana.service