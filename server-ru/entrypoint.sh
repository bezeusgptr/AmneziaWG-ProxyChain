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

# Подстановка переменных окружения в шаблон конфига awg0
envsubst < /config/awg0.conf.template > /etc/amnezia/amneziawg/awg0.conf

# Если задан ключ Сервера Армении, генерируем конфиг awg1
if [ -n "$AM_PUB_KEY" ] && [ -n "$AM_ENDPOINT" ]; then
    echo "AM_PUB_KEY and AM_ENDPOINT provided. Generating awg1 configuration..."
    envsubst < /config/awg1.conf.template > /etc/amnezia/amneziawg/awg1.conf
fi

echo "Downloading RU subnets..."
ipset create ru_subnets hash:net || true
curl -sSL https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr | sed -e 's/^/add ru_subnets /' | ipset restore || echo "Failed to load some ru subnets"

echo "Configuring iptables for Selective Routing..."
# Маркируем пакеты от клиента (awg0), которые идут НЕ в российские подсети и НЕ к приватным адресам
iptables -t mangle -A PREROUTING -i awg0 -m set ! --match-set ru_subnets dst -d 0.0.0.0/0 ! -d 10.0.0.0/8 ! -d 172.16.0.0/12 ! -d 192.168.0.0/16 -j MARK --set-mark 1

# Настраиваем Policy Routing для маркированных пакетов (отправляем в таблицу 100, которая маршрутизирует через awg1)
ip rule add fwmark 1 table 100 || true

# Настраиваем NAT для трафика, уходящего в интернет напрямую с Сервера РФ (российские IP)
iptables -t nat -A POSTROUTING -o eth0 -m set --match-set ru_subnets dst -j MASQUERADE

echo "Starting awg-quick on awg0..."
env WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go awg-quick up awg0

if [ -f /etc/amnezia/amneziawg/awg1.conf ]; then
    echo "Starting awg-quick on awg1 (Link to AM)..."
    env WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go awg-quick up awg1
    
    # NAT для трафика, уходящего в туннель до Армении
    iptables -t nat -A POSTROUTING -o awg1 -j MASQUERADE
fi

echo "AmneziaWG is running. Tailing logs..."
# Оставляем контейнер работать
tail -f /dev/null
