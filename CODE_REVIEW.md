# Code Review: AmneziaWG-ProxyChain

## Контекст

Проект создаёт Docker-инфраструктуру для proxy-цепочки на базе AmneziaWG:
**Клиент -> Сервер РФ (awg0/awg1) -> Сервер Армения (awg0) -> Интернет.**

Сервер РФ выполняет selective routing: российские IP идут напрямую через eth0, остальной трафик маршрутизируется через туннель awg1 до Армении.

Ниже приведены найденные ошибки и рекомендации по их устранению, отсортированные по степени критичности.

---

## 1. CRITICAL: Сборка Docker-образа сломана

**Файл:** `shared/Dockerfile:32`
```dockerfile
COPY entrypoint.sh /entrypoint.sh
```
Build context в `docker-compose.yml` - корень проекта (`.`). Файла `entrypoint.sh` в корне **не существует** - скрипты лежат в `server-ru/entrypoint.sh` и `server-am/entrypoint.sh`. Сборка образа упадёт с ошибкой на этом шаге.

Хотя docker-compose монтирует `entrypoint.sh` через volumes (строки 14, 40), это происходит **после** сборки образа. `COPY` обязан отработать на этапе build.

**Рекомендация:** Убрать `COPY entrypoint.sh /entrypoint.sh` и `RUN chmod +x /entrypoint.sh` из Dockerfile, так как entrypoint монтируется через volume. Либо создать общий базовый `entrypoint.sh` в корне проекта.

---

## 2. CRITICAL: Пиры закомментированы - туннели не работают

**Файлы:**
- `server-ru/awg0.conf.template:21-23` - пир клиента закомментирован
- `server-am/awg0.conf.template:22-25` - пир Сервера РФ закомментирован

Оба сервера поднимутся, но без `[Peer]` секций не примут ни одного входящего соединения. Цепочка полностью нерабочая.

`deploy.sh` извлекает публичные ключи (строки 13-14), выводит их на экран, но **не инжектит обратно** в конфигурацию. Оператору предлагается вручную вписать ключи, но для этого нужно раскомментировать пиры и заменить плейсхолдеры - это нигде не задокументировано.

**Рекомендация:** Автоматизировать обмен ключами в `deploy.sh`: после генерации ключей подставить их в конфиги через `envsubst` или `sed`, перезапустить контейнеры. Пиры не должны быть закомментированы - вместо этого использовать переменные окружения (как уже сделано для `${AM_PUB_KEY}` в `awg1.conf.template`).

---

## 3. HIGH: Нет chmod 600 на приватные ключи

**Файлы:** `server-ru/entrypoint.sh:10`, `server-am/entrypoint.sh:8`

Приватные ключи генерируются через `tee` без явного `umask 077` или последующего `chmod 600`. По умолчанию файл будет создан с umask процесса (обычно 022), т.е. world-readable.

**Рекомендация:** Добавить после генерации:
```bash
chmod 600 /etc/amnezia/amneziawg/server_private_key
```

---

## 4. HIGH: Race condition в deploy.sh

**Файл:** `deploy.sh:10-14`
```bash
sleep 3
RU_KEY=$(docker exec awg-ru cat /etc/amnezia/amneziawg/server_public_key)
AM_KEY=$(docker exec awg-am cat /etc/amnezia/amneziawg/server_public_key)
```

Фиксированная задержка 3 секунды не гарантирует, что контейнеры успели сгенерировать ключи. На медленных системах или при долгой сборке образа скрипт прочитает несуществующие файлы. Ошибка не обрабатывается - переменные будут пустыми.

**Рекомендация:** Заменить `sleep 3` на polling с таймаутом:
```bash
for i in $(seq 1 30); do
    docker exec awg-ru test -f /etc/amnezia/amneziawg/server_public_key 2>/dev/null && break
    sleep 1
done
```
Плюс добавить проверку, что ключи не пустые после извлечения.

---

## 5. HIGH: ip rule создаётся до заполнения таблицы маршрутизации

**Файлы:** `server-ru/entrypoint.sh:34`, `server-ru/awg1.conf.template:7`

Директива `Table = 100` в `awg1.conf.template` заставляет `awg-quick` автоматически добавлять маршруты для `AllowedIPs` в таблицу 100 при поднятии интерфейса. Это **правильно**, но есть нюанс порядка выполнения:

- Строка 34: `ip rule add fwmark 1 table 100` выполняется **до** `awg-quick up awg1` (строка 44)
- Между запуском `awg0` (строка 40) и `awg1` (строка 44) таблица 100 пуста
- Если в этот момент придёт трафик от клиента через `awg0`, маркированные пакеты будут дропнуты

**Рекомендация:** Перенести `ip rule add fwmark 1 table 100` **после** `awg-quick up awg1`, чтобы правило заработало только когда таблица маршрутизации уже заполнена.

---

## 6. HIGH: Скачивание ipset-списка без таймаута и валидации

**Файл:** `server-ru/entrypoint.sh:27`
```bash
curl -sSL https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr \
  | sed -e 's/^/add ru_subnets /' | ipset restore || echo "Failed to load some ru subnets"
```

Проблемы:
1. **Нет таймаута curl** - при недоступности GitHub контейнер зависнет навсегда
2. **Нет валидации формата** - если контент URL изменится (HTML вместо CIDR), `ipset restore` получит мусор
3. **Ошибка маскируется** - `|| echo` позволяет скрипту продолжить без рабочего ipset, selective routing молча не работает
4. **Нет fallback** - если GitHub недоступен (а в РФ он может быть заблокирован!), нет запасного списка

**Рекомендация:**
```bash
curl --max-time 30 --connect-timeout 10 -sSL "$URL" -o /tmp/ru.cidr
# Валидация: проверить, что файл содержит CIDR-нотацию
if grep -qP '^\d+\.\d+\.\d+\.\d+/\d+$' /tmp/ru.cidr; then
    sed -e 's/^/add ru_subnets /' /tmp/ru.cidr | ipset restore
else
    echo "ERROR: Invalid CIDR data, falling back to embedded list"
    # использовать встроенный минимальный список
fi
```

---

## 7. MEDIUM: Правила iptables дублируются при рестарте контейнера

**Файл:** `server-ru/entrypoint.sh:31,37,47`

При рестарте контейнера (`restart: unless-stopped`) `entrypoint.sh` выполняется заново. Все iptables-правила добавляются через `-A` (append) без предварительной очистки. Это приводит к накоплению дублирующих правил.

Аналогичная проблема в `server-am/awg0.conf.template:19` (PostUp), хотя `awg-quick` при `down` выполнит PostDown.

**Рекомендация:** Добавить в начало `entrypoint.sh` очистку:
```bash
iptables -t mangle -F PREROUTING 2>/dev/null || true
iptables -t nat -F POSTROUTING 2>/dev/null || true
```
Или использовать `-C` (check) перед `-A` для идемпотентности.

---

## 8. MEDIUM: Избыточное условие `-d 0.0.0.0/0` в iptables

**Файл:** `server-ru/entrypoint.sh:31`
```bash
iptables -t mangle -A PREROUTING -i awg0 -m set ! --match-set ru_subnets dst \
  -d 0.0.0.0/0 ! -d 10.0.0.0/8 ! -d 172.16.0.0/12 ! -d 192.168.0.0/16 -j MARK --set-mark 1
```

`-d 0.0.0.0/0` совпадает с **любым** адресом назначения - это условие логически бессмысленно и только засоряет правило. Его можно безопасно удалить без изменения поведения.

---

## 9. MEDIUM: Одинаковые обфускационные параметры на всех интерфейсах

**Файлы:** все `.conf.template`

Параметры AmneziaWG (`Jc=4, Jmin=50, Jmax=1000, S1=80, S2=120, H1=1, H2=2, H3=3, H4=4`) захардкожены одинаково во всех трёх конфигах. Это создаёт единый fingerprint для DPI-анализа, что снижает эффективность обфускации.

**Рекомендация:** Сделать параметры конфигурируемыми через переменные окружения и генерировать случайные значения при первом запуске. Параметры на обоих концах одного туннеля должны совпадать, но для `awg0` (клиент->РФ) и `awg1` (РФ->Армения) они могут и должны отличаться.

---

## 10. MEDIUM: ipset create с `|| true` маскирует ошибки

**Файл:** `server-ru/entrypoint.sh:26`
```bash
ipset create ru_subnets hash:net || true
```

Это маскирует не только ожидаемую ситуацию "set already exists", но и любые другие ошибки (нет прав, ipset не установлен, и т.д.).

**Рекомендация:**
```bash
ipset create ru_subnets hash:net 2>/dev/null || ipset flush ru_subnets
```

---

## 11. MEDIUM: Docker-образ не воспроизводим

**Файл:** `shared/Dockerfile:7,13`

`git clone` без указания тега или коммита. Каждая сборка может дать разный результат. При breaking changes в upstream проект внезапно перестанет собираться.

**Рекомендация:** Зафиксировать конкретный коммит или тег:
```dockerfile
RUN git clone --branch v1.0.1 --depth 1 https://github.com/amnezia-vpn/amneziawg-go.git /awg-go
```

---

## 12. LOW: `tail -f /dev/null` без healthcheck

**Файлы:** `server-ru/entrypoint.sh:52`, `server-am/entrypoint.sh:20`

`tail -f /dev/null` - рабочий приём для удержания контейнера, но маскирует реальное состояние сервиса. Если `amneziawg-go` упадёт, контейнер останется в статусе "Running".

**Рекомендация:** Добавить healthcheck в `docker-compose.yml`:
```yaml
healthcheck:
  test: ["CMD", "awg", "show", "awg0"]
  interval: 30s
  timeout: 5s
  retries: 3
```

---

## 13. LOW: docker-compose `version: '3.8'` устарел

**Файл:** `docker-compose.yml:1`

С Docker Compose V2 ключ `version` игнорируется и не нужен. Можно безопасно удалить.

---

## 14. LOW: Документация расходится с реализацией

**Файл:** `architecture.md:19`

В документации сказано "раз в сутки скачивает список всех IPv4 подсетей России". В реальности список скачивается **один раз при старте контейнера**. Периодическое обновление (cron и т.п.) не реализовано.

---

## Сводная таблица

| # | Серьёзность | Проблема | Файл |
|---|-------------|----------|------|
| 1 | CRITICAL | `COPY entrypoint.sh` в Dockerfile - файла нет в build context | `shared/Dockerfile:32` |
| 2 | CRITICAL | Пиры закомментированы, туннели не работают | `awg0.conf.template` (оба) |
| 3 | HIGH | Нет `chmod 600` на приватный ключ | `entrypoint.sh` (оба) |
| 4 | HIGH | Race condition: `sleep 3` без проверки готовности | `deploy.sh:10-14` |
| 5 | HIGH | `ip rule` до `awg-quick up awg1` (пустая таблица 100) | `server-ru/entrypoint.sh:34 vs 44` |
| 6 | HIGH | `curl` без таймаута, без валидации, без fallback | `server-ru/entrypoint.sh:27` |
| 7 | MEDIUM | iptables правила дублируются при рестарте | `server-ru/entrypoint.sh:31,37,47` |
| 8 | MEDIUM | Бессмысленный `-d 0.0.0.0/0` в iptables | `server-ru/entrypoint.sh:31` |
| 9 | MEDIUM | Одинаковые AWG-параметры = единый DPI-fingerprint | все `.conf.template` |
| 10 | MEDIUM | `ipset create \|\| true` маскирует реальные ошибки | `server-ru/entrypoint.sh:26` |
| 11 | MEDIUM | `git clone` без version pinning | `shared/Dockerfile:7,13` |
| 12 | LOW | `tail -f /dev/null` без healthcheck | `entrypoint.sh` (оба) |
| 13 | LOW | Устаревший `version: '3.8'` | `docker-compose.yml:1` |
| 14 | LOW | Документация расходится с реализацией | `architecture.md:19` |

---

## Рекомендуемый приоритет исправлений

1. Починить Dockerfile (убрать `COPY entrypoint.sh` или создать файл)
2. Автоматизировать обмен ключами и раскомментировать пиры
3. Добавить `chmod 600` на приватные ключи
4. Заменить `sleep` на polling в `deploy.sh`
5. Переупорядочить `ip rule` / `awg-quick up` в `entrypoint.sh`
6. Добавить таймаут и валидацию для `curl`
7. Добавить очистку iptables при рестарте
8. Добавить healthcheck в `docker-compose.yml`
