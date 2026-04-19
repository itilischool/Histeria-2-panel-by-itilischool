#!/bin/bash
# ================================================
# Hysteria 2 + Web Panel Uninstaller
# Репозиторий: https://github.com/itilischool/Histeria-2-panel-by-itilischool
# ================================================

set -euo pipefail

echo "🗑️  Запуск удаления Hysteria 2 и веб-панели..."

# Останавливаем сервисы
systemctl stop hysteria hysteria-panel nginx 2>/dev/null || true
systemctl disable hysteria hysteria-panel 2>/dev/null || true

# Удаляем файлы и директории
rm -f /etc/systemd/system/hysteria.service
rm -f /etc/systemd/system/hysteria-panel.service
rm -rf /etc/hysteria
rm -rf /opt/hysteria-panel
rm -rf /var/www/mask
rm -f /usr/local/bin/hysteria

# Удаляем сертификаты Let's Encrypt
certbot delete --cert-name "${PANEL_DOMAIN:-}" --non-interactive 2>/dev/null || true
certbot delete --cert-name "${MASK_DOMAIN:-}" --non-interactive 2>/dev/null || true

# Очищаем конфиги Nginx
rm -f /etc/nginx/sites-enabled/panel
rm -f /etc/nginx/sites-enabled/mask
rm -f /etc/nginx/sites-available/panel
rm -f /etc/nginx/sites-available/mask

# Перезапускаем Nginx
nginx -t && systemctl restart nginx 2>/dev/null || true

echo ""
echo "✅ Удаление завершено успешно!"
echo "Сервер очищен от Hysteria 2, панели управления и маскировочного сайта."
echo ""
echo "Если использовался UFW — можешь отключить его вручную: ufw disable"