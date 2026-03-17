FROM golang:1.22-alpine AS builder

# Установка зависимостей для сборки
RUN apk add --no-cache make gcc musl-dev git linux-headers

# Сборка amneziawg-go (userspace реализация)
RUN git clone https://github.com/amnezia-vpn/amneziawg-go.git /awg-go && \
    cd /awg-go && \
    make && \
    cp amneziawg-go /usr/bin/amneziawg-go

# Сборка amneziawg-tools (утилиты awg и awg-quick)
RUN git clone https://github.com/amnezia-vpn/amneziawg-tools.git /awg-tools && \
    cd /awg-tools/src && \
    make && \
    make install

# Финальный легковесный образ
FROM alpine:3.19

# Установка iptables, сетевых утилит, curl и ipset для выборочной маршрутизации
RUN apk add --no-cache iptables ipset curl bash iproute2 openresolv gettext

# Перенос бинарных файлов из builder'а
COPY --from=builder /usr/bin/amneziawg-go /usr/bin/amneziawg-go
COPY --from=builder /usr/bin/awg /usr/bin/awg
COPY --from=builder /usr/bin/awg-quick /usr/bin/awg-quick

# Рабочая директория для конфигураций
WORKDIR /etc/amnezia/amneziawg

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
