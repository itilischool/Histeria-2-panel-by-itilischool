#!/bin/bash
# ================================================
# Hysteria 2 + Web Panel Auto Installer
# Репозиторий: https://github.com/itilischool/Histeria-2-panel-by-itilischool
# ================================================

set -eo pipefail

echo "Запуск автоустановки Hysteria 2 с веб-панелью..."

# ====================== ВВОД ДАННЫХ ======================
read -p "Домен для панели управления (например: panel.digitalteen.ru): " PANEL_DOMAIN
read -p "Домен для маскировочного сайта (например: digitalteen.ru): " MASK_DOMAIN
read -p "Email для Let's Encrypt: " LETS_EMAIL
read -p "Порт для Hysteria 2 [по умолчанию 8443]: " HY_PORT
HY_PORT=${HY_PORT:-8443}
read -p "Пароль администратора панели (минимум 12 символов): " ADMIN_PASS
read -p "Включить UFW firewall? (y/n): " ENABLE_UFW
read -p "Включить BBR? (y/n): " ENABLE_BBR

if [[ -z "$PANEL_DOMAIN" || -z "$MASK_DOMAIN" || -z "$LETS_EMAIL" || -z "$ADMIN_PASS" ]]; then
  echo "Ошибка: Все обязательные поля должны быть заполнены!"
  exit 1
fi

if [[ ${#ADMIN_PASS} -lt 12 ]]; then
  echo "Ошибка: Пароль должен быть не менее 12 символов!"
  exit 1
fi

# ====================== ПОДГОТОВКА ======================
apt-get update && apt-get upgrade -y
apt-get install -y curl wget nginx python3 python3-venv python3-pip certbot python3-certbot-nginx ufw sqlite3

if [[ "$ENABLE_BBR" == "y" || "$ENABLE_BBR" == "Y" ]]; then
  echo "Включаем BBR..."
  echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p
fi

# ====================== HYSTERIA 2 ======================
echo "Устанавливаем Hysteria 2..."
curl -Lo /usr/local/bin/hysteria https://download.hysteria.network/app/latest/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

mkdir -p /etc/hysteria /opt/hysteria-panel/static /var/www/mask

# ====================== ПАНЕЛЬ ======================
echo "Скачиваем файлы панели..."
curl -fsSL https://raw.githubusercontent.com/itilischool/Histeria-2-panel-by-itilischool/main/panel/main.py -o /opt/hysteria-panel/main.py
curl -fsSL https://raw.githubusercontent.com/itilischool/Histeria-2-panel-by-itilischool/main/panel/static/index.html -o /opt/hysteria-panel/static/index.html

sed -i "s/__ADMIN_PASS_PLACEHOLDER__/${ADMIN_PASS}/g" /opt/hysteria-panel/main.py

cd /opt/hysteria-panel
python3 -m venv venv
venv/bin/pip install --upgrade pip
venv/bin/pip install fastapi uvicorn pydantic PyJWT==2.8.0 bcrypt pyyaml python-multipart

# ====================== CONFIG HYSTERIA ======================
cat > /etc/hysteria/config.yaml << EOF
listen: :${HY_PORT}

acme:
  domains:
    - ${MASK_DOMAIN}
  email: ${LETS_EMAIL}
  ca: letsencrypt

auth:
  type: userpass
  userpass: {}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF

# ====================== SYSTEMD ======================
cat > /etc/systemd/system/hysteria.service << EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/hysteria-panel.service << EOF
[Unit]
Description=Hysteria 2 Control Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hysteria-panel
ExecStart=/opt/hysteria-panel/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria
systemctl enable --now hysteria-panel

# ====================== NGINX ======================
echo "Настраиваем Nginx..."

cat > /var/www/mask/index.html << 'HTML'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Tech Insights</title><style>body{font-family:system-ui;background:#0a0a0a;color:#ddd;padding:40px}</style></head>
<body>
<h1>Tech Insights</h1>
<p>Актуальные статьи о технологиях, безопасности и разработке.</p>
</body></html>
HTML

cat > /etc/nginx/sites-available/panel << EOF
server {
    listen 80;
    server_name ${PANEL_DOMAIN};
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

cat > /etc/nginx/sites-available/mask << EOF
server {
    listen 80;
    server_name ${MASK_DOMAIN};
    root /var/www/mask;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf /etc/nginx/sites-available/panel /etc/nginx/sites-enabled/
ln -sf /etc/nginx/sites-available/mask /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl restart nginx

# ====================== SSL ======================
echo "Получаем SSL-сертификаты..."
certbot certonly --nginx --domains "${PANEL_DOMAIN},${MASK_DOMAIN}" \
  --non-interactive --agree-tos --email "${LETS_EMAIL}" --redirect || echo "SSL не удалось получить автоматически (проверь email)"

# ====================== UFW ======================
if [[ "$ENABLE_UFW" == "y" || "$ENABLE_UFW" == "Y" ]]; then
  echo "Настраиваем UFW..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow ${HY_PORT}/udp
  ufw --force enable
fi

# ====================== СОЗДАЁМ UNINSTALL.SH ======================
cat > /opt/hysteria-panel/uninstall.sh << 'UNINSTALL'
#!/bin/bash
echo "Удаление Hysteria 2 и панели..."

systemctl stop hysteria hysteria-panel nginx 2>/dev/null || true
systemctl disable hysteria hysteria-panel 2>/dev/null || true

rm -f /etc/systemd/system/hysteria.service
rm -f /etc/systemd/system/hysteria-panel.service
rm -rf /etc/hysteria /opt/hysteria-panel /var/www/mask /usr/local/bin/hysteria

rm -f /etc/nginx/sites-enabled/panel /etc/nginx/sites-enabled/mask
rm -f /etc/nginx/sites-available/panel /etc/nginx/sites-available/mask

nginx -t && systemctl restart nginx 2>/dev/null || true

echo "Удаление завершено успешно."
UNINSTALL

chmod +x /opt/hysteria-panel/uninstall.sh

# ====================== ФИНАЛ ======================
echo ""
echo "=================================================="
echo "УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!"
echo "=================================================="
echo "Панель управления: https://${PANEL_DOMAIN}"
echo "Логин: admin"
echo "Пароль: ${ADMIN_PASS}"
echo "Маскировочный сайт: https://${MASK_DOMAIN}"
echo "Hysteria слушает UDP порт: ${HY_PORT}"
echo ""
echo "Для удаления всей системы выполните:"
echo "   /opt/hysteria-panel/uninstall.sh"
echo "=================================================="
