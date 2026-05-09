#!/usr/bin/env bash
set -euo pipefail

VERSION_DEFAULT="1.25.5"
GITEA_VERSION_DEFAULT="${VERSION_DEFAULT}"
GITEA_USER="git"
GITEA_HOME="/home/git"
GITEA_WORK_DIR="/var/lib/gitea"
GITEA_CONF_FILE="${GITEA_WORK_DIR}/custom/conf/app.ini"
GITEA_BIN="/usr/local/bin/gitea"
SERVICE_FILE="/etc/systemd/system/gitea.service"

BACKUP_DIR="/var/backups/gitea"
BACKUP_ZIP="/root/backupgit.zip"
TELEGRAM_BACKUP_ZIP="/tmp/backupgit.zip"
BACKUP_TMP="/tmp/gitea-backup"
BACKUP_INTERVAL_FILE="/etc/gitea-backup-interval"

BOT_ENABLED_FILE="/etc/gitea-bot-enabled"
BOT_CONFIG_FILE="/etc/gitea-telegram.conf"
TOKEN_STORE_FILE="/root/gitea-tokens.txt"

CLOUDFLARE_TOKEN_FILE="/root/cloudflare"
CLOUDFLARE_TOKEN_LEGACY_FILE="/root/gitea-cloudflare-token"
CLOUDFLARE_TOKEN_LEGACY_BACKUP="/root/gitea-cloudflare-token.backup"
CLOUDFLARE_TOKEN_LEGACY_ETC="/etc/gitea-cloudflare-token"
CLOUDFLARE_API="https://api.cloudflare.com/client/v4"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

PROGRESS_WIDTH=14

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Execute como root."
    exit 1
  fi
}

require_supported_ubuntu() {
  local version_id major
  [[ -r /etc/os-release ]] || { echo "Sistema não suportado."; exit 1; }
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || { echo "Este script suporta apenas Ubuntu 20.04, 22.04 e 24.04."; exit 1; }
  version_id="${VERSION_ID:-}"
  case "$version_id" in
    20.04|22.04|24.04) ;;
    *)
      echo "Versão do Ubuntu não suportada: ${version_id}. Use Ubuntu 20.04, 22.04 ou 24.04."
      exit 1
      ;;
  esac
}

sanitize_domain_input() {
  local domain="${1:-}"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"
  domain="${domain%%:*}"
  printf '%s' "$domain"
}

get_primary_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

get_public_ip() {
  local ip
  ip="$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4fsS --max-time 4 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(get_primary_ip)"
  printf '%s' "$ip"
}

get_current_root_url() {
  [[ -f "${GITEA_CONF_FILE}" ]] || return 0
  awk -F= '
    /^\[server\]/ { in_server=1; next }
    /^\[/ { in_server=0 }
    in_server && $1 ~ /ROOT_URL/ {
      sub(/^[ \t]+/, "", $2)
      sub(/[ \t]+$/, "", $2)
      print $2
      exit
    }
  ' "${GITEA_CONF_FILE}"
}

is_ipv4_addr() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

build_root_url() {
  local domain="${1:-}"
  local port="${2:-3000}"
  local protocol="${3:-http}"

  domain="$(sanitize_domain_input "$domain")"
  [[ -z "$domain" ]] && domain="$(get_primary_ip)"

  if [[ "$protocol" == "https" ]]; then
    if [[ "$port" == "443" || -z "$port" ]]; then
      printf 'https://%s/' "$domain"
    else
      printf 'https://%s:%s/' "$domain" "$port"
    fi
  else
    if [[ "$port" == "80" || -z "$port" ]]; then
      printf 'http://%s/' "$domain"
    else
      printf 'http://%s:%s/' "$domain" "$port"
    fi
  fi
}

get_base_url_protocol() {
  local base="${1:-}"
  if [[ "$base" == https://* ]]; then
    echo "https"
  else
    echo "http"
  fi
}

get_base_url_host() {
  local base="${1:-}"
  base="${base#http://}"
  base="${base#https://}"
  base="${base%%/*}"
  base="${base%%:*}"
  printf '%s' "$base"
}

normalize_base_url() {
  local base="${1:-}"
  local default_port="${2:-3000}"
  local protocol host rest explicit_port

  if [[ "$base" != http://* && "$base" != https://* ]]; then
    base="http://$base"
  fi

  protocol="$(get_base_url_protocol "$base")"
  rest="${base#http://}"
  rest="${rest#https://}"
  host="${rest%%/*}"

  if [[ "$host" == *:* ]]; then
    explicit_port="${host##*:}"
    host="${host%%:*}"
  else
    explicit_port=""
  fi

  host="$(sanitize_domain_input "$host")"
  [[ -z "$host" ]] && host="$(get_primary_ip)"

  if [[ -n "$explicit_port" ]]; then
    if [[ "$protocol" == "https" && "$explicit_port" == "443" ]]; then
      printf 'https://%s/' "$host"
    elif [[ "$protocol" == "http" && "$explicit_port" == "80" ]]; then
      printf 'http://%s/' "$host"
    else
      printf '%s://%s:%s/' "$protocol" "$host" "$explicit_port"
    fi
    return
  fi

  if is_ipv4_addr "$host"; then
    build_root_url "$host" "$default_port" "$protocol"
  else
    if [[ "$protocol" == "https" ]]; then
      printf 'https://%s/' "$host"
    else
      build_root_url "$host" "$default_port" "$protocol"
    fi
  fi
}

build_local_root_url() {
  local ip="${1:-}"
  local port="${2:-3000}"
  ip="$(sanitize_domain_input "$ip")"
  [[ -z "$ip" ]] && ip="$(get_primary_ip)"
  build_root_url "$ip" "$port" "http"
}
ensure_gitea_executable() {
  if [[ -f "${GITEA_BIN}" ]]; then
    chown root:root "${GITEA_BIN}" >/dev/null 2>&1 || true
    chmod 755 "${GITEA_BIN}" >/dev/null 2>&1 || chmod +x "${GITEA_BIN}" >/dev/null 2>&1 || true
  fi
  [[ -x "${GITEA_BIN}" ]]
}

run_gitea_cli() {
  ensure_gitea_executable || { echo "Binário do Gitea sem permissão de execução: ${GITEA_BIN}" >&2; return 126; }
  sudo -u "${GITEA_USER}" env \
    USER="${GITEA_USER}" \
    HOME="${GITEA_HOME}" \
    GITEA_WORK_DIR="${GITEA_WORK_DIR}" \
    "${GITEA_BIN}" "$@"
}

# Quantidade visual/entrada dos números do menu.
# 1 = 1,2,3... | 2 = 01,02,03...10
MENU_OPTION_DIGITS=1

fix_gitea_permissions() {
  mkdir -p "${GITEA_WORK_DIR}/custom/conf" "${GITEA_WORK_DIR}/data" "${GITEA_WORK_DIR}/data/gitea-repositories" "${GITEA_WORK_DIR}/log" "${BACKUP_DIR}"
  ensure_gitea_executable >/dev/null 2>&1 || true
  chown -R "${GITEA_USER}:${GITEA_USER}" "${GITEA_WORK_DIR}"
  chmod -R u+rwX,g+rX,o-rwx "${GITEA_WORK_DIR}"
}


pause() {
  echo
  read -r -p "Enter para continuar..." _ || true
}

read_menu_option_2d() {
  local prompt="${1:-Opção: }"
  local digits="${2:-${MENU_OPTION_DIGITS:-1}}"
  local first="" second="" opt=""

  # Limpa teclas pendentes para evitar inversão de dígitos.
  while IFS= read -r -s -n 1 -t 0.001 _ < /dev/tty 2>/dev/null; do :; done

  printf '%s' "$prompt" > /dev/tty

  while true; do
    IFS= read -r -s -n 1 first < /dev/tty || true
    case "$first" in
      $'\x1b')
        read -r -s -n 2 -t 0.001 _ < /dev/tty || true
        ;;
      [0-9])
        printf '%s' "$first" > /dev/tty
        break
        ;;
      *)
        ;;
    esac
  done

  if [[ "$digits" == "2" ]]; then
    # Menus com opção 10+ são exibidos em dois dígitos: 01,02...10.
    # Aqui o segundo dígito é obrigatório para não confundir 1 com 10.
    while true; do
      IFS= read -r -s -n 1 second < /dev/tty || true
      case "$second" in
        $'\x1b')
          read -r -s -n 2 -t 0.001 _ < /dev/tty || true
          ;;
        [0-9])
          printf '%s\n' "$second" > /dev/tty
          opt="${first}${second}"
          break
          ;;
        *)
          ;;
      esac
    done
  else
    # Menus normais são selecionados com 1 dígito instantâneo.
    printf '\n' > /dev/tty
    opt="$first"
  fi

  case "$opt" in
    00) printf '0' ;;
    01|02|03|04|05|06|07|08|09) printf '%s' "${opt#0}" ;;
    *) printf '%s' "$opt" ;;
  esac
}


safe_clear() {
  command -v clear >/dev/null 2>&1 && clear || true
}

progress_line() {
  local percent="$1"
  local message="$2"
  local filled empty cols width max_msg line msg prefix bar

  (( percent < 0 )) && percent=0
  (( percent > 100 )) && percent=100

  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  (( cols < 32 )) && cols=32

  width="$PROGRESS_WIDTH"
  (( cols < 58 )) && width=10
  (( cols < 44 )) && width=8

  filled=$(( percent * width / 100 ))
  empty=$(( width - filled ))

  bar=""
  if (( filled > 0 )); then bar+="$(printf '%*s' "$filled" '' | tr ' ' '#')"; fi
  if (( empty > 0 )); then bar+="$(printf '%*s' "$empty" '' | tr ' ' '-')"; fi

  prefix="[${bar}] $(printf '%3d' "$percent")% - "
  msg="$(printf '%s' "$message" | tr '\r\n' '  ')"
  max_msg=$(( cols - ${#prefix} - 1 ))
  (( max_msg < 0 )) && max_msg=0
  if (( ${#msg} > max_msg )); then
    if (( max_msg > 3 )); then
      msg="${msg:0:max_msg-3}..."
    else
      msg="${msg:0:max_msg}"
    fi
  fi

  line="${prefix}${msg}"
  printf '\033[2K\r%s' "$line"
}

progress_ok() {
  local message="$1"
  progress_line 100 "$message"
  printf "\n"
}

progress_fail() {
  local percent="$1"
  local message="$2"
  progress_line "$percent" "$message"
  printf " [ERRO]\n"
}

run_step() {
  local percent="$1"
  local message="$2"
  shift 2

  progress_line "$percent" "$message"
  if "$@" >/dev/null 2>&1; then
    return 0
  else
    progress_fail "$percent" "$message"
    return 1
  fi
}

fit_text() {
  local text="$1"
  local max="$2"
  if (( ${#text} > max )); then
    printf '%s' "${text:0:max}"
  else
    printf '%s' "$text"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "Arquitetura não suportada: $(uname -m)"; return 1 ;;
  esac
}

ensure_packages() {
  run_step 10 "Atualizando repositórios..." apt-get update || return 1
  run_step 25 "Instalando dependências..." env DEBIAN_FRONTEND=noninteractive apt-get install -y git sqlite3 wget curl zip unzip ca-certificates sudo python3 || return 1
}

ensure_git_user() {
  if ! id -u "${GITEA_USER}" >/dev/null 2>&1; then
    adduser \
      --system \
      --shell /bin/bash \
      --gecos 'Git Version Control' \
      --group \
      --disabled-password \
      --home "${GITEA_HOME}" \
      "${GITEA_USER}" >/dev/null 2>&1
  fi
}

ensure_dirs() {
  mkdir -p "${GITEA_WORK_DIR}/custom/conf" "${GITEA_WORK_DIR}/data" "${GITEA_WORK_DIR}/log" "${BACKUP_DIR}"
  chown -R "${GITEA_USER}:${GITEA_USER}" "${GITEA_WORK_DIR}"
  chmod -R 750 "${GITEA_WORK_DIR}"
}

ensure_swap_2g_optimized() {
  local target_mb=2048 current_kb current_mb need_mb swap_path="/swapfile" existing_path desired_bytes

  current_kb="$(awk 'NR>1 {sum+=$3} END {print sum+0}' /proc/swaps 2>/dev/null || echo 0)"
  current_mb=$(( current_kb / 1024 ))

  if (( current_mb >= target_mb )); then
    :
  else
    need_mb=$(( target_mb - current_mb ))
    existing_path=""
    if [[ -f "$swap_path" ]]; then
      existing_path="$swap_path"
    elif grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
      existing_path="$swap_path"
    fi

    if [[ -n "$existing_path" ]]; then
      swapoff "$swap_path" >/dev/null 2>&1 || true
      desired_bytes=$(( target_mb * 1024 * 1024 ))
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "$desired_bytes" "$swap_path" >/dev/null 2>&1 || dd if=/dev/zero of="$swap_path" bs=1M count="$target_mb" conv=fsync status=none
      else
        dd if=/dev/zero of="$swap_path" bs=1M count="$target_mb" conv=fsync status=none
      fi
    else
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "${target_mb}M" "$swap_path" >/dev/null 2>&1 || dd if=/dev/zero of="$swap_path" bs=1M count="$target_mb" conv=fsync status=none
      else
        dd if=/dev/zero of="$swap_path" bs=1M count="$target_mb" conv=fsync status=none
      fi
    fi

    chmod 600 "$swap_path"
    mkswap "$swap_path" >/dev/null 2>&1
    swapon "$swap_path" >/dev/null 2>&1
  fi

  if grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab 2>/dev/null; then
    sed -i 's|^[^#].*[[:space:]]/swapfile[[:space:]].*|/swapfile none swap sw 0 0|' /etc/fstab
  else
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  cat > /etc/sysctl.d/99-gitea-swap.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl --system >/dev/null 2>&1 || true
}

is_installed() {
  [[ -x "${GITEA_BIN}" && -f "${SERVICE_FILE}" ]]
}

is_auto_backup_enabled() {
  systemctl is-enabled gitea-backup.timer >/dev/null 2>&1
}

load_bot_config() {
  if [[ -f "${BOT_CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${BOT_CONFIG_FILE}"
  fi
}

is_bot_enabled() {
  [[ -f "${BOT_ENABLED_FILE}" ]] && grep -q '^on$' "${BOT_ENABLED_FILE}"
}

telegram_ready() {
  load_bot_config
  is_bot_enabled && [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]
}

get_backup_interval() {
  if [[ -f "${BACKUP_INTERVAL_FILE}" ]]; then
    cat "${BACKUP_INTERVAL_FILE}"
  else
    echo "6h"
  fi
}

set_backup_interval() {
  echo "$1" > "${BACKUP_INTERVAL_FILE}"
}

get_gitea_db_path() {
  [[ -f "${GITEA_CONF_FILE}" ]] || return 1
  awk -F= '''
    /^\[database\]/ { in_db=1; next }
    /^\[/ { in_db=0 }
    in_db && $1 ~ /PATH/ {
      sub(/^[ 	]+/, "", $2)
      sub(/[ 	]+$/, "", $2)
      print $2
      exit
    }
  ''' "${GITEA_CONF_FILE}"
}

gitea_sqlite_ready() {
  local db_path
  db_path="$(get_gitea_db_path 2>/dev/null || true)"
  [[ -n "${db_path}" && -f "${db_path}" ]]
}

sqlite_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

generate_numeric_password() {
  tr -dc '0-9' </dev/urandom | head -c 8
}

enable_bot() { echo "on" > "${BOT_ENABLED_FILE}"; }
disable_bot() { echo "off" > "${BOT_ENABLED_FILE}"; }

toggle_bot() {
  safe_clear
  if is_bot_enabled; then
    disable_bot
    echo "Bot desativado."
  else
    enable_bot
    echo "Bot ativado."
  fi
  pause
}

get_service_state_plain() {
  if systemctl is-active --quiet gitea 2>/dev/null; then
    echo "Ligado"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^gitea\.service'; then
    echo "Parado"
  else
    echo "Não instalado"
  fi
}

get_ram_usage() {
  free -m | awk '
    /Mem:/ {
      mem_used=$3; mem_total=$2
    }
    /Swap:/ {
      swap_used=$3; swap_total=$2
    }
    END {
      total = mem_total + swap_total
      used = mem_used + swap_used
      if (total > 0) {
        printf "%.1f%%/100%%", (used / total) * 100
      } else {
        printf "0.0%%/100%%"
      }
    }
  '
}

get_cpu_usage() {
  local cpu user nice system idle iowait irq softirq steal total idle_all usage
  read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat 2>/dev/null || { printf '0.0%%/100%%'; return; }
  total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle_all=$((idle + iowait))
  if (( total <= 0 )); then
    printf '0.0%%/100%%'
    return
  fi
  usage=$(( (1000 * (total - idle_all) / total + 5) / 10 ))
  printf '%s%%/100%%' "$usage"
}

get_current_port() {
  [[ -f "${GITEA_CONF_FILE}" ]] || return 0
  awk -F= '
    /^\[server\]/ { in_server=1; next }
    /^\[/ { in_server=0 }
    in_server && $1 ~ /HTTP_PORT/ {
      gsub(/ /, "", $2)
      print $2
      exit
    }
  ' "${GITEA_CONF_FILE}"
}

get_current_domain() {
  [[ -f "${GITEA_CONF_FILE}" ]] || return 0
  awk -F= '
    /^\[server\]/ { in_server=1; next }
    /^\[/ { in_server=0 }
    in_server && $1 ~ /DOMAIN/ {
      sub(/^[ \t]+/, "", $2)
      sub(/[ \t]+$/, "", $2)
      print $2
      exit
    }
  ' "${GITEA_CONF_FILE}"
}

get_current_gitea_version() {
  if [[ -x "${GITEA_BIN}" ]]; then
    "${GITEA_BIN}" --version 2>/dev/null | awk '{print $3; exit}'
  else
    echo "N/A"
  fi
}

get_latest_gitea_version() {
  local arch latest url
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "$GITEA_VERSION_DEFAULT"; return 0 ;;
  esac
  url="https://dl.gitea.com/gitea/latest/gitea-linux-${arch}"
  latest="$(curl -fsSLI "$url" 2>/dev/null \
    | awk -F'/' 'tolower($1) ~ /^location:/ {print $(NF-1)}' \
    | tr -d '\r' || true)"
  if [[ -n "$latest" ]]; then
    echo "$latest"
  else
    echo "$GITEA_VERSION_DEFAULT"
  fi
}


get_update_info() {
  local current latest
  current="$(get_current_gitea_version)"
  latest="$(get_latest_gitea_version)"

  if [[ -n "${latest}" && "${current}" != "${latest}" ]]; then
    echo "update|${latest}|${current}"
  else
    echo "ok|${current}|${current}"
  fi
}

get_update_info_menu() {
  local current
  current="$(get_current_gitea_version)"
  # O menu não consulta a internet para não gerar delay ao trocar de tela.
  # A verificação real continua sendo feita ao escolher Atualizar Gitea.
  echo "ok|${current}|${current}"
}

get_current_protocol() {
  [[ -f "${GITEA_CONF_FILE}" ]] || return 0
  awk -F= '
    /^\[server\]/ { in_server=1; next }
    /^\[/ { in_server=0 }
    in_server && $1 ~ /PROTOCOL/ {
      sub(/^[ \t]+/, "", $2)
      sub(/[ \t]+$/, "", $2)
      print $2
      exit
    }
  ' "${GITEA_CONF_FILE}"
}

get_current_http_addr() {
  [[ -f "${GITEA_CONF_FILE}" ]] || return 0
  awk -F= '
    /^\[server\]/ { in_server=1; next }
    /^\[/ { in_server=0 }
    in_server && $1 ~ /HTTP_ADDR/ {
      sub(/^[ \t]+/, "", $2)
      sub(/[ \t]+$/, "", $2)
      print $2
      exit
    }
  ' "${GITEA_CONF_FILE}"
}

set_ini_value() {
  local section="$1"
  local key="$2"
  local value="$3"
  local file="${4:-$GITEA_CONF_FILE}"
  python3 - "$section" "$key" "$value" "$file" <<'PYINI'
import sys, re
section, key, value, path = sys.argv[1:5]
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()
section_re = re.compile(r'(?ms)^\\[' + re.escape(section) + r'\\]\\n(.*?)(?=^\\[|\\Z)')
m = section_re.search(text)
if not m:
    if text and not text.endswith("\n"):
        text += "\n"
    text += f"\n[{section}]\n{key} = {value}\n"
else:
    block = m.group(1)
    key_re = re.compile(r'(?m)^' + re.escape(key) + r'\\s*=.*$')
    if key_re.search(block):
        block = key_re.sub(f"{key} = {value}", block)
    else:
        if block and not block.endswith("\n"):
            block += "\n"
        block += f"{key} = {value}\n"
    text = text[:m.start(1)] + block + text[m.end(1):]
with open(path, 'w', encoding='utf-8') as f:
    f.write(text)
PYINI
}

apply_gitea_defaults() {
  local domain port protocol http_addr root_url local_root_url

  [[ -f "${GITEA_CONF_FILE}" ]] || return 1

  domain="$(get_public_ip)"
  port="$(get_current_port)"
  protocol="$(get_current_protocol)"
  http_addr="$(sanitize_domain_input "$(get_current_http_addr)")"
  root_url="$(get_current_root_url)"

  [[ -z "${domain}" ]] && domain="$(get_primary_ip)"
  [[ -z "${port}" ]] && port="$(get_current_port)"
[[ -z "${port}" ]] && port="2096"
  [[ -z "${protocol}" ]] && protocol="http"
  [[ -z "${http_addr}" || "${http_addr}" == "0.0.0.0" ]] && http_addr="$(get_primary_ip)"
  [[ -z "${root_url}" ]] && root_url="$(build_root_url "${domain}" "${port}" "${protocol}")"

  local_root_url="http://${domain}:${port}/"

  set_ini_value server PROTOCOL "${protocol}"
  set_ini_value server DOMAIN "${domain}"
  set_ini_value server HTTP_ADDR "${http_addr}"
  set_ini_value server HTTP_PORT "${port}"
  set_ini_value server ROOT_URL "${root_url}"
  set_ini_value server LOCAL_ROOT_URL "${local_root_url}"
  sed -i '/^[[:space:]]*DISABLE_SSH[[:space:]]*=/d' "${GITEA_CONF_FILE}" 2>/dev/null || true

  set_ini_value database DB_TYPE "sqlite3"
  set_ini_value database PATH "${GITEA_WORK_DIR}/data/gitea.db"
  set_ini_value repository ROOT "${GITEA_WORK_DIR}/data/gitea-repositories"

  set_ini_value service DISABLE_REGISTRATION "true"
  set_ini_value service REQUIRE_SIGNIN_VIEW "false"
  set_ini_value service ALLOW_ONLY_EXTERNAL_REGISTRATION "false"
  set_ini_value service ENABLE_OPENID_SIGNIN "false"
  set_ini_value service ENABLE_OPENID_SIGNUP "false"

  set_ini_value cors ENABLED "true"
  set_ini_value cors ALLOW_DOMAIN "*"
  set_ini_value cors METHODS "GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS"
  set_ini_value cors HEADERS "Content-Type,User-Agent,Authorization"
  set_ini_value cors MAX_AGE "10m"
  set_ini_value cors ALLOW_CREDENTIALS "false"

  set_ini_value security INSTALL_LOCK "true"
  chown -R "${GITEA_USER}:${GITEA_USER}" "${GITEA_WORK_DIR}"
}
write_config() {
  local port="$1"
  local public_ip="$2"
  local base_url="$3"
  local app_name="${4:-Gitea}"
  local host root_url local_root_url

  public_ip="$(get_public_ip)"
  [[ -z "${public_ip}" ]] && public_ip="$(get_primary_ip)"

  host="$(sanitize_domain_input "$base_url")"
  [[ -z "${host}" ]] && host="${public_ip}"

  root_url="$(normalize_base_url "${base_url:-$host}" "${port}")"
  local_root_url="http://${public_ip}:${port}/"

  mkdir -p "$(dirname "${GITEA_CONF_FILE}")" "${GITEA_WORK_DIR}/data" "${GITEA_WORK_DIR}/data/gitea-repositories" "${GITEA_WORK_DIR}/log"

  cat > "${GITEA_CONF_FILE}" <<EOF
APP_NAME = ${app_name}
RUN_USER = ${GITEA_USER}
RUN_MODE = prod
APP_DATA_PATH = ${GITEA_WORK_DIR}/data

[database]
DB_TYPE = sqlite3
PATH = ${GITEA_WORK_DIR}/data/gitea.db

[repository]
ROOT = ${GITEA_WORK_DIR}/data/gitea-repositories

[server]
PROTOCOL = http
DOMAIN = ${public_ip}
HTTP_ADDR = 0.0.0.0
HTTP_PORT = ${port}
ROOT_URL = ${root_url}
LOCAL_ROOT_URL = ${local_root_url}

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = false
ALLOW_ONLY_EXTERNAL_REGISTRATION = false
ENABLE_OPENID_SIGNIN = false
ENABLE_OPENID_SIGNUP = false

[cors]
ENABLED = true
ALLOW_DOMAIN = *
METHODS = GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS
HEADERS = Content-Type,User-Agent,Authorization
MAX_AGE = 10m
ALLOW_CREDENTIALS = false

[ui]
DEFAULT_THEME = gitea-dark

[log]
MODE = file
LEVEL = Info
ROOT_PATH = ${GITEA_WORK_DIR}/log

[security]
INSTALL_LOCK = true
EOF

  chown -R "${GITEA_USER}:${GITEA_USER}" "${GITEA_WORK_DIR}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Gitea
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${GITEA_USER}
Group=${GITEA_USER}
WorkingDirectory=${GITEA_WORK_DIR}
ExecStart=${GITEA_BIN} web --config ${GITEA_CONF_FILE}
Restart=always
RestartSec=3s
StartLimitIntervalSec=0
Environment=USER=${GITEA_USER} HOME=${GITEA_HOME} GITEA_WORK_DIR=${GITEA_WORK_DIR}

[Install]
WantedBy=multi-user.target
EOF
}

export_backup_no_pause() {
  local db_path="${GITEA_WORK_DIR}/data/gitea.db"

  mkdir -p "${BACKUP_TMP}"
  rm -rf "${BACKUP_TMP:?}"/*
  mkdir -p "${BACKUP_TMP}/data" "${BACKUP_TMP}/repos" "${BACKUP_TMP}/conf" "${BACKUP_TMP}/log" "${BACKUP_TMP}/bin" "${BACKUP_TMP}/systemd"

  [[ -f "${db_path}" ]] && sqlite3 "${db_path}" ".backup '${BACKUP_TMP}/data/gitea.db'" >/dev/null 2>&1
  [[ -f "${GITEA_CONF_FILE}" ]] && cp -f "${GITEA_CONF_FILE}" "${BACKUP_TMP}/conf/app.ini"
  [[ -d "${GITEA_WORK_DIR}/data/gitea-repositories" ]] && cp -a "${GITEA_WORK_DIR}/data/gitea-repositories" "${BACKUP_TMP}/repos/"
  [[ -d "${GITEA_WORK_DIR}/log" ]] && cp -a "${GITEA_WORK_DIR}/log/." "${BACKUP_TMP}/log/" 2>/dev/null || true
  [[ -x "${GITEA_BIN}" ]] && cp -f "${GITEA_BIN}" "${BACKUP_TMP}/bin/gitea"
  [[ -f "${SERVICE_FILE}" ]] && cp -f "${SERVICE_FILE}" "${BACKUP_TMP}/systemd/gitea.service"
  [[ -x /usr/local/bin/gitea-preflight.sh ]] && cp -f /usr/local/bin/gitea-preflight.sh "${BACKUP_TMP}/bin/gitea-preflight.sh"

  cat > "${BACKUP_TMP}/metadata.txt" <<EOF
backup_date=$(date '+%Y-%m-%d %H:%M:%S')
gitea_version=$(get_current_gitea_version)
service_state=$(get_service_state_plain)
domain=$(get_current_domain)
port=$(get_current_port)
hostname=$(hostname)
type=full-local-backup
EOF

  rm -f "${BACKUP_ZIP}"
  (
    cd "${BACKUP_TMP}"
    zip -rq "${BACKUP_ZIP}" .
  ) >/dev/null 2>&1

  rm -rf "${BACKUP_TMP}"
}

export_telegram_backup_no_pause() {
  local db_path="${GITEA_WORK_DIR}/data/gitea.db"
  local tmp_dir="/tmp/gitea-backup-telegram"

  mkdir -p "${tmp_dir}"
  rm -rf "${tmp_dir:?}"/*
  mkdir -p "${tmp_dir}/data" "${tmp_dir}/conf" "${tmp_dir}/bin"

  [[ -f "${db_path}" ]] && sqlite3 "${db_path}" ".backup '${tmp_dir}/data/gitea.db'" >/dev/null 2>&1
  [[ -f "${GITEA_CONF_FILE}" ]] && cp -f "${GITEA_CONF_FILE}" "${tmp_dir}/conf/app.ini"
  [[ -x /usr/local/bin/gitea-preflight.sh ]] && cp -f /usr/local/bin/gitea-preflight.sh "${tmp_dir}/bin/gitea-preflight.sh"

  cat > "${tmp_dir}/metadata.txt" <<EOF
backup_date=$(date '+%Y-%m-%d %H:%M:%S')
gitea_version=$(get_current_gitea_version)
type=telegram-slim-backup
EOF

  rm -f "${TELEGRAM_BACKUP_ZIP}"
  (
    cd "${tmp_dir}"
    zip -rq "${TELEGRAM_BACKUP_ZIP}" .
  ) >/dev/null 2>&1

  rm -rf "${tmp_dir}"
}

send_backup_to_telegram() {
  local current_ver response target_file caption

  telegram_ready || { echo "Telegram não configurado."; return 1; }

  target_file="${TELEGRAM_BACKUP_ZIP}"
  [[ -f "${target_file}" ]] || { echo "Backup Telegram não encontrado: ${target_file}"; return 1; }

  current_ver="$(get_current_gitea_version)"
  caption="Versão: ${current_ver}"

  response="$(curl -sS \
    -F "chat_id=${TELEGRAM_CHAT_ID}" \
    -F "caption=${caption}" \
    -F "document=@${target_file}" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument")"

  echo "${response}" | grep -q '"ok":true'
}



cloudflare_verify_token() {
  local token="$1" tmp="/tmp/cloudflare-token-verify.json"

  curl -sS --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "${CLOUDFLARE_API}/user/tokens/verify" > "$tmp" || {
      echo "Falha de conexão com a API da Cloudflare."
      return 1
    }

  python3 - "$tmp" <<'PYCFVERIFY'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("Resposta inválida da Cloudflare.")
    raise SystemExit(1)

if data.get("success") is True:
    print("ok")
    raise SystemExit(0)

errors = data.get("errors") or []
messages = []
for err in errors:
    msg = err.get("message") or err.get("code") or "erro desconhecido"
    messages.append(str(msg))
print("; ".join(messages) if messages else "token não aceito")
raise SystemExit(1)
PYCFVERIFY
}

node_major_version() {
  if command -v node >/dev/null 2>&1; then
    node -v 2>/dev/null | sed 's/^v//' | awk -F. '{print $1+0}'
  else
    echo 0
  fi
}

ensure_nodejs_20() {
  local major
  major="$(node_major_version)"
  if (( major >= 18 )); then
    return 0
  fi

  progress_line 8 "Preparando Node.js 20..."
  env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || return 1
  env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg >/dev/null 2>&1 || return 1

  progress_line 18 "Configurando repositório Node..."
  mkdir -p /etc/apt/keyrings
  rm -f /etc/apt/keyrings/nodesource.gpg /etc/apt/sources.list.d/nodesource.list
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg >/dev/null 2>&1 || return 1
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list

  progress_line 30 "Instalando Node.js 20..."
  env DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1 || return 1
  env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >/dev/null 2>&1 || return 1

  major="$(node_major_version)"
  (( major >= 18 ))
}

ensure_wrangler_installed() {
  safe_clear
  echo "Preparando login Cloudflare..."
  echo

  ensure_nodejs_20 || {
    echo
    echo "Não foi possível instalar Node.js 20 automaticamente."
    echo "No Ubuntu 20 o Node do apt é antigo; por isso o Wrangler falha."
    echo
    echo "Tente manualmente:"
    echo "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
    echo "apt-get install -y nodejs"
    return 1
  }

  if command -v wrangler >/dev/null 2>&1; then
    return 0
  fi

  progress_line 55 "Instalando Wrangler..."
  npm install -g wrangler@latest >/tmp/wrangler-install.log 2>&1 || {
    echo
    echo "Falha ao instalar Wrangler. Últimas linhas do erro:"
    tail -n 20 /tmp/wrangler-install.log 2>/dev/null || true
    return 1
  }

  command -v wrangler >/dev/null 2>&1
}

cloudflare_token_from_wrangler() {
  local token="" login_status=0

  ensure_wrangler_installed || return 1

  safe_clear
  echo "LOGIN CLOUDFLARE SEM LOCALHOST"
  echo
  echo "O script vai gerar um link do Cloudflare sem usar localhost."
  echo "Abra o link no navegador, faça login, autorize e depois volte aqui."
  echo
  echo "Node: $(node -v 2>/dev/null || echo N/A)"
  echo "Wrangler: $(wrangler --version 2>/dev/null | head -n1 || echo N/A)"
  echo
  read -r -p "Pressione Enter para iniciar o login..." _ || true
  echo

  echo "Modo sem localhost ativado."
  echo "Se aparecer um link, copie e abra no navegador do celular/PC."
  echo

  # IMPORTANTE:
  # Nunca usar 'wrangler login' padrão em VPS, porque ele tenta retornar para
  # localhost:8976 no navegador do usuário. Em servidor remoto isso falha.
  if wrangler login --browser=false; then
    login_status=0
  else
    login_status=$?
  fi

  if (( login_status != 0 )); then
    echo
    echo "Login Cloudflare não concluído."
    return 1
  fi

  token="$(wrangler auth token 2>/dev/null | awk 'NF {line=$0} END {gsub(/^[[:space:]]+|[[:space:]]+$/, "", line); print line}' || true)"

  if [[ -z "$token" ]]; then
    echo
    echo "Não foi possível capturar o token do Wrangler."
    echo "Tente rodar manualmente: wrangler auth token"
    return 1
  fi

  if cloudflare_verify_token "$token" >/dev/null 2>&1; then
    printf '%s' "$token" > "${CLOUDFLARE_TOKEN_FILE}"
    chmod 600 "${CLOUDFLARE_TOKEN_FILE}" 2>/dev/null || true
    CF_AUTH_TOKEN="$token"
    echo
    echo "Cloudflare autenticado com sucesso."
    return 0
  fi

  echo
  echo "Login feito, mas o token retornado não passou na validação da API."
  echo "Use a opção 02 e cole um API Token com Zone:Read + DNS:Edit."
  return 1
}

save_cloudflare_token() {
  local token="$1"
  umask 077
  printf '%s' "$token" > "${CLOUDFLARE_TOKEN_FILE}"
  chmod 600 "${CLOUDFLARE_TOKEN_FILE}" 2>/dev/null || true
  rm -f "${CLOUDFLARE_TOKEN_LEGACY_FILE}" "${CLOUDFLARE_TOKEN_LEGACY_BACKUP}" >/dev/null 2>&1 || true
}

read_saved_cloudflare_token() {
  local token=""
  if [[ -f "${CLOUDFLARE_TOKEN_FILE}" ]]; then
    token="$(cat "${CLOUDFLARE_TOKEN_FILE}" 2>/dev/null || true)"
  elif [[ -f "${CLOUDFLARE_TOKEN_LEGACY_FILE}" ]]; then
    token="$(cat "${CLOUDFLARE_TOKEN_LEGACY_FILE}" 2>/dev/null || true)"
  elif [[ -f "${CLOUDFLARE_TOKEN_LEGACY_BACKUP}" ]]; then
    token="$(cat "${CLOUDFLARE_TOKEN_LEGACY_BACKUP}" 2>/dev/null || true)"
  elif [[ -f "${CLOUDFLARE_TOKEN_LEGACY_ETC}" ]]; then
    token="$(cat "${CLOUDFLARE_TOKEN_LEGACY_ETC}" 2>/dev/null || true)"
  fi
  printf '%s' "$token"
}

cloudflare_token_manual() {
  local token verify_result
  echo
  echo "Cole seu API Token da Cloudflare."
  echo "Permissões necessárias: Zone:Read, DNS:Edit e Rulesets:Edit/Origin Rules."
  echo "O token será salvo em: ${CLOUDFLARE_TOKEN_FILE}"
  echo
  read -r -p "Token Cloudflare: " token || true
  echo
  [[ -z "$token" ]] && return 1

  echo "Token colado: ${token}"
  echo

  verify_result="$(cloudflare_verify_token "$token" 2>&1)" || {
    echo "Token recusado pela Cloudflare: ${verify_result}"
    return 1
  }

  save_cloudflare_token "$token"
  CF_AUTH_TOKEN="$token"
  echo "Token validado e salvo para uso automático."
  return 0
}

cloudflare_token_prompt() {
  local token use_saved verify_result
  CF_AUTH_TOKEN=""

  token="$(read_saved_cloudflare_token)"

  if [[ -n "$token" ]]; then
    echo "Token Cloudflare salvo encontrado em /root."
    read -r -p "Usar token salvo? [S/n]: " use_saved || true
    if [[ ! "${use_saved:-S}" =~ ^[nN]$ ]]; then
      verify_result="$(cloudflare_verify_token "$token" 2>&1)" || {
        echo "Token salvo inválido: ${verify_result}"
        rm -f "${CLOUDFLARE_TOKEN_FILE}" "${CLOUDFLARE_TOKEN_LEGACY_FILE}" "${CLOUDFLARE_TOKEN_LEGACY_BACKUP}" >/dev/null 2>&1 || true
        return 1
      }
      save_cloudflare_token "$token"
      CF_AUTH_TOKEN="$token"
      echo "Token salvo validado. Continuando..."
      return 0
    fi
  fi

  cloudflare_token_manual
}

cloudflare_list_zones() {
  local token="$1" tmp="/tmp/cloudflare-zones.json"
  curl -fsS --max-time 20 -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${CLOUDFLARE_API}/zones?per_page=100" > "$tmp" || return 1
  python3 - "$tmp" <<'PYCF'
import json, sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
if not data.get('success'):
    print('ERRO|' + '; '.join(e.get('message','erro') for e in data.get('errors',[])))
    raise SystemExit(2)
for i,z in enumerate(data.get('result',[]), 1):
    print(f"{i}|{z.get('id','')}|{z.get('name','')}")
PYCF
}

cloudflare_pick_zone() {
  local token="$1" zones_file="/tmp/cloudflare-zones.list" idx zone_id zone_name n zid zname
  cloudflare_list_zones "$token" > "$zones_file" || return 1
  if grep -q '^ERRO|' "$zones_file"; then cut -d'|' -f2- "$zones_file"; return 1; fi
  [[ ! -s "$zones_file" ]] && { echo "Nenhum domínio encontrado nessa conta Cloudflare."; return 1; }
  echo
  echo "Domínios encontrados na Cloudflare:"
  while IFS='|' read -r n zid zname; do printf '  %02d) %s\n' "$n" "$zname"; done < "$zones_file"
  echo
  read -r -p "Escolha o domínio: " idx || true
  idx="${idx#0}"; [[ -z "$idx" ]] && idx="0"
  zone_id="$(awk -F'|' -v i="$idx" '$1==i {print $2; exit}' "$zones_file")"
  zone_name="$(awk -F'|' -v i="$idx" '$1==i {print $3; exit}' "$zones_file")"
  [[ -z "$zone_id" || -z "$zone_name" ]] && { echo "Domínio inválido."; return 1; }
  CF_ZONE_ID="$zone_id"; CF_ZONE_NAME="$zone_name"
}

cloudflare_upsert_a_record() {
  local token="$1" zone_id="$2" name="$3" ip="$4" tmp="/tmp/cloudflare-dns.json" rec_id payload
  curl -fsS --max-time 20 -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${CLOUDFLARE_API}/zones/${zone_id}/dns_records?type=A&name=${name}" > "$tmp" || return 1
  rec_id="$(python3 - "$tmp" <<'PYCF'
import json, sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
if not data.get('success'):
    raise SystemExit(2)
res=data.get('result') or []
print(res[0].get('id','') if res else '')
PYCF
)" || return 1
  payload="$(python3 - "$name" "$ip" <<'PYCF'
import json, sys
print(json.dumps({"type":"A","name":sys.argv[1],"content":sys.argv[2],"ttl":1,"proxied":True}))
PYCF
)"
  if [[ -n "$rec_id" ]]; then
    curl -fsS --max-time 20 -X PUT -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" --data "$payload" "${CLOUDFLARE_API}/zones/${zone_id}/dns_records/${rec_id}" > "$tmp" || return 1
  else
    curl -fsS --max-time 20 -X POST -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" --data "$payload" "${CLOUDFLARE_API}/zones/${zone_id}/dns_records" > "$tmp" || return 1
  fi
  python3 - "$tmp" <<'PYCF'
import json, sys
data=json.load(open(sys.argv[1], encoding='utf-8'))
if data.get('success'):
    print('ok')
else:
    print('; '.join(e.get('message','erro') for e in data.get('errors',[])))
    raise SystemExit(1)
PYCF
}


cloudflare_upsert_origin_rule() {
  local token="$1" zone_id="$2" host="$3" port="$4"
  local get_tmp="/tmp/cloudflare-origin-get.json" put_tmp="/tmp/cloudflare-origin-put.json" payload_tmp="/tmp/cloudflare-origin-payload.json"

  curl -sS --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "${CLOUDFLARE_API}/zones/${zone_id}/rulesets/phases/http_request_origin/entrypoint" > "$get_tmp" || true

  python3 - "$get_tmp" "$payload_tmp" "$host" "$port" <<'PYCFORIGIN'
import json, sys, pathlib
get_path, out_path, host, port_s = sys.argv[1:5]
port = int(port_s)
try:
    data = json.load(open(get_path, encoding='utf-8'))
except Exception:
    data = {}
result = data.get('result') if data.get('success') else None
if not isinstance(result, dict):
    result = {
        "name": "Gitea Origin Rules",
        "kind": "zone",
        "phase": "http_request_origin",
        "rules": []
    }
rules = result.get('rules') or []
expr = f'(http.host eq "{host}")'
marker = f'Gitea auto origin port {host}'
new_rules = []
for rule in rules:
    if rule.get('description') == marker or rule.get('expression') == expr:
        continue
    new_rules.append(rule)
new_rules.append({
    "description": marker,
    "expression": expr,
    "action": "route",
    "action_parameters": {
        "origin": {
            "port": port
        }
    },
    "enabled": True
})
# IMPORTANTE: no endpoint /rulesets/phases/http_request_origin/entrypoint
# a Cloudflare NAO aceita enviar campos como kind, name ou phase no PUT.
# Enviar kind causa: invalid JSON: unknown field "kind".
payload = {
    "description": "Origin Rules automaticas do Gitea",
    "rules": new_rules
}
pathlib.Path(out_path).write_text(json.dumps(payload, ensure_ascii=False), encoding='utf-8')
PYCFORIGIN

  curl -sS --max-time 25 -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data @"$payload_tmp" \
    "${CLOUDFLARE_API}/zones/${zone_id}/rulesets/phases/http_request_origin/entrypoint" > "$put_tmp" || return 1

  python3 - "$put_tmp" <<'PYCFORIGINOK'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    print('Resposta inválida da Cloudflare ao criar Origin Rule.')
    raise SystemExit(1)
if data.get('success'):
    print('ok')
    raise SystemExit(0)
errors = data.get('errors') or []
print('; '.join(str(e.get('message') or e.get('code') or 'erro') for e in errors) or 'falha ao criar Origin Rule')
raise SystemExit(1)
PYCFORIGINOK
}

cloudflare_find_zone_for_host() {
  local token="$1" host="$2" tmp="/tmp/cloudflare-zone-match.json"
  host="$(sanitize_domain_input "$host")"
  [[ -z "$host" || "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 1
  curl -fsS --max-time 20 -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "${CLOUDFLARE_API}/zones?per_page=100" > "$tmp" || return 1
  python3 - "$tmp" "$host" <<'PYCFZONE'
import json, sys
path, host = sys.argv[1:3]
data = json.load(open(path, encoding="utf-8"))
if not data.get("success"):
    raise SystemExit(1)
match = None
for z in data.get("result", []):
    name = z.get("name", "")
    if host == name or host.endswith("." + name):
        if match is None or len(name) > len(match[1]):
            match = (z.get("id", ""), name)
if not match:
    raise SystemExit(1)
print(match[0] + "|" + match[1])
PYCFZONE
}

cloudflare_sync_host_port() {
  local host="$1" port="$2" public_ip="$3" token zone_line zone_id
  host="$(sanitize_domain_input "$host")"
  [[ -z "$host" || "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  cloudflare_token_prompt || return 1
  token="${CF_AUTH_TOKEN:-}"
  [[ -z "$token" ]] && return 1
  zone_line="$(cloudflare_find_zone_for_host "$token" "$host" 2>/tmp/cloudflare-zone-match.err || true)"
  if [[ -z "$zone_line" ]]; then
    echo "Não encontrei esse domínio na conta Cloudflare: ${host}"
    return 1
  fi
  zone_id="${zone_line%%|*}"
  progress_line 35 "Atualizando DNS Cloudflare..."
  if ! cloudflare_upsert_a_record "$token" "$zone_id" "$host" "$public_ip" >/tmp/cloudflare-sync-dns.log 2>&1; then
    progress_fail 35 "Atualizando DNS Cloudflare..."
    echo; cat /tmp/cloudflare-sync-dns.log 2>/dev/null || true
    return 1
  fi
  progress_line 55 "Atualizando Origin Rule..."
  if ! cloudflare_upsert_origin_rule "$token" "$zone_id" "$host" "$port" >/tmp/cloudflare-sync-origin.log 2>&1; then
    progress_fail 55 "Atualizando Origin Rule..."
    echo; cat /tmp/cloudflare-sync-origin.log 2>/dev/null || true
    echo "Verifique se o token tem permissão: Zone Read + DNS Edit + Origin Rules Edit."
    return 1
  fi
  progress_line 70 "Liberando firewall local..."
  open_firewall_port "$port"
  return 0
}

show_install_panel() {
  local title="$1" external="$2" port="$3" ip="$4" app="$5" admin="$6"
  local width top mid bot
  width="$(menu_width)"
  top="╔$(hline $((width-2)))╗"
  mid="╠$(hline $((width-2)))╣"
  bot="╚$(hline $((width-2)))╝"
  safe_clear
  echo "  $top"
  echo "  $(center_line "$title" "$width")"
  echo "  $mid"
  echo "  $(plain_line " Site externo : ${external}" "$width")"
  echo "  $(plain_line " Porta interna: ${port}" "$width")"
  echo "  $(plain_line " IP público   : ${ip}" "$width")"
  echo "  $(plain_line " Nome do site : ${app}" "$width")"
  echo "  $(plain_line " Admin        : ${admin}" "$width")"
  echo "  $mid"
  echo "  $(center_line "Iniciando instalação automática" "$width")"
  echo "  $bot"
  echo
}


open_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then ufw allow "${port}/tcp" >/dev/null 2>&1 || true; fi
}

cloudflare_prepare_install() {
  local token sub port public_ip fqdn root_url
  safe_clear
  echo "CLOUDFLARE TOKEN + DNS + ORIGIN RULE + GITEA"
  echo
  cloudflare_token_prompt || { echo "Token inválido."; pause; return 1; }
  token="${CF_AUTH_TOKEN:-}"
  [[ -z "$token" ]] && { echo "Token inválido."; pause; return 1; }
  cloudflare_pick_zone "$token" || { pause; return 1; }
  echo
  read -r -p "Subdomínio (ex: git) ou @ para raiz: " sub || true
  sub="${sub:-git}"
  if [[ "$sub" == "@" ]]; then fqdn="${CF_ZONE_NAME}"; else sub="$(sanitize_domain_input "$sub")"; fqdn="${sub}.${CF_ZONE_NAME}"; fi
  read -r -p "Porta interna do Gitea [2096]: " port || true
  port="${port:-2096}"
  [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )) && { echo "Porta inválida."; pause; return 1; }
  public_ip="$(get_public_ip)"; [[ -z "$public_ip" ]] && public_ip="$(get_primary_ip)"
  [[ -z "$public_ip" ]] && { echo "Não foi possível detectar o IP público da VPS."; pause; return 1; }
  safe_clear
  progress_line 20 "Criando DNS Cloudflare..."
  if ! cloudflare_upsert_a_record "$token" "$CF_ZONE_ID" "$fqdn" "$public_ip" >/tmp/cloudflare-dns-result.log 2>&1; then
    progress_fail 20 "Criando DNS Cloudflare..."; echo; cat /tmp/cloudflare-dns-result.log 2>/dev/null || true; pause; return 1
  fi
  progress_line 35 "Criando Origin Rule..."
  if ! cloudflare_upsert_origin_rule "$token" "$CF_ZONE_ID" "$fqdn" "$port" >/tmp/cloudflare-origin-result.log 2>&1; then
    progress_fail 35 "Criando Origin Rule..."
    echo
    cat /tmp/cloudflare-origin-result.log 2>/dev/null || true
    echo
    echo "Verifique se o token tem permissão: Zone Read + DNS Edit + Rulesets Edit/Origin Rules."
    pause
    return 1
  fi
  progress_line 45 "Liberando firewall local..."
  open_firewall_port "$port"
  root_url="https://${fqdn}/"
  AUTO_GITEA_PORT="$port"
  AUTO_GITEA_BASE_URL="$root_url"
  AUTO_GITEA_PUBLIC_IP="$public_ip"
  AUTO_GITEA_FQDN="$fqdn"
  AUTO_GITEA_CLOUDFLARE="1"
  printf "\n"
  install_gitea
}

install_gitea() {
  local port public_ip base_url version arch url
  local app_name admin_user admin_email admin_password root_url local_root_url

  if [[ -n "${AUTO_GITEA_PORT:-}" && -n "${AUTO_GITEA_BASE_URL:-}" ]]; then
    port="${AUTO_GITEA_PORT}"
    base_url="${AUTO_GITEA_BASE_URL}"
    public_ip="${AUTO_GITEA_PUBLIC_IP:-$(get_public_ip)}"
    [[ -z "${public_ip}" ]] && public_ip="$(get_primary_ip)"
    echo "Instalação via Cloudflare detectada."
    echo "Domínio externo: ${base_url}"
    echo "Porta interna: ${port}"
    echo "IP público no DOMAIN: ${public_ip}"
    echo
  else
    read -r -p "Porta [2096]: " port || true
    port="${port:-2096}"
    [[ ! "${port}" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )) && { echo "Porta inválida."; pause; return; }
    public_ip="$(get_public_ip)"
    [[ -z "${public_ip}" ]] && public_ip="$(get_primary_ip)"
    [[ -z "${public_ip}" ]] && { echo "Não foi possível detectar o IP do servidor."; pause; return; }
    read -r -p "URL base do Gitea: " base_url || true
    [[ -z "${base_url}" ]] && { echo "URL base inválida."; pause; return; }
  fi

  root_url="$(normalize_base_url "${base_url}" "${port}")"
  local_root_url="$(build_local_root_url "${public_ip}" "${port}")"

  read -r -p "Nome do site [Gitea]: " app_name || true
  app_name="${app_name:-Gitea}"
  read -r -p "Usuário admin: " admin_user || true
  read -r -p "Email admin: " admin_email || true
  read -r -p "Senha admin: " admin_password || true
  echo

  [[ -z "${admin_user}" || -z "${admin_email}" || -z "${admin_password}" ]] && {
    echo "Usuário, email ou senha do admin inválidos."
    pause
    return
  }

  version="$(get_latest_gitea_version)"
  arch="$(detect_arch)" || { pause; return; }
  url="https://dl.gitea.com/gitea/${version}/gitea-${version}-linux-${arch}"

  if [[ -n "${AUTO_GITEA_CLOUDFLARE:-}" ]]; then
    show_install_panel "INSTALAÇÃO CLOUDFLARE + GITEA" "${root_url}" "${port}" "${public_ip}" "${app_name}" "${admin_user}"
  else
    show_install_panel "INSTALAÇÃO MANUAL DO GITEA" "${root_url}" "${port}" "${public_ip}" "${app_name}" "${admin_user}"
  fi
  progress_line 5 "Preparando instalação..."
  ensure_packages || { pause; return; }
  progress_line 20 "Criando usuário..."
  ensure_git_user || { progress_fail 20 "Criando usuário..."; pause; return; }
  progress_line 30 "Criando diretórios..."
  ensure_dirs || { progress_fail 30 "Criando diretórios..."; pause; return; }
  run_step 38 "Configurando swap 2GB..." ensure_swap_2g_optimized || { pause; return; }
  run_step 48 "Baixando Gitea ${version}..." wget -O "${GITEA_BIN}" "${url}" || { pause; return; }
  run_step 55 "Ajustando permissões..." chmod 755 "${GITEA_BIN}" || { pause; return; }
  ensure_gitea_executable >/dev/null 2>&1 || { progress_fail 55 "Ajustando permissões..."; pause; return; }
  progress_line 64 "Gerando configuração..."
  write_config "${port}" "${public_ip}" "${base_url}" "${app_name}" >/dev/null 2>&1 || { progress_fail 64 "Gerando configuração..."; pause; return; }
  fix_gitea_permissions >/dev/null 2>&1 || true
  ensure_gitea_executable >/dev/null 2>&1 || { progress_fail 78 "Permissão do binário Gitea"; pause; return; }
  progress_line 78 "Inicializando banco..."
  if ! run_gitea_cli migrate --config "${GITEA_CONF_FILE}" >/tmp/gitea-migrate.log 2>&1; then
    fix_gitea_permissions >/dev/null 2>&1 || true
    if ! run_gitea_cli migrate --config "${GITEA_CONF_FILE}" >/tmp/gitea-migrate.log 2>&1; then
      progress_fail 78 "Inicializando banco..."
      echo
      echo "Erro real salvo em: /tmp/gitea-migrate.log"
      tail -n 8 /tmp/gitea-migrate.log 2>/dev/null || true
      pause
      return
    fi
  fi
  progress_line 86 "Criando admin inicial..."
  if ! run_gitea_cli admin user create     --username "${admin_user}"     --password "${admin_password}"     --email "${admin_email}"     --admin     --must-change-password=false     --config "${GITEA_CONF_FILE}" >/tmp/gitea-admin-create.log 2>&1; then
    if grep -qi "already exists\|user already" /tmp/gitea-admin-create.log 2>/dev/null; then
      run_gitea_cli admin user change-password --username "${admin_user}" --password "${admin_password}" --config "${GITEA_CONF_FILE}" >/dev/null 2>&1 || true
    else
      progress_fail 86 "Criando admin inicial..."
      echo
      echo "Erro real salvo em: /tmp/gitea-admin-create.log"
      tail -n 8 /tmp/gitea-admin-create.log 2>/dev/null || true
      pause
      return
    fi
  fi
  progress_line 92 "Aplicando padrão..."
  apply_gitea_defaults >/dev/null 2>&1 || { progress_fail 92 "Aplicando padrão..."; pause; return; }
  progress_line 96 "Criando serviço..."
  write_service >/dev/null 2>&1 || { progress_fail 96 "Criando serviço..."; pause; return; }
  run_step 98 "Recarregando systemd..." systemctl daemon-reload || { pause; return; }
  run_step 100 "Ativando Gitea..." systemctl enable --now gitea || { pause; return; }

  echo
  echo "Site interno: ${local_root_url}"
  echo "Site externo: ${root_url}"
  echo "Porta: ${port}"
  echo "Nome do site: ${app_name}"
echo "Usuário: ${admin_user}"
  echo "Senha: ${admin_password}"
  echo "Swap: 2GB otimizado"
  progress_ok "Instalação concluída."
  pause
}
remove_gitea() {
  local confirm

  read -r -p "Tem certeza que deseja remover o Gitea? [s/N]: " confirm || true
  [[ ! "${confirm}" =~ ^[sS]$ ]] && { echo "Cancelado."; pause; return; }

  safe_clear
  progress_line 30 "Parando serviço..."
  systemctl stop gitea >/dev/null 2>&1 || true
  systemctl disable gitea >/dev/null 2>&1 || true

  progress_line 70 "Removendo arquivos..."
  rm -f "${SERVICE_FILE}" "${GITEA_BIN}"
  rm -rf "${GITEA_WORK_DIR}"

  progress_line 90 "Recarregando systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true

  progress_ok "Gitea removido."
  pause
}

restart_gitea() {
  safe_clear
  run_step 100 "Reiniciando Gitea..." systemctl restart gitea || { pause; return; }
  progress_ok "Gitea reiniciado."
  pause
}

change_port() {
  local p public_ip host new_root new_local

  [[ -f "${GITEA_CONF_FILE}" ]] || { echo "Configuração não encontrada."; pause; return; }

  read -r -p "Nova porta: " p || true
  [[ ! "${p}" =~ ^[0-9]{1,5}$ ]] || (( p < 1 || p > 65535 )) && { echo "Porta inválida."; pause; return; }

  public_ip="$(get_public_ip)"
  [[ -z "$public_ip" ]] && public_ip="$(get_primary_ip)"
  host="$(sanitize_domain_input "$(get_current_root_url)")"
  [[ -z "$host" ]] && host="$public_ip"

  if is_ipv4_addr "$host"; then
    new_root="http://${host}:${p}/"
  else
    new_root="https://${host}/"
  fi
  new_local="http://${public_ip}:${p}/"

  safe_clear
  if ! is_ipv4_addr "$host"; then
    echo "Sincronizando Cloudflare para: ${host}"
    echo
    if ! cloudflare_sync_host_port "$host" "$p" "$public_ip"; then
      echo
      echo "A porta NÃO foi alterada para evitar quebrar o acesso."
      pause
      return
    fi
  fi

  progress_line 80 "Alterando app.ini..."
  set_ini_value server DOMAIN "${public_ip}"
  set_ini_value server HTTP_ADDR "0.0.0.0"
  set_ini_value server HTTP_PORT "${p}"
  set_ini_value server ROOT_URL "${new_root}"
  set_ini_value server LOCAL_ROOT_URL "${new_local}"
  run_step 100 "Reiniciando serviço..." systemctl restart gitea || { pause; return; }
  progress_ok "Porta alterada e Cloudflare sincronizado."
  pause
}

change_domain() {
  local base_url p public_ip host new_root new_local

  [[ -f "${GITEA_CONF_FILE}" ]] || { echo "Configuração não encontrada."; pause; return; }

  read -r -p "Novo domínio/URL base do Gitea: " base_url || true
  [[ -z "${base_url}" ]] && { echo "URL base inválida."; pause; return; }

  p="$(get_current_port)"
  [[ -z "$p" ]] && p="2096"
  public_ip="$(get_public_ip)"
  [[ -z "$public_ip" ]] && public_ip="$(get_primary_ip)"
  host="$(sanitize_domain_input "$base_url")"
  [[ -z "$host" ]] && { echo "Domínio inválido."; pause; return; }

  if is_ipv4_addr "$host"; then
    new_root="http://${host}:${p}/"
  else
    new_root="https://${host}/"
  fi
  new_local="http://${public_ip}:${p}/"

  safe_clear
  if ! is_ipv4_addr "$host"; then
    echo "Sincronizando Cloudflare para: ${host}"
    echo
    if ! cloudflare_sync_host_port "$host" "$p" "$public_ip"; then
      echo
      echo "O domínio NÃO foi alterado para evitar quebrar o acesso."
      pause
      return
    fi
  fi

  progress_line 80 "Alterando app.ini..."
  set_ini_value server DOMAIN "${public_ip}"
  set_ini_value server HTTP_ADDR "0.0.0.0"
  set_ini_value server HTTP_PORT "${p}"
  set_ini_value server ROOT_URL "${new_root}"
  set_ini_value server LOCAL_ROOT_URL "${new_local}"
  run_step 100 "Reiniciando serviço..." systemctl restart gitea || { pause; return; }
  progress_ok "Domínio alterado e Cloudflare sincronizado."
  pause
}

export_backup() {
  safe_clear
  progress_line 40 "Gerando backup..."
  export_backup_no_pause || { progress_fail 40 "Gerando backup..."; pause; return; }
  progress_ok "Backup exportado."
  pause
}

export_backup_and_send() {
  safe_clear
  progress_line 20 "Gerando backup local..."
  export_backup_no_pause || { progress_fail 20 "Gerando backup local..."; pause; return; }

  progress_line 60 "Gerando backup slim pro Telegram..."
  export_telegram_backup_no_pause || { progress_fail 60 "Gerando backup slim pro Telegram..."; pause; return; }

  if telegram_ready; then
    progress_line 100 "Enviando para Telegram..."
    if send_backup_to_telegram; then
      progress_ok "Backup enviado."
    else
      progress_fail 100 "Enviando para Telegram..."
      echo
      echo "Confira o tamanho com:"
      echo "ls -lh ${TELEGRAM_BACKUP_ZIP}"
    fi
  else
    progress_ok "Backup local gerado."
  fi

  pause
}

import_backup() {
  local db_path="${GITEA_WORK_DIR}/data/gitea.db"
  local extracted="${BACKUP_TMP}/imported"
  local confirm restored_bin=0

  [[ ! -f "${BACKUP_ZIP}" ]] && { echo "Arquivo não encontrado: ${BACKUP_ZIP}"; pause; return; }

  read -r -p "Importar backup de ${BACKUP_ZIP}? Isso sobrescreve dados atuais. [s/N]: " confirm || true
  [[ ! "${confirm}" =~ ^[sS]$ ]] && { echo "Cancelado."; pause; return; }

  safe_clear
  progress_line 8 "Preparando importação..."
  ensure_packages || { pause; return; }
  ensure_git_user || { progress_fail 8 "Preparando importação..."; pause; return; }
  ensure_dirs || { progress_fail 8 "Preparando importação..."; pause; return; }

  mkdir -p "${BACKUP_TMP}"
  rm -rf "${extracted}"
  mkdir -p "${extracted}"

  run_step 20 "Extraindo backup..." unzip -oq "${BACKUP_ZIP}" -d "${extracted}" || { pause; return; }

  progress_line 30 "Parando Gitea..."
  systemctl stop gitea >/dev/null 2>&1 || true
  systemctl disable gitea >/dev/null 2>&1 || true

  mkdir -p "${GITEA_WORK_DIR}/custom/conf" "${GITEA_WORK_DIR}/data" "${GITEA_WORK_DIR}/log"

  progress_line 45 "Restaurando banco e config..."
  [[ -f "${extracted}/data/gitea.db" ]] && cp -f "${extracted}/data/gitea.db" "${db_path}"
  [[ -f "${extracted}/conf/app.ini" ]] && cp -f "${extracted}/conf/app.ini" "${GITEA_CONF_FILE}"

  progress_line 58 "Restaurando repositórios..."
  if [[ -d "${extracted}/repos/gitea-repositories" ]]; then
    rm -rf "${GITEA_WORK_DIR}/data/gitea-repositories"
    cp -a "${extracted}/repos/gitea-repositories" "${GITEA_WORK_DIR}/data/"
  elif [[ -d "${extracted}/repos" ]]; then
    rm -rf "${GITEA_WORK_DIR}/data/gitea-repositories"
    cp -a "${extracted}/repos" "${GITEA_WORK_DIR}/data/gitea-repositories"
  fi

  if [[ -d "${extracted}/log" ]]; then
    rm -rf "${GITEA_WORK_DIR}/log"
    mkdir -p "${GITEA_WORK_DIR}/log"
    cp -a "${extracted}/log/." "${GITEA_WORK_DIR}/log/" 2>/dev/null || true
  fi

  progress_line 68 "Restaurando binário e serviço..."
  if [[ -f "${extracted}/bin/gitea" ]]; then
    cp -f "${extracted}/bin/gitea" "${GITEA_BIN}"
    chmod +x "${GITEA_BIN}"
    restored_bin=1
  fi

  if [[ -f "${extracted}/systemd/gitea.service" ]]; then
    cp -f "${extracted}/systemd/gitea.service" "${SERVICE_FILE}"
  fi

  if [[ ! -x "${GITEA_BIN}" ]]; then
    if [[ "${restored_bin}" -eq 0 ]]; then
      progress_fail 68 "Restaurando binário e serviço..."
      echo
      echo "O backup não contém o binário do Gitea e nenhum binário atual foi encontrado."
      echo "Instale o Gitea primeiro ou use um backup completo gerado por esta versão do script."
      rm -rf "${extracted}"
      pause
      return
    fi
  fi

  if [[ ! -f "${SERVICE_FILE}" ]]; then
    write_service
  fi

  if [[ -f "${GITEA_CONF_FILE}" ]]; then
    current_domain="$(get_current_domain)"
    current_port="$(get_current_port)"
    current_protocol="$(awk -F= '
      /^\[server\]/ { in_server=1; next }
      /^\[/ { in_server=0 }
      in_server && $1 ~ /PROTOCOL/ {
        sub(/^[ 	]+/, "", $2)
        sub(/[ 	]+$/, "", $2)
        print $2
        exit
      }
    ' "${GITEA_CONF_FILE}")"
    current_protocol="${current_protocol:-http}"
    current_domain="$(sanitize_domain_input "${current_domain}")"
    [[ -z "${current_domain}" ]] && current_domain="$(get_primary_ip)"
    current_root="$(build_root_url "${current_domain}" "${current_port:-3000}" "${current_protocol}")"
    if grep -q '^ROOT_URL = ' "${GITEA_CONF_FILE}"; then
      sed -i "s|^ROOT_URL = .*|ROOT_URL = ${current_root}|" "${GITEA_CONF_FILE}"
    else
      echo "ROOT_URL = ${current_root}" >> "${GITEA_CONF_FILE}"
    fi
  fi

  chown -R "${GITEA_USER}:${GITEA_USER}" "${GITEA_WORK_DIR}"
  chmod -R 750 "${GITEA_WORK_DIR}"

  progress_line 78 "Reaplicando padrão..."
  apply_gitea_defaults >/dev/null 2>&1 || { progress_fail 78 "Reaplicando padrão..."; rm -rf "${extracted}"; pause; return; }

  run_step 82 "Recarregando systemd..." systemctl daemon-reload || { rm -rf "${extracted}"; pause; return; }
  run_step 90 "Ativando serviço..." systemctl enable gitea || { rm -rf "${extracted}"; pause; return; }
  run_step 100 "Iniciando Gitea..." systemctl restart gitea || {
    echo
    systemctl status gitea --no-pager -l 2>/dev/null | tail -n 20 || true
    rm -rf "${extracted}"
    pause
    return
  }

  rm -rf "${extracted}"
  progress_ok "Importação concluída."
  pause
}

update_gitea() {
  local current_version new_version arch url
  local db_path backup_db backup_bin ts tmp_bin backup_conf latest_version
  local update_info update_status

  is_installed || { echo "Gitea não instalado."; pause; return; }

  update_info="$(get_update_info)"
  update_status="${update_info%%|*}"
  latest_version="$(printf '%s' "$update_info" | awk -F'|' '{print $2}')"
  current_version="$(get_current_gitea_version)"

  if [[ "${update_status}" != "update" ]]; then
    echo "Já está na última versão."
    pause
    return
  fi

  new_version="${latest_version}"
  arch="$(detect_arch)" || { pause; return; }
  url="https://dl.gitea.com/gitea/${new_version}/gitea-${new_version}-linux-${arch}"
  db_path="${GITEA_WORK_DIR}/data/gitea.db"
  ts="$(date +%Y%m%d-%H%M%S)"
  tmp_bin="/tmp/gitea-${new_version}"
  backup_bin="${BACKUP_DIR}/gitea-bin-${current_version}-${ts}"
  backup_conf="${BACKUP_DIR}/app-${ts}.ini"

  mkdir -p "${BACKUP_DIR}"

  safe_clear
  run_step 12 "Baixando ${new_version}..." wget -O "${tmp_bin}" "${url}" || { pause; return; }
  run_step 20 "Ajustando binário..." chmod +x "${tmp_bin}" || { rm -f "${tmp_bin}"; pause; return; }

  progress_line 30 "Criando backup do banco..."
  backup_db=""
  if [[ -f "${db_path}" ]]; then
    backup_db="${BACKUP_DIR}/gitea-db-${ts}.sqlite3"
    sqlite3 "${db_path}" ".backup '${backup_db}'" >/dev/null 2>&1 || {
      progress_fail 30 "Criando backup do banco..."
      rm -f "${tmp_bin}"
      pause
      return
    }
  fi

  progress_line 40 "Salvando configuração..."
  [[ -f "${GITEA_CONF_FILE}" ]] && cp -f "${GITEA_CONF_FILE}" "${backup_conf}"

  run_step 50 "Parando Gitea..." systemctl stop gitea || { rm -f "${tmp_bin}"; pause; return; }

  progress_line 60 "Salvando binário atual..."
  [[ -x "${GITEA_BIN}" ]] && cp -f "${GITEA_BIN}" "${backup_bin}"

  run_step 70 "Instalando nova versão..." mv -f "${tmp_bin}" "${GITEA_BIN}" || { pause; return; }
  run_step 75 "Aplicando permissões..." chmod 755 "${GITEA_BIN}" || { pause; return; }
  ensure_gitea_executable >/dev/null 2>&1 || { progress_fail 75 "Aplicando permissões..."; pause; return; }

  run_step 82 "Migrando banco..." run_gitea_cli migrate --config "${GITEA_CONF_FILE}" || {
    progress_fail 82 "Migrando banco..."
    systemctl stop gitea >/dev/null 2>&1 || true
    [[ -f "${backup_bin}" ]] && cp -f "${backup_bin}" "${GITEA_BIN}"
    [[ -n "${backup_db}" && -f "${backup_db}" ]] && cp -f "${backup_db}" "${db_path}"
    [[ -f "${backup_conf}" ]] && cp -f "${backup_conf}" "${GITEA_CONF_FILE}"
    chmod +x "${GITEA_BIN}" >/dev/null 2>&1 || true
    systemctl start gitea >/dev/null 2>&1 || true
    pause
    return
  }

  progress_line 90 "Reaplicando padrão..."
  apply_gitea_defaults >/dev/null 2>&1 || {
    progress_fail 90 "Reaplicando padrão..."
    systemctl stop gitea >/dev/null 2>&1 || true
    [[ -f "${backup_bin}" ]] && cp -f "${backup_bin}" "${GITEA_BIN}"
    [[ -n "${backup_db}" && -f "${backup_db}" ]] && cp -f "${backup_db}" "${db_path}"
    [[ -f "${backup_conf}" ]] && cp -f "${backup_conf}" "${GITEA_CONF_FILE}"
    chmod +x "${GITEA_BIN}" >/dev/null 2>&1 || true
    systemctl start gitea >/dev/null 2>&1 || true
    pause
    return
  }

  run_step 95 "Recarregando systemd..." systemctl daemon-reload || { pause; return; }
  run_step 100 "Iniciando Gitea..." systemctl start gitea || true

  sleep 2
  if systemctl is-active --quiet gitea; then
    progress_ok "Atualização concluída."
    pause
    return
  fi

  progress_line 100 "Restaurando versão anterior..."
  systemctl stop gitea >/dev/null 2>&1 || true
  [[ -f "${backup_bin}" ]] && cp -f "${backup_bin}" "${GITEA_BIN}"
  [[ -n "${backup_db}" && -f "${backup_db}" ]] && cp -f "${backup_db}" "${db_path}"
  [[ -f "${backup_conf}" ]] && cp -f "${backup_conf}" "${GITEA_CONF_FILE}"
  chmod +x "${GITEA_BIN}" >/dev/null 2>&1 || true
  systemctl start gitea >/dev/null 2>&1 || true

  progress_fail 100 "Rollback concluído"
  pause
}

write_backup_script() {
  cat > /usr/local/bin/gitea-backup.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BACKUP_ZIP="/root/backupgit.zip"
TELEGRAM_BACKUP_ZIP="/tmp/backupgit.zip"
GITEA_WORK_DIR="/var/lib/gitea"
GITEA_CONF_FILE="/var/lib/gitea/custom/conf/app.ini"
GITEA_BIN="/usr/local/bin/gitea"
SERVICE_FILE="/etc/systemd/system/gitea.service"
TMP_DIR="/tmp/gitea-backup-auto"
TMP_TG_DIR="/tmp/gitea-backup-telegram-auto"
BOT_ENABLED_FILE="/etc/gitea-bot-enabled"

if [[ -f /etc/gitea-telegram.conf ]]; then
  source /etc/gitea-telegram.conf
fi

mkdir -p "$TMP_DIR"
rm -rf "${TMP_DIR:?}"/*
mkdir -p "$TMP_DIR/data" "$TMP_DIR/repos" "$TMP_DIR/conf" "$TMP_DIR/log" "$TMP_DIR/bin" "$TMP_DIR/systemd"

[[ -f "${GITEA_WORK_DIR}/data/gitea.db" ]] && sqlite3 "${GITEA_WORK_DIR}/data/gitea.db" ".backup '${TMP_DIR}/data/gitea.db'" >/dev/null 2>&1
[[ -f "$GITEA_CONF_FILE" ]] && cp -f "$GITEA_CONF_FILE" "${TMP_DIR}/conf/app.ini"
[[ -d "${GITEA_WORK_DIR}/data/gitea-repositories" ]] && cp -a "${GITEA_WORK_DIR}/data/gitea-repositories" "${TMP_DIR}/repos/"
[[ -d "${GITEA_WORK_DIR}/log" ]] && cp -a "${GITEA_WORK_DIR}/log/." "${TMP_DIR}/log/" 2>/dev/null || true
[[ -x "$GITEA_BIN" ]] && cp -f "$GITEA_BIN" "${TMP_DIR}/bin/gitea"
[[ -f "$SERVICE_FILE" ]] && cp -f "$SERVICE_FILE" "${TMP_DIR}/systemd/gitea.service"
[[ -x /usr/local/bin/gitea-preflight.sh ]] && cp -f /usr/local/bin/gitea-preflight.sh "${TMP_DIR}/bin/gitea-preflight.sh"

cat > "${TMP_DIR}/metadata.txt" <<META
backup_date=$(date '+%Y-%m-%d %H:%M:%S')
gitea_version=$("$GITEA_BIN" --version 2>/dev/null | awk '{print $3; exit}')
type=full-local-backup
META

rm -f "$BACKUP_ZIP"
(
  cd "$TMP_DIR"
  zip -rq "$BACKUP_ZIP" .
) >/dev/null 2>&1

if [[ -f "$BOT_ENABLED_FILE" ]] && grep -q '^on$' "$BOT_ENABLED_FILE"; then
  mkdir -p "$TMP_TG_DIR"
  rm -rf "${TMP_TG_DIR:?}"/*
  mkdir -p "$TMP_TG_DIR/data" "$TMP_TG_DIR/conf" "$TMP_TG_DIR/bin"

  [[ -f "${GITEA_WORK_DIR}/data/gitea.db" ]] && sqlite3 "${GITEA_WORK_DIR}/data/gitea.db" ".backup '${TMP_TG_DIR}/data/gitea.db'" >/dev/null 2>&1
  [[ -f "$GITEA_CONF_FILE" ]] && cp -f "$GITEA_CONF_FILE" "${TMP_TG_DIR}/conf/app.ini"
  [[ -x /usr/local/bin/gitea-preflight.sh ]] && cp -f /usr/local/bin/gitea-preflight.sh "${TMP_TG_DIR}/bin/gitea-preflight.sh"

  cat > "${TMP_TG_DIR}/metadata.txt" <<META
backup_date=$(date '+%Y-%m-%d %H:%M:%S')
gitea_version=$("$GITEA_BIN" --version 2>/dev/null | awk '{print $3; exit}')
type=telegram-slim-backup
META

  rm -f "$TELEGRAM_BACKUP_ZIP"
  (
    cd "$TMP_TG_DIR"
    zip -rq "$TELEGRAM_BACKUP_ZIP" .
  ) >/dev/null 2>&1

  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" && -f "$TELEGRAM_BACKUP_ZIP" ]]; then
    if [[ -x "$GITEA_BIN" ]]; then
      current_ver="$("$GITEA_BIN" --version 2>/dev/null | awk '{print $3; exit}')"
    else
      current_ver="N/A"
    fi
    caption="Versão: ${current_ver}"
    curl -fsS \
      -F "chat_id=${TELEGRAM_CHAT_ID}" \
      -F "caption=${caption}" \
      -F "document=@${TELEGRAM_BACKUP_ZIP}" \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" >/dev/null 2>&1 || true
  fi

  rm -rf "$TMP_TG_DIR"
fi

rm -rf "$TMP_DIR"
EOF

  chmod +x /usr/local/bin/gitea-backup.sh
}

enable_auto_backup() {
  local interval
  interval="$(get_backup_interval)"

  safe_clear
  progress_line 5 "Preparando backup automático..."
  ensure_packages || { pause; return; }

  progress_line 30 "Gerando script de backup..."
  write_backup_script >/dev/null 2>&1 || { progress_fail 30 "Gerando script de backup..."; pause; return; }

  progress_line 55 "Criando serviço..."
  cat > /etc/systemd/system/gitea-backup.service <<EOF
[Unit]
Description=Backup automático do Gitea
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gitea-backup.sh
StandardOutput=append:/var/log/gitea-backup.log
StandardError=append:/var/log/gitea-backup.log
EOF

  progress_line 75 "Criando timer..."
  cat > /etc/systemd/system/gitea-backup.timer <<EOF
[Unit]
Description=Backup automático Gitea

[Timer]
OnBootSec=5min
OnUnitActiveSec=${interval}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  run_step 90 "Recarregando systemd..." systemctl daemon-reload || { pause; return; }
  systemctl stop gitea-backup.timer >/dev/null 2>&1 || true
  run_step 100 "Ativando timer..." systemctl enable --now gitea-backup.timer || { pause; return; }
  systemctl restart gitea-backup.timer >/dev/null 2>&1 || true

  printf "\n"
  pause
}

disable_auto_backup() {
  safe_clear
  progress_line 30 "Parando timer..."
  systemctl stop gitea-backup.timer >/dev/null 2>&1 || true
  systemctl disable gitea-backup.timer >/dev/null 2>&1 || true

  progress_line 70 "Removendo arquivos..."
  rm -f /etc/systemd/system/gitea-backup.timer /etc/systemd/system/gitea-backup.service /usr/local/bin/gitea-backup.sh

  run_step 100 "Recarregando systemd..." systemctl daemon-reload || { pause; return; }
  progress_ok "Backup automático desativado."
  pause
}

fix_boot_services() {
  safe_clear
  progress_line 30 "Recarregando systemd..."
  systemctl daemon-reload >/dev/null 2>&1 || true

  progress_line 60 "Ajustando serviços..."
  [[ -f "${SERVICE_FILE}" ]] && { systemctl enable gitea >/dev/null 2>&1 || true; systemctl restart gitea >/dev/null 2>&1 || true; }
  [[ -f /etc/systemd/system/gitea-backup.timer ]] && { systemctl enable gitea-backup.timer >/dev/null 2>&1 || true; systemctl restart gitea-backup.timer >/dev/null 2>&1 || true; }

  progress_ok "Serviços reparados."
  pause
}

configure_bot() {
  local token chat_id

  read -r -p "TELEGRAM_BOT_TOKEN: " token || true
  read -r -p "TELEGRAM_CHAT_ID: " chat_id || true

  [[ -z "${token:-}" || -z "${chat_id:-}" ]] && {
    echo "Token ou chat ID inválido."
    pause
    return
  }

  cat > "${BOT_CONFIG_FILE}" <<EOF
TELEGRAM_BOT_TOKEN="${token}"
TELEGRAM_CHAT_ID="${chat_id}"
EOF

  chmod 600 "${BOT_CONFIG_FILE}"

  TELEGRAM_BOT_TOKEN="${token}"
  TELEGRAM_CHAT_ID="${chat_id}"

  echo "Bot configurado com sucesso."
  pause
}

set_backup_time_menu() {
  local interval

  echo
  echo "Tempos sugeridos: 1h, 3h, 6h, 12h, 24h"
  read -r -p "Novo intervalo de backup: " interval || true

  [[ -z "${interval:-}" ]] && {
    echo "Intervalo inválido."
    pause
    return
  }

  set_backup_interval "${interval}"

  if is_auto_backup_enabled; then
    enable_auto_backup >/dev/null 2>&1 || true
  fi

  echo "Tempo de backup atualizado para: ${interval}"
  pause
}


create_gitea_user() {
  local username password email admin_opt admin_flag create_token scopes token_name output token_value

  safe_clear
  echo "CRIAR CONTA"
  echo

  read -r -p "Nome de usuário: " username || true
  read -r -p "Email: " email || true
  read -s -r -p "Senha: " password || true
  echo
  read -r -p "Conta admin? [s/N]: " admin_opt || true
  read -r -p "Gerar token inicial? [s/N]: " create_token || true

  if [[ -z "$username" || -z "$email" || -z "$password" ]]; then
    echo "Usuário, email ou senha inválidos."
    pause
    return
  fi

  admin_flag=""
  [[ "$admin_opt" =~ ^[sS]$ ]] && admin_flag="--admin"

  safe_clear
  progress_line 25 "Criando conta..."

  if ! sudo -u git /usr/local/bin/gitea admin user create     --username "$username"     --password "$password"     --email "$email"     $admin_flag     --config /var/lib/gitea/custom/conf/app.ini >/dev/null 2>&1; then
    progress_fail 25 "Criando conta..."
    pause
    return
  fi

  token_value=""
  if [[ "$create_token" =~ ^[sS]$ ]]; then
    read -r -p "Nome do token: " token_name || true
    read -r -p "Scopes (ex: all ou write:repository,read:user) [all]: " scopes || true
    token_name="${token_name:-token-inicial}"
    scopes="${scopes:-all}"

    progress_line 75 "Gerando token inicial..."
    output="$(sudo -u git /usr/local/bin/gitea admin user generate-access-token       --username "$username"       --token-name "$token_name"       --scopes "$scopes"       --config /var/lib/gitea/custom/conf/app.ini 2>/dev/null || true)"
    token_value="$(printf '%s
' "$output" | awk -F': ' '/^Token:/ {print $2; exit}')"
    if [[ -z "$token_value" ]]; then
      progress_fail 75 "Gerando token inicial..."
    fi
  fi

  progress_ok "Conta criada com sucesso."
  echo
  echo "✔ Dados utilizados:"
  echo "Usuário: $username"
  echo "Email: $email"
  echo "Senha: $password"
  if [[ -n "$admin_flag" ]]; then
    echo "Tipo: Admin"
  else
    echo "Tipo: Normal"
  fi
  if [[ -n "$token_value" ]]; then
    echo "Token inicial ($token_name): $token_value"
  fi

  pause
}

change_user_password() {
  local username password

  safe_clear
  echo "RESETAR SENHA DA CONTA"
  echo

  read -r -p "Nome de usuário: " username || true

  if [[ -z "$username" ]]; then
    echo "Usuário inválido."
    pause
    return
  fi

  password="$(generate_numeric_password)"

  safe_clear
  progress_line 40 "Resetando senha..."

  if sudo -u git /usr/local/bin/gitea admin user change-password     --username "$username"     --password "$password"     --config /var/lib/gitea/custom/conf/app.ini >/dev/null 2>&1; then

    progress_ok "Senha resetada com sucesso."
    echo
    echo "✔ Dados utilizados:"
    echo "Usuário: $username"
    echo "Nova senha: $password"
  else
    progress_fail 40 "Resetando senha..."
  fi

  pause
}

delete_gitea_user() {
  local username confirm

  safe_clear
  echo "EXCLUIR CONTA"
  echo

  read -r -p "Nome de usuário: " username || true

  if [[ -z "$username" ]]; then
    echo "Usuário inválido."
    pause
    return
  fi

  read -r -p "Confirma excluir a conta '$username'? [s/N]: " confirm || true
  [[ ! "$confirm" =~ ^[sS]$ ]] && { echo "Cancelado."; pause; return; }

  safe_clear
  progress_line 40 "Excluindo conta..."

  if sudo -u git /usr/local/bin/gitea admin user delete     --username "$username"     --config /var/lib/gitea/custom/conf/app.ini >/dev/null 2>&1; then

    progress_ok "Conta excluída com sucesso."
    echo
    echo "✔ Conta removida: $username"
  else
    progress_fail 40 "Excluindo conta..."
  fi

  pause
}

list_gitea_users() {
  safe_clear
  echo "LISTAR CONTAS"
  echo

  sudo -u git /usr/local/bin/gitea admin user list     --config /var/lib/gitea/custom/conf/app.ini 2>/dev/null || echo "Não foi possível listar os usuários."

  echo
  pause
}

toggle_admin_gitea_user() {
  local username action admin_value db_path username_sql current_value

  safe_clear
  echo "ALTERAR PRIVILÉGIO ADMIN"
  echo

  read -r -p "Nome de usuário: " username || true
  read -r -p "01) Tornar admin  02) Remover admin : " action || true

  [[ -z "$username" ]] && { echo "Usuário inválido."; pause; return; }
  gitea_sqlite_ready || { echo "Banco SQLite não encontrado para alterar admin."; pause; return; }

  case "$action" in
    01|1) admin_value=1 ;;
    02|2) admin_value=0 ;;
    *) echo "Opção inválida."; pause; return ;;
  esac

  db_path="$(get_gitea_db_path)"
  username_sql="$(sqlite_escape "$username")"
  current_value="$(sqlite3 "$db_path" "SELECT is_admin FROM user WHERE lower_name = lower('$username_sql') OR name = '$username_sql' LIMIT 1;" 2>/dev/null || true)"

  [[ -z "$current_value" ]] && { echo "Usuário não encontrado."; pause; return; }

  safe_clear
  progress_line 40 "Atualizando privilégios..."
  if sqlite3 "$db_path" "UPDATE user SET is_admin = $admin_value WHERE lower_name = lower('$username_sql') OR name = '$username_sql';" >/dev/null 2>&1; then
    progress_ok "Privilégio atualizado."
    echo
    echo "Usuário: $username"
    if [[ "$admin_value" == "1" ]]; then
      echo "Novo nível: Admin"
    else
      echo "Novo nível: Normal"
    fi
    systemctl restart gitea >/dev/null 2>&1 || true
  else
    progress_fail 40 "Atualizando privilégios..."
  fi

  pause
}

list_user_tokens() {
  local username db_path username_sql token_count

  safe_clear
  echo "TOKENS DO USUÁRIO"
  echo

  read -r -p "Nome de usuário: " username || true
  [[ -z "$username" ]] && { echo "Usuário inválido."; pause; return; }
  gitea_sqlite_ready || { echo "Banco SQLite não encontrado para consultar tokens."; pause; return; }

  db_path="$(get_gitea_db_path)"
  username_sql="$(sqlite_escape "$username")"
  token_count="$(sqlite3 "$db_path" "SELECT COUNT(*) FROM access_token at INNER JOIN user u ON u.id = at.uid WHERE u.lower_name = lower('$username_sql') OR u.name = '$username_sql';" 2>/dev/null || true)"

  if [[ -z "$token_count" || "$token_count" == "0" ]]; then
    echo "Nenhum token encontrado para esse usuário."
    echo
    pause
    return
  fi

  echo "Aplicação | Últimos 8 | Escopo | Criado em"
  echo "---------------------------------------------"
  sqlite3 -separator ' | ' "$db_path" "
    SELECT at.name,
           COALESCE(at.token_last_eight, '--------'),
           COALESCE(at.scope, 'sem-escopo'),
           datetime(at.created_unix, 'unixepoch', 'localtime')
    FROM access_token at
    INNER JOIN user u ON u.id = at.uid
    WHERE u.lower_name = lower('$username_sql') OR u.name = '$username_sql'
    ORDER BY at.created_unix DESC;
  " 2>/dev/null

  echo
  echo "Obs: o valor completo de tokens antigos não pode ser exibido novamente."
  pause
}


show_user_token_application() {
  local username app_name db_path username_sql app_sql found

  safe_clear
  echo "INFORMAÇÕES DO TOKEN DA APLICAÇÃO"
  echo

  read -r -p "Nome de usuário: " username || true
  read -r -p "Nome da aplicação/token: " app_name || true

  [[ -z "$username" || -z "$app_name" ]] && { echo "Usuário ou nome da aplicação inválido."; pause; return; }
  gitea_sqlite_ready || { echo "Banco SQLite não encontrado para consultar tokens."; pause; return; }

  db_path="$(get_gitea_db_path)"
  username_sql="$(sqlite_escape "$username")"
  app_sql="$(sqlite_escape "$app_name")"
  found="$(sqlite3 -separator ' | ' "$db_path" "
    SELECT at.name,
           COALESCE(at.token_last_eight, '--------'),
           COALESCE(at.scope, 'sem-escopo'),
           datetime(at.created_unix, 'unixepoch', 'localtime')
    FROM access_token at
    INNER JOIN user u ON u.id = at.uid
    WHERE (u.lower_name = lower('$username_sql') OR u.name = '$username_sql')
      AND lower(at.name) = lower('$app_sql')
    ORDER BY at.created_unix DESC
    LIMIT 1;
  " 2>/dev/null || true)"

  if [[ -z "$found" ]]; then
    echo "Nenhum token encontrado para essa aplicação nesse usuário."
    echo
    pause
    return
  fi

  echo "Usuário: $username"
  echo "$found" | awk -F' \| ' '{
    printf "Aplicação: %s\n", $1
    printf "Últimos 8: %s\n", $2
    printf "Escopo: %s\n", $3
    printf "Criado em: %s\n", $4
  }'
  echo
  echo "Obs: o valor completo de tokens antigos não pode ser exibido novamente."
  pause
}

revoke_user_token() {
  local username token_name output

  safe_clear
  echo "REVOGAR TOKEN"
  echo

  read -r -p "Nome de usuário: " username || true
  read -r -p "Nome da aplicação/token: " token_name || true

  [[ -z "$username" || -z "$token_name" ]] && { echo "Usuário ou nome do token inválido."; pause; return; }

  safe_clear
  progress_line 40 "Revogando token..."
  output="$(sudo -u git /usr/local/bin/gitea admin user delete-access-token \
    --username "$username" \
    --token-name "$token_name" \
    --config /var/lib/gitea/custom/conf/app.ini 2>&1 || true)"

  if printf '%s' "$output" | grep -qiE 'success|removed|deleted|revoked'; then
    progress_ok "Token revogado com sucesso."
    echo
    echo "Usuário: $username"
    echo "Aplicação: $token_name"
  elif [[ -z "$output" ]]; then
    progress_ok "Token revogado com sucesso."
    echo
    echo "Usuário: $username"
    echo "Aplicação: $token_name"
  else
    progress_fail 40 "Revogando token..."
    echo
    echo "$output"
  fi

  pause
}

tokens_menu() {
  local op width top mid bot

  while true; do
    safe_clear
    MENU_OPTION_DIGITS=1

    width="$(menu_width)"
    top="╔$(hline $((width-2)))╗"
    mid="╠$(hline $((width-2)))╣"
    bot="╚$(hline $((width-2)))╝"

    echo "  $top"
    echo "  $(center_line "GERENCIAR TOKENS" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "$(menu_item 1 'Listar Tokens')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Info da Aplicação')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Revogar Token')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 4 'Novo Token [ALL]')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Voltar')" "" "$width")"
    echo "  $bot"
    echo

    op="$(read_menu_option_2d "Opção: ")" || return

    case "$op" in
      01|1) safe_clear; list_user_tokens ;;
      02|2) safe_clear; show_user_token_application ;;
      03|3) safe_clear; revoke_user_token ;;
      04|4) safe_clear; generate_user_token ;;
      00|0) safe_clear; return ;;
      *) echo "Opção inválida."; pause ;;
    esac
  done
}

save_local_token_record() {
  local username="$1"
  local token_name="$2"
  local token_value="$3"
  local scopes="${4:-all}"
  local created_at

  [[ -z "$username" || -z "$token_name" || -z "$token_value" ]] && return 0

  created_at="$(date '+%Y-%m-%d %H:%M:%S')"

  umask 077
  if [[ ! -f "$TOKEN_STORE_FILE" ]]; then
    {
      echo "# Tokens Gitea salvos automaticamente pelo Gestor VPS"
      echo "# Arquivo sensível. Mantido com permissão 600. Não compartilhe este arquivo."
      echo "# Formato: DATA | USUARIO | NOME_TOKEN | ESCOPO | TOKEN"
    } > "$TOKEN_STORE_FILE"
    chmod 600 "$TOKEN_STORE_FILE" 2>/dev/null || true
  fi

  printf '%s | %s | %s | %s | %s\n' "$created_at" "$username" "$token_name" "$scopes" "$token_value" >> "$TOKEN_STORE_FILE"
  chmod 600 "$TOKEN_STORE_FILE" 2>/dev/null || true
}

generate_user_token() {
  local username token_name scopes output token_value clean_output

  safe_clear
  echo "GERAR NOVO TOKEN"
  echo

  read -r -p "Nome de usuário: " username || true
  read -r -p "Nome da aplicação/token: " token_name || true

  [[ -z "$username" || -z "$token_name" ]] && { echo "Usuário ou nome do token inválido."; pause; return; }

  scopes="all"

  safe_clear
  progress_line 40 "Gerando token..."
  output="$(sudo -u git /usr/local/bin/gitea admin user generate-access-token     --username "$username"     --token-name "$token_name"     --scopes "$scopes"     --config /var/lib/gitea/custom/conf/app.ini 2>&1 || true)"

  clean_output="$(printf '%s' "$output" | tr -d '
')"
  token_value="$(printf '%s' "$clean_output" | tr -d '
' | grep -oE '[A-Fa-f0-9]{40,}' | head -n1)"

  if printf '%s' "$clean_output" | grep -qi 'successfully created' || [[ -n "$token_value" ]]; then
    progress_ok "Token gerado com sucesso."
    echo
    echo "Usuário: $username"
    echo "Aplicação: $token_name"
    echo "Permissão: leitura e escrita total"
    echo "Escopo: $scopes"
    echo "Tempo: infinito"
    echo "Token: $token_value"
    if [[ -n "$token_value" ]]; then
      save_local_token_record "$username" "$token_name" "$token_value" "$scopes"
      echo "Salvo em: ${TOKEN_STORE_FILE}"
    else
      echo "Aviso: o token foi criado, mas o valor completo não foi capturado para salvar."
    fi
    echo
    echo "Guarde esse token agora, porque depois o Gitea não mostra o valor completo novamente."
  else
    progress_fail 40 "Gerando token..."
    echo
    echo "$clean_output"
  fi

  pause
}

urlencode_component() {
  python3 - "$1" <<'PYURL'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PYURL
}

valid_repo_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$name" != "." && "$name" != ".." ]] || return 1
  [[ "$name" != *"/"* ]] || return 1
}

gitea_api_base_url() {
  local port
  port="$(get_current_port)"
  [[ -z "$port" ]] && port="2096"
  printf 'http://127.0.0.1:%s/api/v1' "$port"
}

print_api_error() {
  local file="$1"
  python3 - "$file" <<'PYAPIERR'
import json, sys
path = sys.argv[1]
try:
    raw = open(path, 'r', encoding='utf-8', errors='replace').read().strip()
except Exception:
    raw = ''
if not raw:
    print('Resposta vazia da API.')
    raise SystemExit(0)
try:
    data = json.loads(raw)
except Exception:
    print(raw[:1200])
    raise SystemExit(0)
messages = []
if isinstance(data, dict):
    for key in ('message', 'error', 'documentation_url'):
        value = data.get(key)
        if value:
            messages.append(str(value))
    errors = data.get('errors')
    if isinstance(errors, list):
        for err in errors:
            if isinstance(err, dict):
                messages.append(str(err.get('message') or err.get('code') or err))
            else:
                messages.append(str(err))
print(' | '.join(messages) if messages else raw[:1200])
PYAPIERR
}

gitea_repo_api_ready() {
  local api
  [[ -f "${GITEA_CONF_FILE}" ]] || { echo "Configuração do Gitea não encontrada."; return 1; }
  ensure_gitea_executable >/dev/null 2>&1 || { echo "Binário do Gitea inválido: ${GITEA_BIN}"; return 1; }
  if ! systemctl is-active --quiet gitea 2>/dev/null; then
    echo "Serviço Gitea não está ativo. Reinicie o Gitea primeiro."
    return 1
  fi
  api="$(gitea_api_base_url)"
  if ! curl -fsS --max-time 8 "${api}/version" >/dev/null 2>&1; then
    echo "API local do Gitea não respondeu em ${api}."
    return 1
  fi
}

gitea_user_exists() {
  local username="$1" db_path username_sql found
  gitea_sqlite_ready || return 0
  db_path="$(get_gitea_db_path)"
  username_sql="$(sqlite_escape "$username")"
  found="$(sqlite3 "$db_path" "SELECT id FROM user WHERE lower_name = lower('$username_sql') OR name = '$username_sql' LIMIT 1;" 2>/dev/null || true)"
  [[ -n "$found" ]]
}

prompt_repo_username() {
  local title="$1" username
  REPO_OWNER_USERNAME=""
  safe_clear
  echo "$title"
  echo
  read -r -p "Usuário dono do repositório: " username || true
  [[ -z "$username" ]] && { echo "Usuário inválido."; pause; return 1; }
  if ! gitea_user_exists "$username"; then
    echo "Usuário não encontrado: ${username}"
    pause
    return 1
  fi
  REPO_OWNER_USERNAME="$username"
}

generate_repo_manager_token() {
  local username="$1" token_name output clean_output token_value
  token_name="repo-manager-$(date +%s)-$RANDOM"

  output="$(run_gitea_cli admin user generate-access-token \
    --username "$username" \
    --token-name "$token_name" \
    --scopes all \
    --config "${GITEA_CONF_FILE}" 2>&1 || true)"

  token_value="$(printf '%s\n' "$output" | awk -F': ' '/^Token:/ {print $2; exit}')"
  if [[ -z "$token_value" ]]; then
    clean_output="$(printf '%s' "$output" | tr -d '\r\n')"
    token_value="$(printf '%s' "$clean_output" | grep -oE 'gitea_[A-Za-z0-9_=-]+' | head -n1 || true)"
  fi
  if [[ -z "$token_value" ]]; then
    clean_output="$(printf '%s' "$output" | tr -d '\r\n')"
    token_value="$(printf '%s' "$clean_output" | grep -oE '[A-Fa-f0-9]{40,}' | head -n1 || true)"
  fi

  [[ -z "$token_value" ]] && {
    echo "Não foi possível gerar token temporário para ${username}." >&2
    echo "$output" >&2
    return 1
  }

  printf '%s|%s' "$token_name" "$token_value"
}

revoke_repo_manager_token() {
  local username="$1" token_name="$2"
  [[ -z "$username" || -z "$token_name" ]] && return 0
  run_gitea_cli admin user delete-access-token \
    --username "$username" \
    --token-name "$token_name" \
    --config "${GITEA_CONF_FILE}" >/dev/null 2>&1 || true
}

gitea_api_request() {
  local method="$1" api_path="$2" token="$3" body_file="${4:-}" out_file="$5"
  local api code
  api="$(gitea_api_base_url)"

  if [[ -n "$body_file" && -f "$body_file" ]]; then
    code="$(curl -sS --max-time 35 -X "$method" \
      -H "Authorization: token ${token}" \
      -H "Content-Type: application/json" \
      --data @"$body_file" \
      -o "$out_file" \
      -w '%{http_code}' \
      "${api}${api_path}" 2>/dev/null || echo "000")"
  else
    code="$(curl -sS --max-time 35 -X "$method" \
      -H "Authorization: token ${token}" \
      -H "Content-Type: application/json" \
      -o "$out_file" \
      -w '%{http_code}' \
      "${api}${api_path}" 2>/dev/null || echo "000")"
  fi

  printf '%s' "$code"
}

write_create_repo_payload() {
  local repo_name="$1" description="$2" with_readme="${3:-1}" out_file="$4"
  python3 - "$repo_name" "$description" "$with_readme" "$out_file" <<'PYREPOCREATE'
import json, sys
name, description, with_readme, out = sys.argv[1:5]
payload = {
    "name": name,
    "description": description,
    "private": False,
    "auto_init": True,
    "default_branch": "main"
}
if with_readme == "1":
    payload["readme"] = "Default"
with open(out, 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=False)
PYREPOCREATE
}

write_rename_repo_payload() {
  local new_name="$1" out_file="$2"
  python3 - "$new_name" "$out_file" <<'PYREPORENAME'
import json, sys
new_name, out = sys.argv[1:3]
with open(out, 'w', encoding='utf-8') as f:
    json.dump({"name": new_name, "private": False}, f, ensure_ascii=False)
PYREPORENAME
}

append_public_repos_from_json() {
  local json_file="$1" out_file="$2"
  python3 - "$json_file" "$out_file" <<'PYREPOLIST'
import json, sys
json_file, out_file = sys.argv[1:3]
try:
    data = json.load(open(json_file, encoding='utf-8'))
except Exception:
    raise SystemExit(1)
if not isinstance(data, list):
    raise SystemExit(1)
with open(out_file, 'a', encoding='utf-8') as out:
    for repo in data:
        if repo.get('private') is True:
            continue
        name = repo.get('name') or ''
        html = repo.get('html_url') or repo.get('clone_url') or ''
        desc = (repo.get('description') or '').replace('\n', ' ').strip()
        if name:
            out.write(f"{name}|{html}|{desc}\n")
print(len(data))
PYREPOLIST
}

fetch_public_user_repos() {
  local username="$1" token="$2" out_file="$3"
  local owner page tmp_json code count
  owner="$(urlencode_component "$username")"
  : > "$out_file"
  page=1

  while true; do
    tmp_json="/tmp/gitea-repos-$$-${page}.json"
    code="$(gitea_api_request GET "/users/${owner}/repos?limit=100&page=${page}" "$token" "" "$tmp_json")"
    if [[ "$code" != "200" ]]; then
      echo "Falha ao listar repositórios. HTTP ${code}."
      print_api_error "$tmp_json"
      rm -f "$tmp_json"
      return 1
    fi
    count="$(append_public_repos_from_json "$tmp_json" "$out_file" 2>/dev/null || echo 0)"
    rm -f "$tmp_json"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    (( count < 100 )) && break
    page=$((page + 1))
  done
}

show_public_repos_file() {
  local repo_file="$1" n=0 name url desc
  if [[ ! -s "$repo_file" ]]; then
    echo "Nenhum repositório público encontrado para esse usuário."
    return 1
  fi
  echo "Repositórios públicos:"
  echo
  while IFS='|' read -r name url desc; do
    n=$((n + 1))
    printf '  %02d) %s' "$n" "$name"
    [[ -n "$desc" ]] && printf ' - %s' "$desc"
    [[ -n "$url" ]] && printf ' [%s]' "$url"
    printf '\n'
  done < "$repo_file"
  return 0
}

pick_repo_from_file() {
  local repo_file="$1" opt total
  PICKED_REPO_NAME=""
  total="$(wc -l < "$repo_file" 2>/dev/null | tr -d ' ')"
  [[ -z "$total" || "$total" == "0" ]] && return 1
  echo
  read -r -p "Escolha o número do repositório: " opt || true
  opt="${opt#0}"
  [[ -z "$opt" ]] && opt="0"
  [[ "$opt" =~ ^[0-9]+$ ]] || { echo "Opção inválida."; return 1; }
  (( opt >= 1 && opt <= total )) || { echo "Opção inválida."; return 1; }
  PICKED_REPO_NAME="$(sed -n "${opt}p" "$repo_file" | cut -d'|' -f1)"
  [[ -n "$PICKED_REPO_NAME" ]]
}

create_public_repository() {
  local username repo_name description token_data token_name token payload response code html_url

  gitea_repo_api_ready || { pause; return; }
  prompt_repo_username "CRIAR REPOSITÓRIO PÚBLICO" || return
  username="$REPO_OWNER_USERNAME"

  echo
  read -r -p "Nome do novo repositório: " repo_name || true
  read -r -p "Descrição opcional: " description || true

  valid_repo_name "$repo_name" || { echo "Nome inválido. Use apenas letras, números, ponto, hífen ou underline."; pause; return; }

  safe_clear
  progress_line 25 "Gerando acesso temporário..."
  token_data="$(generate_repo_manager_token "$username")" || { echo; pause; return; }
  token_name="${token_data%%|*}"
  token="${token_data#*|}"
  payload="/tmp/gitea-create-repo-$$.json"
  response="/tmp/gitea-create-repo-response-$$.json"

  write_create_repo_payload "$repo_name" "$description" "1" "$payload"
  progress_line 55 "Criando repositório público..."
  code="$(gitea_api_request POST "/user/repos" "$token" "$payload" "$response")"

  if [[ "$code" == "422" ]]; then
    write_create_repo_payload "$repo_name" "$description" "0" "$payload"
    code="$(gitea_api_request POST "/user/repos" "$token" "$payload" "$response")"
  fi

  if [[ "$code" == "200" || "$code" == "201" ]]; then
    progress_ok "Repositório criado."
    html_url="$(python3 - "$response" <<'PYREPOURL'
import json, sys
try:
    data=json.load(open(sys.argv[1], encoding='utf-8'))
    print(data.get('html_url') or data.get('clone_url') or '')
except Exception:
    print('')
PYREPOURL
)"
    echo
    echo "Usuário: ${username}"
    echo "Repositório: ${repo_name}"
    echo "Visibilidade: Público"
    echo "README: criado automaticamente"
    [[ -n "$html_url" ]] && echo "URL: ${html_url}"
  else
    progress_fail 55 "Criando repositório público..."
    echo
    echo "HTTP ${code}"
    print_api_error "$response"
  fi

  revoke_repo_manager_token "$username" "$token_name"
  rm -f "$payload" "$response"
  pause
}

list_public_repositories() {
  local username token_data token_name token repo_file log_file

  gitea_repo_api_ready || { pause; return; }
  prompt_repo_username "LISTAR REPOSITÓRIOS PÚBLICOS" || return
  username="$REPO_OWNER_USERNAME"

  safe_clear
  progress_line 25 "Gerando acesso temporário..."
  token_data="$(generate_repo_manager_token "$username")" || { echo; pause; return; }
  token_name="${token_data%%|*}"
  token="${token_data#*|}"
  repo_file="/tmp/gitea-public-repos-$$.list"
  log_file="/tmp/gitea-repo-list-$$.log"

  progress_line 70 "Buscando repositórios..."
  if fetch_public_user_repos "$username" "$token" "$repo_file" >"$log_file" 2>&1; then
    progress_ok "Consulta concluída."
    echo
    echo "Usuário: ${username}"
    echo "Visibilidade exibida: somente públicos"
    echo
    show_public_repos_file "$repo_file" || true
  else
    progress_fail 70 "Buscando repositórios..."
    echo
    cat "$log_file" 2>/dev/null || true
  fi

  revoke_repo_manager_token "$username" "$token_name"
  rm -f "$repo_file" "$log_file"
  pause
}

remove_public_repository() {
  local username token_data token_name token repo_file repo_name confirm owner repo_enc response code log_file

  gitea_repo_api_ready || { pause; return; }
  prompt_repo_username "REMOVER REPOSITÓRIO PÚBLICO" || return
  username="$REPO_OWNER_USERNAME"

  safe_clear
  progress_line 25 "Gerando acesso temporário..."
  token_data="$(generate_repo_manager_token "$username")" || { echo; pause; return; }
  token_name="${token_data%%|*}"
  token="${token_data#*|}"
  repo_file="/tmp/gitea-public-repos-$$.list"
  log_file="/tmp/gitea-repo-remove-$$.log"

  progress_line 55 "Listando repositórios..."
  if ! fetch_public_user_repos "$username" "$token" "$repo_file" >"$log_file" 2>&1; then
    progress_fail 55 "Listando repositórios..."
    echo
    cat "$log_file" 2>/dev/null || true
    revoke_repo_manager_token "$username" "$token_name"
    rm -f "$repo_file" "$log_file"
    pause
    return
  fi

  safe_clear
  echo "REMOVER REPOSITÓRIO PÚBLICO"
  echo
  echo "Usuário: ${username}"
  echo
  if ! show_public_repos_file "$repo_file"; then
    revoke_repo_manager_token "$username" "$token_name"
    rm -f "$repo_file" "$log_file"
    pause
    return
  fi

  pick_repo_from_file "$repo_file" || { revoke_repo_manager_token "$username" "$token_name"; rm -f "$repo_file" "$log_file"; pause; return; }
  repo_name="$PICKED_REPO_NAME"

  echo
  read -r -p "Confirma remover '${username}/${repo_name}'? [s/N]: " confirm || true
  [[ ! "$confirm" =~ ^[sS]$ ]] && { echo "Cancelado."; revoke_repo_manager_token "$username" "$token_name"; rm -f "$repo_file" "$log_file"; pause; return; }

  owner="$(urlencode_component "$username")"
  repo_enc="$(urlencode_component "$repo_name")"
  response="/tmp/gitea-delete-repo-response-$$.json"

  safe_clear
  progress_line 65 "Removendo repositório..."
  code="$(gitea_api_request DELETE "/repos/${owner}/${repo_enc}" "$token" "" "$response")"

  if [[ "$code" == "200" || "$code" == "202" || "$code" == "204" ]]; then
    progress_ok "Repositório removido."
    echo
    echo "Removido: ${username}/${repo_name}"
  else
    progress_fail 65 "Removendo repositório..."
    echo
    echo "HTTP ${code}"
    print_api_error "$response"
  fi

  revoke_repo_manager_token "$username" "$token_name"
  rm -f "$repo_file" "$response" "$log_file"
  pause
}

rename_public_repository() {
  local username token_data token_name token repo_file repo_name new_name confirm owner repo_enc payload response code log_file

  gitea_repo_api_ready || { pause; return; }
  prompt_repo_username "ALTERAR NOME DO REPOSITÓRIO" || return
  username="$REPO_OWNER_USERNAME"

  safe_clear
  progress_line 25 "Gerando acesso temporário..."
  token_data="$(generate_repo_manager_token "$username")" || { echo; pause; return; }
  token_name="${token_data%%|*}"
  token="${token_data#*|}"
  repo_file="/tmp/gitea-public-repos-$$.list"
  log_file="/tmp/gitea-repo-rename-$$.log"

  progress_line 55 "Listando repositórios..."
  if ! fetch_public_user_repos "$username" "$token" "$repo_file" >"$log_file" 2>&1; then
    progress_fail 55 "Listando repositórios..."
    echo
    cat "$log_file" 2>/dev/null || true
    revoke_repo_manager_token "$username" "$token_name"
    rm -f "$repo_file" "$log_file"
    pause
    return
  fi

  safe_clear
  echo "ALTERAR NOME DO REPOSITÓRIO"
  echo
  echo "Usuário: ${username}"
  echo
  if ! show_public_repos_file "$repo_file"; then
    revoke_repo_manager_token "$username" "$token_name"
    rm -f "$repo_file" "$log_file"
    pause
    return
  fi

  pick_repo_from_file "$repo_file" || { revoke_repo_manager_token "$username" "$token_name"; rm -f "$repo_file" "$log_file"; pause; return; }
  repo_name="$PICKED_REPO_NAME"

  echo
  read -r -p "Novo nome do repositório: " new_name || true
  valid_repo_name "$new_name" || { echo "Nome inválido. Use apenas letras, números, ponto, hífen ou underline."; revoke_repo_manager_token "$username" "$token_name"; rm -f "$repo_file" "$log_file"; pause; return; }

  read -r -p "Confirma renomear '${repo_name}' para '${new_name}'? [s/N]: " confirm || true
  [[ ! "$confirm" =~ ^[sS]$ ]] && { echo "Cancelado."; revoke_repo_manager_token "$username" "$token_name"; rm -f "$repo_file" "$log_file"; pause; return; }

  owner="$(urlencode_component "$username")"
  repo_enc="$(urlencode_component "$repo_name")"
  payload="/tmp/gitea-rename-repo-$$.json"
  response="/tmp/gitea-rename-repo-response-$$.json"
  write_rename_repo_payload "$new_name" "$payload"

  safe_clear
  progress_line 65 "Renomeando repositório..."
  code="$(gitea_api_request PATCH "/repos/${owner}/${repo_enc}" "$token" "$payload" "$response")"

  if [[ "$code" == "200" ]]; then
    progress_ok "Repositório renomeado."
    echo
    echo "Usuário: ${username}"
    echo "Antes: ${repo_name}"
    echo "Depois: ${new_name}"
    echo "Visibilidade mantida: Público"
  else
    progress_fail 65 "Renomeando repositório..."
    echo
    echo "HTTP ${code}"
    print_api_error "$response"
  fi

  revoke_repo_manager_token "$username" "$token_name"
  rm -f "$repo_file" "$payload" "$response" "$log_file"
  pause
}

repositories_menu() {
  local op width top mid bot

  while true; do
    safe_clear
    MENU_OPTION_DIGITS=1

    width="$(menu_width)"
    top="╔$(hline $((width-2)))╗"
    mid="╠$(hline $((width-2)))╣"
    bot="╚$(hline $((width-2)))╝"

    echo "  $top"
    echo "  $(center_line "GERENCIAR REPOSITÓRIOS" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "$(menu_item 1 'Criar Público')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Listar Públicos')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Remover')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 4 'Alterar Nome')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Voltar')" "" "$width")"
    echo "  $bot"
    echo

    op="$(read_menu_option_2d "Opção: ")" || return

    case "$op" in
      01|1) safe_clear; create_public_repository ;;
      02|2) safe_clear; list_public_repositories ;;
      03|3) safe_clear; remove_public_repository ;;
      04|4) safe_clear; rename_public_repository ;;
      00|0) safe_clear; return ;;
      *) echo "Opção inválida."; pause ;;
    esac
  done
}

accounts_menu() {
  local op width top mid bot

  while true; do
    safe_clear
    MENU_OPTION_DIGITS=1

    width="$(menu_width)"
    top="╔$(hline $((width-2)))╗"
    mid="╠$(hline $((width-2)))╣"
    bot="╚$(hline $((width-2)))╝"

    echo "  $top"
    echo "  $(center_line "GERENCIAR CONTAS" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "$(menu_item 1 'Criar Conta')" "$(menu_item 6 'Gerenciar Tokens')" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Resetar Senha')" "$(menu_item 7 'Gerenciar Repositório')" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Excluir Conta')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 4 'Listar Contas')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 5 'Admin [ON/OFF]')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Voltar')" "" "$width")"
    echo "  $bot"
    echo

    op="$(read_menu_option_2d "Opção: ")" || return

    case "$op" in
      01|1) safe_clear; create_gitea_user ;;
      02|2) safe_clear; change_user_password ;;
      03|3) safe_clear; delete_gitea_user ;;
      04|4) safe_clear; list_gitea_users ;;
      05|5) safe_clear; toggle_admin_gitea_user ;;
      06|6) safe_clear; tokens_menu ;;
      07|7) safe_clear; repositories_menu ;;
      00|0) safe_clear; return ;;
      *) echo "Opção inválida."; pause ;;
    esac
  done
}
status_label() {
  if is_bot_enabled; then
    echo "[ON]"
  else
    echo "[OFF]"
  fi
}

CYAN_BG=$'\e[48;5;19m'
WHITE_FG=$'\e[97m'
RESET_FMT=$'\e[0m'
GREEN_FG=$'\e[92m'

menu_width() {
  local cols width
  cols="$(tput cols 2>/dev/null || echo 80)"

  # Reserva margem para o recuo usado nos echos do layout e evita quebra.
  width=$((cols - 4))

  if (( width < 60 )); then
    width=60
  elif (( width > 96 )); then
    width=96
  fi

  echo "$width"
}

hline() {
  local w="$1"
  local line=""
  local i
  for ((i=0;i<w;i++)); do line="${line}═"; done
  echo "$line"
}

strip_ansi() {
  printf '%s' "$1" | sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g'
}

visible_length() {
  local clean
  clean="$(strip_ansi "$1")"
  printf '%s' "${#clean}"
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i
  for ((i=0;i<count;i++)); do out+="$char"; done
  printf '%s' "$out"
}

pad_right_ansi() {
  local text="$1"
  local width="$2"
  local vis
  vis="$(visible_length "$text")"
  if (( vis >= width )); then
    printf '%s' "$text"
  else
    printf '%s%s' "$text" "$(repeat_char ' ' $((width - vis)))"
  fi
}

fit_colored_text() {
  local text="$1"
  local max="$2"
  local plain ansi_prefix ansi_suffix
  plain="$(strip_ansi "$text")"
  if (( ${#plain} <= max )); then
    printf '%s' "$text"
    return
  fi

  ansi_prefix="${text%%${plain}*}"
  ansi_suffix=""
  if [[ "$text" == *"$RESET_FMT" ]]; then
    ansi_suffix="$RESET_FMT"
  fi
  printf '%s%s%s' "$ansi_prefix" "${plain:0:max}" "$ansi_suffix"
}

format_option() {
  local num="$1"
  local digits="${MENU_OPTION_DIGITS:-1}"
  if [[ "$digits" == "2" ]]; then
    printf '%s%s %02d %s' "$CYAN_BG" "$WHITE_FG" "$num" "$RESET_FMT"
  else
    printf '%s%s %d %s' "$CYAN_BG" "$WHITE_FG" "$num" "$RESET_FMT"
  fi
}

menu_item() {
  local num="$1"
  local label="$2"
  printf '%s %s' "$(format_option "$num")" "$label"
}

two_col_line() {
  local left="$1"
  local right="$2"
  local width="$3"
  local inner left_width right_width gap rendered_left rendered_right single_width

  inner=$((width - 2))

  if [[ -n "$right" ]]; then
    gap=6
    left_width=$(( (inner - gap - 4) / 2 ))
    right_width=$(( inner - gap - 4 - left_width ))
    rendered_left="$(fit_colored_text "$left" "$left_width")"
    rendered_right="$(fit_colored_text "$right" "$right_width")"
    printf '║  %s%s%s  ║\n' \
      "$(pad_right_ansi "$rendered_left" "$left_width")" \
      "$(repeat_char ' ' "$gap")" \
      "$(pad_right_ansi "$rendered_right" "$right_width")"
  else
    single_width=$((inner - 4))
    rendered_left="$(fit_colored_text "$left" "$single_width")"
    printf '║  %s  ║\n' "$(pad_right_ansi "$rendered_left" "$single_width")"
  fi
}

center_line() {
  local text="$1"
  local width="$2"
  local inner text_len left_pad right_pad
  inner=$((width - 2))
  text_len="$(visible_length "$text")"
  if (( text_len > inner )); then
    text="$(fit_colored_text "$text" "$inner")"
    text_len="$(visible_length "$text")"
  fi
  left_pad=$(( (inner - text_len) / 2 ))
  right_pad=$(( inner - text_len - left_pad ))
  printf '║%s%s%s║\n' "$(repeat_char ' ' "$left_pad")" "$text" "$(repeat_char ' ' "$right_pad")"
}

plain_line() {
  local text="$1"
  local width="$2"
  local inner
  inner=$((width - 2))
  text="$(fit_colored_text "$text" "$inner")"
  printf '║%s║\n' "$(pad_right_ansi "$text" "$inner")"
}

show_header() {
  safe_clear

  local width top mid bot
  local ram cpu status port domain auto_label bot_label
  local update_info update_status update_version update_label

  width="$(menu_width)"
  top="╔$(hline $((width-2)))╗"
  mid="╠$(hline $((width-2)))╣"
  bot="╚$(hline $((width-2)))╝"

  ram="$(get_ram_usage)"
  cpu="$(get_cpu_usage)"
  status="$(get_service_state_plain)"
  port="$(get_current_port)"
  domain="$(get_current_domain)"
  update_info="$(get_update_info_menu)"
  update_status="${update_info%%|*}"
  update_version="$(printf '%s' "$update_info" | awk -F'|' '{print $2}')"

  if [[ "${update_status}" == "update" ]]; then
    update_label="${GREEN_FG}${update_version}${RESET_FMT}"
  else
    update_label="${update_version}"
  fi

  if is_auto_backup_enabled; then
    auto_label="Backup Auto [ON]"
  else
    auto_label="Backup Auto [OFF]"
  fi

  bot_label="Menu do Bot $(status_label)"

  echo "  $top"
  echo "  $(center_line "GERENCIADOR DO GITEA [${status}]" "$width")"
  echo "  $mid"
  echo "  $(two_col_line "RAM [${ram}]" "CPU [${cpu}]" "$width")"
  echo "  $mid"

  if is_installed; then
    echo "  $(two_col_line "$(menu_item 1 'Remover Gitea')" "$(menu_item 6 'Importar Backup')" "$width")"
    echo "  $(two_col_line "$(menu_item 2 "Reiniciar")" "$(menu_item 7 "${auto_label}")" "$width")"
    echo "  $(two_col_line "$(menu_item 3 "Alterar Porta CF [${port:-N/A}]")" "$(menu_item 8 'Reparar no Boot')" "$width")"
    echo "  $(two_col_line "$(menu_item 4 "Alterar Domínio CF")" "$(menu_item 9 "${bot_label}")" "$width")"
    echo "  $(two_col_line "$(menu_item 5 "Atualizar Gitea [${update_label}]")" "$(menu_item 10 'Gerenciar Contas')" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Sair')" "" "$width")"
  else
    echo "  $(two_col_line "$(menu_item 1 'Cloudflare Token')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Instalar Manual')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Importar Backup')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Sair')" "" "$width")"
  fi

  echo "  $bot"
  echo
}

bot_menu() {
  local op width top mid bot
  local backup status

  while true; do
    safe_clear
    MENU_OPTION_DIGITS=1

    width="$(menu_width)"
    top="╔$(hline $((width-2)))╗"
    mid="╠$(hline $((width-2)))╣"
    bot="╚$(hline $((width-2)))╝"

    status="$(status_label)"
    backup="[$(get_backup_interval)]"

    echo "  $top"
    echo "  $(center_line "MENU DO BOT ${status}" "$width")"
    echo "  $mid"
    echo "  $(center_line "Tempo de Backup ${backup}" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "$(menu_item 1 'Tempo de backup')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Configurar bot')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Ativar / Desativar')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 4 'Exportar Backup')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 5 'Exportar + Telegram')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Voltar')" "" "$width")"
    echo "  $bot"
    echo

    op="$(read_menu_option_2d "Opção: ")" || return

    case "$op" in
      01|1) safe_clear; set_backup_time_menu ;;
      02|2) safe_clear; configure_bot ;;
      03|3) safe_clear; toggle_bot ;;
      04|4) safe_clear; export_backup ;;
      05|5) safe_clear; export_backup_and_send ;;
      00|0) safe_clear; return ;;
      *) echo "Opção inválida."; pause ;;
    esac
  done
}
main_menu() {
  local op

  while true; do
    if is_installed; then
      MENU_OPTION_DIGITS=2
    else
      MENU_OPTION_DIGITS=1
    fi

    show_header

    op="$(read_menu_option_2d "Opção: ")"
    if [[ -z "$op" ]]; then
      echo
      echo "Não foi possível ler a opção."
      exit 1
    fi

    if is_installed; then
      case "$op" in
        01|1) safe_clear; remove_gitea ;;
        02|2) safe_clear; restart_gitea ;;
        03|3) safe_clear; change_port ;;
        04|4) safe_clear; change_domain ;;
        05|5) safe_clear; update_gitea ;;
        06|6) safe_clear; import_backup ;;
        07|7)
          safe_clear
          if is_auto_backup_enabled; then
            disable_auto_backup
          else
            enable_auto_backup
          fi
          ;;
        08|8) safe_clear; fix_boot_services ;;
        09|9) safe_clear; bot_menu ;;
        10) safe_clear; accounts_menu ;;
        00|0) exit 0 ;;
        *) echo "Opção inválida."; pause ;;
      esac
    else
      case "$op" in
        01|1) safe_clear; cloudflare_prepare_install ;;
        02|2) safe_clear; install_gitea ;;
        03|3) safe_clear; import_backup ;;
        00|0) exit 0 ;;
        *) echo "Opção inválida."; pause ;;
      esac
    fi
  done
}

require_root
require_supported_ubuntu
main_menu
