#!/bin/bash
set -e

# Скрипт для автоматического поднятия всех сервисов и отображения ключей
echo "Starting AmneziaWG Proxy Chain..."

docker compose up -d

echo "Waiting for containers to generate keys..."
sleep 3

# Извлекаем и показываем публичные ключи серверов для конфигурации
RU_KEY=$(docker exec awg-ru cat /etc/amnezia/amneziawg/server_public_key)
AM_KEY=$(docker exec awg-am cat /etc/amnezia/amneziawg/server_public_key)

echo "----------------------------------------"
echo "Public Key (Server RU): $RU_KEY"
echo "Public Key (Server AM): $AM_KEY"
echo "----------------------------------------"
echo "Use these keys in your AWG Peer configurations."
