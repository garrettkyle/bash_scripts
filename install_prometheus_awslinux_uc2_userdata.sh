#!/bin/bash
set -x

# Script assumes that AWS CLI is installed as part of the base AMI and that the desired EBS volume and ENI have been created in the same
# AZ as the instance

##################################   VARIABLES     #################################################
# ================================================================================================================

# General/Shared
EBS_VOLUME_NAME="prometheus_node_1_data_volume"
ENI_NAME="prometheus_node_1_eni"
PROMETHEUS_ENI_IP_ADDRESS="10.0.1.10"
SERVERNAME="prometheus-node-1"
WORKING_DIR="/tmp"

# Prometheus
PROMETHEUS_DOWNLOAD_URL="https://github.com/prometheus/prometheus/releases/download/v2.11.0"
PROMETHEUS_BINARY_FILENAME="prometheus-2.11.0.linux-amd64.tar.gz"
PROMETHEUS_DIRECTORY="/prometheus_node_1"
PROMETHEUS_USERNAME="prometheus"
PROMETHEUS_DATA_DIRECTORY="/prometheus_node_1/data"
PROMETHEUS_CONFIG_DIRECTORY="/prometheus_node_1/config"

##################################   DEPENDENCY INSTALLATION    #################################################
# ================================================================================================================

# Set SERVERNAME
echo "127.0.0.1 $SERVERNAME" >> /etc/hosts
echo "$PROMETHEUS_ENI_IP_ADDRESS $SERVERNAME" >> /etc/hosts
rm -f /etc/hostname
echo "$SERVERNAME" >> /etc/hostname
hostname "$SERVERNAME"

# Make directory for Prometheus data volume to mount to
mkdir -p $PROMETHEUS_DIRECTORY

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

# Format the volume
mkfs -t xfs -f /dev/xvdf

# Mount the volume
mount /dev/xvdf /prometheus_node_1

# Mount the volume at boot
echo "/dev/xvdf       /prometheus_node_1  xfs    defaults,nofail        0       2" >> /etc/fstab

# Create the Prometheus data directory
mkdir -p "$PROMETHEUS_DATA_DIRECTORY"

# Create the Prometheus config directory
mkdir -p "$PROMETHEUS_CONFIG_DIRECTORY"


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
ip route add "$PROMETHEUS_ENI_IP_ADDRESS" dev eth1 table 1000
ip rule add from "$PROMETHEUS_ENI_IP_ADDRESS" lookup 1000

# Create secondary static route file for interface
touch "$WORKING_DIR"/route-eth1
cat << EOF > "$WORKING_DIR"/route-eth1
default via $GATEWAY dev eth1 table 1000
$PROMETHEUS_ENI_IP_ADDRESS dev eth1 table 1000
EOF
mv "$WORKING_DIR"/route-eth1 /etc/sysconfig/network-scripts/route-eth1

# Create rule file for interface
touch "$WORKING_DIR"/rule-eth1
cat << EOF > "$WORKING_DIR"/rule-eth1
from $PROMETHEUS_ENI_IP_ADDRESS lookup 1000
EOF
mv "$WORKING_DIR"/rule-eth1 /etc/sysconfig/network-scripts/rule-eth1

# Bring the eth1 online
ifup eth1

##################################   PROMETHEUS INSTALLATION    #################################################
# ================================================================================================================

# Download Prometheus binary
wget "$PROMETHEUS_DOWNLOAD_URL"/"$PROMETHEUS_BINARY_FILENAME" -O "$WORKING_DIR"/"$PROMETHEUS_BINARY_FILENAME"

# Create Prometheus service user
useradd "$PROMETHEUS_USERNAME"

# Add Prometheus service user to wheel group
usermod -aG wheel "$PROMETHEUS_USERNAME"

# Edit sudoers to allow Prometheus to use systemctl to manipulate the service
echo '# Allow zookeeper user to start the prometheus.service' | sudo EDITOR='tee -a' visudo
echo "$PROMETHEUS_USERNAME ALL=NOPASSWD: /bin/systemctl start prometheus.service" | sudo EDITOR='tee -a' visudo
echo "$PROMETHEUS_USERNAME ALL=NOPASSWD: /bin/systemctl stop prometheus.service" | sudo EDITOR='tee -a' visudo
echo "$PROMETHEUS_USERNAME ALL=NOPASSWD: /bin/systemctl reload prometheus.service" | sudo EDITOR='tee -a' visudo
echo "$PROMETHEUS_USERNAME ALL=NOPASSWD: /bin/systemctl restart prometheus.service" | sudo EDITOR='tee -a' visudo
echo "$PROMETHEUS_USERNAME ALL=NOPASSWD: /bin/systemctl status prometheus.service" | sudo EDITOR='tee -a' visudo

# Extract Prometheus binaries
tar -C "$PROMETHEUS_DIRECTORY" -xvzf "$WORKING_DIR"/"$PROMETHEUS_BINARY_FILENAME" --strip 1

# Cleanup home folder
rm -f "$WORKING_DIR"/"$PROMETHEUS_BINARY_FILENAME"

# Backup default prometheus.yml file
mv $PROMETHEUS_DIRECTORY/prometheus.yml $PROMETHEUS_DIRECTORY/prometheus.yml.backup

# WILL NEED TO SET VARIABLES FOR THINGS LIKE PORTS BELOW #####################
############################################################
# ===========================================================


# Create and configure Prometheus config file
touch "$WORKING_DIR"/prometheus.yml
cat << 'EOF' > "$WORKING_DIR"/prometheus.yml
# my global config
global:
  scrape_interval:     15s # Set the scrape interval to every 15 seconds. Default is every 1 minute.
  evaluation_interval: 15s # Evaluate rules every 15 seconds. The default is every 1 minute.
  # scrape_timeout is set to the global default (10s).
# Alertmanager configuration
alerting:
  alertmanagers:
  - static_configs:
    - targets:
      # - alertmanager:9093
# Load rules once and periodically evaluate them according to the global 'evaluation_interval'.
rule_files:
  # - "first_rules.yml"
  # - "second_rules.yml"
# A scrape configuration containing exactly one endpoint to scrape:
# Here it's Prometheus itself.
scrape_configs:
  # The job name is added as a label `job=<job_name>` to any timeseries scraped from this config.
  - job_name: 'prometheus'
    # metrics_path defaults to '/metrics'
    # scheme defaults to 'http'.
    static_configs:
    - targets: ['localhost:9090']
   # - targets: ['<REMOTE_MACHINE_IP>:9100']
EOF
mv "$WORKING_DIR"/prometheus.yml "$PROMETHEUS_CONFIG_DIRECTORY"/prometheus.yml

# Set permissions on config file
chmod 644 "$PROMETHEUS_CONFIG_DIRECTORY"/prometheus.yml

# Create Prometheus service
touch "$WORKING_DIR"/prometheus.service
cat << EOF > "$WORKING_DIR"/prometheus.service
[Unit]
Requires=network.target remote-fs.target
After=network.target remote-fs.target
[Service]
Type=simple
User=$PROMETHEUS_USERNAME
ExecStart=$PROMETHEUS_DIRECTORY/prometheus --config.file=$PROMETHEUS_CONFIG_DIRECTORY/prometheus.yml --storage.tsdb.path=$PROMETHEUS_DATA_DIRECTORY
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
EOF
mv "$WORKING_DIR"/prometheus.service /etc/systemd/system/

# Configure permissions on service file
chmod 644 /etc/systemd/system/prometheus.service

# Make the Prometheus user owner of the Prometheus directory
chown -R "$PROMETHEUS_USERNAME":"$PROMETHEUS_USERNAME" "$PROMETHEUS_DIRECTORY"

# Set permissions on /prometheus folder
chmod -R 775 /prometheus_node_1

# Allow Prometheus traffic through the firewall
iptables -I INPUT -j ACCEPT
iptables-save > /etc/sysconfig/iptables

# Allow Prometheus to start at boot
systemctl enable prometheus.service

# Start Prometheus
systemctl start prometheus.service

# Install nginx as a reverse proxy
yum install nginx -y

# Backup nginx.conf file
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup

# Create nginx configuration file
touch "$WORKING_DIR"/nginx.conf
cat << EOF > "$WORKING_DIR"/nginx.conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
# Load dynamic modules. See /usr/share/nginx/README.dynamic.
include /usr/share/nginx/modules/*.conf;
events {
    worker_connections 1024;
}
http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    underscores_in_headers on;
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;
    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;
    server {
        listen       80 default_server;
        listen       [::]:80 default_server;
        server_name  jasper-reports;
        root         /usr/share/nginx/html;
        underscores_in_headers on;
        # Load configuration files for the default server block.
        include /etc/nginx/default.d/*.conf;
        location / {
            proxy_pass http://localhost:9090/;
        }
    }
}
EOF
mv "$WORKING_DIR"/nginx.conf /etc/nginx/nginx.conf

# Allow NGINX to start at boot
systemctl enable nginx.service

# Start NGINX
systemctl start nginx.service