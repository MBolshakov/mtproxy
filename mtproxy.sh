Твой скрипт написан довольно хорошо: учтены права root, используется `set -e`, корректно настроен фаервол. Однако в нем есть **одна критическая логическая ошибка**, связанная с маршрутизацией трафика через `sslh`, и пара недочетов, которые приведут к тому, что MTProxy либо не запустится, либо будет моментально блокироваться провайдером (DPI).

### Описание ошибок

**1. Критическая ошибка: Конфликт `sslh` и TLS-трафика (MTProxy не будет работать)**
В конфиге `sslh` ты указываешь:
`--tls 127.0.0.1:${NGINX_PORT}` (отправлять весь TLS в Nginx)
`--anyprot 127.0.0.1:${MTPROXY_PORT}` (остальное в MTProxy)
**В чем проблема:** Клиент Telegram при подключении отправляет TLS-ClientHello. `sslh` видит, что это TLS, и перенаправляет его в Nginx. Nginx пытается расшифровать трафик, не находит подходящего SNI (имени домена) и рвет соединение. До MTProxy трафик даже не доходит.
**Решение:** Использовать SNI-маршрутизацию. Мы должны заставить Telegram-клиент приходить с одним SNI (например, `microsoft.com`), а обычные браузеры — со своими. `sslh` разделит их по заголовку SNI до того, как начнет анализировать сам протокол.

**2. Ошибка формата секрета (Мгновенная блокировка DPI)**
Ты генерируешь секрет так: `SECRET=$(head -c 16 /dev/urandom | xxd -ps)`.
Это "голый" секрет. Если пустить его через 443 порт, провайдер увидит нестандартный TLS-握手 (handshake) и заблокирует IP по DPI.
**Решение:** Секрет должен начинаться с `dd` (Fake TLS) и содержать домен для SNI. Например: `ddmicrosoft.com[случайные_байты]`. Именно этот домен мы потом пропишем в `sslh`.

**3. Жесткая привязка `sslh` к IP**
`--listen ${IP}:${MUX_PORT}` — плохая практика. Если у сервера несколько сетевых интерфейсов или поменяется IP после перезагрузки, `sslh` не запустится.
**Решение:** Слушать на `0.0.0.0:443`.

**4. Потенциальная проблема: OpenSSL 3.x (Официальный MTProxy устарел)**
Официальный репозиторий `TelegramMessenger/MTProxy` больше не обновляется. На современных Ubuntu 22.04/24.04 скрипт упадет на этапе `make` с ошибкой компиляции (из-за удаленных функций в OpenSSL 3). 
*В исправленном скрипте я оставил твой код компиляции, но в комментариях добавил команду для установки OpenSSL 1.1, если make упадет.*

---

### Исправленный вариант скрипта

```bash
#!/bin/bash

set -e

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
FAKE_DOMAIN="microsoft.com" # Домен для обхода DPI

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

# Если на этапе make выдаст ошибку OpenSSL 3.x, раскомментируй строку ниже:
# sed -i 's/CFLAGS=/CFLAGS=-Wno-error\ /g' Makefile && apt install -y libssl1.1 2>/dev/null || true

make
cd objs/bin

curl -s https://core.telegram.org/getProxySecret -o proxy-secret
curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf

# ИСПРАВЛЕНИЕ: Генерируем секрет в формате dd (Fake TLS + SNI)
SECRET="dd${FAKE_DOMAIN}$(head -c 16 /dev/urandom | xxd -ps)"

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
<title>${IP} | Сервер готов</title>
<style>
body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: #f8f9fa;
    display: flex;
    justify-content: center;
    align-items: center;
    height: 100vh;
    margin: 0;
}
.container { max-width: 600px; text-align: center; }
h1 { color: #2c3e50; }
.box { background: white; padding: 20px; margin-top: 20px; border-radius: 8px; }
</style>
</head>
<body>
<div class="container">
<h1>${IP}</h1>
<p>Сервер успешно настроен 🎉</p>
<div class="box">
<ul style="list-style:none;padding:0;text-align:left;">
<li>✓ MTProxy работает на 443 порту</li>
<li>✓ Nginx работает на 80 и 443 порту</li>
<li>✓ sslh разделяет трафик</li>
</ul>
</div>
</div>
</body>
</html>
EOF

#######################################
# NGINX
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
# SSLH (ИСПРАВЛЕН)
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

# Закрываем внешние порты внутренних сервисов
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
echo "=== ГОТОВО ==="
echo ""
echo "Ссылка для подключения:"
echo "tg://proxy?server=$IP&port=443&secret=$SECRET"
echo ""
echo "https://t.me/proxy?server=$IP&port=443&secret=$SECRET"
echo ""
echo "HTTP:  http://$IP"
echo "HTTPS: https://$IP"
echo ""
echo "Конфиг обновляется ежедневно в 3:00"
echo ""
echo "Управление:"
echo "  systemctl status mtproxy"
echo "  systemctl restart mtproxy"
echo "  systemctl stop mtproxy"
echo "  systemctl start mtproxy"
echo ""
echo "Логи:"
echo "  journalctl -u mtproxy -f"
echo "  journalctl -u sslh-mux -f"
echo ""
echo "Ручное обновление:"
echo "  /opt/MTProxy/update-config.sh"
```
