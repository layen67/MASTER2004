#!/bin/sh

read -p "Please enter domain:" domainname
read -p "Please enter vpn domain password: " domainnamevpnpw
read -p "Please enter msql root password: " msqlroot

set -e

apt update -y;
apt install apt-transport-https ca-certificates curl software-properties-common -y;
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -;
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu focal stable";
apt-cache policy docker-ce;
apt install docker-ce -y;



curl -L https://github.com/docker/compose/releases/download/1.29.2/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose;
chmod +x /usr/local/bin/docker-compose;
sysctl -w net.ipv4.ip_forward=1;

apt install wireguard wireguard-tools;
systemctl enable wg-quick@wg0;
touch /etc/wireguard/wg0.conf;

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
version: '3.8'

services:
  adwireguard:
    container_name: adwireguard
    # image: ghcr.io/iganeshk/adwireguard-dark:latest
    image: iganesh/adwireguard-dark:latest
    restart: unless-stopped
    ports:
      - '8088:80'           # AdGuardHome DNS Port
      - '53:53'           # AdGuardHome DNS Port
      - '3000:3000'       # Default Address AdGuardHome WebUI
      - '853:853'         # DNS-TLS
      - '9369:51820/udp' # wiregaurd port
      - '51821:51821/tcp' # wg-easy webUI
    environment:
        # WG-EASY ENVS
      - WG_HOST=vpn.$domainname
      - PASSWORD=$domainnamevpnpw
      - WG_PORT=9369
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_DEFAULT_DNS=1.1.1.1
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
        ipv4_address: 10.10.10.2

networks:
  vpn_net:
    ipam:
      driver: default
      config:
        - subnet: 10.10.10.0/24
"> /var/lib/docker/kl/wirguard/docker-compose.yml;
cd /var/lib/docker/kl/wirguard;
docker-compose up -d;
sleep 15;
apt install openresolv -y;

cd /opt/
mkdir postal;
cd /opt/postal;
mkdir config;
cd /opt/postal/config;
mkdir nginx-proxy;
cd /opt/postal/config/nginx-proxy;

echo "
version: '3'
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
sleep 15;


apt install spamassassin -y;
apt install git curl jq -y;
git clone https://postalserver.io/start/install /opt/postal/install;
ln -s /opt/postal/install/bin/postal /usr/bin/postal;

docker run -d \
   --name postal-mariadb \
   -p 127.0.0.1:3306:3306 \
   --restart always \
   -e MARIADB_DATABASE=postal \
   -e MARIADB_ROOT_PASSWORD=$msqlroot \
   mariadb

docker run -d \
   --name postal-rabbitmq \
   -p 127.0.0.1:5672:5672 \
   --restart always \
   -e RABBITMQ_DEFAULT_USER=postal \
   -e RABBITMQ_DEFAULT_PASS=$msqlroot \
   -e RABBITMQ_DEFAULT_VHOST=postal \
   rabbitmq:3.8
   
postal bootstrap postal.$domainname;
  
sed -i -e '/^smtp_server:/d' /opt/postal/config/postal.yml
sed -i -e '/^  port: 25/d' /opt/postal/config/postal.yml

echo '' | sudo tee -a /opt/postal/config/postal.yml;
echo 'smtp_server:' | sudo tee -a /opt/postal/config/postal.yml;
echo '  port: 25' | sudo tee -a /opt/postal/config/postal.yml;
echo '  tls_enabled: true' | sudo tee -a /opt/postal/config/postal.yml;
echo '  # tls_certificate_path: ' | sudo tee -a /opt/postal/config/postal.yml;
echo '  # tls_private_key_path: ' | sudo tee -a /opt/postal/config/postal.yml;
echo '  proxy_protocol: false' | sudo tee -a /opt/postal/config/postal.yml;
echo '  log_connect: true' | sudo tee -a /opt/postal/config/postal.yml;
echo '  strip_received_headers: true' | sudo tee -a /opt/postal/config/postal.yml;

sed -i -e "s/example.com/$domainname/g" /opt/postal/config/postal.yml;
sed -i -e "s/mx.postal.$domainname/postal.$domainname/g" /opt/postal/config/postal.yml;
sed -i -e "s/bind_address: 127.0.0.1/bind_address: 0.0.0.0/g" /opt/postal/config/postal.yml;
sed -i -e "s/password: postal/password: $msqlroot/g" /opt/postal/config/postal.yml;

postal initialize;

postal make-user;

command hostnamectl set-hostname postal.$domainname;

postal stop;
# docker run --restart=always -d --name phpmyadmin -e PMA_ARBITRARY=1 -p 8080:80 phpmyadmin;

sleep 15;
mkdir /opt/postal/config/nginx-proxy/npm/letsencrypt/live
chmod 777 /opt/postal/config/nginx-proxy/npm/letsencrypt/live -R;

sed -i -r "s/.*tls_certificate_path.*/  #tls_certificate_path: \/config\/nginx-proxy\/npm\/letsencrypt\/live\/npm-1\/cert.pem/g" /opt/postal/config/postal.yml;
sed -i -r "s/.*tls_private_key_path.*/  #tls_private_key_path: \/config\/nginx-proxy\/npm\/letsencrypt\/live\/npm-1\/fullchain.pem/g" /opt/postal/config/postal.yml;

sed -i -e "s/ENABLED=0/ENABLED=1/g" /etc/default/spamassassin;
systemctl restart spamassassin;

echo '' | sudo tee -a /opt/postal/config/postal.yml;
echo 'spamd:' | sudo tee -a /opt/postal/config/postal.yml;
echo '  enabled: true' | sudo tee -a /opt/postal/config/postal.yml;
echo '  host: 127.0.0.1' | sudo tee -a /opt/postal/config/postal.yml;
echo '  port: 783' | sudo tee -a /opt/postal/config/postal.yml;

postal start;


docker exec -it nginx-proxy_app_1 bash -c "echo 'rsa-key-size = 4096' | tee -a /etc/letsencrypt.ini";
docker exec -it nginx-proxy_app_1 sed -i -e "s/elliptic-curve/#elliptic-curve/g" /etc/letsencrypt.ini;
docker exec -it nginx-proxy_app_1 sed -i -e "s/ecdsa/rsa/g" /etc/letsencrypt.ini;

mkdir /var/lib/docker/kl/msqlphpadmin;
cd /var/lib/docker/kl/msqlphpadmin;

echo "
version: '3'

services:
  # Database
  db:
    platform: linux/x86_64
    image: mysql:5.7
    volumes:
      - ./db_data:/var/lib/mysql
    restart: always
    ports:
      - "3307:3306"
    environment:
      MYSQL_ROOT_PASSWORD: $msqlroot
      MYSQL_DATABASE: organizr
      MYSQL_PASSWORD: $msqlroot
    networks:
      - mysql-phpmyadmin

  # phpmyadmin
  phpmyadmin:
    depends_on:
      - db
    image: phpmyadmin
    restart: always
    ports:
      - "8091:80"
    environment:
      PMA_HOST: db
      MYSQL_ROOT_PASSWORD: $msqlroot
    networks:
      - mysql-phpmyadmin

networks:
  mysql-phpmyadmin:
"> /var/lib/docker/kl/msqlphpadmin/docker-compose.yml;
docker-compose up -d;
sleep 15;


mkdir /var/lib/docker/kl/heimdall;
cd /var/lib/docker/kl/heimdall;

echo "
version: '2.1'
services:
  heimdall:
    image: lscr.io/linuxserver/heimdall:latest
    container_name: heimdall
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Paris
    volumes:
      - ./heimdall:/config
    ports:
      - 8087:80
    restart: unless-stopped
"> /var/lib/docker/kl/heimdall/docker-compose.yml;
docker-compose up -d;
sleep 10;


apt-get update -y;
apt-get install -y firewalld;
systemctl enable firewalld;
systemctl start firewalld;
firewall-cmd --permanent --zone=trusted --add-interface=wg0;
#firewall-cmd --permanent --zone=trusted --add-interface=docker0;
firewall-cmd --add-port=53/tcp --permanent;
firewall-cmd --add-port=53/udp --permanent;
firewall-cmd --add-port=80/tcp --permanent;
firewall-cmd --add-port=443/tcp --permanent;
firewall-cmd --add-port=465/tcp --permanent;
firewall-cmd --add-port=25/tcp --permanent;
firewall-cmd --add-port=587/tcp --permanent;
firewall-cmd --add-port=9369/udp --permanent;
firewall-cmd --add-masquerade --permanent;
firewall-cmd --add-forward-port=port=587:proto=tcp:toport=25 --permanent;
firewall-cmd --add-forward-port=port=465:proto=tcp:toport=25 --permanent;
systemctl restart firewalld;

##########################################################################

mkdir /etc/systemd/system/docker.service.d;
cat << EOF > /etc/systemd/system/docker.service.d/noiptables.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// --iptables=false
EOF
systemctl daemon-reload;

#####################################################


cat << EOF > /etc/init.d/wgdo.sh
#!/bin/sh

#sleep 60;
#iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE;
#iptables -t nat -A PREROUTING -d 10.8.0.2/32 -j DNAT --to-destination 172.17.0.1;
postal start;
sleep 30;
postal start;
EOF

chmod +x /etc/init.d/wgdo.sh;

####################################################

cat << EOF > /lib/systemd/system/wgdo.service
[Unit]
Description=Floating wg
After=docker.service
BindsTo=docker.service

[Service]
Type=oneshot
ExecStart=/etc/init.d/wgdo.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable wgdo.service;

##############################################


echo '' | sudo tee -a /etc/hosts.allow;
echo 'sshd: 10.8.0.0/24' | sudo tee -a /etc/hosts.allow;

echo '' | sudo tee -a /etc/hosts.deny;
echo 'sshd: ALL' | sudo tee -a /etc/hosts.deny;







# a finir
# firewall-cmd --runtime-to-permanent;

#iptables -t nat -A PREROUTING -d 10.8.0.0/24 -j DNAT --to-destination 172.17.0.1;
#iptables -t nat -A PREROUTING -d 172.0.0.0/8 -j DNAT --to-destination 172.17.0.1;
#apt install iptables-persistent;
#/sbin/iptables-save > /etc/iptables/rules.v4;

#mkdir /etc/systemd/system/docker.service.d
#cat << EOF > /etc/systemd/system/docker.service.d/noiptables.conf
#[Service]
#ExecStart=
#ExecStart=/usr/bin/dockerd -H fd:// --iptables=false
#EOF
#systemctl daemon-reload

#?????
#iptables -A FORWARD -i docker0 -o wg0 -j ACCEPT
#iptables -A FORWARD -i wg0 -o docker0 -j ACCEPT
#?????

#nano /lib/systemd/system/wgdo.service;

#[Unit]
#Description=Floating wg
#After=docker.service
#BindsTo=docker.service

#[Service]
#Type=oneshot
#ExecStart=/etc/init.d/wgdo.sh
#RemainAfterExit=yes

#[Install]
#WantedBy=multi-user.target

#systemctl enable wgdo.service;


#nano /etc/init.d/wgdo.sh;

#!/bin/sh

#sleep 60;
#iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE;
#iptables -t nat -A PREROUTING -d 10.8.0.2/32 -j DNAT --to-destination 172.17.0.1;


#chmod +x wgdo.sh;
