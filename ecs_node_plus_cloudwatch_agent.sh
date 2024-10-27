#!/bin/bash
set +x

# ECS Cluster Configuration, edit ECS_CLUSTER= to point to the given ECS cluster, default is playground environment
echo "ECS_CLUSTER=ecs-cluster" >> /etc/ecs/ecs.config
echo "ECS_BACKEND_HOST=" >> /etc/ecs/ecs.config

# CloudWatch Agent Installation

# =====================================================================================================

# Create directory to download install file to
mkdir -p /cloudwatch

# Install dependencies
yum install wget curl -y

# Download the CloudWatch Agent installer
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm -O /cloudwatch/amazon-cloudwatch-agent.rpm

# Install the CloudWatch agent
rpm -ivh /cloudwatch/amazon-cloudwatch-agent.rpm

# Create the CloudWatch agent configuration role
cat << 'EOF' > /opt/aws/amazon-cloudwatch-agent/bin/cloudwatch_agent_config.json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/ecs/ecs-init.log*",
            "log_group_name": "ecs-cluster",
            "log_stream_name": "ecs-init.log"
          },
          {
            "file_path": "/var/log/ecs/ecs-agent.log*",
            "log_group_name": "ecs-cluster",
            "log_stream_name": "ecs-agent.log"
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "ecs-cluster",
            "log_stream_name": "cloud-init-output.log"
          }
        ]
      }
    }
  },
  "metrics": {
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    },
    "metrics_collected": {
      "disk": {
        "measurement": [
          "free"
        ],
        "metrics_collection_interval": 60,
        "resources": [
          "*"
        ]
      },
      "mem": {
        "measurement": [
          "mem_used_percent"
        ],
        "metrics_collection_interval": 60
      }
    }
  }
}
EOF

# Start the CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/bin/cloudwatch_agent_config.json -s