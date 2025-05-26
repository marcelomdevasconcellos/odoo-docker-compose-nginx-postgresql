#!/bin/bash

# Fail on errors
set -e

echo "Iniciando instalação do Odoo 18..."

# Função para exibir uso do script
usage() {
  echo "Uso: $0 <SUBDOMAIN> <DB_HOST> <DB_PORT> <DB_USER> <DB_PASSWORD> <DB_NAME>"
  echo "Exemplo: $0 'odoo.example.com' 'db-server' '5432' 'odoo' 'senha123' 'odoo_db'"
  exit 1
}

# Verifica parâmetros
if [ "$#" -ne 6 ]; then
  usage
fi

SUBDOMAIN=$1
DB_HOST=$2
DB_PORT=$3
DB_USER=$4
DB_PASSWORD=$5
DB_NAME=$6
ODOO_VERSION="18.0"
ODOO_USER="odoo18"
ODOO_HOME="/opt/odoo"

# 1. Atualização e dependências
echo "#1 - Atualizando pacotes e instalando dependências..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
    software-properties-common \
    git python3 python3-venv python3-dev \
    build-essential libxslt1-dev libzip-dev libldap2-dev libsasl2-dev libffi-dev \
    libpng-dev libjpeg-dev libpq-dev \
    nodejs npm less postgresql postgresql-client \
    nginx ufw locales \
    wget curl xz-utils \
    certbot python3-certbot-nginx

# 2. Configurar locale
echo "#2 - Configurando locale pt_BR.UTF-8..."
sudo locale-gen pt_BR.UTF-8
sudo update-locale LANG=pt_BR.UTF-8
export LANG=pt_BR.UTF-8
export LC_ALL=pt_BR.UTF-8

# 3. Criar usuário do Odoo
echo "#3 - Criando usuário de sistema $ODOO_USER..."
sudo useradd -m -U -r -s /bin/bash $ODOO_USER || true

# 4. Criar diretórios
echo "#4 - Criando diretórios..."
sudo mkdir -p $ODOO_HOME/$ODOO_VERSION
sudo mkdir -p /var/log/odoo$ODOO_VERSION
sudo mkdir -p /var/lib/odoo$ODOO_VERSION
sudo chown -R $ODOO_USER:$ODOO_USER $ODOO_HOME
sudo chown -R $ODOO_USER:$ODOO_USER /var/log/odoo$ODOO_VERSION /var/lib/odoo$ODOO_VERSION

# 5. Clonar Odoo
echo "#5 - Clonando Odoo v$ODOO_VERSION..."
sudo -u $ODOO_USER git clone --depth 1 --branch $ODOO_VERSION https://github.com/odoo/odoo.git $ODOO_HOME/$ODOO_VERSION

# 6. Configurar ambiente Python
echo "#6 - Criando virtualenv e instalando dependências Python..."
sudo -u $ODOO_USER python3 -m venv $ODOO_HOME/venv
source $ODOO_HOME/venv/bin/activate
pip install --upgrade pip
pip install wheel
# Ajuste: resolver erro de compilação do gevent substituindo versão para uma que possui wheel
sudo -u $ODOO_USER sed -i 's/gevent==21.8.0/gevent==21.12.0/' $ODOO_HOME/$ODOO_VERSION/requirements.txt

pip install -r $ODOO_HOME/$ODOO_VERSION/requirements.txt

# 7. Configurar arquivo de configuração
echo "#7 - Criando arquivo de configuração /etc/odoo$ODOO_VERSION.conf..."
sudo tee /etc/odoo$ODOO_VERSION.conf > /dev/null <<EOF
[options]
; Servidor
admin_passwd = $(openssl rand -base64 16)
xmlrpc_port = 8069
proxy_mode = True

; Caminhos
addons_path = $ODOO_HOME/$ODOO_VERSION/addons
data_dir = /var/lib/odoo$ODOO_VERSION

; Banco de dados
db_host = $DB_HOST
db_port = $DB_PORT
db_user = $DB_USER
db_password = $DB_PASSWORD
db_name = $DB_NAME

; Logs
debug_mode = False
logfile = /var/log/odoo$ODOO_VERSION/odoo.log
EOF
sudo chown $ODOO_USER:$ODOO_USER /etc/odoo$ODOO_VERSION.conf
sudo chmod 640 /etc/odoo$ODOO_VERSION.conf

# 8. Configurar serviço systemd
echo "#8 - Criando service odoo$ODOO_VERSION.service..."
sudo tee /etc/systemd/system/odoo$ODOO_VERSION.service > /dev/null <<EOF
[Unit]
Description=Odoo ERP $ODOO_VERSION
after=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$ODOO_USER
Group=$ODOO_USER
ExecStart=$ODOO_HOME/venv/bin/python3 $ODOO_HOME/$ODOO_VERSION/odoo-bin -c /etc/odoo$ODOO_VERSION.conf
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable odoo$ODOO_VERSION
sudo systemctl start odoo$ODOO_VERSION

# 9. Configurar Nginx
echo "#9 - Configurando Nginx para $SUBDOMAIN..."
sudo tee /etc/nginx/sites-available/$SUBDOMAIN > /dev/null <<EOF
upstream odoo$ODOO_VERSION {
    server 127.0.0.1:8069;
}

server {
    listen 80;
    server_name $SUBDOMAIN;

    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    location / {
        proxy_pass http://odoo$ODOO_VERSION;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static/ {
        alias $ODOO_HOME/$ODOO_VERSION/addons/web/static/;
    }

    location /web/static/ {
        alias $ODOO_HOME/$ODOO_VERSION/odoo/addons/web/static/;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/$SUBDOMAIN /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# 10. Configurar HTTPS via Certbot
echo "#10 - Obtendo certificado SSL com Certbot..."
sudo certbot --nginx -d $SUBDOMAIN --non-interactive --agree-tos -m admin@$SUBDOMAIN --redirect

# 11. Configurar firewall
echo "#11 - Configurando firewall..."
sudo ufw allow 'Nginx Full'
sudo ufw allow OpenSSH
sudo ufw --force enable

# Conclusão
echo "Instalação concluída! Acesse https://$SUBDOMAIN para usar o Odoo 18."
