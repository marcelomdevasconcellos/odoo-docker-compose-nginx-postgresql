#!/usr/bin/env bash
set -e

if [[ $# -ne 2 ]]; then
  echo "Uso: sudo $0 <dominio> <email-certbot>"
  exit 1
fi

# sudo mkdir -p /opt/odoo
# sudo curl -L \
#  https://raw.githubusercontent.com/marcelomdevasconcellos/odoo-docker-compose-nginx-postgresql/refs/heads/main/install_odoo_docker.sh \
#  -o /opt/odoo/install_odoo_docker.sh
# git clone https://github.com/marcelomdevasconcellos/odoo-docker-compose-nginx-postgresql /opt/odoo

DOMAIN="$1"
EMAIL="$2"
INSTALL_DIR="/opt/odoo"
COMPOSE_BIN="/usr/bin/docker-compose"   # ou ajuste se necessário

# 1) Instala Docker & Docker-Compose
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
   https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose
systemctl enable docker && systemctl start docker

# 2) Cria pasta de instalação e docker-compose.yml
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

#cat > docker-compose.yml <<EOF
#version: '3'
#services:
#    odoo:
#        container_name: odoo
#        image: odoo:latest
#        restart: always
#        volumes:
#            - ./addons:/mnt/extra-addons/:rw
#            - ./config/odoo:/etc/odoo/:rw
#            - ./odoo-web-data:/var/lib/odoo/:rw
#        ports:
#            - "8069:8069"
#        depends_on:
#            - "db"
#        networks:
#          - odoo_network
#    nginx:
#        container_name: nginx
#        image: nginx:latest
#        restart: unless-stopped
#        ports:
#            - 80:80
#            - 443:443
#        volumes:
#            - ./config/nginx/conf:/etc/nginx/conf.d/:rw
#            - ./certbot/conf:/etc/letsencrypt
#            - ./certbot/www:/var/www/certbot
#        depends_on:
#            - "odoo"
#        networks:
#            - odoo_network
#    certbot:
#        image: certbot/certbot
#        volumes:
#            - ./certbot/conf:/etc/letsencrypt
#            - ./certbot/www:/var/www/certbot
#        command: certonly --webroot -w /var/www/certbot --force-renewal --email marcelomdevasconcellos@gmail.com -d odoo --agree-tos
#        depends_on:
#            - nginx
#        networks:
#          - odoo_network
#
#    db:
#      image: postgres:13
#      restart: always
#      container_name: postgresql
#      environment:
#        - POSTGRES_PASSWORD=odoo
#        - POSTGRES_USER=odoo
#        - POSTGRES_DB=odoo
#        - PGDATA=/var/lib/postgresql/data/pgdata
#      ports:
#        - "127.0.0.1:9432:5432"
#      volumes:
#        - ./odoo-db-data:/var/lib/postgresql/data/pgdata
#      networks:
#        - odoo_network
#      logging:
#        driver: json-file
#        options:
#          max-size: "30m"
#          max-file: "10"
#
#networks:
#  odoo_network:
#    driver: bridge
#
#volumes:
#  odoo-web-data:
#  odoo-db-data:
#EOF

# 3) Cria config inicial do Nginx (HTTP + ACME-challenge + proxy Odoo)
mkdir -p config/nginx/conf
cat > config/nginx/conf/odoo-http.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    # ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Proxy para Odoo
    location / {
        proxy_pass http://odoo:8069;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# 4) Cria serviço systemd para levantar stack no boot
cat > /etc/systemd/system/odoo.service <<EOF
[Unit]
Description=Odoo Docker Compose Stack
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}
ExecStart=${COMPOSE_BIN} up -d
ExecStop=${COMPOSE_BIN} down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable odoo.service

# 5) Sobe containers (fase HTTP)
systemctl start odoo.service

echo -n "Aguardando Nginx na porta 80..."
until curl -sf http://localhost/ >/dev/null; do
  echo -n "."
  sleep 2
done
echo " ok"

# 6) Gera/renova certificado via Certbot
${COMPOSE_BIN} run --rm certbot

# 7) Cria config final do Nginx (SSL + redirect)
cat > config/nginx/conf/odoo-ssl.conf <<EOF
# redireciona HTTP para HTTPS
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

# proxy via SSL
server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    proxy_buffering off;
    proxy_read_timeout 3600s;

    location / {
        proxy_pass http://odoo:8069;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

cd "${INSTALL_DIR}"
sudo mkdir -p odoo-web-data/.local
sudo chown -R 100:101 odoo-web-data

# 8) Recarrega Nginx com SSL
${COMPOSE_BIN} exec nginx nginx -s reload || true

sudo docker-compose exec odoo  odoo  -c /etc/odoo/odoo.conf  -d odoo  -i base --stop-after-init

echo
echo "==========================================="
echo "  Odoo instalado e rodando em https://${DOMAIN}/"
echo "==========================================="
