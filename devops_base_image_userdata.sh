#!/bin/bash
set -x

# Script is incomplete, mainly a list of bash commands
# required to install some dependencies for a devops box on ubuntu
sudo apt update
sudo apt upgrade -y
sudo apt install git curl -y
sudo apt install apt-transport-https ca-certificates software-properties-common -y
sudo apt autoremove
sudo apt clean
sudo apt install terminator git curl -y
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install terraform -y
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
curl -fsSL ubuntu/gpg | sudo apt-key add -
sudo apt-get remove docker docker-engine docker.io
sudo apt install docker.io -y
sudo snap install docker
sudo docker run hello-world
sudo groupadd docker
sudo usermod -aG docker $USER
sudo apt update
sudo apt upgrade -y
sudo mkdir /git
DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
mkdir -p $DOCKER_CONFIG/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.30.1/docker-compose-linux-x86_64 -o $DOCKER_CONFIG/cli-plugins/docker-compose
chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose