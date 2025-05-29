#!/usr/bin/env bash
set -e

echo "Parando e desabilitando o serviço Nginx..."
systemctl stop nginx    || true
systemctl disable nginx || true

echo "Atualizando cache do apt..."
apt-get update -y

echo "Removendo pacotes Nginx e purgando configurações..."
apt-get remove --purge -y nginx nginx-common nginx-full nginx-core \
                            nginx-extras 'nginx*'

echo "Removendo dependências órfãs e limpando cache..."
apt-get autoremove -y
apt-get autoclean -y

echo "Apagando diretórios e arquivos residuais do Nginx..."
rm -rf /etc/nginx
rm -rf /var/log/nginx
rm -rf /var/lib/nginx
rm -rf /usr/share/nginx*

echo "---------------------------"
echo "Nginx e toda configuração de sites foram removidos."
echo "---------------------------"

exit 0
