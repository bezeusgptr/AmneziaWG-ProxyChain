#!/bin/bash
set -e

# Убедимся, что директория существует
mkdir -p /etc/amnezia/amneziawg

# Если приватный ключ сервера не существует - генерируем его
if [ ! -f /etc/amnezia/amneziawg/server_private_key ]; then
    echo "Generating new server keys..."
    umask 077
    awg genkey | tee /etc/amnezia/amneziawg/server_private_key | awg pubkey > /etc/amnezia/amneziawg/server_public_key
    chmod 600 /etc/amnezia/amneziawg/server_private_key
fi

SERVER_PRIV_KEY=$(cat /etc/amnezia/amneziawg/server_private_key)
export SERVER_PRIV_KEY

# Подстановка переменных окружения в шаблон конфига awg0
envsubst < /config/awg0.conf.template > /etc/amnezia/amneziawg/awg0.conf

# Если задан ключ Сервера Армении, генерируем конфиг awg1
if [ -n "$AM_PUB_KEY" ] && [ -n "$AM_ENDPOINT" ]; then
    echo "AM_PUB_KEY and AM_ENDPOINT provided. Generating awg1 configuration..."
    envsubst < /config/awg1.conf.template > /etc/amnezia/amneziawg/awg1.conf
fi

echo "Downloading RU subnets..."
ipset create ru_subnets hash:net 2>/dev/null || ipset flush ru_subnets

RU_CIDR_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr"
if curl --max-time 30 --connect-timeout 10 -sSL "$RU_CIDR_URL" -o /tmp/ru.cidr; then
    # Валидация: проверяем, что файл содержит CIDR-записи
    if grep -qP '^\d+\.\d+\.\d+\.\d+/\d+$' /tmp/ru.cidr; then
        sed -e 's/^/add ru_subnets /' /tmp/ru.cidr | ipset restore -! || echo "WARNING: Failed to load some ru subnets"
    else
        echo "ERROR: Downloaded file does not contain valid CIDR data"
    fi
    rm -f /tmp/ru.cidr
else
    echo "ERROR: Failed to download RU subnets (curl timeout or network error)"
fi

echo "Configuring iptables for Selective Routing..."

# Очистка правил при рестарте для предотвращения дублирования
iptables -t mangle -F PREROUTING 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true

# Маркируем пакеты от клиента (awg0), которые идут НЕ в российские подсети и НЕ к приватным адресам
iptables -t mangle -A PREROUTING -i awg0 -m set ! --match-set ru_subnets dst ! -d 10.0.0.0/8 ! -d 172.16.0.0/12 ! -d 192.168.0.0/16 -j MARK --set-mark 1

# Настраиваем NAT для трафика, уходящего в интернет напрямую с Сервера РФ (российские IP)
iptables -t nat -A POSTROUTING -o eth0 -m set --match-set ru_subnets dst -j MASQUERADE

echo "Starting awg-quick on awg0..."
env WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go awg-quick up awg0

if [ -f /etc/amnezia/amneziawg/awg1.conf ]; then
    echo "Starting awg-quick on awg1 (Link to AM)..."
    env WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go awg-quick up awg1

    # Настраиваем Policy Routing ПОСЛЕ поднятия awg1, чтобы таблица 100 была уже заполнена
    ip rule add fwmark 1 table 100 2>/dev/null || true

    # NAT для трафика, уходящего в туннель до Армении
    iptables -t nat -A POSTROUTING -o awg1 -j MASQUERADE
fi

echo "AmneziaWG is running. Tailing logs..."
# Оставляем контейнер работать
tail -f /dev/null
