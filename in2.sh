#!/bin/sh

read -p "Please enter domain:" domainname
read -p "Please enter vpn domain password: " domainnamevpnpw
read -p "Please enter msql root password: " msqlroot

set -e

apt-get update;apt-get install -y docker.io;
curl -L https://github.com/docker/compose/releases/download/1.29.2/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose;
chmod +x /usr/local/bin/docker-compose;
sysctl -w net.ipv4.ip_forward=1;

apt install wireguard wireguard-tools;
systemctl enable wg-quick@wg0;
touch /etc/wireguard/wg0.conf;
apt install resolvconf;


echo '' | sudo tee -a /etc/systemd/resolved.conf;
echo 'DNS=1.1.1.1' | sudo tee -a /etc/systemd/resolved.conf;
echo 'Domains=postal.$domainname' | sudo tee -a /etc/systemd/resolved.conf;
echo 'MulticastDNS=no' | sudo tee -a /etc/systemd/resolved.conf;
echo 'DNSStubListener=no' | sudo tee -a /etc/systemd/resolved.conf;

ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
lsof -t -i:53
systemctl stop systemd-resolved;
mkdir /var/lib/docker/kl;
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
          - ./agent:/var/lib/docker/volumes
        ports:
          - "9001:9001"
"> /var/lib/docker/kl/portainer-ce/docker-compose.yml;

cd /var/lib/docker/kl/portainer-ce;
docker-compose up -d;
sleep 30;


mkdir /var/lib/docker/kl/wirguard;


echo "
# version: "3.8"

services:
  adwireguard:
    container_name: adwireguard
    # image: ghcr.io/iganeshk/adwireguard-dark:latest
    image: iganesh/adwireguard-dark:latest
    restart: unless-stopped
    ports:
      - '53:53'           # AdGuardHome DNS Port
      - '3000:3000'       # Default Address AdGuardHome WebUI
      - '853:853'         # DNS-TLS
      - '51920:51820/udp' # wiregaurd port
      - '51821:51821/tcp' # wg-easy webUI
    environment:
        # WG-EASY ENVS
      - WG_HOST=vpn.$domainname
      - PASSWORD=$domainnamevpnpw
      - WG_PORT=51920
      - WG_DEFAULT_ADDRESS=10.10.10.x
      - WG_DEFAULT_DNS=10.10.11.2
      - WG_MTU=1420
      - WG_ALLOWED_IPS=192.0.0.0/8, 10.0.0.0/8
      - WG_PERSISTENT_KEEPALIVE=25
    volumes:
        # adguard-home volume
      - './adguard/work:/opt/adwireguard/work'
      - './adguard/conf:/opt/adwireguard/conf'
        # wg-easy volume
      - './wireguard:/etc/wireguard'
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=1    # Disable IPv6
    networks:
      vpn_net:
        ipv4_address: 10.10.11.2

networks:
  vpn_net:
    ipam:
      driver: default
      config:
        - subnet: 10.10.11.0/24
"> /var/lib/docker/kl/wirguard/docker-compose.yml;
cd /var/lib/docker/kl/wirguard;
docker-compose up -d;
sleep 30;
apt install openresolv -y;

cd /opt/
mkdir postal;
cd /opt/postal;
mkdir config;
cd /opt/postal/config;
mkdir nginx-proxy;
cd /opt/postal/config/nginx-proxy;

echo "
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports:
      # These ports are in format <host-port>:<container-port>
      - '80:80' # Public HTTP Port
      - '443:443' # Public HTTPS Port
      - '81:81' # Admin Web Port
      # Add any other Stream port you want to expose
      # - '21:21' # FTP
    environment:
      DB_MYSQL_HOST: "db"
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: "npm"
      DB_MYSQL_PASSWORD: "$msqlroot"
      DB_MYSQL_NAME: "npm"
      # Uncomment this if IPv6 is not enabled on your host
      # DISABLE_IPV6: 'true'
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    depends_on:
      - db

  db:
    image: 'jc21/mariadb-aria:latest'
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: '$msqlroot'
      MYSQL_DATABASE: 'npm'
      MYSQL_USER: 'npm'
      MYSQL_PASSWORD: '$msqlroot'
    volumes:
      - ./mysql/data/mysql:/var/lib/mysql
"> /opt/postal/config/nginx-proxy/docker-compose.yml;

cd /opt/postal/config/nginx-proxy;
docker-compose up -d;


