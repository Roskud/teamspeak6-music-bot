#!/usr/bin/env bash
# ==============================================================================
# Скрипт автоматической установки Музыкального Бота VibeSpeak на Debian / Ubuntu
# Поддержка: TeamSpeak 6 и TeamSpeak 3, Яндекс.Музыка, Мульти-боты, Радио 24/7
# ==============================================================================
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}  🎵 Установка Музыкального Бота VibeSpeak для TeamSpeak 6 / 3  ${NC}"
echo -e "${BLUE}  Яндекс.Музыка • Мульти-боты • Очередь • Радио Lo-Fi 24/7        ${NC}"
echo -e "${BLUE}================================================================${NC}"

# Проверка root прав
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[Ошибка] Пожалуйста, запустите скрипт от имени root (sudo ./install.sh)${NC}"
  exit 1
fi

echo -e "${YELLOW}[1/6] Обновление пакетов и установка зависимостей...${NC}"
apt-get update -y
apt-get install -y ffmpeg libopus0 curl tar bzip2 ca-certificates \
  python3 python3-pip python3-venv python3-full python3-setuptools 2>/dev/null || true
apt-get install -y libasound2 2>/dev/null || apt-get install -y libasound2t64 2>/dev/null || true

# Проверка и установка libssl1.1 (необходим для .NET Core 3.1 на Debian 12+ / Ubuntu 22.04+)
if ! ldconfig -p 2>/dev/null | grep -q 'libssl.so.1.1'; then
  echo -e "${YELLOW}Настройка совместимости libssl1.1 для .NET Core...${NC}"
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
  if [ "$ARCH" = "amd64" ]; then
    SSL_DEB="/tmp/libssl1.1_deb.deb"
    curl -fsSL "http://ftp.debian.org/debian/pool/main/o/openssl/libssl1.1_1.1.1w-0+deb11u1_amd64.deb" -o "$SSL_DEB" 2>/dev/null || \
    curl -fsSL "http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2.24_amd64.deb" -o "$SSL_DEB" 2>/dev/null || true
    if [ -f "$SSL_DEB" ]; then
      dpkg -i "$SSL_DEB" 2>/dev/null || apt-get install -f -y 2>/dev/null || true
      rm -f "$SSL_DEB"
    fi
  fi
fi

echo -e "${YELLOW}[2/6] Создание пользователя ts3bot и рабочей директории...${NC}"
id -u ts3bot &>/dev/null || useradd -r -m -d /opt/ts3audiobot -s /bin/false ts3bot
mkdir -p /opt/ts3audiobot/logs
cd /opt/ts3audiobot

echo -e "${YELLOW}[3/6] Настройка виртуального окружения Python и yandex-music...${NC}"
python3 -m venv /opt/ts3audiobot/venv
/opt/ts3audiobot/venv/bin/pip install --upgrade pip --quiet 2>/dev/null || true
/opt/ts3audiobot/venv/bin/pip install yandex-music requests --quiet

echo -e "${YELLOW}[4/6] Скачивание и распаковка TS3AudioBot (Linux x64)...${NC}"
curl -L https://github.com/Splamy/TS3AudioBot/releases/download/0.12.0/TS3AudioBot_linux_x64.tar.gz -o /tmp/ts3audiobot.tar.gz
tar -xzf /tmp/ts3audiobot.tar.gz -C /opt/ts3audiobot/
rm -f /tmp/ts3audiobot.tar.gz
chmod +x /opt/ts3audiobot/TS3AudioBot

echo -e "${YELLOW}[5/6] Копирование конфигураций и модулей VibeSpeak...${NC}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CLEANUP_REPO=false

# Если скрипт запущен напрямую через curl / pipe или файлы репозитория отсутствуют:
if [ ! -f "$SCRIPT_DIR/ym_bridge.py" ] || [ ! -d "$SCRIPT_DIR/config" ]; then
  echo -e "${YELLOW}Скачивание актуальных модулей VibeSpeak с GitHub...${NC}"
  TMP_REPO=$(mktemp -d /tmp/vibespeak_repo_XXXXXX)
  if command -v git &>/dev/null; then
    git clone --depth=1 https://github.com/Roskud/teamspeak6-music-bot.git "$TMP_REPO" --quiet 2>/dev/null || true
  fi
  if [ ! -f "$TMP_REPO/debian-vps/ym_bridge.py" ]; then
    curl -fsSL https://github.com/Roskud/teamspeak6-music-bot/archive/refs/heads/main.tar.gz -o /tmp/repo.tar.gz
    tar -xzf /tmp/repo.tar.gz -C "$TMP_REPO" --strip-components=1
    rm -f /tmp/repo.tar.gz
  fi
  SCRIPT_DIR="$TMP_REPO/debian-vps"
  CLEANUP_REPO=true
fi

mkdir -p /opt/ts3audiobot/bots/default
cp "$SCRIPT_DIR/config/ts3audiobot.toml" /opt/ts3audiobot/ts3audiobot.toml
cp "$SCRIPT_DIR/config/rights.toml" /opt/ts3audiobot/rights.toml
cp "$SCRIPT_DIR/config/bots/default/bot.toml" /opt/ts3audiobot/bots/default/bot.toml
cp "$SCRIPT_DIR/config/disable_ytdl.sh" /opt/ts3audiobot/disable_ytdl.sh
chmod +x /opt/ts3audiobot/disable_ytdl.sh
cp "$SCRIPT_DIR/ym_bridge.py" /opt/ts3audiobot/ym_bridge.py
cp "$SCRIPT_DIR/config/ym_logo.png" /opt/ts3audiobot/ym_logo.png
[ -f "$SCRIPT_DIR/config/yandex_token.txt" ] && cp "$SCRIPT_DIR/config/yandex_token.txt" /opt/ts3audiobot/yandex_token.txt || true

# Создание оптимизированного FFmpeg-лаунчера против заикания звука (Auto-Reconnect & Network Buffering)
cat << 'EOF' > /opt/ts3audiobot/ffmpeg_opt.sh
#!/usr/bin/env bash
# VibeSpeak Optimized FFmpeg Launcher:
# Injects network buffer and auto-reconnect options for seamless HTTP audio playback without stuttering
FFMPEG_BIN=$(command -v ffmpeg || echo "/usr/bin/ffmpeg")
ARGS=()
HAS_HTTP=false
for arg in "$@"; do
    if [[ "$arg" =~ ^https?:// ]]; then
        HAS_HTTP=true
    fi
done

for arg in "$@"; do
    if [ "$arg" = "-i" ] && [ "$HAS_HTTP" = true ]; then
        ARGS+=("-reconnect" "1" "-reconnect_streamed" "1" "-reconnect_delay_max" "5" "-i")
    else
        ARGS+=("$arg")
    fi
done

exec "$FFMPEG_BIN" "${ARGS[@]}"
EOF
chmod +x /opt/ts3audiobot/ffmpeg_opt.sh

# Привязка оптимизированного FFmpeg в конфигурацию TS3AudioBot
sed -i 's|path = "ffmpeg"|path = "/opt/ts3audiobot/ffmpeg_opt.sh"|g' /opt/ts3audiobot/ts3audiobot.toml

# Создание стартового скрипта start.sh
cat << 'EOF' > /opt/ts3audiobot/start.sh
#!/usr/bin/env bash
cd /opt/ts3audiobot
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

PY_BIN="/opt/ts3audiobot/venv/bin/python3"
if [ ! -f "$PY_BIN" ]; then
    PY_BIN="python3"
fi

$PY_BIN /opt/ts3audiobot/ym_bridge.py &
BRIDGE_PID=$!

cleanup() {
    kill -TERM "$BRIDGE_PID" 2>/dev/null || true
    exit 0
}

trap cleanup INT TERM

/opt/ts3audiobot/TS3AudioBot --non-interactive &
BOT_PID=$!

wait -n "$BOT_PID" "$BRIDGE_PID" 2>/dev/null || wait "$BOT_PID" 2>/dev/null
cleanup
EOF
chmod +x /opt/ts3audiobot/start.sh

# ==============================================================================
# Мастер интерактивной настройки подключения (поддерживает запуск через curl)
# ==============================================================================
echo ""
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}  ⚙️  Настройка подключения к серверу TeamSpeak                  ${NC}"
echo -e "${CYAN}================================================================${NC}"

# Определение существующих значений для быстрого обновления без сброса
DEF_ADDR="127.0.0.1"
DEF_VPORT="9987"
DEF_QPORT="10011"
DEF_QPW=""
DEF_TOKEN=""

if [ -f /opt/ts3audiobot/bridge_config.json ]; then
  DEF_ADDR=$(grep -o '"host": "[^"]*"' /opt/ts3audiobot/bridge_config.json 2>/dev/null | cut -d'"' -f4 || echo "127.0.0.1")
  DEF_QPORT=$(grep -o '"query_port": [0-9]*' /opt/ts3audiobot/bridge_config.json 2>/dev/null | awk '{print $2}' || echo "10011")
  DEF_QPW=$(grep -o '"query_password": "[^"]*"' /opt/ts3audiobot/bridge_config.json 2>/dev/null | cut -d'"' -f4 || echo "")
fi
if [ -f /opt/ts3audiobot/yandex_token.txt ]; then
  DEF_TOKEN=$(grep -v '^#' /opt/ts3audiobot/yandex_token.txt 2>/dev/null | tr -d '\r\n ' || true)
fi

echo -e "Если ваш TeamSpeak сервер расположен на этом же VPS — оставьте 127.0.0.1"
echo -e "Если сервер на другом хосте — введите его внешний IP адрес или домен."
echo ""

prompt_input() {
  local prompt_msg="$1"
  local default_val="$2"
  local user_val=""
  if [ -t 0 ]; then
    read -p "$prompt_msg" user_val
  elif [ -e /dev/tty ]; then
    read -p "$prompt_msg" user_val </dev/tty
  else
    user_val=""
  fi
  echo "${user_val:-$default_val}"
}

TS_ADDRESS=$(prompt_input "Адрес TeamSpeak сервера [по умолчанию: $DEF_ADDR]: " "$DEF_ADDR")
TS_VOICE_PORT=$(prompt_input "Голосовой порт TeamSpeak [по умолчанию: $DEF_VPORT]: " "$DEF_VPORT")
TS_QUERY_PORT=$(prompt_input "Порт ServerQuery [по умолчанию: $DEF_QPORT]: " "$DEF_QPORT")

echo ""
echo -e "${YELLOW}Пароль Query-пользователя 'serveradmin':${NC}"
echo -e "• Нужен шлюзу для приёма команд, создания временных ботов и защиты чата."
TS_QUERY_PASSWORD=$(prompt_input "Пароль serveradmin [Enter если без изменений]: " "$DEF_QPW")

echo ""
YM_TOKEN=$(prompt_input "Токен Яндекс.Музыки (для полных треков) [Enter если без изменений]: " "$DEF_TOKEN")

# Запись конфигураций
sed -i "s/address = \".*\"/address = \"$TS_ADDRESS\"/g" /opt/ts3audiobot/bots/default/bot.toml

cat << EOF > /opt/ts3audiobot/bridge_config.json
{
  "host": "$TS_ADDRESS",
  "voice_port": $TS_VOICE_PORT,
  "query_port": $TS_QUERY_PORT,
  "query_user": "serveradmin",
  "query_password": "$TS_QUERY_PASSWORD",
  "stream_port": 58925
}
EOF

if [ -n "$YM_TOKEN" ]; then
  echo "$YM_TOKEN" > /opt/ts3audiobot/yandex_token.txt
fi

chown -R ts3bot:ts3bot /opt/ts3audiobot

# Утилита быстрого управления vibespeak
cat << 'EOF' > /usr/local/bin/vibespeak
#!/usr/bin/env bash
case "$1" in
  status)
    systemctl status ts3audiobot
    ;;
  restart)
    systemctl restart ts3audiobot
    echo "Бот VibeSpeak перезапущен."
    ;;
  stop)
    systemctl stop ts3audiobot
    echo "Бот VibeSpeak остановлен."
    ;;
  start)
    systemctl start ts3audiobot
    echo "Бот VibeSpeak запущен."
    ;;
  logs)
    journalctl -u ts3audiobot -f
    ;;
  token)
    nano /opt/ts3audiobot/yandex_token.txt
    systemctl restart ts3audiobot
    ;;
  config)
    nano /opt/ts3audiobot/bridge_config.json
    systemctl restart ts3audiobot
    ;;
  *)
    echo "Команды управления VibeSpeak:"
    echo "  vibespeak status   — статус бота"
    echo "  vibespeak logs     — просмотр логов в реальном времени"
    echo "  vibespeak restart  — перезапуск бота"
    echo "  vibespeak token    — редактировать токен Яндекс.Музыки"
    echo "  vibespeak config   — редактировать IP и пароль сервера"
    ;;
esac
EOF
chmod +x /usr/local/bin/vibespeak

echo -e "${YELLOW}[6/6] Настройка и запуск службы systemd...${NC}"
cp "$SCRIPT_DIR/ts3audiobot.service" /etc/systemd/system/ts3audiobot.service
systemctl daemon-reload
systemctl enable ts3audiobot
systemctl restart ts3audiobot

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  🎉 Установка VibeSpeak успешно завершена!                     ${NC}"
echo -e "${GREEN}  Бот запущен и подключен к серверу: $TS_ADDRESS                 ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo -e "Удобные команды на сервере (работают из любой папки):"
echo -e "  Статус бота:       ${CYAN}vibespeak status${NC}"
echo -e "  Живые логи:        ${CYAN}vibespeak logs${NC}"
echo -e "  Перезапуск:        ${CYAN}vibespeak restart${NC}"
echo -e "  Смена токена:      ${CYAN}vibespeak token${NC}"
echo -e "  Смена IP/пароля:   ${CYAN}vibespeak config${NC}"
echo ""

if [ "$CLEANUP_REPO" = true ]; then
  rm -rf "$TMP_REPO" 2>/dev/null || true
fi

