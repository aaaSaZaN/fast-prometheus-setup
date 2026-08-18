#!/bin/bash
set -e

# ==============================================================================
# Переезд ноды с Tailscale на NetBird
# ==============================================================================
# Порядок намеренно такой: сначала ставится и проверяется NetBird, и только
# потом сносится Tailscale. Если делать наоборот, любой сбой установки оставит
# ноду вообще без mesh. SSH при этом не страдает в любом случае - он идет по
# публичному адресу, а не через Tailscale.

# Права root скрипт добирает сам, чтобы работать и от обычного пользователя.
# Перезапуститься можно только когда скрипт лежит обычным файлом: при
# `bash <(curl ...)` или `curl | bash` в $0 оказывается /dev/fd/N или "bash",
# и перечитать себя оттуда нельзя - интерпретатор уже вычитал часть потока,
# копия вышла бы обрезанной.
if [ "$EUID" -ne 0 ]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "❌ Нужны права root, а sudo не установлен. Запустите от root."
        exit 1
    fi
    if [ -f "$0" ] && [ -r "$0" ]; then
        echo "🔑 Нужны права root — перезапускаемся через sudo..."
        exec sudo -- bash "$0" "$@"
    fi
    echo "❌ Нужны права root, а перезапустить себя из потока нельзя."
    echo "   Запустите одним из способов:"
    echo ""
    echo "     curl -sSL https://raw.githubusercontent.com/aaaSaZaN/fast-prometheus-setup/refs/heads/main/migrate-to-netbird.bash | sudo bash"
    echo ""
    echo "     curl -sSL https://raw.githubusercontent.com/aaaSaZaN/fast-prometheus-setup/refs/heads/main/migrate-to-netbird.bash -o /tmp/s.bash && sudo bash /tmp/s.bash"
    echo ""
    echo "   А вот 'sudo bash <(curl ...)' не сработает: sudo закрывает"
    echo "   лишние файловые дескрипторы, и подстановка /dev/fd/N исчезает"
    echo "   до старта bash."
    exit 1
fi

PROM_URL="https://raw.githubusercontent.com/aaaSaZaN/fast-prometheus-setup/refs/heads/main/prometheus.bash"

echo "=================================================================="
echo "🔄 Переезд с Tailscale на NetBird"
echo "=================================================================="
echo "Этап 1: установка мониторинга и NetBird (вопросы задаст prometheus.bash)"
echo "Этап 2: проверка, что метрики реально уходят через NetBird"
echo "Этап 3: удаление Tailscale — только если этап 2 прошел"
echo "=================================================================="
echo ""

# --- Этап 1 -------------------------------------------------------------
echo "[1/3] 📦 Запуск prometheus.bash..."
# Скрипт спрашивает параметры интерактивно и сам читает /dev/tty,
# поэтому его stdin нам занимать нельзя.
bash <(curl -fsSL "$PROM_URL")

echo ""
echo "[2/3] 🔍 Проверка связности через NetBird..."

# --- Этап 2 -------------------------------------------------------------
if ! command -v netbird >/dev/null 2>&1; then
    echo "❌ netbird не установлен. Tailscale не трогаем."
    exit 1
fi

# Клиенту нужно время на регистрацию и поднятие туннеля.
NB_OK=0
for i in $(seq 1 12); do
    if netbird status 2>/dev/null | grep -q "Management: Connected"; then
        NB_OK=1
        break
    fi
    sleep 5
done

if [ "$NB_OK" -ne 1 ]; then
    echo "❌ NetBird не подключился к Management. Tailscale НЕ удален — сеть не потеряна."
    echo "   Диагностика: netbird status --detail"
    exit 1
fi
echo "✅ NetBird подключен: $(netbird status 2>/dev/null | grep 'NetBird IP:' | head -1)"

# Адрес коллектора берем из уже установленного юнита, чтобы не спрашивать
# его второй раз и проверить ровно тот путь, которым пойдут метрики.
REMOTE_URL=$(grep -o 'remoteWrite.url=[^ ]*' /etc/systemd/system/vmagent.service 2>/dev/null | head -1 | cut -d= -f2-)
if [ -z "$REMOTE_URL" ]; then
    echo "❌ Не удалось определить remoteWrite.url из vmagent.service. Tailscale НЕ удален."
    exit 1
fi

# /api/v1/write -> /health: проверяем сам коллектор, а не эндпоинт записи.
HEALTH_URL="$(echo "$REMOTE_URL" | sed 's#/api/v1/write$##')/health"
echo "   Проверяем коллектор: $HEALTH_URL"

COLLECTOR_OK=0
for i in $(seq 1 6); do
    if curl -sf -o /dev/null --max-time 10 "$HEALTH_URL"; then
        COLLECTOR_OK=1
        break
    fi
    sleep 5
done

if [ "$COLLECTOR_OK" -ne 1 ]; then
    echo "❌ Коллектор $HEALTH_URL недоступен через NetBird. Tailscale НЕ удален."
    echo "   Проверьте: netbird status --detail; curl -v $HEALTH_URL"
    exit 1
fi
echo "✅ Коллектор отвечает через NetBird."

# --- Этап 3 -------------------------------------------------------------
echo ""
echo "[3/3] 🧹 Удаление Tailscale..."

# Адрес ноды в Tailscale могли прописать в сторонних системах: панель
# Remnawave держит ноды именно по их mesh-адресам, и после удаления
# Tailscale она потеряет с ними связь. Автоматически это не проверить -
# ссылка живет на другой машине, поэтому спрашиваем явно.
TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
NB_IP=$(netbird status 2>/dev/null | grep 'NetBird IP:' | head -1 | awk '{print $3}' | cut -d/ -f1)

echo ""
echo "------------------------------------------------------------------"
echo "⚠️  ВНИМАНИЕ. Адрес этой ноды меняется:"
echo "      Tailscale: ${TS_IP:-неизвестен}   (перестанет работать)"
echo "      NetBird:   ${NB_IP:-неизвестен}   (использовать вместо него)"
echo ""
echo "    Проверьте, что этот Tailscale-адрес нигде не прописан:"
echo "      - панель Remnawave: адрес ноды (Nodes -> Address)"
echo "      - .env и конфиги других сервисов"
echo "      - белые списки и правила фаервола на других машинах"
echo "------------------------------------------------------------------"
if [ -c /dev/tty ]; then
    read -p "Все ссылки на $TS_IP уже переведены на $NB_IP? Введите yes для удаления: " CONFIRM </dev/tty
else
    read -p "Все ссылки на $TS_IP уже переведены на $NB_IP? Введите yes для удаления: " CONFIRM
fi
if [ "$CONFIRM" != "yes" ]; then
    echo ""
    echo "⏸️  Удаление Tailscale отменено. NetBird и мониторинг уже настроены и работают."
    echo "    Обновите ссылки на адрес ноды и запустите этот скрипт повторно —"
    echo "    установка пройдет идемпотентно, снесется только Tailscale."
    exit 0
fi

if ! command -v tailscale >/dev/null 2>&1 && ! command -v tailscaled >/dev/null 2>&1; then
    echo "Tailscale не установлен, пропускаем."
else
    # logout снимает ноду с тайлнета, иначе она останется висеть в админке
    # как оффлайн. Может не пройти, если координационный сервер недоступен -
    # это не повод прерывать удаление.
    tailscale logout 2>/dev/null || echo "   (logout не прошел — уберите ноду в админке вручную)"
    tailscale down 2>/dev/null || true

    systemctl stop tailscaled 2>/dev/null || true
    systemctl disable tailscaled 2>/dev/null || true

    # Снимает интерфейс, маршруты и правила iptables, которые Tailscale
    # создал. Без этого остаются висеть цепочки ts-input / ts-forward.
    tailscaled --cleanup 2>/dev/null || true

    if command -v apt-get >/dev/null 2>&1; then
        wait_for_apt_simple() {
            local waited=0
            while ! apt-get check -qq >/dev/null 2>&1; do
                [ "$waited" -ge 300 ] && break
                [ "$waited" -eq 0 ] && echo "   ⏳ Ожидание освобождения apt..."
                sleep 5
                waited=$((waited + 5))
            done
        }
        wait_for_apt_simple
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq tailscale >/dev/null 2>&1 || true
        rm -f /etc/apt/sources.list.d/tailscale.list
        rm -f /usr/share/keyrings/tailscale-archive-keyring.gpg
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y -q tailscale >/dev/null 2>&1 || true
        rm -f /etc/yum.repos.d/tailscale.repo
    elif command -v yum >/dev/null 2>&1; then
        yum remove -y -q tailscale >/dev/null 2>&1 || true
        rm -f /etc/yum.repos.d/tailscale.repo
    elif command -v apk >/dev/null 2>&1; then
        apk del tailscale >/dev/null 2>&1 || true
    fi

    # Ключи и состояние ноды. После этого вернуться в тайлнет можно только
    # заново авторизовавшись.
    rm -rf /var/lib/tailscale
    rm -f /etc/default/tailscaled

    systemctl daemon-reload 2>/dev/null || true
fi

echo ""
echo "=================================================================="
echo "✅ Переезд завершен"
echo "=================================================================="
echo "NetBird:    $(netbird status 2>/dev/null | grep 'NetBird IP:' | head -1)"
echo "Метрики:    $REMOTE_URL"
echo "Tailscale:  $(command -v tailscale >/dev/null 2>&1 && echo 'ВСЁ ЕЩЁ УСТАНОВЛЕН (?)' || echo 'удален')"
echo "Интерфейсы: $(ip -br link show 2>/dev/null | awk '{print $1}' | grep -E '^(wt0|tailscale0)' | tr '\n' ' ')"
echo "=================================================================="
