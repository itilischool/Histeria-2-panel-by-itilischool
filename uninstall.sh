#!/bin/bash
set -e

echo "🗑️  Удаление Hysteria 2 + Панели управления..."

systemctl stop hysteria hysteria-panel nginx 2>/dev/null || true
systemctl disable hysteria hysteria-panel 2>/dev/null || true

rm -f /etc/systemd/system/hysteria.service
rm -f /etc/systemd/system/hysteria-panel.service
rm -rf /etc/hysteria
rm -rf /opt/hysteria-panel
rm -rf /var/www/mask
rm -f /usr/local/bin/hysteria

# Удаление сертификатов (осторожно)
certbot delete --cert-name "${PANEL_DOMAIN:-}" --non-interactive 2>/dev/null || true
certbot delete --cert-name "${MASK_DOMAIN:-}" --non-interactive 2>/dev/null || true

rm -f /etc/nginx/sites-enabled/panel
rm -f /etc/nginx/sites-enabled/mask

nginx -t && systemctl restart nginx 2>/dev/null || true

echo "✅ Удаление завершено. Сервер очищен от Hysteria 2 и панели."