#!/bin/sh
vpndomain=$1;
passwordvpndomain=$2;

set -e

apt-get update;apt-get install -y docker.io;
curl -L https://github.com/docker/compose/releases/download/1.29.2/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose;
chmod +x /usr/local/bin/docker-compose;
sysctl -w net.ipv4.ip_forward=1;

apt install wireguard wireguard-tools;
systemctl enable wg-quick@wg0;
touch /etc/wireguard/wg0.conf;
apt install resolvconf;


mkdir /var/lib/docker/kl/portainer-ce;

# docker run -p 8000:8000 -p 9000:9000 --detach --name=portainer-ce --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /var/lib/docker/kl/portainer-ce:/data portainer/portainer-ce;


echo "
version: '3.3'
services:
    portainer-ce:
        ports:
            - "8000:8000"
            - "9000:9000"
        container_name: portainer
        restart: unless-stopped
        command: -H tcp://agent:9001 --tlsskipverify
        volumes:
            - /var/run/docker.sock:/var/run/docker.sock
            - /var/lib/docker/kl/portainer-ce/data:/data
        image: 'portainer/portainer-ce:latest'
    
    agent:
        container_name: agent
        image: portainer/agent:latest
        restart: unless-stopped
        volumes:
          - /var/run/docker.sock:/var/run/docker.sock
          - /var/lib/docker/kl/portainer-ce/agent:/var/lib/docker/volumes
        ports:
          - "9001:9001"
"> /var/lib/docker/kl/portainer-ce/docker-compose.yml;

cd /var/lib/docker/kl/portainer-ce;
docker-compose up -d;
sleep 30;


mkdir /var/lib/docker/kl/wirguard;


echo "
version: "3.8"
services:
  wg-easy:
    environment:
      # ⚠️ Required:
      # Change this to your host's public address
      - WG_HOST=$1

      # Optional:
      - PASSWORD=$2
      - WG_PORT=51920
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_MTU=1450
      - WG_ALLOWED_IPS=192.0.0.0/8, 10.0.0.0/8
      - WG_PERSISTENT_KEEPALIVE=25
      
    image: weejewel/wg-easy
    container_name: wg-easy
    volumes:
      - /root/umbrel/elianova/wireguard:/etc/wireguard
    ports:
      - "51920:51820/udp"
      - "51821:51821/tcp"
    restart: unless-stopped
    cap_add:
      # this is dropped by portianer but keep it for clarity (and future?)
      - NET_ADMIN
    deploy:
      labels:
        io.portainerhack.cap_add: NET_ADMIN,SYS_MODULE
      mode: replicated
      replicas: 1
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
"> /var/lib/docker/kl/wirguard/docker-compose.yml;
cd /var/lib/docker/kl/wirguard;
docker-compose up -d;


