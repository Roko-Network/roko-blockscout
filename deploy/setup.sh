#!/bin/bash
set -euo pipefail

echo "=== Installing Docker ==="
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker ubuntu

echo "=== Installing certbot ==="
sudo apt-get install -y -qq certbot

echo "=== Creating deploy directory ==="
sudo mkdir -p /opt/roko-blockscout
sudo chown ubuntu:ubuntu /opt/roko-blockscout

echo "=== Setup complete ==="
echo "Next steps:"
echo "  1. Copy docker images and deploy files"
echo "  2. Run certbot for SSL"
echo "  3. Start services"
