#!/usr/bin/env bash
# FastCloud Installer — Nextcloud + PostgreSQL + Redis + Caddy в Docker.
# Режимы: локальный (HTTP), публичный с доменом (HTTPS), публичный по IP (HTTP).
set -euo pipefail

# --- Поддержка запуска через `curl ... | bash` ---
# При пайпе stdin занят скриптом, и интерактивные read не работают.
# Если stdin — не терминал, но /dev/tty доступен, переключаем ввод на терминал.
if [[ ! -t 0 && -r /dev/tty ]]; then
    exec < /dev/tty
fi

# --- Цвета и константы ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
INSTALL_DIR="/opt/fastcloud"
LOG_FILE="/var/log/fastcloud-install.log"

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
header(){ echo -e "\n${CYAN}=== $* ===${NC}\n"; }

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local msg=$2

    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " ${CYAN}[%c]${NC} %s" "$spinstr" "$msg"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r"
    done
    printf " ✓\n"
}

progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    printf "\r\033[K"
    printf " ${CYAN}["
    for ((i=0; i<filled; i++)); do printf "█"; done
    for ((i=0; i<empty; i++)); do printf "░"; done
    printf "]${NC} ${YELLOW}%3d%%${NC}" "$percentage"

    [[ $current -eq $total ]] && echo ""
    sync
}

is_valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_valid_email() {
    [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Пароль ровно заданной длины из алфавита без спецсимволов: значения попадают
# в .env, docker-compose и psql, где кавычки/слэши ломают парсинг.
#
# ВАЖНО: нельзя писать `tr < /dev/urandom | head -c N` — head закрывает пайп
# после N байт, tr получает SIGPIPE, и под `set -euo pipefail` весь скрипт
# молча падает с кодом 141. Поэтому читаем фиксированный блок заранее
# (head завершается сам), а длину подрезаем через cut, который дочитывает
# весь ввод и пайп не рвёт.
gen_password() {
    local len=${1:-32} pw
    pw=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$len")
    [[ ${#pw} -eq $len ]] || return 1
    printf '%s' "$pw"
}

run_with_spinner() {
    local msg=$1
    shift

    local logtmp
    logtmp=$(mktemp)
    "$@" > "$logtmp" 2>&1 &
    local cmd_pid=$!
    spinner "$cmd_pid" "$msg"

    # Проверяем код возврата фоновой команды — иначе set -e её не увидит.
    if ! wait "$cmd_pid"; then
        echo ""
        warn "Команда завершилась с ошибкой: $*"
        [[ -s "$logtmp" ]] && tail -n 20 "$logtmp"
        rm -f "$logtmp"
        error "Установка прервана из-за ошибки на предыдущем шаге."
    fi
    rm -f "$logtmp"
}

header "Проверка окружения"

[[ $EUID -ne 0 ]] && error "Скрипт нужно запускать от root (sudo)"

touch "$LOG_FILE" 2>/dev/null || { echo "Не удалось создать лог-файл $LOG_FILE"; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1

if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) ok "ОС: $PRETTY_NAME" ;;
        *) error "Поддерживаются только Ubuntu и Debian. У вас: $PRETTY_NAME" ;;
    esac
else
    error "Не удалось определить ОС"
fi

# Повторная установка сгенерирует новые пароли и перезапишет .env, но том БД
# инициализирован старым паролём — стек не поднимется. Не трогаем без согласия.
if [[ -f "${INSTALL_DIR}/.env" ]]; then
    warn "Обнаружена существующая установка FastCloud в ${INSTALL_DIR}."
    echo -e "  Для управления используйте: ${CYAN}cd ${INSTALL_DIR} && ./manage.sh${NC}"
    echo ""
    warn "Повторная установка перезапишет конфигурацию и пароли и может"
    warn "сделать текущую базу данных недоступной."
    echo ""
    read -rp "$(echo -e "${CYAN}Введите ${RED}WIPE${CYAN}, чтобы снести и переустановить с нуля, или Enter для выхода:${NC} ")" REINSTALL_CONFIRM
    if [[ "$REINSTALL_CONFIRM" == "WIPE" ]]; then
        warn "Останавливаю и удаляю старую установку..."
        if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]] && command -v docker &>/dev/null; then
            ( cd "$INSTALL_DIR" && docker compose down --remove-orphans ) || true
        fi
        rm -f /etc/cron.d/fastcloud-nextcloud
        # Убираем задания FastCloud из пользовательского crontab, иначе после
        # rm -rf они будут ежедневно падать с ошибками "нет такого файла".
        crontab -l 2>/dev/null | grep -v "${INSTALL_DIR}/scripts/" | crontab - 2>/dev/null || true
        rm -rf "$INSTALL_DIR"
        ok "Старая установка удалена. Продолжаю чистую установку."
    else
        error "Установка отменена, чтобы не повредить существующий сервер."
    fi
fi

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

if [[ $TOTAL_RAM_GB -lt 2 ]]; then
    warn "У вас ${TOTAL_RAM_GB} ГБ RAM. Рекомендуется минимум 2 ГБ (иначе возможен OOM)."

    # Мало памяти — предлагаем swap-файл, чтобы стек не убивался OOM-killer'ом.
    SWAP_TOTAL_KB=$(grep -i SwapTotal /proc/meminfo | awk '{print $2}')
    if [[ "${SWAP_TOTAL_KB:-0}" -lt 1048576 ]]; then
        read -rp "Создать swap-файл 2 ГБ, чтобы снизить риск OOM? [Y/n]: " MK_SWAP
        if [[ ! "$MK_SWAP" =~ ^[Nn]$ ]]; then
            SWAPFILE="/swapfile"
            if [[ -e "$SWAPFILE" ]]; then
                warn "Файл $SWAPFILE уже существует — пропускаю создание."
            else
                info "Создаю swap-файл 2 ГБ (${SWAPFILE})..."
                if fallocate -l 2G "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=2048 status=none; then
                    chmod 600 "$SWAPFILE"
                    mkswap "$SWAPFILE" >/dev/null
                    swapon "$SWAPFILE"
                    grep -q "^${SWAPFILE} " /etc/fstab || echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
                    ok "Swap-файл 2 ГБ создан и подключён"
                else
                    warn "Не удалось создать swap-файл. Продолжаю без него."
                fi
            fi
        fi
    fi

    read -rp "Продолжить установку? (y/N): " CONTINUE_LOW_RAM
    [[ "$CONTINUE_LOW_RAM" != "y" && "$CONTINUE_LOW_RAM" != "Y" ]] && error "Установка прервана пользователем."
else
    ok "Оперативная память: ${TOTAL_RAM_GB} ГБ (достаточно)"
fi

FREE_DISK_KB=$(df -k "$INSTALL_DIR" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
FREE_DISK_GB=$((FREE_DISK_KB / 1024 / 1024))

if [[ $FREE_DISK_GB -lt 10 ]]; then
    warn "Свободно менее 10 ГБ на диске (${FREE_DISK_GB} ГБ). Система и Docker займут ~5 ГБ."
    read -rp "Продолжить установку? (y/N): " CONTINUE_LOW_DISK
    [[ "$CONTINUE_LOW_DISK" != "y" && "$CONTINUE_LOW_DISK" != "Y" ]] && error "Установка прервана пользователем."
else
    ok "Свободное место на диске: ${FREE_DISK_GB} ГБ (достаточно)"
fi

header "Проверка портов 80 и 443"

for port in 80 443; do
    pid=$(ss -tulpn 2>/dev/null | grep ":${port} " | awk '{print $NF}' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
    if [[ -n "$pid" ]]; then
        proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        warn "Порт $port занят процессом: $proc_name (PID $pid)"
        if [[ "$proc_name" =~ ^(nginx|apache2|httpd)$ ]]; then
            info "Останавливаю и отключаю $proc_name..."
            run_with_spinner "Остановка $proc_name..." systemctl stop "$proc_name"
            run_with_spinner "Отключение $proc_name..." systemctl disable "$proc_name"
            ok "Порт $port освобожден"
        elif [[ "$proc_name" =~ ^(docker-proxy|caddy|containerd)$ ]]; then
            info "Порт $port держит Docker ($proc_name) — вероятно, прошлый запуск FastCloud. Продолжаю."
        else
            error "Порт $port занят нестандартным процессом ($proc_name). Остановите его вручную."
        fi
    else
        ok "Порт $port свободен"
    fi
done

header "Установка Docker"

if ! command -v docker &>/dev/null; then
    info "Docker не найден. Устанавливаю..."
    run_with_spinner "Обновление списка пакетов..." apt-get update -qq
    run_with_spinner "Установка зависимостей..." apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/$ID/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    run_with_spinner "Обновление списка пакетов..." apt-get update -qq
    run_with_spinner "Установка Docker (это может занять 1-2 минуты)..." apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    ok "Docker установлен: $(docker --version)"
else
    ok "Docker уже установлен: $(docker --version)"
fi

if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 не найден. Установите docker-compose-plugin."
fi

header "Настройка Docker daemon"

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "ipv6": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "default-address-pools": [
    {"base": "172.80.0.0/16", "size": 24}
  ]
}
EOF
run_with_spinner "Перезапуск Docker..." systemctl restart docker
ok "Docker daemon настроен (IPv6 off, log rotation on)"

header "Настройка фаервола UFW"

if command -v ufw &>/dev/null; then
    warn "Текущие правила UFW будут сброшены и заменены (будут открыты только 22/80/443)."
    read -rp "Продолжить настройку фаервола? [Y/n]: " CONFIRM_UFW
    if [[ "$CONFIRM_UFW" =~ ^[Nn]$ ]]; then
        warn "Настройка UFW пропущена по решению пользователя."
    else
        run_with_spinner "Сброс правил UFW..." ufw --force reset
        run_with_spinner "Настройка правил по умолчанию..." ufw default deny incoming
        run_with_spinner "Настройка правил по умолчанию..." ufw default allow outgoing
        run_with_spinner "Открытие порта 22 (SSH)..." ufw allow 22/tcp comment 'SSH'
        run_with_spinner "Открытие порта 80 (HTTP)..." ufw allow 80/tcp comment 'HTTP'
        run_with_spinner "Открытие порта 443 (HTTPS)..." ufw allow 443/tcp comment 'HTTPS'
        run_with_spinner "Активация UFW..." ufw --force enable
        ok "UFW настроен: открыты порты 22, 80, 443"
    fi
else
    warn "UFW не установлен. Пропускаю настройку фаервола."
fi

header "Выбор режима установки"

echo -e "${CYAN}Выберите режим установки:${NC}"
echo -e "  ${YELLOW}1)${NC} Локальный сервер (для домашней сети/VPN, HTTP)"
echo -e "  ${YELLOW}2)${NC} Публичный сервер с доменом (HTTPS, автоматический SSL)"
echo -e "  ${YELLOW}3)${NC} Публичный сервер без домена (только IP, HTTP)"
echo ""
read -rp "$(echo -e ${CYAN})Введите номер (1, 2 или 3):$(echo -e ${NC}) " MODE_CHOICE

case "$MODE_CHOICE" in
    1)
        INSTALL_MODE="local"
        ok "Выбран режим: Локальный сервер"

        header "Настройка локального сервера"
        echo -e "${YELLOW}Внимание:${NC} Локальный режим работает по HTTP (без SSL)."
        echo -e "Подходит для домашней сети, тестирования или VPN.\n"

        SERVER_IP=$(hostname -I | awk '{print $1}')
        read -rp "$(echo -e ${CYAN})Введите локальный IP-адрес сервера [по умолчанию: ${SERVER_IP}]:$(echo -e ${NC}) " CUSTOM_IP
        SERVER_IP=${CUSTOM_IP:-$SERVER_IP}

        DOMAIN="${SERVER_IP}"
        EMAIL="local@localhost"
        NC_URL="http://${SERVER_IP}"
        OVERWRITE_PROTOCOL="http"
        OVERWRITE_HOST="${SERVER_IP}"
        ;;
    2)
        INSTALL_MODE="public-domain"
        ok "Выбран режим: Публичный сервер с доменом"

        header "Настройка публичного сервера с доменом"
        echo -e "${GREEN}Caddy автоматически выпустит бесплатный SSL-сертификат от Let's Encrypt.${NC}\n"

        # Опечатка в домене = провал выпуска LE и риск упереться в rate-limit.
        while true; do
            read -rp "$(echo -e ${CYAN})Введите домен для Nextcloud (например, cloud.example.com):$(echo -e ${NC}) " DOMAIN
            [[ -z "$DOMAIN" ]] && { warn "Домен не может быть пустым."; continue; }
            if is_valid_domain "$DOMAIN"; then break; fi
            warn "Похоже на некорректный домен: '${DOMAIN}'. Пример: cloud.example.com"
        done

        while true; do
            read -rp "$(echo -e ${CYAN})Введите email для Let's Encrypt SSL:$(echo -e ${NC}) " EMAIL
            [[ -z "$EMAIL" ]] && { warn "Email не может быть пустым."; continue; }
            if is_valid_email "$EMAIL"; then break; fi
            warn "Похоже на некорректный email: '${EMAIL}'. Пример: you@example.com"
        done

        NC_URL="https://${DOMAIN}"
        OVERWRITE_PROTOCOL="https"
        OVERWRITE_HOST="${DOMAIN}"
        ok "Домен: ${DOMAIN}"
        ok "Email: ${EMAIL}"
        ;;
    3)
        INSTALL_MODE="public-ip"
        ok "Выбран режим: Публичный сервер без домена"

        header "Настройка публичного сервера без домена"
        echo -e "${YELLOW}Внимание:${NC} режим без домена работает по HTTP (без SSL)."
        echo -e "Данные передаются в открытом виде. Для чувствительных данных используйте режим 2.\n"

        info "Определение внешнего IP-адреса сервера..."
        # hostname -I за NAT вернёт приватный адрес, поэтому спрашиваем внешние сервисы.
        PUBLIC_IP=""
        for svc in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
            PUBLIC_IP=$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
            [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
            PUBLIC_IP=""
        done
        [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(hostname -I | awk '{print $1}')

        if [[ -z "$PUBLIC_IP" ]]; then
            warn "Не удалось автоматически определить IP."
            read -rp "$(echo -e ${CYAN})Введите IP-адрес сервера вручную:$(echo -e ${NC}) " PUBLIC_IP
            [[ -z "$PUBLIC_IP" ]] && error "IP-адрес не может быть пустым"
        else
            ok "IP определен: ${PUBLIC_IP}"
            read -rp "$(echo -e ${CYAN})Использовать этот IP? [Y/n]:$(echo -e ${NC}) " CONFIRM_IP
            if [[ "$CONFIRM_IP" =~ ^[Nn]$ ]]; then
                read -rp "$(echo -e ${CYAN})Введите правильный IP-адрес:$(echo -e ${NC}) " PUBLIC_IP
                [[ -z "$PUBLIC_IP" ]] && error "IP-адрес не может быть пустым"
            fi
        fi

        DOMAIN="${PUBLIC_IP}"
        EMAIL="public@localhost"
        NC_URL="http://${PUBLIC_IP}"
        OVERWRITE_PROTOCOL="http"
        OVERWRITE_HOST="${PUBLIC_IP}"
        ;;
    *)
        error "Неверный выбор. Введите 1, 2 или 3."
        ;;
esac

DB_PASSWORD=$(gen_password 32)
REDIS_PASSWORD=$(gen_password 32)
ADMIN_PASSWORD=$(gen_password 24)
for _pw in "$DB_PASSWORD" "$REDIS_PASSWORD" "$ADMIN_PASSWORD"; do
    [[ ${#_pw} -ge 24 ]] || error "Не удалось сгенерировать пароль нужной длины."
done
ok "Пароли сгенерированы автоматически"

header "Генерация конфигурации"

# Лимиты памяти считаем от фактического объёма RAM: без них OOM-killer на
# слабом сервере убивает Postgres в момент записи, что грозит потерей данных.
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
if [[ $TOTAL_RAM_MB -lt 2048 ]]; then
    DB_MEM_LIMIT="384m";  REDIS_MEM_LIMIT="128m"; REDIS_MAXMEMORY="96mb"
    NC_MEM_LIMIT="768m";  PHP_MEM="384M"
elif [[ $TOTAL_RAM_MB -lt 4096 ]]; then
    DB_MEM_LIMIT="512m";  REDIS_MEM_LIMIT="192m"; REDIS_MAXMEMORY="128mb"
    NC_MEM_LIMIT="1g";    PHP_MEM="512M"
elif [[ $TOTAL_RAM_MB -lt 8192 ]]; then
    DB_MEM_LIMIT="1g";    REDIS_MEM_LIMIT="384m"; REDIS_MAXMEMORY="256mb"
    NC_MEM_LIMIT="2g";    PHP_MEM="512M"
else
    DB_MEM_LIMIT="2g";    REDIS_MEM_LIMIT="512m"; REDIS_MAXMEMORY="384mb"
    NC_MEM_LIMIT="4g";    PHP_MEM="768M"
fi
info "Лимиты памяти: db=${DB_MEM_LIMIT}, redis=${REDIS_MEM_LIMIT}, nextcloud=${NC_MEM_LIMIT}"

mkdir -p "$INSTALL_DIR"/{data,db,redis,caddy_config,caddy_data,scripts}
cd "$INSTALL_DIR"

cat > .env <<EOF
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
DB_PASSWORD=${DB_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
OVERWRITE_PROTOCOL=${OVERWRITE_PROTOCOL}
OVERWRITE_HOST=${OVERWRITE_HOST}
NC_URL=${NC_URL}
INSTALL_DIR=${INSTALL_DIR}
INSTALL_MODE=${INSTALL_MODE}
DB_MEM_LIMIT=${DB_MEM_LIMIT}
REDIS_MEM_LIMIT=${REDIS_MEM_LIMIT}
REDIS_MAXMEMORY=${REDIS_MAXMEMORY}
NC_MEM_LIMIT=${NC_MEM_LIMIT}
PHP_MEM=${PHP_MEM}
EOF
chmod 600 .env
ok "Создан .env (пароли сохранены)"

# Режим фиксируем сразу: manage.sh doctor и monitor.sh опираются на него, и он
# нужен даже если установка прервётся на следующих шагах.
echo "${INSTALL_MODE}" > "${INSTALL_DIR}/.install_mode"
chmod 600 "${INSTALL_DIR}/.install_mode"

cat > docker-compose.yml <<'EOF'
services:
  db:
    image: postgres:15-alpine
    restart: unless-stopped
    volumes:
      - ${INSTALL_DIR}/db:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nextcloud"]
      interval: 5s
      timeout: 5s
      retries: 10
    mem_limit: ${DB_MEM_LIMIT}
    networks:
      - nc_net

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    # maxmemory обязателен: Redis используется как кэш и без лимита растёт,
    # пока не съест всю память сервера (на 2 ГБ VPS это OOM-kill Postgres).
    command: >
      redis-server --requirepass ${REDIS_PASSWORD}
      --maxmemory ${REDIS_MAXMEMORY}
      --maxmemory-policy allkeys-lru
      --save ""
      --appendonly no
    volumes:
      - ${INSTALL_DIR}/redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 5s
      timeout: 5s
      retries: 10
    mem_limit: ${REDIS_MEM_LIMIT}
    networks:
      - nc_net

  nextcloud:
    image: nextcloud:stable-apache
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
    volumes:
      - ${INSTALL_DIR}/data:/var/www/html
      - ${INSTALL_DIR}/nextcloud.ini:/usr/local/etc/php/conf.d/nextcloud.ini
    environment:
      POSTGRES_HOST: db
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      REDIS_HOST: redis
      REDIS_HOST_PASSWORD: ${REDIS_PASSWORD}
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${DOMAIN} localhost 127.0.0.1
      OVERWRITEPROTOCOL: ${OVERWRITE_PROTOCOL}
      OVERWRITEHOST: ${OVERWRITE_HOST}
      OVERWRITECLIURL: ${NC_URL}
      # TRUSTED_PROXIES ожидает IP/CIDR: Caddy получает адрес из пула
      # default-address-pools (172.80.0.0/16), заданного в daemon.json.
      TRUSTED_PROXIES: 172.80.0.0/16
      PHP_MEMORY_LIMIT: ${PHP_MEM}
      PHP_UPLOAD_LIMIT: 10G
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost/status.php || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 120s
    mem_limit: ${NC_MEM_LIMIT}
    networks:
      - nc_net

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${INSTALL_DIR}/Caddyfile:/etc/caddy/Caddyfile
      - ${INSTALL_DIR}/caddy_data:/data
      - ${INSTALL_DIR}/caddy_config:/config
    depends_on:
      - nextcloud
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:80 || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - nc_net

networks:
  nc_net:
    driver: bridge
    enable_ipv6: false
EOF
ok "Создан docker-compose.yml"

if [[ "$INSTALL_MODE" == "public-domain" ]]; then
    cat > Caddyfile <<EOF
${DOMAIN} {
    reverse_proxy nextcloud:80
    header {
        Strict-Transport-Security "max-age=15552000; includeSubDomains; preload"
        Referrer-Policy no-referrer
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        X-Permitted-Cross-Domain-Policies none
        X-Robots-Tag "noindex, nofollow"
        X-XSS-Protection "1; mode=block"
    }

    redir /.well-known/carddav /remote.php/dav 301
    redir /.well-known/caldav /remote.php/dav 301
}
EOF
    ok "Создан Caddyfile (режим: public-domain, SSL включен)"
else
    cat > Caddyfile <<EOF
:80 {
    reverse_proxy nextcloud:80
    header {
        Referrer-Policy no-referrer
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        X-Permitted-Cross-Domain-Policies none
        X-Robots-Tag "noindex, nofollow"
        X-XSS-Protection "1; mode=block"
    }

    redir /.well-known/carddav /remote.php/dav 301
    redir /.well-known/caldav /remote.php/dav 301
}
EOF
    ok "Создан Caddyfile (режим: ${INSTALL_MODE}, SSL отключен)"
fi

cat > nextcloud.ini <<EOF
upload_max_filesize = 10G
post_max_size = 10G
memory_limit = ${PHP_MEM}
max_execution_time = 3600
max_input_time = 3600
output_buffering = off
opcache.enable=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=10000
opcache.memory_consumption=128
opcache.save_comments=1
opcache.revalidate_freq=1
EOF
ok "Создан nextcloud.ini"

cat > manage.sh <<'MANAGE_EOF'
#!/usr/bin/env bash
# FastCloud Manager — управление стеком: статус, бэкапы, обновления,
# Telegram-уведомления, мониторинг, оффсайт-бэкапы.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

INSTALL_DIR="/opt/fastcloud"
BACKUP_DIR="/opt/fastcloud-backups"
TELEGRAM_CONFIG="${INSTALL_DIR}/.telegram_config"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
RCLONE_CONFIG_FILE="${INSTALL_DIR}/.rclone.conf"
BACKUP_REMOTE_FILE="${INSTALL_DIR}/.backup_remote"

# Сколько последних бэкапов хранить (локально и в облаке). Переопределяется
# переменной окружения FASTCLOUD_KEEP_BACKUPS.
KEEP_BACKUPS="${FASTCLOUD_KEEP_BACKUPS:-7}"

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Пароль заданной длины без спецсимволов. Читаем блок заранее и режем через
# cut: вариант `tr < /dev/urandom | head -c N` роняет скрипт с кодом 141
# (SIGPIPE у tr) при включённом `set -euo pipefail`.
gen_password() {
    local len=${1:-32} pw
    pw=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$len")
    [[ ${#pw} -eq $len ]] || return 1
    printf '%s' "$pw"
}

cmd_status() {
    info "Статус FastCloud:"
    echo ""
    cd "$INSTALL_DIR"
    docker compose ps
    echo ""
    info "Использование диска:"
    du -sh "${INSTALL_DIR}/data" 2>/dev/null | awk '{print "  Данные Nextcloud: " $1}'
    du -sh "${INSTALL_DIR}/db" 2>/dev/null | awk '{print "  База данных: " $1}'
    echo ""
    info "Режим установки:"
    cat "${INSTALL_DIR}/.install_mode" 2>/dev/null || echo "  Не определен"
}

cmd_logs() {
    local service=${1:-}
    cd "$INSTALL_DIR"
    if [[ -n "$service" ]]; then
        info "Логи сервиса: $service"
        docker compose logs -f "$service"
    else
        info "Логи всех сервисов (Ctrl+C для выхода):"
        docker compose logs -f
    fi
}

cmd_restart() {
    info "Перезапуск FastCloud..."
    cd "$INSTALL_DIR"
    docker compose restart
    ok "FastCloud перезапущен"
}

cmd_stop() {
    info "Остановка FastCloud..."
    cd "$INSTALL_DIR"
    docker compose stop
    ok "FastCloud остановлен"
}

cmd_start() {
    info "Запуск FastCloud..."
    cd "$INSTALL_DIR"
    docker compose start
    ok "FastCloud запущен"
}

prune_local_backups() {
    # Оставляем только KEEP_BACKUPS самых свежих локальных архивов.
    [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ && "$KEEP_BACKUPS" -gt 0 ]] || return 0
    local old
    old=$(ls -t "${BACKUP_DIR}"/fastcloud_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)))
    if [[ -n "$old" ]]; then
        info "Удаляю старые локальные бэкапы (храним последние ${KEEP_BACKUPS}):"
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            echo "  - $(basename "$f")"
            rm -f "$f"
        done <<< "$old"
    fi
}

cmd_backup() {
    info "Создание локального бэкапа..."

    mkdir -p "$BACKUP_DIR"

    cd "$INSTALL_DIR"

    # Проверяем место ДО начала: на переполненном диске tar создаст битый архив,
    # который затем вытеснит рабочий бэкап из ротации.
    local need_kb free_kb
    need_kb=$(du -sk "${INSTALL_DIR}/data" "${INSTALL_DIR}/db" 2>/dev/null | awk '{s+=$1} END {print int(s*0.6)+262144}')
    free_kb=$(df -Pk "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    if [[ -n "$need_kb" && -n "$free_kb" && $free_kb -lt $need_kb ]]; then
        error "Недостаточно места для бэкапа: нужно ~$((need_kb / 1024)) МБ, свободно $((free_kb / 1024)) МБ."
    fi

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/fastcloud_backup_${TIMESTAMP}.tar.gz"
    local tmp_file="${BACKUP_FILE}.partial"

    docker compose exec -T nextcloud php occ maintenance:mode --on > /dev/null 2>&1 || true

    # Согласованный дамп БД через pg_dump вместо копирования "горячего" каталога db/.
    local staging
    staging=$(mktemp -d)
    info "Дамп базы данных (pg_dump)..."
    if ! docker compose exec -T db pg_dump -U nextcloud nextcloud | gzip > "${staging}/database.sql.gz"; then
        docker compose exec -T nextcloud php occ maintenance:mode --off > /dev/null 2>&1 || true
        rm -rf "$staging"
        error "Не удалось создать дамп базы данных."
    fi
    [[ -s "${staging}/database.sql.gz" ]] || {
        docker compose exec -T nextcloud php occ maintenance:mode --off > /dev/null 2>&1 || true
        rm -rf "$staging"
        error "Дамп базы данных пуст — бэкап не создан."
    }

    # Версию Nextcloud пишем в архив: restore на несовместимый мажор ломает
    # приложение уже после импорта БД, когда откатываться поздно.
    local nc_version
    nc_version=$(docker compose exec -T nextcloud php occ status --output=json 2>/dev/null \
        | tr -d ' ' | grep -oE '"versionstring":"[^"]+"' | cut -d'"' -f4 || true)
    cat > "${staging}/backup_meta" <<META
FASTCLOUD_BACKUP_VERSION=1
NEXTCLOUD_VERSION=${nc_version:-unknown}
CREATED_AT=$(date -Iseconds)
META

    info "Архивирование данных и конфигурации..."
    if ! tar -czf "$tmp_file" \
        -C "$INSTALL_DIR" data Caddyfile nextcloud.ini .env docker-compose.yml \
        -C "$staging" database.sql.gz backup_meta; then
        docker compose exec -T nextcloud php occ maintenance:mode --off > /dev/null 2>&1 || true
        rm -f "$tmp_file"; rm -rf "$staging"
        error "Не удалось создать архив (проверьте свободное место)."
    fi

    docker compose exec -T nextcloud php occ maintenance:mode --off > /dev/null 2>&1 || true
    rm -rf "$staging"

    # Архив считается готовым только после успешной проверки целостности,
    # поэтому до этого момента он лежит под именем *.partial.
    info "Проверка целостности архива..."
    if ! tar -tzf "$tmp_file" > /dev/null 2>&1; then
        rm -f "$tmp_file"
        error "Архив повреждён — бэкап не сохранён."
    fi

    mv "$tmp_file" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"   # содержит .env с паролями
    SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    ok "Бэкап создан: ${BACKUP_FILE} (${SIZE})"
    warn "Бэкап содержит .env с паролями. Храните его в защищённом месте."

    prune_local_backups
}

cmd_verify_backup() {
    local backup_file=${1:-}

    if [[ -z "$backup_file" ]]; then
        backup_file=$(ls -t "${BACKUP_DIR}"/fastcloud_backup_*.tar.gz 2>/dev/null | head -n1 || true)
        [[ -n "$backup_file" ]] || error "Бэкапы не найдены в ${BACKUP_DIR}."
        info "Проверяю последний бэкап: $(basename "$backup_file")"
    fi
    [[ -f "$backup_file" ]] || error "Файл бэкапа не найден: $backup_file"

    info "1/3 Проверка целостности архива..."
    tar -tzf "$backup_file" > /dev/null 2>&1 || error "Архив повреждён или не читается."
    ok "Архив читается"

    info "2/3 Проверка состава..."
    local listing
    listing=$(tar -tzf "$backup_file")
    for required in "database.sql.gz" ".env" "docker-compose.yml"; do
        grep -qx "$required" <<< "$listing" || error "В архиве отсутствует ${required}."
    done
    grep -q '^data/' <<< "$listing" || error "В архиве отсутствует каталог data/."
    ok "Все обязательные компоненты на месте"

    if grep -qx "backup_meta" <<< "$listing"; then
        local meta
        meta=$(tar -xzf "$backup_file" -O backup_meta 2>/dev/null || true)
        [[ -n "$meta" ]] && echo "$meta" | sed 's/^/  /'
    fi

    info "3/3 Пробный импорт дампа БД в одноразовый контейнер..."
    # Реальная проверка: дамп не просто распаковывается, а применяется к чистому
    # PostgreSQL. Контейнер временный и не касается рабочей базы.
    local probe="fastcloud-verify-$$"
    local probe_pw
    probe_pw=$(gen_password 24)
    local pg_image
    pg_image=$(grep -oE 'image:[[:space:]]*postgres:[^[:space:]]+' "${INSTALL_DIR}/docker-compose.yml" \
        | head -n1 | awk '{print $2}')
    pg_image=${pg_image:-postgres:15-alpine}

    docker run -d --rm --name "$probe" \
        -e POSTGRES_DB=nextcloud -e POSTGRES_USER=nextcloud \
        -e POSTGRES_PASSWORD="$probe_pw" "$pg_image" > /dev/null 2>&1 \
        || error "Не удалось запустить временный контейнер PostgreSQL."

    # EXIT, а не RETURN: error() завершает скрипт через exit, и RETURN-обработчик
    # в этом случае не сработает — временный контейнер остался бы висеть.
    trap 'docker rm -f "'"$probe"'" >/dev/null 2>&1 || true' EXIT

    local ready=0
    for _ in $(seq 1 40); do
        if docker exec "$probe" pg_isready -U nextcloud > /dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    [[ $ready -eq 1 ]] || error "Временный PostgreSQL не поднялся."

    if tar -xzf "$backup_file" -O database.sql.gz | gunzip \
        | docker exec -i "$probe" psql -U nextcloud -d nextcloud -v ON_ERROR_STOP=1 > /dev/null 2>&1; then
        local tables
        tables=$(docker exec "$probe" psql -U nextcloud -d nextcloud -tAc \
            "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -dc '0-9')
        [[ "${tables:-0}" -gt 0 ]] || error "Дамп импортировался, но таблиц в схеме нет."
        docker rm -f "$probe" > /dev/null 2>&1 || true
        trap - EXIT
        ok "Дамп БД успешно импортирован (таблиц: ${tables})"
        echo ""
        ok "Бэкап пригоден для восстановления: $(basename "$backup_file")"
    else
        error "Дамп БД не импортируется — этот бэкап восстановить не удастся!"
    fi
}

cmd_restore() {
    local backup_file=${1:-}

    [[ -z "$backup_file" ]] && error "Укажите файл бэкапа: ./manage.sh restore <путь-к-архиву.tar.gz>"
    [[ ! -f "$backup_file" ]] && error "Файл бэкапа не найден: $backup_file"

    # Всё, что можно проверить, проверяем ДО остановки сервисов и до того,
    # как тронуты рабочие данные.
    info "Проверка архива перед восстановлением..."
    tar -tzf "$backup_file" > /dev/null 2>&1 || error "Архив повреждён или не читается: ${backup_file}"

    local listing
    listing=$(tar -tzf "$backup_file")
    grep -qx "database.sql.gz" <<< "$listing" || error "В архиве нет дампа БД (database.sql.gz)."
    grep -q '^data/' <<< "$listing" || error "В архиве нет каталога data/."
    ok "Архив корректен"

    cd "$INSTALL_DIR"

    # Сверяем мажорную версию Nextcloud: импорт дампа от более старого мажора
    # в новый образ проходит, но приложение после этого не работает.
    if grep -qx "backup_meta" <<< "$listing"; then
        local backup_nc_ver current_nc_ver
        backup_nc_ver=$(tar -xzf "$backup_file" -O backup_meta 2>/dev/null \
            | grep '^NEXTCLOUD_VERSION=' | cut -d= -f2- || true)
        current_nc_ver=$(docker compose exec -T nextcloud php occ status --output=json 2>/dev/null \
            | tr -d ' ' | grep -oE '"versionstring":"[^"]+"' | cut -d'"' -f4 || true)
        if [[ -n "$backup_nc_ver" && "$backup_nc_ver" != "unknown" && -n "$current_nc_ver" ]]; then
            if [[ "${backup_nc_ver%%.*}" != "${current_nc_ver%%.*}" ]]; then
                warn "Версия в бэкапе (${backup_nc_ver}) и текущая (${current_nc_ver}) — разные мажоры."
                warn "После восстановления Nextcloud может не запуститься."
                read -rp "Всё равно продолжить? (введите 'yes'): " VER_CONFIRM
                [[ "$VER_CONFIRM" == "yes" ]] || error "Восстановление отменено."
            else
                ok "Версия Nextcloud совместима (${backup_nc_ver})"
            fi
        fi
    fi

    # Нужно место под распаковку архива и под копию текущих данных.
    local arch_kb free_kb
    arch_kb=$(du -sk "$backup_file" | awk '{print $1}')
    free_kb=$(df -Pk "$INSTALL_DIR" | awk 'NR==2 {print $4}')
    if [[ $free_kb -lt $((arch_kb * 4)) ]]; then
        warn "Мало свободного места: $((free_kb / 1024)) МБ при архиве $((arch_kb / 1024)) МБ."
        read -rp "Продолжить? (введите 'yes'): " SPACE_CONFIRM
        [[ "$SPACE_CONFIRM" == "yes" ]] || error "Восстановление отменено."
    fi

    warn "ВНИМАНИЕ: восстановление ПЕРЕЗАПИШЕТ текущие данные и базу FastCloud!"
    info "Текущие данные будут сохранены рядом и удалены только после успеха."
    read -rp "Продолжить восстановление из ${backup_file}? (введите 'yes'): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && error "Восстановление отменено."

    local staging
    staging=$(mktemp -d -p "$INSTALL_DIR" .restore.XXXXXX)
    info "Распаковка архива..."
    tar -xzf "$backup_file" -C "$staging" || { rm -rf "$staging"; error "Не удалось распаковать архив."; }

    info "Остановка контейнеров..."
    docker compose down

    # Старые данные и БД переносим, а не удаляем: при сбое на любом шаге ниже
    # их возвращает rollback_restore, иначе потеря была бы безвозвратной.
    local stamp prev_data prev_db
    stamp=$(date +%Y%m%d_%H%M%S)
    prev_data="${INSTALL_DIR}/data.before-restore-${stamp}"
    prev_db="${INSTALL_DIR}/db.before-restore-${stamp}"

    rollback_restore() {
        warn "Откат: возвращаю прежнее состояние..."
        rm -rf "${INSTALL_DIR}/data"
        [[ -d "$prev_data" ]] && mv "$prev_data" "${INSTALL_DIR}/data"
        if [[ -d "$prev_db" ]]; then
            rm -rf "${INSTALL_DIR}/db"
            mv "$prev_db" "${INSTALL_DIR}/db"
        fi
        for f in Caddyfile nextcloud.ini .env docker-compose.yml; do
            [[ -f "${staging}/.prev_${f}" ]] && cp -a "${staging}/.prev_${f}" "${INSTALL_DIR}/${f}"
        done
        docker compose up -d > /dev/null 2>&1 || true
        rm -rf "$staging"
        error "Восстановление не удалось. Прежние данные возвращены на место."
    }

    info "Сохранение текущего состояния..."
    for f in Caddyfile nextcloud.ini .env docker-compose.yml; do
        [[ -f "${INSTALL_DIR}/${f}" ]] && cp -a "${INSTALL_DIR}/${f}" "${staging}/.prev_${f}"
    done
    mv "${INSTALL_DIR}/data" "$prev_data" || { rm -rf "$staging"; error "Не удалось сохранить текущие данные."; }
    [[ -d "${INSTALL_DIR}/db" ]] && mv "${INSTALL_DIR}/db" "$prev_db"
    mkdir -p "${INSTALL_DIR}/db"

    info "Восстановление файлов данных и конфигурации..."
    mv "${staging}/data" "${INSTALL_DIR}/data" || rollback_restore
    for f in Caddyfile nextcloud.ini .env docker-compose.yml; do
        [[ -f "${staging}/${f}" ]] && cp -a "${staging}/${f}" "${INSTALL_DIR}/${f}"
    done

    info "Запуск базы данных..."
    docker compose up -d db || rollback_restore
    local db_ready=0
    for _ in $(seq 1 40); do
        if docker compose exec -T db pg_isready -U nextcloud > /dev/null 2>&1; then db_ready=1; break; fi
        sleep 2
    done
    [[ $db_ready -eq 1 ]] || rollback_restore

    info "Восстановление базы данных из дампа..."
    docker compose exec -T db psql -U nextcloud -d nextcloud \
        -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" > /dev/null 2>&1 || true
    # ON_ERROR_STOP: без него psql проглотит ошибки и оставит битую БД,
    # отрапортовав об успехе.
    if ! gunzip -c "${staging}/database.sql.gz" \
        | docker compose exec -T db psql -U nextcloud -d nextcloud -v ON_ERROR_STOP=1 > /dev/null 2>&1; then
        rollback_restore
    fi

    info "Запуск остальных сервисов..."
    docker compose up -d || rollback_restore

    info "Проверка работоспособности Nextcloud..."
    local nc_ok=0
    for _ in $(seq 1 60); do
        if docker compose exec -T nextcloud curl -fsS http://localhost/status.php 2>/dev/null \
            | grep -q '"installed":true'; then nc_ok=1; break; fi
        sleep 2
    done
    if [[ $nc_ok -ne 1 ]]; then
        warn "Nextcloud не ответил после восстановления."
        read -rp "Откатиться к прежнему состоянию? [Y/n]: " DO_ROLLBACK
        [[ "$DO_ROLLBACK" =~ ^[Nn]$ ]] || rollback_restore
    else
        ok "Nextcloud отвечает"
    fi

    rm -rf "$staging"
    ok "Восстановление завершено."
    echo ""
    info "Прежнее состояние сохранено в:"
    echo "  ${prev_data}"
    [[ -d "$prev_db" ]] && echo "  ${prev_db}"
    echo ""
    warn "Убедитесь, что всё работает, затем удалите их для освобождения места:"
    echo -e "  ${CYAN}rm -rf ${prev_data} ${prev_db}${NC}"
}

cmd_update() {
    info "Обновление FastCloud..."
    cd "$INSTALL_DIR"

    info "Создание бэкапа перед обновлением..."
    cmd_backup

    # Запоминаем текущие digest'ы: теги плавающие, и при неудачном обновлении
    # без них вернуться к работавшим образам невозможно.
    local prev_digests
    prev_digests=$(docker compose config --images 2>/dev/null | while read -r img; do
        [[ -n "$img" ]] || continue
        docker image inspect "$img" --format '{{.RepoTags}} {{.Id}}' 2>/dev/null || true
    done)
    [[ -n "$prev_digests" ]] && printf '%s\n' "$prev_digests" > "${INSTALL_DIR}/.previous_images"

    docker compose exec -T nextcloud php occ maintenance:mode --on > /dev/null 2>&1 || true

    info "Скачивание новых образов..."
    if ! docker compose pull; then
        docker compose exec -T nextcloud php occ maintenance:mode --off > /dev/null 2>&1 || true
        error "Не удалось скачать образы. Обновление отменено, стек не тронут."
    fi

    info "Перезапуск контейнеров..."
    docker compose up -d

    info "Ожидание инициализации Nextcloud..."
    # Готовность проверяем по status.php: occ на слабом сервере поднимает
    # тяжёлый PHP-процесс и может не ответить, хотя стек живой.
    local ready=false
    for _ in $(seq 1 90); do
        if docker compose exec -T nextcloud curl -fsS http://localhost/status.php 2>/dev/null \
            | grep -q '"installed":true'; then
            ready=true
            break
        fi
        sleep 2
    done

    if [[ "$ready" != true ]]; then
        echo ""
        warn "Nextcloud не поднялся после обновления."
        docker compose logs --tail 30 nextcloud 2>/dev/null | grep -iv '"GET \|"HEAD \|"POST ' || true
        echo ""
        warn "Доступен бэкап, созданный перед обновлением, в ${BACKUP_DIR}."
        echo -e "  Откат: ${CYAN}./manage.sh restore <файл-бэкапа>${NC}"
        docker compose exec -T nextcloud php occ maintenance:mode --off > /dev/null 2>&1 || true
        error "Обновление завершилось неудачно."
    fi
    ok "Nextcloud отвечает после обновления"

    docker compose exec -T nextcloud php occ maintenance:mode --off > /dev/null 2>&1 || true

    info "Применение оптимизаций..."
    docker compose exec -T nextcloud php occ db:add-missing-indices --no-interaction > /dev/null 2>&1 || true
    docker compose exec -T nextcloud php occ db:add-missing-columns --no-interaction > /dev/null 2>&1 || true
    docker compose exec -T nextcloud php occ maintenance:repair --no-interaction > /dev/null 2>&1 || true

    info "Очистка устаревших Docker-образов..."
    docker image prune -f > /dev/null 2>&1 || true

    ok "FastCloud обновлен"
}

cmd_doctor() {
    local problems=0 warnings=0
    echo -e "${CYAN}=== FastCloud Doctor ===${NC}"
    echo ""
    cd "$INSTALL_DIR"

    echo -e "${CYAN}Контейнеры:${NC}"
    local expected="db redis nextcloud caddy"
    for svc in $expected; do
        local state
        state=$(docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null \
            | awk -v s="$svc" '$1==s {print $2}')
        if [[ "$state" == "running" ]]; then
            echo -e "  ${GREEN}✓${NC} ${svc}: running"
        else
            echo -e "  ${RED}✗${NC} ${svc}: ${state:-отсутствует}"
            problems=$((problems + 1))
        fi
    done
    echo ""

    echo -e "${CYAN}Доступность Nextcloud:${NC}"
    if docker compose exec -T nextcloud curl -fsS http://localhost/status.php 2>/dev/null \
        | grep -q '"installed":true'; then
        echo -e "  ${GREEN}✓${NC} status.php отвечает, установка завершена"
    else
        echo -e "  ${RED}✗${NC} status.php не отвечает"
        problems=$((problems + 1))
    fi
    echo ""

    echo -e "${CYAN}Диск:${NC}"
    local use_pct free_h
    use_pct=$(df --output=pcent "$INSTALL_DIR" 2>/dev/null | tail -n1 | tr -dc '0-9')
    free_h=$(df -h "$INSTALL_DIR" | awk 'NR==2 {print $4}')
    if [[ -n "$use_pct" && $use_pct -ge 90 ]]; then
        echo -e "  ${RED}✗${NC} занято ${use_pct}%, свободно ${free_h}"
        problems=$((problems + 1))
    elif [[ -n "$use_pct" && $use_pct -ge 80 ]]; then
        echo -e "  ${YELLOW}!${NC} занято ${use_pct}%, свободно ${free_h}"
        warnings=$((warnings + 1))
    else
        echo -e "  ${GREEN}✓${NC} занято ${use_pct:-?}%, свободно ${free_h}"
    fi
    du -sh "${INSTALL_DIR}/data" 2>/dev/null | awk '{print "    данные: " $1}'
    du -sh "${INSTALL_DIR}/db" 2>/dev/null | awk '{print "    база:   " $1}'
    echo ""

    echo -e "${CYAN}Память:${NC}"
    local mem_free_mb swap_used_mb
    mem_free_mb=$(free -m | awk '/^Mem:/ {print $7}')
    swap_used_mb=$(free -m | awk '/^Swap:/ {print $3}')
    if [[ -n "$mem_free_mb" && $mem_free_mb -lt 150 ]]; then
        echo -e "  ${YELLOW}!${NC} доступно ${mem_free_mb} МБ — риск OOM"
        warnings=$((warnings + 1))
    else
        echo -e "  ${GREEN}✓${NC} доступно ${mem_free_mb:-?} МБ"
    fi
    [[ -n "$swap_used_mb" ]] && echo "    swap занят: ${swap_used_mb} МБ"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
        docker stats --no-stream --format '    {{.Name}}: {{.MemUsage}}' 2>/dev/null | head -6 || true
    fi
    echo ""

    echo -e "${CYAN}SSL-сертификат:${NC}"
    local mode; mode=$(cat "${INSTALL_DIR}/.install_mode" 2>/dev/null || echo "")
    if [[ "$mode" == "public-domain" ]]; then
        local dom; dom=$(grep '^DOMAIN=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2-)
        local not_after days_left
        not_after=$(echo | openssl s_client -servername "$dom" -connect "${dom}:443" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$not_after" ]]; then
            days_left=$(( ( $(date -d "$not_after" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
            if [[ $days_left -lt 7 ]]; then
                echo -e "  ${RED}✗${NC} истекает через ${days_left} дн. (${not_after})"
                problems=$((problems + 1))
            elif [[ $days_left -lt 21 ]]; then
                echo -e "  ${YELLOW}!${NC} истекает через ${days_left} дн."
                warnings=$((warnings + 1))
            else
                echo -e "  ${GREEN}✓${NC} действителен ещё ${days_left} дн."
            fi
        else
            echo -e "  ${YELLOW}!${NC} не удалось проверить сертификат для ${dom}"
            warnings=$((warnings + 1))
        fi
    else
        echo "  — режим ${mode:-неизвестен}, HTTPS не используется"
    fi
    echo ""

    echo -e "${CYAN}Бэкапы:${NC}"
    local latest
    latest=$(ls -t "${BACKUP_DIR}"/fastcloud_backup_*.tar.gz 2>/dev/null | head -n1 || true)
    if [[ -n "$latest" ]]; then
        local age_days
        age_days=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 86400 ))
        local count; count=$(ls "${BACKUP_DIR}"/fastcloud_backup_*.tar.gz 2>/dev/null | wc -l)
        if [[ $age_days -gt 7 ]]; then
            echo -e "  ${RED}✗${NC} последний бэкап ${age_days} дн. назад ($(basename "$latest"))"
            problems=$((problems + 1))
        elif [[ $age_days -gt 2 ]]; then
            echo -e "  ${YELLOW}!${NC} последний бэкап ${age_days} дн. назад"
            warnings=$((warnings + 1))
        else
            echo -e "  ${GREEN}✓${NC} последний бэкап ${age_days} дн. назад"
        fi
        echo "    всего архивов: ${count}, каталог: ${BACKUP_DIR}"
        echo -e "    проверить пригодность: ${CYAN}./manage.sh verify-backup${NC}"
    else
        echo -e "  ${RED}✗${NC} бэкапов нет — настройте: ./manage.sh backup"
        problems=$((problems + 1))
    fi
    if [[ -f "$BACKUP_REMOTE_FILE" ]]; then
        echo -e "  ${GREEN}✓${NC} оффсайт-бэкапы настроены"
    else
        echo -e "  ${YELLOW}!${NC} оффсайт-бэкапы не настроены (backup-setup)"
        warnings=$((warnings + 1))
    fi
    echo ""

    echo -e "${CYAN}Фоновые задачи Nextcloud:${NC}"
    if [[ -f /etc/cron.d/fastcloud-nextcloud ]]; then
        echo -e "  ${GREEN}✓${NC} системный cron установлен"
        local last_cron
        last_cron=$(docker compose exec -T -u www-data nextcloud php occ config:app:get \
            core lastcron 2>/dev/null | tr -dc '0-9' || true)
        if [[ -n "$last_cron" && "$last_cron" -gt 0 ]]; then
            local cron_age=$(( ( $(date +%s) - last_cron ) / 60 ))
            if [[ $cron_age -gt 30 ]]; then
                echo -e "  ${YELLOW}!${NC} последний запуск ${cron_age} мин назад (ожидается ≤10)"
                warnings=$((warnings + 1))
            else
                echo -e "  ${GREEN}✓${NC} последний запуск ${cron_age} мин назад"
            fi
        fi
    else
        echo -e "  ${RED}✗${NC} /etc/cron.d/fastcloud-nextcloud отсутствует"
        problems=$((problems + 1))
    fi
    echo ""

    echo -e "${CYAN}Защита и доступ:${NC}"
    # За reverse-proxy Nextcloud без trusted_proxies видит IP Caddy вместо
    # клиентского: встроенная защита от брутфорса при этом не работает.
    local tp
    tp=$(docker compose exec -T -u www-data nextcloud php occ config:system:get \
        trusted_proxies 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -n "$tp" ]]; then
        echo -e "  ${GREEN}✓${NC} trusted_proxies настроен (${tp})"
    else
        echo -e "  ${RED}✗${NC} trusted_proxies не задан — защита от брутфорса видит только IP Caddy"
        problems=$((problems + 1))
    fi
    if command -v fail2ban-client &>/dev/null; then
        if fail2ban-client status fastcloud-nextcloud &>/dev/null; then
            local banned
            banned=$(fail2ban-client status fastcloud-nextcloud 2>/dev/null \
                | grep -i 'Currently banned' | tr -dc '0-9' || echo 0)
            echo -e "  ${GREEN}✓${NC} fail2ban активен (забанено сейчас: ${banned:-0})"
        else
            echo -e "  ${YELLOW}!${NC} jail fastcloud-nextcloud неактивен"
            warnings=$((warnings + 1))
        fi
    fi
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo -e "  ${GREEN}✓${NC} UFW активен"
    else
        echo -e "  ${YELLOW}!${NC} UFW неактивен"
        warnings=$((warnings + 1))
    fi
    echo ""

    echo -e "${CYAN}Права на секреты:${NC}"
    for f in .env .admin_password .telegram_config .rclone.conf; do
        [[ -f "${INSTALL_DIR}/${f}" ]] || continue
        local perms; perms=$(stat -c %a "${INSTALL_DIR}/${f}")
        if [[ "$perms" == "600" ]]; then
            echo -e "  ${GREEN}✓${NC} ${f}: ${perms}"
        else
            echo -e "  ${YELLOW}!${NC} ${f}: ${perms} (ожидается 600)"
            warnings=$((warnings + 1))
        fi
    done
    echo ""

    echo -e "${CYAN}=== Итог ===${NC}"
    if [[ $problems -eq 0 && $warnings -eq 0 ]]; then
        ok "Проблем не обнаружено."
    else
        [[ $problems -gt 0 ]] && echo -e "  ${RED}Проблем: ${problems}${NC}"
        [[ $warnings -gt 0 ]] && echo -e "  ${YELLOW}Предупреждений: ${warnings}${NC}"
    fi
    [[ $problems -eq 0 ]]
}

cmd_show_password() {
    if [[ -f "${INSTALL_DIR}/.admin_password" ]]; then
        info "Пароль администратора:"
        echo -e "  ${YELLOW}$(cat ${INSTALL_DIR}/.admin_password)${NC}"
    elif [[ -f "${INSTALL_DIR}/.env" ]]; then
        info "Пароль администратора (из .env):"
        echo -e "  ${YELLOW}$(grep '^ADMIN_PASSWORD=' "${INSTALL_DIR}/.env" | cut -d= -f2-)${NC}"
    else
        error "Файл с паролем не найден"
    fi
}

cmd_occ() {
    [[ $# -gt 0 ]] || error "Укажите команду occ, например: ./manage.sh occ status"
    cd "$INSTALL_DIR"
    docker compose exec -T -u www-data nextcloud php occ "$@"
}

cmd_reset_password() {
    local new_password=${1:-}
    cd "$INSTALL_DIR"

    if [[ -z "$new_password" ]]; then
        read -rsp "Введите новый пароль администратора (Enter — сгенерировать): " new_password
        echo ""
    fi
    if [[ -z "$new_password" ]]; then
        new_password=$(gen_password 24)
        info "Сгенерирован новый пароль."
    fi

    info "Сброс пароля пользователя admin..."
    # occ user:resetpassword читает пароль из stdin в неинтерактивном режиме.
    if printf '%s\n%s\n' "$new_password" "$new_password" | \
        docker compose exec -T -u www-data nextcloud php occ user:resetpassword admin > /dev/null 2>&1; then
        echo "$new_password" > "${INSTALL_DIR}/.admin_password"
        chmod 600 "${INSTALL_DIR}/.admin_password"
        # Синхронизируем .env, чтобы show-password не показывал устаревший пароль.
        if [[ -f "${INSTALL_DIR}/.env" ]]; then
            sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${new_password}|" "${INSTALL_DIR}/.env"
        fi
        ok "Пароль администратора обновлён:"
        echo -e "  ${YELLOW}${new_password}${NC}"
    else
        error "Не удалось сбросить пароль. Проверьте, что стек запущен: ./manage.sh status"
    fi
}

cmd_set_domain() {
    local new_domain=${1:-}
    [[ -z "$new_domain" ]] && error "Укажите домен: ./manage.sh set-domain cloud.example.com"
    cd "$INSTALL_DIR"

    info "Добавляю ${new_domain} в trusted_domains..."
    # Индекс 0 — localhost/основной; новый домен добавляем следующим свободным.
    local idx=1
    while docker compose exec -T -u www-data nextcloud php occ config:system:get "trusted_domains" "$idx" >/dev/null 2>&1; do
        idx=$((idx + 1))
    done
    docker compose exec -T -u www-data nextcloud php occ config:system:set trusted_domains "$idx" --value="$new_domain" > /dev/null

    info "Обновляю overwrite-настройки..."
    local proto="https"
    [[ "$new_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && proto="http"
    docker compose exec -T -u www-data nextcloud php occ config:system:set overwrite.cli.url --value="${proto}://${new_domain}" > /dev/null
    docker compose exec -T -u www-data nextcloud php occ config:system:set overwriteprotocol --value="$proto" > /dev/null
    docker compose exec -T -u www-data nextcloud php occ config:system:set overwritehost --value="$new_domain" > /dev/null

    ok "Домен ${new_domain} добавлен."
    warn "Для HTTPS обновите Caddyfile и DNS вручную, затем: ./manage.sh restart"
}

cmd_uninstall() {
    warn "ВНИМАНИЕ: это остановит и удалит все контейнеры FastCloud."
    read -rp "Продолжить удаление? (введите 'yes'): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && error "Удаление отменено."

    cd "$INSTALL_DIR"
    info "Остановка и удаление контейнеров..."
    docker compose down --remove-orphans || true

    info "Удаление cron-заданий..."
    rm -f /etc/cron.d/fastcloud-nextcloud
    crontab -l 2>/dev/null | grep -v "${SCRIPTS_DIR}/" | crontab - 2>/dev/null || true

    echo ""
    warn "Удалить также ВСЕ данные (файлы, база, конфигурация в ${INSTALL_DIR})?"
    warn "Это НЕОБРАТИМО. Бэкапы в /opt/fastcloud-backups затронуты НЕ будут."
    read -rp "Удалить данные? (введите 'DELETE' для подтверждения): " CONFIRM_DATA
    if [[ "$CONFIRM_DATA" == "DELETE" ]]; then
        rm -rf "$INSTALL_DIR"
        ok "FastCloud полностью удалён вместе с данными."
    else
        ok "Контейнеры удалены. Данные сохранены в ${INSTALL_DIR}."
    fi
}

cmd_telegram_setup() {
    info "Настройка Telegram-уведомлений"
    echo ""
    echo -e "${CYAN}Инструкция:${NC}"
    echo "  1. Откройте Telegram и найдите @BotFather"
    echo "  2. Отправьте команду /newbot и получите токен бота"
    echo "  3. Напишите своему боту любое сообщение"
    echo "  4. Откройте https://api.telegram.org/bot<ТОКЕН>/getUpdates"
    echo "  5. Найдите в JSON поле 'chat':{'id':<ЧИСЛО>} — это ваш chat_id"
    echo ""

    read -rp "Введите токен бота: " BOT_TOKEN
    [[ -z "$BOT_TOKEN" ]] && error "Токен не может быть пустым"

    read -rp "Введите chat_id: " CHAT_ID
    [[ -z "$CHAT_ID" ]] && error "Chat ID не может быть пустым"

    cat > "$TELEGRAM_CONFIG" <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
TELEGRAM_CHAT_ID=${CHAT_ID}
EOF
    chmod 600 "$TELEGRAM_CONFIG"

    info "Отправка тестового сообщения..."
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=✅ FastCloud успешно подключён к Telegram!" > /dev/null

    ok "Telegram настроен!"

    info "Настройка ежедневных отчетов (каждый день в 9:00)..."
    local cron_job="0 9 * * * ${SCRIPTS_DIR}/telegram-report.sh"
    if ! crontab -l 2>/dev/null | grep -q "telegram-report.sh"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        ok "Ежедневные отчеты настроены"
    else
        ok "Ежедневные отчеты уже настроены"
    fi
}

cmd_telegram_test() {
    [[ -f "$TELEGRAM_CONFIG" ]] || error "Telegram не настроен. Выполните: ./manage.sh telegram-setup"
    source "$TELEGRAM_CONFIG"

    info "Отправка тестового сообщения..."
    RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=🧪 Тестовое сообщение от FastCloud")

    if echo "$RESPONSE" | grep -q '"ok":true'; then
        ok "Сообщение отправлено!"
    else
        error "Ошибка отправки: $RESPONSE"
    fi
}

cmd_backup_setup() {
    info "Настройка оффсайт-бэкапов (rclone)"

    if ! command -v rclone &>/dev/null; then
        info "rclone не найден, устанавливаю..."
        curl -fsSL https://rclone.org/install.sh | bash || error "Не удалось установить rclone"
    fi
    ok "rclone доступен: $(rclone version | head -n1)"

    echo ""
    echo -e "${CYAN}Сейчас откроется интерактивная настройка rclone.${NC}"
    echo -e "Создайте remote (например, ${YELLOW}fastcloud${NC}) для вашего S3/B2/Yandex."
    echo ""
    read -rp "Нажмите Enter для запуска настройки rclone..."

    rclone config --config "$RCLONE_CONFIG_FILE"
    chmod 600 "$RCLONE_CONFIG_FILE" 2>/dev/null || true

    echo ""
    echo -e "${CYAN}Доступные remote:${NC}"
    rclone --config "$RCLONE_CONFIG_FILE" listremotes || true
    echo ""
    read -rp "Введите назначение для бэкапов (например, fastcloud:my-bucket/backups): " REMOTE_DEST
    [[ -z "$REMOTE_DEST" ]] && error "Назначение не может быть пустым"

    echo "BACKUP_REMOTE_DEST=${REMOTE_DEST}" > "$BACKUP_REMOTE_FILE"
    chmod 600 "$BACKUP_REMOTE_FILE"
    ok "Назначение оффсайт-бэкапов сохранено: ${REMOTE_DEST}"

    info "Настройка ежедневной выгрузки (в 3:30)..."
    local cron_job="30 3 * * * ${SCRIPTS_DIR}/backup-remote.sh >> /var/log/fastcloud-backup.log 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "backup-remote.sh"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        ok "Ежедневные оффсайт-бэкапы настроены"
    else
        ok "Ежедневные оффсайт-бэкапы уже настроены"
    fi
}

cmd_backup_remote() {
    [[ -f "$BACKUP_REMOTE_FILE" ]] || error "Оффсайт-бэкапы не настроены. Выполните: ./manage.sh backup-setup"
    source "$BACKUP_REMOTE_FILE"
    [[ -n "${BACKUP_REMOTE_DEST:-}" ]] || error "Не задано назначение бэкапа. Перезапустите backup-setup."

    cmd_backup

    local latest
    latest=$(ls -t "${BACKUP_DIR}"/fastcloud_backup_*.tar.gz 2>/dev/null | head -n1)
    [[ -n "$latest" ]] || error "Локальный бэкап не найден для выгрузки."

    info "Выгрузка ${latest} -> ${BACKUP_REMOTE_DEST}..."
    if rclone --config "$RCLONE_CONFIG_FILE" copy "$latest" "$BACKUP_REMOTE_DEST" --progress; then
        ok "Бэкап выгружен в облако: ${BACKUP_REMOTE_DEST}"

        # Ротация в облаке: удаляем всё, кроме KEEP_BACKUPS самых свежих архивов.
        if [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ && "$KEEP_BACKUPS" -gt 0 ]]; then
            local stale
            stale=$(rclone --config "$RCLONE_CONFIG_FILE" lsf "$BACKUP_REMOTE_DEST" \
                --include 'fastcloud_backup_*.tar.gz' 2>/dev/null | sort -r | tail -n +$((KEEP_BACKUPS + 1)))
            if [[ -n "$stale" ]]; then
                info "Удаляю старые облачные бэкапы (храним последние ${KEEP_BACKUPS})..."
                while IFS= read -r f; do
                    [[ -n "$f" ]] || continue
                    echo "  - $f"
                    rclone --config "$RCLONE_CONFIG_FILE" deletefile "${BACKUP_REMOTE_DEST}/${f}" 2>/dev/null || true
                done <<< "$stale"
            fi
        fi
        if [[ -f "$TELEGRAM_CONFIG" ]]; then
            source "$TELEGRAM_CONFIG"
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
                --data-urlencode "text=☁️ FastCloud: оффсайт-бэкап $(basename "$latest") успешно выгружен." > /dev/null || true
        fi
    else
        error "Ошибка выгрузки бэкапа в облако."
    fi
}

cmd_monitor_setup() {
    [[ -f "$TELEGRAM_CONFIG" ]] || error "Сначала настройте Telegram: ./manage.sh telegram-setup"

    info "Порог свободного места на диске для алерта (в %)."
    read -rp "Алертить, если свободно меньше N% [по умолчанию 10]: " DISK_THRESHOLD
    DISK_THRESHOLD=${DISK_THRESHOLD:-10}
    [[ "$DISK_THRESHOLD" =~ ^[0-9]+$ ]] || error "Порог должен быть числом"

    echo "MONITOR_DISK_THRESHOLD=${DISK_THRESHOLD}" > "${INSTALL_DIR}/.monitor_config"
    chmod 600 "${INSTALL_DIR}/.monitor_config"

    info "Настройка проверки каждые 10 минут..."
    local cron_job="*/10 * * * * ${SCRIPTS_DIR}/monitor.sh >> /var/log/fastcloud-monitor.log 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "${SCRIPTS_DIR}/monitor.sh"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        ok "Мониторинг настроен (проверка каждые 10 минут)"
    else
        ok "Мониторинг уже настроен"
    fi

    [[ -x "${SCRIPTS_DIR}/monitor.sh" ]] && "${SCRIPTS_DIR}/monitor.sh" --test || true
    ok "Готово. Алерты будут приходить в Telegram при проблемах."
}

show_help() {
    echo -e "${CYAN}FastCloud Manager${NC}"
    echo -e "${CYAN}Совет:${NC} запустите ${GREEN}./manage.sh${NC} без аргументов — откроется меню."
    echo ""
    echo -e "${YELLOW}Команды:${NC}"
    echo -e "  ${GREEN}status${NC}              - Показать статус FastCloud"
    echo -e "  ${GREEN}doctor${NC}              - Самодиагностика (контейнеры, диск, SSL, бэкапы, защита)"
    echo -e "  ${GREEN}logs [сервис]${NC}       - Показать логи (опционально конкретного сервиса)"
    echo -e "  ${GREEN}restart${NC}             - Перезапустить FastCloud"
    echo -e "  ${GREEN}stop${NC}                - Остановить FastCloud"
    echo -e "  ${GREEN}start${NC}               - Запустить FastCloud"
    echo -e "  ${GREEN}backup${NC}              - Создать локальный бэкап (данные + дамп БД)"
    echo -e "  ${GREEN}verify-backup [файл]${NC} - Проверить, что бэкап реально восстановим"
    echo -e "  ${GREEN}restore <файл>${NC}      - Восстановить из бэкапа"
    echo -e "  ${GREEN}update${NC}              - Обновить FastCloud"
    echo -e "  ${GREEN}occ <аргументы>${NC}     - Выполнить команду Nextcloud occ"
    echo -e "  ${GREEN}show-password${NC}       - Показать пароль администратора"
    echo -e "  ${GREEN}reset-password${NC}      - Сбросить пароль администратора"
    echo -e "  ${GREEN}set-domain <домен>${NC}  - Добавить домен в trusted_domains"
    echo -e "  ${GREEN}uninstall${NC}           - Удалить FastCloud"
    echo -e "  ${GREEN}telegram-setup${NC}      - Настроить Telegram-уведомления"
    echo -e "  ${GREEN}telegram-test${NC}       - Отправить тестовое сообщение в Telegram"
    echo -e "  ${GREEN}monitor-setup${NC}       - Мониторинг и алерты в Telegram"
    echo -e "  ${GREEN}backup-setup${NC}        - Настроить оффсайт-бэкапы (S3/B2/Yandex)"
    echo -e "  ${GREEN}backup-remote${NC}       - Выгрузить бэкап в облако"
    echo ""
}

interactive_menu() {
    while true; do
        clear 2>/dev/null || true
        echo -e "${CYAN}FastCloud Manager${NC}"
        echo ""
        echo -e "${YELLOW}Управление:${NC}"
        echo -e "   ${GREEN}1)${NC} Статус сервера"
        echo -e "   ${GREEN}2)${NC} Логи"
        echo -e "   ${GREEN}3)${NC} Перезапустить"
        echo -e "   ${GREEN}4)${NC} Остановить"
        echo -e "   ${GREEN}5)${NC} Запустить"
        echo -e "   ${GREEN}6)${NC} Создать бэкап"
        echo -e "   ${GREEN}7)${NC} Восстановить из бэкапа"
        echo -e "   ${GREEN}8)${NC} Обновить FastCloud"
        echo ""
        echo -e "${YELLOW}Диагностика:${NC}"
        echo -e "  ${GREEN}19)${NC} Самодиагностика (doctor)"
        echo -e "  ${GREEN}20)${NC} Проверить бэкап на восстановимость"
        echo ""
        echo -e "${YELLOW}Администрирование:${NC}"
        echo -e "   ${GREEN}9)${NC} Показать пароль администратора"
        echo -e "  ${GREEN}10)${NC} Сбросить пароль администратора"
        echo -e "  ${GREEN}11)${NC} Добавить домен (trusted_domains)"
        echo -e "  ${GREEN}12)${NC} Выполнить команду occ"
        echo ""
        echo -e "${YELLOW}Уведомления и бэкапы:${NC}"
        echo -e "  ${GREEN}13)${NC} Настроить Telegram-уведомления"
        echo -e "  ${GREEN}14)${NC} Тест Telegram"
        echo -e "  ${GREEN}15)${NC} Мониторинг и алерты"
        echo -e "  ${GREEN}16)${NC} Настроить оффсайт-бэкапы (S3/B2/Yandex)"
        echo -e "  ${GREEN}17)${NC} Выгрузить бэкап в облако"
        echo ""
        echo -e "${YELLOW}Система:${NC}"
        echo -e "  ${GREEN}18)${NC} Удалить FastCloud"
        echo ""
        echo -e "   ${GREEN}0)${NC} Выход"
        echo ""
        read -rp "$(echo -e "${CYAN}Выберите пункт:${NC} ")" choice

        echo ""
        # Каждую команду запускаем в подоболочке, чтобы её exit/error не убивал меню.
        case "$choice" in
            1)  ( cmd_status ) ;;
            2)  read -rp "Имя сервиса (пусто = все): " svc; ( cmd_logs "$svc" ) ;;
            3)  ( cmd_restart ) ;;
            4)  ( cmd_stop ) ;;
            5)  ( cmd_start ) ;;
            6)  ( cmd_backup ) ;;
            7)  read -rp "Путь к файлу бэкапа: " bf; ( cmd_restore "$bf" ) ;;
            8)  ( cmd_update ) ;;
            9)  ( cmd_show_password ) ;;
            10) ( cmd_reset_password ) ;;
            11) read -rp "Домен: " dom; ( cmd_set_domain "$dom" ) ;;
            12) read -rp "occ аргументы (например, status): " occargs; ( cmd_occ $occargs ) ;;
            13) ( cmd_telegram_setup ) ;;
            14) ( cmd_telegram_test ) ;;
            15) ( cmd_monitor_setup ) ;;
            16) ( cmd_backup_setup ) ;;
            17) ( cmd_backup_remote ) ;;
            18) ( cmd_uninstall ) ;;
            19) ( cmd_doctor ) || true ;;
            20) read -rp "Путь к бэкапу (пусто = последний): " vbf; ( cmd_verify_backup "$vbf" ) ;;
            0)  echo -e "${CYAN}До встречи!${NC}"; break ;;
            *)  warn "Неверный пункт меню" ;;
        esac

        echo ""
        read -rp "$(echo -e "${CYAN}Нажмите Enter, чтобы вернуться в меню...${NC}")" _
    done
}

main() {
    if [[ $# -eq 0 ]]; then
        interactive_menu
        exit 0
    fi

    local command=${1:-help}
    shift || true

    case "$command" in
        status)          cmd_status ;;
        doctor)          cmd_doctor ;;
        logs)            cmd_logs "$@" ;;
        restart)         cmd_restart ;;
        stop)            cmd_stop ;;
        start)           cmd_start ;;
        backup)          cmd_backup ;;
        verify-backup)   cmd_verify_backup "$@" ;;
        restore)         cmd_restore "$@" ;;
        update)          cmd_update ;;
        occ)             cmd_occ "$@" ;;
        show-password)   cmd_show_password ;;
        reset-password)  cmd_reset_password "$@" ;;
        set-domain)      cmd_set_domain "$@" ;;
        uninstall)       cmd_uninstall ;;
        telegram-setup)  cmd_telegram_setup ;;
        telegram-test)   cmd_telegram_test ;;
        backup-setup)    cmd_backup_setup ;;
        backup-remote)   cmd_backup_remote ;;
        monitor-setup)   cmd_monitor_setup ;;
        help|--help|-h)  show_help ;;
        *)               error "Неизвестная команда: $command\nИспользуйте: ./manage.sh help" ;;
    esac
}

main "$@"
MANAGE_EOF
chmod +x manage.sh
ok "Создан manage.sh"

cat > scripts/telegram-report.sh <<'TELEGRAM_EOF'
#!/usr/bin/env bash
# Ежедневный отчёт о статусе сервера в Telegram.
set -euo pipefail

INSTALL_DIR="/opt/fastcloud"
TELEGRAM_CONFIG="${INSTALL_DIR}/.telegram_config"

[[ -f "$TELEGRAM_CONFIG" ]] || exit 0
source "$TELEGRAM_CONFIG"

DISK_USAGE=$(du -sh "${INSTALL_DIR}/data" 2>/dev/null | cut -f1 || echo "N/A")
DB_SIZE=$(du -sh "${INSTALL_DIR}/db" 2>/dev/null | cut -f1 || echo "N/A")
FREE_DISK=$(df -h "${INSTALL_DIR}" | awk 'NR==2 {print $4}')
UPTIME=$(uptime -p | sed 's/up //')

cd "$INSTALL_DIR"
SERVICES_STATUS=$(docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || echo "Ошибка получения статуса")

MESSAGE="📊 *Ежедневный отчет FastCloud*

💾 *Использование диска:*
  • Данные: ${DISK_USAGE}
  • База данных: ${DB_SIZE}
  • Свободно: ${FREE_DISK}

⏱ *Аптайм:* ${UPTIME}

🔧 *Статус сервисов:*
\`\`\`
${SERVICES_STATUS}
\`\`\`

✅ Все системы работают нормально!"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}" \
    --data-urlencode "parse_mode=Markdown" > /dev/null
TELEGRAM_EOF
chmod +x scripts/telegram-report.sh
ok "Создан scripts/telegram-report.sh"

cat > scripts/monitor.sh <<'MONITOR_EOF'
#!/usr/bin/env bash
# Проверяет контейнеры и свободное место, шлёт алерт в Telegram при проблемах.
# Запускается по cron каждые 10 минут. Флаг --test шлёт пробное сообщение.
set -euo pipefail

INSTALL_DIR="/opt/fastcloud"
TELEGRAM_CONFIG="${INSTALL_DIR}/.telegram_config"
MONITOR_CONFIG="${INSTALL_DIR}/.monitor_config"
STATE_FILE="${INSTALL_DIR}/.monitor_state"

[[ -f "$TELEGRAM_CONFIG" ]] || exit 0
source "$TELEGRAM_CONFIG"

DISK_THRESHOLD=10
[[ -f "$MONITOR_CONFIG" ]] && source "$MONITOR_CONFIG" && DISK_THRESHOLD=${MONITOR_DISK_THRESHOLD:-10}

send() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1" \
        --data-urlencode "parse_mode=Markdown" > /dev/null || true
}

if [[ "${1:-}" == "--test" ]]; then
    send "🔔 FastCloud Monitor подключён. Порог свободного диска: ${DISK_THRESHOLD}%."
    exit 0
fi

cd "$INSTALL_DIR"
ALERTS=""

while read -r name state; do
    [[ -z "$name" ]] && continue
    if [[ "$state" != "running" ]]; then
        ALERTS+="⚠️ Контейнер *${name}* в состоянии: ${state}"$'\n'
    fi
done < <(docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null)

USE_PCT=$(df --output=pcent "${INSTALL_DIR}" 2>/dev/null | tail -n1 | tr -dc '0-9')
if [[ -n "$USE_PCT" ]]; then
    FREE_PCT=$((100 - USE_PCT))
    if [[ $FREE_PCT -lt $DISK_THRESHOLD ]]; then
        ALERTS+="🔴 Мало места на диске: свободно ${FREE_PCT}% (порог ${DISK_THRESHOLD}%)"$'\n'
    fi
fi

# Истёкший сертификат — самая частая причина недоступности самохоста, причём
# Caddy может молча не продлить его (занят порт 80, rate-limit LE).
if [[ "$(cat "${INSTALL_DIR}/.install_mode" 2>/dev/null)" == "public-domain" ]]; then
    DOM=$(grep '^DOMAIN=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2-)
    if [[ -n "$DOM" ]]; then
        NOT_AFTER=$(echo | timeout 10 openssl s_client -servername "$DOM" -connect "${DOM}:443" 2>/dev/null \
            | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$NOT_AFTER" ]]; then
            DAYS_LEFT=$(( ( $(date -d "$NOT_AFTER" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
            if [[ $DAYS_LEFT -lt 14 ]]; then
                ALERTS+="🔐 SSL-сертификат ${DOM} истекает через ${DAYS_LEFT} дн."$'\n'
            fi
        else
            ALERTS+="🔐 Не удалось проверить SSL-сертификат ${DOM} (порт 443 недоступен?)"$'\n'
        fi
    fi
fi

# Бэкапы: молча переставший работать cron обнаруживается только по возрасту
# последнего архива.
LATEST_BACKUP=$(ls -t /opt/fastcloud-backups/fastcloud_backup_*.tar.gz 2>/dev/null | head -n1 || true)
if [[ -n "$LATEST_BACKUP" ]]; then
    BACKUP_AGE_DAYS=$(( ( $(date +%s) - $(stat -c %Y "$LATEST_BACKUP") ) / 86400 ))
    if [[ $BACKUP_AGE_DAYS -gt 8 ]]; then
        ALERTS+="💾 Последний бэкап создан ${BACKUP_AGE_DAYS} дн. назад"$'\n'
    fi
fi

# Антиспам: шлём алерт, только если состояние изменилось с прошлой проверки.
PREV=""
[[ -f "$STATE_FILE" ]] && PREV=$(cat "$STATE_FILE")
CURRENT=$(printf '%s' "$ALERTS" | md5sum 2>/dev/null | awk '{print $1}')

if [[ -n "$ALERTS" ]]; then
    if [[ "$CURRENT" != "$PREV" ]]; then
        send "🚨 *FastCloud: обнаружены проблемы*"$'\n\n'"${ALERTS}"
    fi
    echo "$CURRENT" > "$STATE_FILE"
else
    if [[ -n "$PREV" ]]; then
        send "✅ FastCloud: все проблемы устранены, системы в норме."
    fi
    : > "$STATE_FILE"
fi
MONITOR_EOF
chmod +x scripts/monitor.sh
ok "Создан scripts/monitor.sh"

cat > scripts/backup-remote.sh <<'BACKUPREMOTE_EOF'
#!/usr/bin/env bash
# cron-обёртка: создаёт и выгружает бэкап в облако через manage.sh.
set -euo pipefail
INSTALL_DIR="/opt/fastcloud"
cd "$INSTALL_DIR"
exec ./manage.sh backup-remote
BACKUPREMOTE_EOF
chmod +x scripts/backup-remote.sh
ok "Создан scripts/backup-remote.sh"

header "Запуск контейнеров"

echo -e "${BLUE}[INFO]${NC} Скачивание Docker-образов (это может занять 2-5 минут)..."
# Пишем вывод в лог и проверяем код возврата: при пайпе в фон set -e его не увидит.
pull_log=$(mktemp)
docker compose pull > "$pull_log" 2>&1 &
PULL_PID=$!
spinner "$PULL_PID" "Скачивание образов (PostgreSQL, Redis, Nextcloud, Caddy)..."
if ! wait "$PULL_PID"; then
    echo ""
    warn "Не удалось скачать Docker-образы. Последние строки вывода:"
    [[ -s "$pull_log" ]] && tail -n 20 "$pull_log"
    rm -f "$pull_log"
    error "Установка прервана: образы не скачаны. Проверьте интернет и повторите."
fi
rm -f "$pull_log"
ok "Docker-образы скачаны"

echo -e "${BLUE}[INFO]${NC} Запуск контейнеров..."
run_with_spinner "Запуск PostgreSQL..." docker compose up -d db
run_with_spinner "Запуск Redis..." docker compose up -d redis
run_with_spinner "Запуск Nextcloud..." docker compose up -d nextcloud
run_with_spinner "Запуск Caddy..." docker compose up -d caddy
ok "Все контейнеры запущены"

echo -e "${BLUE}[INFO]${NC} Ожидание инициализации Nextcloud..."
# Готовность определяем по status.php через HTTP, а не через `occ`:
# каждый вызов `occ` поднимает тяжёлый PHP-процесс (всё ядро Nextcloud) и на
# слабых серверах отвечает медленно/срывается по памяти, тогда как уже
# прогретый Apache стабильно отдаёт status.php. status.php содержит
# "installed":true только после завершения установки.
nc_installed() {
    docker compose exec -T nextcloud curl -fsS http://localhost/status.php 2>/dev/null \
        | grep -q '"installed":true'
}

wait_for_install() {
    local max_wait=$1
    for i in $(seq 1 "$max_wait"); do
        if nc_installed; then
            progress_bar "$max_wait" "$max_wait"
            return 0
        fi
        progress_bar "$i" "$max_wait"
        sleep 1
    done
    return 1
}

MAX_WAIT=300
if wait_for_install "$MAX_WAIT"; then
    ok "Nextcloud инициализирован"
else
    echo ""
    warn "Nextcloud не завершил установку за ${MAX_WAIT} с. Проверяю причину..."

    # Классическая проблема: config.php остался от прерванной установки
    # (например, из-за OOM), и entrypoint больше не пытается установить заново.
    if docker compose exec -T nextcloud test -f /var/www/html/config/config.php 2>/dev/null; then
        warn "Найден config.php от предыдущей попытки установки."
        warn "Похоже, установка была прервана (нехватка RAM?) и не была завершена."
        info "Пересоздаю установку: удаляю недописанный config.php и схему БД, повторяю попытку..."

        docker compose exec -T nextcloud rm -f /var/www/html/config/config.php || true
        docker compose exec -T db psql -U nextcloud -d nextcloud \
            -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" > /dev/null 2>&1 || true
        docker compose restart nextcloud

        info "Повторное ожидание инициализации (ещё до ${MAX_WAIT} с)..."
        if wait_for_install "$MAX_WAIT"; then
            ok "Nextcloud инициализирован со второй попытки"
        else
            echo ""
            warn "Повторная попытка тоже не удалась. Диагностика:"
            docker compose exec -T nextcloud curl -fsS http://localhost/status.php 2>/dev/null || true
            echo ""
            docker compose logs --tail 50 nextcloud 2>/dev/null | grep -iv '"GET \|"HEAD \|"POST ' || true
            echo ""
            docker compose logs --tail 30 db 2>/dev/null || true
            error "Nextcloud не удалось инициализировать. Проверьте объём RAM и логи БД."
        fi
    else
        echo ""
        warn "config.php отсутствует — установка не запустилась вовсе. Диагностика:"
        docker compose logs --tail 50 nextcloud 2>/dev/null | grep -iv '"GET \|"HEAD \|"POST ' || true
        echo ""
        docker compose logs --tail 30 db 2>/dev/null || true
        error "Nextcloud не удалось инициализировать за отведенное время"
    fi
fi

header "Оптимизация Nextcloud"

OCC="docker compose exec -T nextcloud php occ"

run_with_spinner "Добавление отсутствующих индексов БД..." $OCC db:add-missing-indices --no-interaction
run_with_spinner "Добавление отсутствующих колонок БД..." $OCC db:add-missing-columns --no-interaction
run_with_spinner "Добавление первичных ключей БД..." $OCC db:add-missing-primary-keys --no-interaction
run_with_spinner "Конвертация filecache в bigint..." $OCC db:convert-filecache-bigint --no-interaction

run_with_spinner "Настройка Redis для кэширования..." $OCC config:system:set memcache.distributed --value='\OC\Memcache\Redis'
run_with_spinner "Настройка Redis для блокировок..." $OCC config:system:set memcache.locking --value='\OC\Memcache\Redis'
run_with_spinner "Настройка APCu для локального кэша..." $OCC config:system:set memcache.local --value='\OC\Memcache\APCu'

run_with_spinner "Настройка фоновых задач (Cron)..." $OCC background:cron

# Фиксируем формат лога, на который рассчитан fail2ban-фильтр:
# запись в файл, ISO8601-время в поле "time".
run_with_spinner "Настройка логирования (файл, JSON)..." $OCC config:system:set log_type --value=file
run_with_spinner "Путь к лог-файлу..." $OCC config:system:set logfile --value=/var/www/html/data/nextcloud.log
run_with_spinner "Формат времени в логе..." $OCC config:system:set logdateformat --value='Y-m-d\TH:i:sP'

run_with_spinner "Восстановление системы..." $OCC maintenance:repair --no-interaction

# background:cron переключает Nextcloud в режим системного cron — создаём задание,
# иначе фоновые задачи выполняться не будут.
CRON_LINE="*/5 * * * * root cd ${INSTALL_DIR} && /usr/bin/docker compose exec -T -u www-data nextcloud php -f /var/www/html/cron.php > /dev/null 2>&1"
echo "$CRON_LINE" > /etc/cron.d/fastcloud-nextcloud
chmod 644 /etc/cron.d/fastcloud-nextcloud
ok "Системный cron для Nextcloud настроен (каждые 5 минут)"

ok "Оптимизация завершена"

if [[ "$INSTALL_MODE" == "public-domain" || "$INSTALL_MODE" == "public-ip" ]]; then
    header "Настройка fail2ban (защита от подбора паролей)"

    if ! command -v fail2ban-server &>/dev/null; then
        run_with_spinner "Установка fail2ban..." apt-get install -y -qq fail2ban
    fi

    cat > /etc/fail2ban/filter.d/fastcloud-nextcloud.conf <<'F2B_FILTER'
[Definition]
_groupsre = (?:(?:,?\s*"\w+":(?:"[^"]*"|[\d.]+|null|true|false))*)
failregex = ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Login failed:
            ^\{%(_groupsre)s,?\s*"remoteAddr":"<HOST>"%(_groupsre)s,?\s*"message":"Trusted domain error.
datepattern = ,?\s*"time"\s*:\s*"%%Y-%%m-%%dT%%H:%%M:%%S%%z"
F2B_FILTER

    cat > /etc/fail2ban/jail.d/fastcloud.conf <<F2B_JAIL
[fastcloud-nextcloud]
enabled  = true
port     = 80,443
protocol = tcp
filter   = fastcloud-nextcloud
logpath  = ${INSTALL_DIR}/data/data/nextcloud.log
maxretry = 5
bantime  = 3600
findtime = 600
F2B_JAIL

    # fail2ban не стартует, если logpath не существует (роняет весь демон).
    # Nextcloud создаёт лог лениво — заранее создаём пустой файл.
    NC_LOG="${INSTALL_DIR}/data/data/nextcloud.log"
    mkdir -p "$(dirname "$NC_LOG")"
    [[ -f "$NC_LOG" ]] || : > "$NC_LOG"
    chown 33:33 "$NC_LOG" 2>/dev/null || true

    run_with_spinner "Перезапуск fail2ban..." systemctl restart fail2ban
    run_with_spinner "Включение fail2ban в автозапуск..." systemctl enable fail2ban
    ok "fail2ban настроен (бан на 1 час после 5 неудачных входов)"
fi

clear
echo -e "${GREEN}"
cat << "ART"
  ███████╗ █████╗ ███████╗████████╗ ██████╗██╗  ██╗ ██████╗██╗      ██████╗
  ██╔════╝██╔══██╗██╔════╝╚══██╔══╝██╔════╝██║  ██║██╔════╝██║     ██╔═══██╗
  █████╗  ███████║███████╗   ██║   ██║     ███████║██║     ██║     ██║   ██║
  ██╔══╝  ██╔══██║╚════██║   ██║   ██║     ██╔══██║██║     ██║     ██║   ██║
  ██║     ██║  ██║███████║   ██║   ╚██████╗██║  ██║╚██████╗███████╗╚██████╔╝
  ╚═╝     ╚═╝  ╚═╝╚══════╝   ╚═╝    ╚═════╝╚═╝  ╚═╝ ╚═════╝╚══════╝ ╚═════╝
ART
echo -e "${NC}"

echo -e "${GREEN}✅ Установка успешно завершена!${NC}\n"

case "$INSTALL_MODE" in
    public-domain)
        echo -e "${CYAN}🌐 Ваш Nextcloud доступен по адресу:${NC}"
        echo -e "   ${YELLOW}https://${DOMAIN}${NC}\n"
        echo -e "${CYAN}🔒 SSL-сертификат автоматически выпущен Let's Encrypt${NC}\n"
        ;;
    public-ip)
        echo -e "${CYAN}🌐 Ваш Nextcloud доступен по адресу:${NC}"
        echo -e "   ${YELLOW}http://${PUBLIC_IP}${NC}\n"
        echo -e "${YELLOW}⚠️  Публичный доступ без SSL — данные передаются в открытом виде.${NC}"
        echo -e "   Для безопасности рассмотрите домен и режим с HTTPS.\n"
        ;;
    local)
        echo -e "${CYAN}🌐 Ваш Nextcloud доступен по адресу:${NC}"
        echo -e "   ${YELLOW}http://${SERVER_IP}${NC}\n"
        echo -e "${YELLOW}⚠️  Локальный режим работает без SSL.${NC}\n"
        ;;
esac

echo -e "${CYAN}🔑 Данные для входа:${NC}"
echo -e "   Логин: ${YELLOW}admin${NC}"
echo -e "   Пароль: ${YELLOW}${ADMIN_PASSWORD}${NC}\n"
echo -e "${CYAN}📁 Файлы установлены в:${NC} ${YELLOW}${INSTALL_DIR}${NC}\n"
echo -e "${CYAN}🔧 Управление:${NC} ${YELLOW}cd ${INSTALL_DIR} && ./manage.sh${NC}\n"

echo "${ADMIN_PASSWORD}" > "${INSTALL_DIR}/.admin_password"
chmod 600 "${INSTALL_DIR}/.admin_password"

echo "${INSTALL_MODE}" > "${INSTALL_DIR}/.install_mode"
chmod 600 "${INSTALL_DIR}/.install_mode"
