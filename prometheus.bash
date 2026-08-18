#!/bin/bash
set -e

# ==============================================================================
# Fast Prometheus + NetBird + VictoriaMetrics Agent + Firewall + BBR Setup
# ==============================================================================

# Проверка наличия прав root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Пожалуйста, запустите скрипт с правами root (sudo)."
  exit 1
fi

# Запрос названия инстанса
if [ -c /dev/tty ]; then
    read -p "Введите название инстанса (например, Remnawave): " INSTANCE_NAME </dev/tty
else
    read -p "Введите название инстанса (например, Remnawave): " INSTANCE_NAME
fi

if [ -z "$INSTANCE_NAME" ]; then
    echo "❌ Ошибка: Название инстанса не может быть пустым."
    exit 1
fi

# Запрос URL с дефолтным значением NetBird
DEFAULT_URL="http://100.105.143.73:8428/api/v1/write"
if [ -c /dev/tty ]; then
    read -p "Что вписать в -remoteWrite.url? По умолчанию [$DEFAULT_URL]: " REMOTE_URL </dev/tty
else
    read -p "Что вписать в -remoteWrite.url? По умолчанию [$DEFAULT_URL]: " REMOTE_URL
fi
REMOTE_URL=${REMOTE_URL:-$DEFAULT_URL}

# Запрос доверенного IP или домена для доступа к порту 2222 (например, панель Remnawave)
if [ -c /dev/tty ]; then
    read -p "Введите домен или IP для доступа к порту 2222 (оставьте пустым, если не нужно): " ALLOWED_HOST_2222 </dev/tty
else
    read -p "Введите домен или IP для доступа к порту 2222 (оставьте пустым, если не нужно): " ALLOWED_HOST_2222
fi

# Подключение к self-hosted NetBird. Дефолтов нет намеренно: адрес панели
# управления в репозитории не хранится.
if [ -c /dev/tty ]; then
    read -p "NetBird Management URL (https://host:port): " NETBIRD_MGMT_URL </dev/tty
else
    read -p "NetBird Management URL (https://host:port): " NETBIRD_MGMT_URL
fi
if [ -z "$NETBIRD_MGMT_URL" ]; then
    echo "❌ Ошибка: NetBird Management URL не может быть пустым."
    exit 1
fi

# Ключ из дашборда: Setup Keys -> Create Setup Key
if [ -c /dev/tty ]; then
    read -p "NetBird Setup Key: " NETBIRD_SETUP_KEY </dev/tty
else
    read -p "NetBird Setup Key: " NETBIRD_SETUP_KEY
fi
if [ -z "$NETBIRD_SETUP_KEY" ]; then
    echo "❌ Ошибка: NetBird Setup Key не может быть пустым (netbird up без него не пройдет неинтерактивно)."
    exit 1
fi

echo ""
echo "=================================================================="
echo "🚀 Начинаем полную установку мониторинга и сетевой защиты..."
echo "Инстанс:      $INSTANCE_NAME"
echo "Remote URL:   $REMOTE_URL"
if [ -n "$ALLOWED_HOST_2222" ]; then
echo "Порт 2222:    Разрешен только для $ALLOWED_HOST_2222 (и белого списка)"
fi
echo "NetBird:      $NETBIRD_MGMT_URL"
echo "Защита:       IPSUM Level 1 + СКИПА (CyberOK) / Сканеры (ipset/iptables + cron)"
echo "=================================================================="
echo ""

# Ожидание освобождения блокировок apt/dpkg.
# Вызывается ДО первого разрушительного шага: unattended-upgrades по умолчанию
# работает на Ubuntu и держит lock, а из-за set -e падение установки пакетов
# обрывало скрипт уже после сноса старого мониторинга.
#
# fuser (пакет psmisc) стоит не везде. Запасной вариант - `apt-get check`:
# он берет тот же самый lock, поэтому дает точный ответ. Проверка по именам
# процессов тут не годится: pgrep -f ловит и постоянно висящий
# unattended-upgrade-shutdown --wait-for-signal (он lock не держит), и сам
# себя, из-за чего ожидание срабатывало бы всегда и на всех.
apt_is_busy() {
    if command -v fuser >/dev/null 2>&1; then
        local l
        for l in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
                 /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
            [ -e "$l" ] || continue
            fuser "$l" >/dev/null 2>&1 && return 0
        done
        return 1
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get check -qq >/dev/null 2>&1 && return 1
        return 0
    fi
    # Не apt-система (dnf/yum/apk) - ждать нечего.
    return 1
}

wait_for_apt() {
    local waited=0
    local max_wait=600
    while apt_is_busy; do
        if [ "$waited" -eq 0 ]; then
            echo "⏳ Ожидание освобождения apt/dpkg. Обычно это unattended-upgrades."
        fi
        if [ "$waited" -ge "$max_wait" ]; then
            echo "❌ apt/dpkg занят более ${max_wait}s. Проверьте: ps -ef | grep -E 'apt|dpkg'"
            exit 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    [ "$waited" -gt 0 ] && echo "✅ apt/dpkg свободен (ждали ${waited}s)."
    return 0
}

wait_for_apt

# 1. Полная очистка
echo "[1/8] 🧹 Полная очистка старых конфигов и служб мониторинга..."
systemctl stop cadvisor nodeexporter vmagent firewall-blocklist 2>/dev/null || true
systemctl disable cadvisor nodeexporter vmagent firewall-blocklist 2>/dev/null || true
rm -f /etc/systemd/system/cadvisor.service
rm -f /etc/systemd/system/nodeexporter.service
rm -f /etc/systemd/system/vmagent.service
rm -f /etc/systemd/system/firewall-blocklist.service
systemctl daemon-reload
rm -rf /opt/monitoring/
pkill -f vmagent 2>/dev/null || true
pkill -f cadvisor 2>/dev/null || true
pkill -f node_exporter 2>/dev/null || true

# 2. Установка NetBird
echo "[2/8] 🌐 Установка и подключение NetBird..."
curl -fsSL https://pkgs.netbird.io/install.sh | sh
echo "------------------------------------------------------------------"
echo "Подключаемся к $NETBIRD_MGMT_URL по Setup Key..."
echo "------------------------------------------------------------------"
netbird up --management-url "$NETBIRD_MGMT_URL" --setup-key "$NETBIRD_SETUP_KEY" || true

# 3. Включение TCP BBR
echo "[3/8] ⚡ Оптимизация сети (включение TCP BBR)..."
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p 2>/dev/null || sysctl --system 2>/dev/null || true

# 4. Установка и настройка сетевой защиты (IPsum Level 1 + СКИПА + ipset + Cron)
echo "[4/8] 🛡️ Установка и настройка сетевой защиты (IPsum Level 1 + СКИПА + ipset + Cron)..."

# Установка необходимых пакетов (включая утилиты DNS резолва)
echo "📦 Проверка и установка зависимостей (ipset, iptables, curl, dnsutils)..."
if command -v apt-get &>/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ipset iptables curl dnsutils
elif command -v dnf &>/dev/null; then
    dnf install -y -q ipset iptables curl bind-utils
elif command -v yum &>/dev/null; then
    yum install -y -q ipset iptables curl bind-utils
elif command -v apk &>/dev/null; then
    apk add --no-cache ipset iptables curl bind-tools
fi

mkdir -p /opt/security
mkdir -p /var/lib/node_exporter/textfile_collector

# Создаем кастомные списки, если они еще не созданы
if [ ! -f /opt/security/custom-whitelist.txt ]; then
    cat <<'EOF' > /opt/security/custom-whitelist.txt
# Добавьте сюда ваши доверенные IP, подсети или доменные имена (по одному на строку), например:
# 1.2.3.4
# 198.51.100.0/24
# panel.example.com
# my-home.ddns.net
EOF
fi

# Если при установке был указан хост для порта 2222, добавляем его в белый список
if [ -n "$ALLOWED_HOST_2222" ]; then
    if ! grep -Fxq "$ALLOWED_HOST_2222" /opt/security/custom-whitelist.txt 2>/dev/null; then
        echo "$ALLOWED_HOST_2222" >> /opt/security/custom-whitelist.txt
    fi
fi

if [ ! -f /opt/security/custom-blacklist.txt ]; then
    cat <<'EOF' > /opt/security/custom-blacklist.txt
# Добавьте сюда дополнительные IP/подсети для блокировки (по одному на строку)
EOF
fi

# Создаем исполняемый скрипт обновления блэклиста и вайтлиста
cat <<'EOF' > /usr/local/bin/update-firewall-blocklist.sh
#!/bin/bash
set -e

SECURITY_DIR="/opt/security"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
mkdir -p "$SECURITY_DIR" "$METRICS_DIR"

SET_NAME="ipsum_blacklist"
SET_TMP="ipsum_blacklist_tmp"
SET_WHITELIST="security_whitelist"
SET_WHITELIST_TMP="security_whitelist_tmp"
TMP_IPSUM="/tmp/ipsum_level1.txt"
TMP_RESTORE="/tmp/ipset_restore.txt"

# Функция резолва домена в IPv4
resolve_domain() {
    local host="$1"
    local ips=""
    if command -v getent &>/dev/null; then
        ips=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u)
    fi
    if [ -z "$ips" ] && command -v dig &>/dev/null; then
        ips=$(dig +short "$host" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    fi
    if [ -z "$ips" ] && command -v nslookup &>/dev/null; then
        ips=$(nslookup "$host" 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    fi
    if [ -z "$ips" ] && command -v host &>/dev/null; then
        ips=$(host -t A "$host" 2>/dev/null | awk '/has address/ { print $4 }' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    fi
    echo "$ips"
}

# Режим восстановления из локального кэша при старте (если передан флаг --restore-only)
if [ "$1" = "--restore-only" ] && [ -f "$SECURITY_DIR/ipset-rules.save" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Быстрое восстановление ipset из кэша..."
    ipset restore -! < "$SECURITY_DIR/ipset-rules.save" || true
elif [ "$1" != "--refresh-whitelist" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📥 Загрузка свежего списка IPSUM Level 1..."
    
    DOWNLOAD_SUCCESS=0
    if curl -fsSL --retry 3 --connect-timeout 15 "https://raw.githubusercontent.com/stamparm/ipsum/master/levels/1.txt" -o "$TMP_IPSUM"; then
        DOWNLOAD_SUCCESS=1
    elif [ -f "$SECURITY_DIR/ipsum_backup.txt" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Ошибка загрузки, используем резервную копию списка..."
        cp "$SECURITY_DIR/ipsum_backup.txt" "$TMP_IPSUM"
        DOWNLOAD_SUCCESS=1
    fi

    if [ "$DOWNLOAD_SUCCESS" -eq 1 ]; then
        cp "$TMP_IPSUM" "$SECURITY_DIR/ipsum_backup.txt" 2>/dev/null || true

        # Формируем правила для атомарной загрузки во временный ipset
        cat <<SET_EOF > "$TMP_RESTORE"
create $SET_TMP hash:net family inet hashsize 65536 maxelem 1000000 -exist
flush $SET_TMP
SET_EOF

        # Добавляем адреса из IPSUM (фильтруем комментарии и невалидные строки)
        grep -vE '^#|^$' "$TMP_IPSUM" | awk '{print "add '"$SET_TMP"' " $1 " -exist"}' >> "$TMP_RESTORE"

        # Добавляем диапазоны активных сканеров интернета:
        # 85.142.100.0/24 - СКИПА (CyberOK / EASM сканеры)
        # Censys, Shodan, Shadowserver, ZoomEye и др.
        cat <<SET_EOF >> "$TMP_RESTORE"
add $SET_TMP 85.142.100.0/24 -exist
add $SET_TMP 162.142.125.0/24 -exist
add $SET_TMP 167.94.138.0/24 -exist
add $SET_TMP 167.94.145.0/24 -exist
add $SET_TMP 167.94.146.0/24 -exist
add $SET_TMP 167.248.133.0/24 -exist
add $SET_TMP 185.180.143.0/24 -exist
add $SET_TMP 185.220.101.0/24 -exist
add $SET_TMP 198.235.24.0/24 -exist
add $SET_TMP 184.105.139.0/24 -exist
add $SET_TMP 184.105.247.0/24 -exist
add $SET_TMP 216.218.206.0/24 -exist
SET_EOF

        # Пользовательский черный список
        if [ -f "$SECURITY_DIR/custom-blacklist.txt" ]; then
            grep -vE '^#|^$' "$SECURITY_DIR/custom-blacklist.txt" | awk '{print "add '"$SET_TMP"' " $1 " -exist"}' >> "$TMP_RESTORE" 2>/dev/null || true
        fi

        # Применяем временный набор
        ipset restore -! < "$TMP_RESTORE"

        # Создаем постоянный сет (если нет) и делаем бесшовный SWAP
        ipset create $SET_NAME hash:net family inet hashsize 65536 maxelem 1000000 -exist
        ipset swap $SET_TMP $SET_NAME
        ipset destroy $SET_TMP 2>/dev/null || true

        rm -f "$TMP_IPSUM" "$TMP_RESTORE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Не удалось скачать список IPSUM."
    fi
fi

# Настройка Белого Списка (Whitelist): NetBird, Localhost, локальные подсети, SSH и домены
ipset create $SET_WHITELIST_TMP hash:net family inet hashsize 1024 maxelem 65536 -exist
cat <<WL_EOF | ipset restore -!
flush $SET_WHITELIST_TMP
add $SET_WHITELIST_TMP 127.0.0.0/8 -exist
add $SET_WHITELIST_TMP 10.0.0.0/8 -exist
add $SET_WHITELIST_TMP 172.16.0.0/12 -exist
add $SET_WHITELIST_TMP 192.168.0.0/16 -exist
add $SET_WHITELIST_TMP 100.64.0.0/10 -exist  # CGNAT: покрывает и NetBird, и Tailscale
WL_EOF

# Добавляем текущий IP подключения администратора по SSH в белый список
CURRENT_SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
if [ -n "$CURRENT_SSH_IP" ]; then
    ipset add $SET_WHITELIST_TMP "$CURRENT_SSH_IP" -exist 2>/dev/null || true
fi

# Пользовательский белый список (поддержка IP, CIDR подсетей и доменов с динамическим DNS резолвом)
if [ -f "$SECURITY_DIR/custom-whitelist.txt" ]; then
    grep -vE '^#|^$' "$SECURITY_DIR/custom-whitelist.txt" | while read -r line; do
        line=$(echo "$line" | tr -d '\r' | xargs)
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            ipset add $SET_WHITELIST_TMP "$line" -exist 2>/dev/null || true
        else
            resolved_ips=$(resolve_domain "$line")
            if [ -n "$resolved_ips" ]; then
                for rip in $resolved_ips; do
                    [ -n "$rip" ] && ipset add $SET_WHITELIST_TMP "$rip" -exist 2>/dev/null || true
                done
            fi
        fi
    done
fi

# Бесшовный SWAP белого списка
ipset create $SET_WHITELIST hash:net family inet hashsize 1024 maxelem 65536 -exist
ipset swap $SET_WHITELIST_TMP $SET_WHITELIST
ipset destroy $SET_WHITELIST_TMP 2>/dev/null || true

# Настройка правил iptables (без дублирования через проверку -C)
# 1. Разрешаем уже установленные и зависимые соединения
if ! iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi

# 2. Разрешаем локальный интерфейс loopback
if ! iptables -C INPUT -i lo -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 2 -i lo -j ACCEPT
fi

# 3. Разрешаем интерфейс NetBird (по умолчанию wt0 у официального клиента)
if ! iptables -C INPUT -i wt0 -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 3 -i wt0 -j ACCEPT
fi

# 4. Разрешаем весь Whitelist (включая CGNAT NetBird/Tailscale 100.64.0.0/10, доверенные IP и домены)
if ! iptables -C INPUT -m set --match-set $SET_WHITELIST src -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 4 -m set --match-set $SET_WHITELIST src -j ACCEPT
fi

# 5. Дропаем все пакеты от IPSUM Level 1 и СКИПА / Сканеров
if ! iptables -C INPUT -m set --match-set $SET_NAME src -j DROP 2>/dev/null; then
    iptables -I INPUT 5 -m set --match-set $SET_NAME src -j DROP
fi

# 6. Ограничиваем порт 2222 (разрешен только для белого списка/NetBird/localhost, для остальных DROP)
if ! iptables -C INPUT -p tcp --dport 2222 -j DROP 2>/dev/null; then
    iptables -A INPUT -p tcp --dport 2222 -j DROP
fi

# Сохраняем состояние ipset для восстановления при перезагрузке ОС
ipset save > "$SECURITY_DIR/ipset-rules.save" 2>/dev/null || true

# Экспорт метрик в Prometheus Node Exporter (Textfile Collector)
TOTAL_BLOCKED=$(ipset list $SET_NAME 2>/dev/null | grep -E '^[0-9]' | wc -l || echo 0)
cat <<METRICS_EOF > "$METRICS_DIR/firewall_security.prom.$$"
# HELP firewall_blocked_ips_total Total number of blocked IPs in IPSUM and Scanner lists
# TYPE firewall_blocked_ips_total gauge
firewall_blocked_ips_total $TOTAL_BLOCKED
# HELP firewall_blocklist_last_updated_timestamp_seconds Timestamp of last blocklist update
# TYPE firewall_blocklist_last_updated_timestamp_seconds gauge
firewall_blocklist_last_updated_timestamp_seconds $(date +%s)
# HELP firewall_blocklist_update_success Status of last firewall blocklist update
# TYPE firewall_blocklist_update_success gauge
firewall_blocklist_update_success 1
METRICS_EOF
mv "$METRICS_DIR/firewall_security.prom.$$" "$METRICS_DIR/firewall_security.prom"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Защита активна! Заблокировано IP-адресов/сетей: $TOTAL_BLOCKED"
EOF

chmod +x /usr/local/bin/update-firewall-blocklist.sh

# Создаем службу автозапуска для восстановления правил после перезагрузки
cat <<'EOF' > /etc/systemd/system/firewall-blocklist.service
[Unit]
Description=Restore Firewall IPset and Blocklist Rules on Boot
After=network.target
Before=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-firewall-blocklist.sh --restore-only
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Настраиваем Cron:
# - Каждые 10 минут: быстрое обновление белого списка и перерезолв DNS-доменов
# - Ежедневно в 04:00: полное обновление базы IPSUM Level 1 и сканеров СКИПА
cat <<'EOF' > /etc/cron.d/firewall-blocklist
# Быстрое обновление динамических IP из доменов (каждые 10 минут)
*/10 * * * * root /usr/local/bin/update-firewall-blocklist.sh --refresh-whitelist >/dev/null 2>&1
# Ежедневное обновление базы IPSUM Level 1 и сканеров СКИПА
0 4 * * * root /usr/local/bin/update-firewall-blocklist.sh > /var/log/firewall-blocklist.log 2>&1
EOF
chmod 644 /etc/cron.d/firewall-blocklist

# Выполняем первоначальную загрузку и применение защиты
/usr/local/bin/update-firewall-blocklist.sh

# 5. Создание директорий мониторинга
echo "[5/8] 📁 Создание директорий мониторинга..."
mkdir -p /opt/monitoring/{cadvisor,nodeexporter,vmagent/conf.d}

# 6. Скачивание и распаковка бинарников
echo "[6/8] 📥 Скачивание бинарников (cAdvisor v0.54.0, Node Exporter v1.9.1, vmagent v1.123.0)..."

# cAdvisor
wget -q --show-progress https://github.com/google/cadvisor/releases/download/v0.54.0/cadvisor-v0.54.0-linux-amd64 -O /opt/monitoring/cadvisor/cadvisor
chmod +x /opt/monitoring/cadvisor/cadvisor

# Node Exporter
cd /opt/monitoring/nodeexporter
wget -q --show-progress https://github.com/prometheus/node_exporter/releases/download/v1.9.1/node_exporter-1.9.1.linux-amd64.tar.gz
tar -xzf node_exporter-1.9.1.linux-amd64.tar.gz
mv node_exporter-1.9.1.linux-amd64/node_exporter .
chmod +x node_exporter
rm -rf node_exporter-1.9.1.linux-amd64.tar.gz node_exporter-1.9.1.linux-amd64

# vmagent
cd /opt/monitoring/vmagent
wget -q --show-progress https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v1.123.0/vmutils-linux-amd64-v1.123.0.tar.gz
tar -xzf vmutils-linux-amd64-v1.123.0.tar.gz
mv vmagent-prod vmagent
find . ! -name 'vmagent' -type f -delete
chmod +x vmagent
cd /opt/monitoring

# 7. Создание конфигурационных файлов
echo "[7/8] ⚙️ Создание конфигурационных файлов vmagent..."

cat <<EOF > /opt/monitoring/vmagent/scrape.yml
scrape_config_files:
  - "/opt/monitoring/vmagent/conf.d/*.yml"

global:
  scrape_interval: 15s
EOF

cat <<EOF > /opt/monitoring/vmagent/conf.d/cadvisor.yml
- job_name: cadvisor
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9101']
      labels:
        instance: "${INSTANCE_NAME}"
EOF

cat <<EOF > /opt/monitoring/vmagent/conf.d/nodeexporter.yml
- job_name: integrations/node_exporter
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9100']
      labels:
        instance: "${INSTANCE_NAME}"
EOF

# 8. Создание и запуск systemd служб
echo "[8/8] 🚀 Настройка и запуск systemd служб..."

cat <<EOF > /etc/systemd/system/cadvisor.service
[Unit]
Description=cAdvisor
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/cadvisor/cadvisor \\
        -listen_ip=127.0.0.1 \\
        -logtostderr \\
        -port=9101 \\
        -docker_only=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/nodeexporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/nodeexporter/node_exporter \\
        --web.listen-address=127.0.0.1:9100 \\
        --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/vmagent.service
[Unit]
Description=VictoriaMetrics Agent
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/vmagent/vmagent \\
      -httpListenAddr=127.0.0.1:8429 \\
      -promscrape.config=/opt/monitoring/vmagent/scrape.yml \\
      -promscrape.configCheckInterval=60s \\
      -remoteWrite.url=${REMOTE_URL}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Перезагрузка демонов и запуск всех служб
systemctl daemon-reload
systemctl enable cadvisor nodeexporter vmagent firewall-blocklist
systemctl restart cadvisor nodeexporter vmagent firewall-blocklist

echo ""
echo "=================================================================="
echo "✅ Установка успешно завершена!"
echo "=================================================================="
echo "🛡️ Сетевая защита и фаервол:"
echo "   - Защита IPSUM + СКИПА / Сканеры: блокировка опасных подсетей"
echo "   - Ограничение порта 2222:    доступен только для белого списка / NetBird"
echo "   - Кастомный белый список:    /opt/security/custom-whitelist.txt (поддерживает IP и домены)"
echo "   - Кастомный черный список:   /opt/security/custom-blacklist.txt"
echo "   - Автообновление DNS/IP:     каждые 10 минут через cron"
echo "   - Полное обновление баз:     ежедневно в 04:00 (лог: /var/log/firewall-blocklist.log)"
echo "   - Ручной запуск обновления:  /usr/local/bin/update-firewall-blocklist.sh"
echo "🚀 Оптимизация сети:"
echo "   - Контроль перегрузок TCP:  BBR (qdisc: fq)"
echo ""
echo "📊 Метрики и мониторинг:"
echo "   - VictoriaMetrics Agent:     systemctl status vmagent"
echo "   - Node Exporter (с метриками безопасности): systemctl status nodeexporter"
echo "   - cAdvisor:                  systemctl status cadvisor"
echo "   - Метрика количества заблокированных IP: firewall_blocked_ips_total"
echo "=================================================================="
