#!/bin/bash

# Временно отключаем падение скрипта для этапа компиляции
set +e

echo "=== MTProxy + Nginx + sslh Installer ==="
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo "Запусти как root: sudo bash $0"
    exit 1
fi

#######################################
# IP и SNI для Fake TLS
#######################################
IP=$(curl -s --max-time 5 ifconfig.me)
FAKE_DOMAIN="microsoft.com"

#######################################
# ПОРТЫ
#######################################
SSH_PORT=22
MUX_PORT=443
NGINX_PORT=8443
MTPROXY_PORT=9443

#######################################
# ПАКЕТЫ
#######################################
export DEBIAN_FRONTEND=noninteractive
echo "sslh sslh/inetd_or_standalone select standalone" | debconf-set-selections

apt update
apt install -y git curl build-essential libssl-dev zlib1g-dev xxd cron \
               nginx sslh ufw openssl

#######################################
# MTProxy
#######################################
cd /opt
rm -rf MTProxy || true
git clone https://github.com/TelegramMessenger/MTProxy
cd MTProxy

# Патчим под OpenSSL 3.x (игнорируем ошибки, если патч не нужен)
sed -i 's/ERR_remove_thread_state(NULL);//g' src/engine.c 2>/dev/null
sed -i 's/RAND_pseudo_bytes/RAND_bytes/g' src/engine.c 2>/dev/null

echo "Компиляция MTProxy (может занять минуту)..."
make -j$(nproc)

# Проверяем, скомпилировался ли бинарник
if [ ! -f "objs/bin/mtproto-proxy" ]; then
    echo "ОШИБКА: MTProxy не скомпилировался. Скорее всего, проблема в версии OpenSSL."
    echo "Попробуйте обновить систему: apt update && apt upgrade -y, и запустить скрипт заново."
    exit 1
fi

# Включаем строгий режим обратно
set -e

cd objs/bin

curl -s https://core.telegram.org/getProxySecret -o proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf

# Генерация секрета строго без переноса строки
SECRET="dd${FAKE_DOMAIN}$(head -c 16 /dev/urandom | xxd -p | tr -d '\n')"

#######################################
# MTProxy systemd
#######################################
cat > /etc/systemd/system/mtproxy.service << EOF
[Unit]
Description=MTProxy
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/MTProxy/objs/bin
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u nobody -p 8888 -H ${MTPROXY_PORT} -S $SECRET --aes-pwd proxy-secret proxy-multi.conf -M 1
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

#######################################
# ОБНОВЛЕНИЕ КОНФИГА
#######################################
cat > /opt/MTProxy/update-config.sh << 'EOF'
#!/bin/bash
cd /opt/MTProxy/objs/bin
curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf.new
if [ $? -eq 0 ]; then
    mv proxy-multi.conf.new proxy-multi.conf
    echo "$(date): Конфиг обновлен"
    systemctl restart mtproxy
else
    echo "$(date): Ошибка обновления"
fi
EOF

chmod +x /opt/MTProxy/update-config.sh
(crontab -l 2>/dev/null | grep -v update-config.sh; echo "0 3 * * * /opt/MTProxy/update-config.sh") | crontab -

#######################################
# SSL self-signed
#######################################
mkdir -p /etc/nginx/ssl

openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/self.key \
    -out /etc/nginx/ssl/self.crt \
    -subj "/CN=${IP}"

#######################################
# СТРАНИЦА
#######################################
mkdir -p /var/www/landing

cat > /var/www/landing/index.html <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${IP}</title>
<style>
body { font-family: sans-serif; background: #f8f9fa; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
.container { text-align: center; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 4px 10px rgba(0,0,0,0.05); }
h1 { color: #2c3e50; }
</style>
</head>
<body>
<div class="container">
<h1>Сервер работает</h1>
<p>MTProxy + Nginx успешно настроены.</p>
</div>
</body>
</html>
EOF

#######################################
# NGINX (Универсальный конфиг для любых версий)
#######################################
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/landing.conf <<EOF
server {
    listen 127.0.0.1:${NGINX_PORT} ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/self.crt;
    ssl_certificate_key /etc/nginx/ssl/self.key;

    root /var/www/landing;
    index index.html;
}

server {
    listen 0.0.0.0:80;
    server_name _;

    root /var/www/landing;
    index index.html;
}
EOF

ln -sf /etc/nginx/sites-available/landing.conf /etc/nginx/sites-enabled/landing.conf

#######################################
# SSLH (Без регулярок, простое совпадение)
#######################################
cat > /etc/systemd/system/sslh-mux.service <<EOF
[Unit]
Description=sslh mux
After=network.target

[Service]
ExecStart=/usr/sbin/sslh-select -f \
  --listen 0.0.0.0:443 \
  --ssh 127.0.0.1:${SSH_PORT} \
  --sni ${FAKE_DOMAIN}:127.0.0.1:${MTPROXY_PORT} \
  --tls 127.0.0.1:${NGINX_PORT}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

#######################################
# FIREWALL
#######################################
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp

ufw deny ${NGINX_PORT}/tcp
ufw deny ${MTPROXY_PORT}/tcp

ufw --force enable

#######################################
# ЗАПУСК
#######################################
systemctl daemon-reload
systemctl enable mtproxy
systemctl restart mtproxy

systemctl enable nginx
systemctl restart nginx

systemctl enable sslh-mux
systemctl restart sslh-mux

#######################################
# ФИНАЛ
#######################################
echo ""
echo "=== УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА ==="
echo ""
echo "Ссылка для подключения:"
echo "tg://proxy?server=$IP&port=443&secret=$SECRET"
echo ""
echo "Если ссылка не кликается, используй:"
echo "https://t.me/proxy?server=$IP&port=443&secret=$SECRET"
