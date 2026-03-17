#!/bin/bash
set -e

# Убедимся, что директория существует
mkdir -p /etc/amnezia/amneziawg

# Если приватный ключ сервера не существует - генерируем его
if [ ! -f /etc/amnezia/amneziawg/server_private_key ]; then
    echo "Generating new server keys..."
    awg genkey | tee /etc/amnezia/amneziawg/server_private_key | awg pubkey > /etc/amnezia/amneziawg/server_public_key
fi

SERVER_PRIV_KEY=$(cat /etc/amnezia/amneziawg/server_private_key)
export SERVER_PRIV_KEY

# Включаем форвардинг пакетов (sysctl может быть read-only в докере без privileged)
# Поэтому мы делаем это через конфигурацию контейнера или ожидаем, что включено.
# Подстановка переменных окружения в шаблон конфига
envsubst < /config/awg0.conf.template > /etc/amnezia/amneziawg/awg0.conf

echo "Starting awg-quick on awg0..."
env WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go awg-quick up awg0

echo "AmneziaWG is running. Tailing logs..."
# Оставляем контейнер работать
tail -f /dev/null
