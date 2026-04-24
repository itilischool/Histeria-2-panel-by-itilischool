#!/bin/bash
set -e

echo "🚀 Hysteria2 Panel Installer"
echo "============================="

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "❌ Запустите скрипт от имени root (sudo ./install.sh)"
   exit 1
fi

# Обновление и установка зависимостей
echo "📦 Обновление системы..."
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget unzip jq

# Установка Node.js
echo "📦 Установка Node.js..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
    apt install -y -qq nodejs
fi

# Определение архитектуры и скачивание Hysteria2
echo "📦 Скачивание Hysteria2..."
HYSTERIA_VERSION=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name')
HYSTERIA_ARCH=$(uname -m)
[[ "$HYSTERIA_ARCH" == "x86_64" ]] && HYSTERIA_ARCH="amd64"
[[ "$HYSTERIA_ARCH" == "aarch64" ]] && HYSTERIA_ARCH="arm64"

wget -q "https://github.com/apernet/hysteria/releases/download/$HYSTERIA_VERSION/hysteria-linux-$HYSTERIA_ARCH" -O /usr/local/bin/hysteria
chmod +x /usr/local/bin/hysteria

# Ввод параметров
echo ""
read -p "📦 Домен или IP сервера: " DOMAIN
read -p "🔌 Порт Hysteria2 [58066]: " PORT
PORT=${PORT:-58066}
read -p "🔐 Obfs пароль: " OBFS_PASS
read -p "🔐 Пароль для панели [admin]: " PANEL_PASS
PANEL_PASS=${PANEL_PASS:-admin}

# Генерация пароля аутентификации Hysteria2
AUTH_PASS=$(openssl rand -hex 16)

# Создание директорий
mkdir -p /etc/hysteria2
mkdir -p /opt/hysteria-panel/panel

# Конфиг Hysteria2 (без TLS для простоты, как в примере пользователя)
cat > /etc/hysteria2/config.yaml << EOF
listen: :$PORT

auth:
  type: password
  password: $AUTH_PASS

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS

# TLS отключён для совместимости с insecure=1 в клиентах
# Для продакшена рекомендуется добавить ACME/Let's Encrypt
EOF

# systemd сервис для Hysteria2
cat > /etc/systemd/system/hysteria2.service << 'EOF'
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria2/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Копирование файлов панели
echo "📁 Копирование файлов панели..."
cp -r panel/* /opt/hysteria-panel/panel/

# Создание config.json для панели
cat > /opt/hysteria-panel/panel/config.json << EOF
{
  "domain": "$DOMAIN",
  "port": $PORT,
  "obfsPassword": "$OBFS_PASS",
  "authPassword": "$AUTH_PASS",
  "panelPort": 3000,
  "panelPass": "$PANEL_PASS"
}
EOF

# Инициализация users.json
echo '[]' > /opt/hysteria-panel/panel/users.json

# Установка зависимостей панели
cd /opt/hysteria-panel/panel
npm install --production --silent

# systemd сервис для панели
cat > /etc/systemd/system/hysteria-panel.service << EOF
[Unit]
Description=Hysteria2 Panel
After=network.target hysteria2.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/hysteria-panel/panel
ExecStart=/usr/bin/node /opt/hysteria-panel/panel/server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Запуск сервисов
echo "🔄 Запуск сервисов..."
systemctl daemon-reload
systemctl enable --now hysteria2
systemctl enable --now hysteria-panel

# Открытие порта в фаерволе
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow $PORT/tcp > /dev/null 2>&1
    ufw allow 3000/tcp > /dev/null 2>&1
fi

echo ""
echo "✅ Установка завершена!"
echo "━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 Панель: http://YOUR_IP:3000"
echo "🔑 Пароль панели: $PANEL_PASS"
echo "🔌 Порт Hysteria2: $PORT"
echo "📋 Конфиг: /etc/hysteria2/config.yaml"
echo ""
echo "⚠️  Откройте порт $PORT в фаерволе вашего хостинг-провайдера!"
echo "🔒 Для продакшена: настройте TLS и ограничьте доступ к панели через Nginx."