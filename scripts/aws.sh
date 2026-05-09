#!/usr/bin/env bash

# Layout v2: menus organizados e janelas aplicadas em mais telas.
set -Eeuo pipefail

APP_NAME="Gestor VPS AWS"
APP_VERSION="2.4"
# aws_v3: correção das sequências ANSI para evitar exibir \033 literal.
# aws_v4: CPU em consumido/total; removidos PRETTY_OS extra e campo Rede do cabeçalho.
LOG_FILE="/var/log/primevpn-aws-setup.log"

# =========================================================
# CONFIGURAÇÕES FIXAS
# =========================================================
CONFIG_HOSTNAME="primevpn"
CONFIG_TIMEZONE="America/Sao_Paulo"
CONFIG_AUTO_REBOOT="false"

RED=$'\e[1;31m'
GREEN=$'\e[1;32m'
YELLOW=$'\e[1;33m'
BLUE=$'\e[1;34m'
MAGENTA=$'\e[1;35m'
CYAN=$'\e[1;36m'
WHITE=$'\e[1;37m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
NC=$'\e[0m'

OS_ID=""
OS_NAME=""
OS_VERSION=""
PRETTY_OS=""
PKG_UPDATE=""
PKG_UPGRADE=""
PKG_INSTALL=""
TOTAL_STEPS=0
CURRENT_STEP=0
ROOT_PASSWORD=""

NET_TUNING_FILE="/etc/sysctl.d/99-aws-network-tuning.conf"
LIMITS_FILE="/etc/security/limits.d/99-aws-limits.conf"
SWAP_TUNING_FILE="/etc/sysctl.d/99-swap-tuning.conf"
BADVPN_SYSCTL_FILE="/etc/sysctl.d/99-badvpn.conf"
BADVPN_SOURCE_DIR="/usr/local/src/badvpn"
BADVPN_BUILD_DIR="/usr/local/src/badvpn/build-udpgw"
BADVPN_REPO_URL="https://github.com/ambrop72/badvpn.git"
BADVPN_SINGLE_PORT="7300"
BADVPN_MULTI_PORTS=(7300 7400 3478)
BADVPN_SERVICE_FILE="/etc/systemd/system/badvpn.service"
BADVPN_TEMPLATE_FILE="/etc/systemd/system/badvpn@.service"
DRAGONCORE_INSTALL_URL="https://git.dr2.site/penguinehis/DragonCoreSSH-Beta/raw/branch/main/install.sh"
CHECKUSER_INSTALL_URL="https://raw.githubusercontent.com/DTunnel0/CheckUser-Go/master/install.sh"
REINSTALLER_INSTALL_URL="https://raw.githubusercontent.com/nandoslayer/vps-reinstaller/main/install.sh"
LIMITER_DIR="/etc/primevpn/limiter"
LIMITER_DB="$LIMITER_DIR/limits.db"
LIMITER_STATUS_FILE="$LIMITER_DIR/status.tsv"
LIMITER_LOG_FILE="/var/log/primevpn-limiter.log"
LIMITER_BIN="/usr/local/bin/primevpn-limiter"
LIMITER_SERVICE_FILE="/etc/systemd/system/primevpn-limiter.service"
DRAGONCORE_SYSTEMD_SERVICE="/etc/systemd/system/dragoncore-autostart.service"
XRAY_API_HOST="127.0.0.1"
XRAY_API_PORT="10085"
XRAY_TUNING_DIR="/etc/primevpn/xray-tuning"
XRAY_TUNING_BACKUP="$XRAY_TUNING_DIR/config.before-vless-xhttp-tls.json"
XRAY_TUNING_MARKER="$XRAY_TUNING_DIR/applied"
XRAY_TUNING_META="$XRAY_TUNING_DIR/targets.count"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

ok() {
  echo -e "${GREEN}✔${NC} $*"
  log "OK: $*"
}

warn() {
  echo -e "${YELLOW}⚠${NC} $*"
  log "WARN: $*"
}

err() {
  echo -e "${RED}✘${NC} $*"
  log "ERROR: $*"
}

line() {
  printf "%b\n" "${DIM}────────────────────────────────────────────────────────────${NC}"
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED}Execute como root: sudo bash $0${NC}"
    exit 1
  fi
}

check_command() {
  command -v "$1" >/dev/null 2>&1
}


detect_architecture() {
  local machine deb_arch
  machine="$(uname -m 2>/dev/null || true)"
  deb_arch="$(dpkg --print-architecture 2>/dev/null || true)"

  case "$machine:$deb_arch" in
    x86_64:*|amd64:*|*:amd64)
      SYSTEM_ARCH="amd64"
      ;;
    aarch64:*|arm64:*|*:arm64)
      SYSTEM_ARCH="arm64"
      ;;
    *)
      err "Arquitetura não suportada: ${machine:-desconhecida}. Use x64/amd64 ou ARM64/aarch64."
      exit 1
      ;;
  esac
}

require_supported_ubuntu_version() {
  case "${OS_VERSION:-}" in
    20.04|22.04|24.04) ;;
    *)
      err "Ubuntu ${OS_VERSION:-desconhecido} não suportado. Use Ubuntu 20.04, 22.04 ou 24.04."
      exit 1
      ;;
  esac
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${NAME:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    PRETTY_OS="${PRETTY_NAME:-$OS_NAME $OS_VERSION}"
    detect_architecture
  else
    err "Não foi possível detectar o sistema operacional."
    exit 1
  fi

  case "$OS_ID" in
    ubuntu)
      require_supported_ubuntu_version
      export DEBIAN_FRONTEND=noninteractive
      PKG_UPDATE="apt update -y"
      PKG_UPGRADE="apt full-upgrade -y"
      PKG_INSTALL="apt install -y"
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      PKG_UPDATE="apt update -y"
      PKG_UPGRADE="apt full-upgrade -y"
      PKG_INSTALL="apt install -y"
      ;;
    amzn|amazon)
      if check_command dnf; then
        PKG_UPDATE="dnf makecache -y"
        PKG_UPGRADE="dnf upgrade -y --refresh"
        PKG_INSTALL="dnf install -y"
      else
        PKG_UPDATE="yum makecache -y"
        PKG_UPGRADE="yum update -y"
        PKG_INSTALL="yum install -y"
      fi
      ;;
    *)
      err "Sistema não suportado: ${PRETTY_OS}"
      exit 1
      ;;
  esac
}

install_base_tools() {
  case "$OS_ID" in
    ubuntu|debian)
      bash -c "$PKG_INSTALL curl wget ca-certificates tzdata nano vim htop jq git unzip sudo openssh-server procps coreutils util-linux" >> "$LOG_FILE" 2>&1
      ;;
    amzn|amazon)
      bash -c "$PKG_INSTALL curl wget ca-certificates tzdata nano vim htop jq git unzip shadow-utils util-linux sudo openssh-server procps-ng coreutils" >> "$LOG_FILE" 2>&1
      ;;
  esac
}

get_ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    echo "sshd"
  else
    echo "ssh"
  fi
}

validate_and_restart_ssh() {
  local svc
  svc="$(get_ssh_service_name)"
  if check_command sshd && sshd -t >> "$LOG_FILE" 2>&1; then
    systemctl enable "$svc" >> "$LOG_FILE" 2>&1 || true
    systemctl restart "$svc" >> "$LOG_FILE" 2>&1
    return 0
  fi
  return 1
}

ensure_ssh_setting() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
  else
    printf '\n%s %s\n' "$key" "$value" >> "$file"
  fi
}

format_bar() {
  local current="$1"
  local total="$2"
  local width="${3:-20}"
  local filled empty bar="" i

  (( total <= 0 )) && total=1
  (( current < 0 )) && current=0
  (( current > total )) && current="$total"

  filled=$(( current * width / total ))
  empty=$(( width - filled ))
  for ((i=0; i<filled; i++)); do bar+="#"; done
  for ((i=0; i<empty; i++)); do bar+="-"; done
  printf "%s" "$bar"
}

progress_start() {
  TOTAL_STEPS="$1"
  CURRENT_STEP=0
}

progress_render_step() {
  local shown_step="$1"
  local total="$2"
  local msg="$3"
  local spin="${4:-}"
  local cols bar_width prefix visible_prefix max_msg clean_msg bar line

  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  (( cols < 32 )) && cols=32

  bar_width=20
  (( cols < 72 )) && bar_width=14
  (( cols < 52 )) && bar_width=10

  bar="$(format_bar "$shown_step" "$total" "$bar_width")"
  prefix="${CYAN}[${bar}]${NC} ${BOLD}$(printf '%02d/%02d' "$shown_step" "$total")${NC} "
  visible_prefix="$(strip_ansi "$prefix")"
  clean_msg="$(printf '%s' "$msg" | tr '\r\n' '  ')"
  max_msg=$(( cols - ${#visible_prefix} - ${#spin} - 2 ))
  (( max_msg < 0 )) && max_msg=0
  if (( ${#clean_msg} > max_msg )); then
    if (( max_msg > 3 )); then
      clean_msg="${clean_msg:0:max_msg-3}..."
    else
      clean_msg="${clean_msg:0:max_msg}"
    fi
  fi

  line="${prefix}${clean_msg}"
  [[ -n "$spin" ]] && line+=" ${spin}"
  printf "\r\033[2K%b" "$line"
}

run_step() {
  local msg="$1"
  local cmd="$2"
  local spinner='|/-\\'
  local spin_idx=0
  local pid
  local next_step=$((CURRENT_STEP + 1))

  (
    eval "$cmd"
  ) >> "$LOG_FILE" 2>&1 &
  pid=$!

  progress_render_step "$CURRENT_STEP" "$TOTAL_STEPS" "$msg" "${spinner:$spin_idx:1}"

  while kill -0 "$pid" >/dev/null 2>&1; do
    progress_render_step "$CURRENT_STEP" "$TOTAL_STEPS" "$msg" "${spinner:$spin_idx:1}"
    spin_idx=$(( (spin_idx + 1) % ${#spinner} ))
    sleep 0.12
  done

  wait "$pid" >/dev/null 2>&1 || true
  CURRENT_STEP=$next_step
  progress_render_step "$CURRENT_STEP" "$TOTAL_STEPS" "$msg" ""
  printf "\n"

  log "STEP OK: $msg"
}

pause() {
  echo
  echo -e "${DIM}Pressione qualquer tecla para voltar ao menu...${NC}"
  read -rsn1 _
}

wait_key_menu() {
  local first=""

  # Menus AWS têm até 9 opções: seleção instantânea com 1 dígito.
  while true; do
    IFS= read -r -s -n 1 first || true
    case "$first" in
      $'\x1b')
        read -r -s -n 2 -t 0.001 _ || true
        ;;
      [0-9])
        printf "%s\n" "$first"
        MENU_KEY="$first"
        return 0
        ;;
      *)
        ;;
    esac
  done
}
get_cpu_usage_percent() {
  local cpu user nice system idle iowait irq softirq steal total1 total2 idle1 idle2 totald idled usage
  read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle1=$((idle + iowait))
  sleep 0.03
  read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat
  total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle2=$((idle + iowait))
  totald=$((total2 - total1))
  idled=$((idle2 - idle1))
  if (( totald <= 0 )); then
    echo "0%"
    return
  fi
  usage=$(( (1000 * (totald - idled) / totald + 5) / 10 ))
  echo "${usage}%"
}

get_cpu_display() {
  local used cores total
  used="$(get_cpu_usage_percent)"
  cores="$(nproc 2>/dev/null || echo 1)"
  total="$((cores * 100))%"
  echo "${used}/${total}"
}

get_ram_and_swap_display() {
  local mem_line swap_line mem_total mem_used swap_total swap_used
  mem_line="$(free -h | awk '/^Mem:/ {print $2" "$3}')"
  swap_line="$(free -h | awk '/^Swap:/ {print $2" "$3}')"
  mem_total="$(awk '{print $1}' <<< "$mem_line")"
  mem_used="$(awk '{print $2}' <<< "$mem_line")"
  swap_total="$(awk '{print $1}' <<< "$swap_line")"
  swap_used="$(awk '{print $2}' <<< "$swap_line")"
  echo "${mem_used}/${mem_total} (${swap_used}/${swap_total})"
}

get_storage_display() {
  df -h --output=avail,size / | awk 'NR==2 {print $1"/"$2}'
}

connection_tuning_status() {
  if [[ -f "$NET_TUNING_FILE" ]]; then
    echo "ATIVO"
  else
    echo "INATIVO"
  fi
}


CYAN_BG=$'\e[48;5;19m'
WHITE_FG=$'\e[1;97m'
RESET_FMT=$'\e[0m'

menu_width() {
  local cols width
  cols="$(tput cols 2>/dev/null || echo 80)"
  width=$((cols - 4))
  if (( width < 64 )); then
    width=64
  elif (( width > 104 )); then
    width=104
  fi
  echo "$width"
}

hline() {
  local w="$1"
  local line=""
  local i
  for ((i=0;i<w;i++)); do line+="═"; done
  printf '%s' "$line"
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
  local plain
  plain="$(strip_ansi "$text")"
  if (( ${#plain} <= max )); then
    printf '%s' "$text"
  elif (( max > 3 )); then
    printf '%s...' "${plain:0:max-3}"
  else
    printf '%s' "${plain:0:max}"
  fi
}

status_color() {
  local s="${1^^}"
  if [[ "$s" == *"ATIVO"* || "$s" == *"DEFINIDA"* || "$s" == *"INSTALADO"* || "$s" == *"PRONTO"* || "$s" == *"OK"* ]]; then
    printf '%b' "$GREEN"
  elif [[ "$s" == *"NÃO INSTALADO"* || "$s" == *"INATIVO"* || "$s" == *"PENDENTE"* || "$s" == *"PARADO"* || "$s" == *"BLOQUEADA"* || "$s" == '-' ]]; then
    printf '%b' "$YELLOW"
  else
    printf '%b' "$CYAN"
  fi
}

format_option() {
  local num="$1"
  # Menus de até 9 opções usam 1 dígito: 1, 2, 3...
  printf '%b%b%d%b' "$CYAN_BG" "$WHITE_FG" "$num" "$NC"
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
header() {
  clear
  local width top mid bot
  local cpu_use ram_swap storage distro_label

  cpu_use="$(get_cpu_display)"
  ram_swap="$(get_ram_and_swap_display)"
  storage="$(get_storage_display)"
  distro_label="${OS_NAME} ${OS_VERSION}"

  width="$(menu_width)"
  top="╔$(hline $((width-2)))╗"
  mid="╠$(hline $((width-2)))╣"
  bot="╚$(hline $((width-2)))╝"

  echo "  $top"
  echo "  $(center_line "${WHITE}${BOLD}${APP_NAME}${NC} ${DIM}v${APP_VERSION}${NC}" "$width")"
  echo "  $mid"
  echo "  $(two_col_line "Sistema: [${distro_label}]" "Kernel: [$(uname -r)]" "$width")"
  echo "  $(two_col_line "CPU: [${cpu_use}]" "RAM/SWAP: [${ram_swap}]" "$width")"
  echo "  $(two_col_line "Espaço: [${storage}]" "" "$width")"
  echo "  $bot"
  echo
}

ask_root_password() {
  local p1 p2
  while true; do
    echo
    read -r -p "Digite a nova senha do root: " p1
    read -r -p "Confirme a nova senha do root: " p2

    if [[ -z "$p1" ]]; then
      warn "A senha não pode ficar vazia."
      continue
    fi

    if [[ "$p1" != "$p2" ]]; then
      warn "As senhas não conferem. Tente novamente."
      continue
    fi

    ROOT_PASSWORD="$p1"
    break
  done
}

get_total_ram_mb() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

get_total_swap_mb() {
  if check_command swapon; then
    swapon --show --bytes --noheadings 2>/dev/null | awk '{sum+=$3} END {print int(sum/1024/1024)}'
  else
    echo 0
  fi
}

recommended_swap_mb() {
  local ram_mb="$1"
  if (( ram_mb <= 1024 )); then
    echo 2048
  elif (( ram_mb <= 2048 )); then
    echo 4096
  elif (( ram_mb <= 4096 )); then
    echo 4096
  elif (( ram_mb <= 8192 )); then
    echo 8192
  elif (( ram_mb <= 16384 )); then
    echo 8192
  elif (( ram_mb <= 32768 )); then
    echo 4096
  else
    echo 4096
  fi
}

apply_hostname_now() {
  hostnamectl set-hostname "$CONFIG_HOSTNAME"
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${CONFIG_HOSTNAME}/" /etc/hosts
  elif ! grep -qE "(^|[[:space:]])${CONFIG_HOSTNAME}([[:space:]]|$)" /etc/hosts; then
    echo "127.0.1.1 ${CONFIG_HOSTNAME}" >> /etc/hosts
  fi
}

apply_swap_auto_now() {
  local ram_mb current_swap rec_mb
  ram_mb="$(get_total_ram_mb)"
  current_swap="$(get_total_swap_mb)"
  rec_mb="$(recommended_swap_mb "$ram_mb")"

  if (( current_swap < rec_mb )); then
    if [[ -f /swapfile ]]; then
      swapoff /swapfile >> "$LOG_FILE" 2>&1 || true
      rm -f /swapfile
    fi
    if check_command fallocate; then
      fallocate -l "${rec_mb}M" /swapfile
    else
      dd if=/dev/zero of=/swapfile bs=1M count="${rec_mb}" status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  if [[ -f /swapfile ]]; then
    swapon /swapfile >> "$LOG_FILE" 2>&1 || swapon -a >> "$LOG_FILE" 2>&1 || true
  fi

  cat > "$SWAP_TUNING_FILE" <<'EOSWAP'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOSWAP
}

kernel_meta_ready() {
  case "$OS_ID" in
    ubuntu)
      dpkg -s linux-aws >/dev/null 2>&1 && dpkg -s linux-headers-aws >/dev/null 2>&1
      ;;
    debian)
      local arch="${SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
      if apt-cache show "linux-image-cloud-${arch}" >/dev/null 2>&1; then
        dpkg -s "linux-image-cloud-${arch}" >/dev/null 2>&1 && dpkg -s "linux-headers-cloud-${arch}" >/dev/null 2>&1
      else
        dpkg -s "linux-image-${arch}" >/dev/null 2>&1 && dpkg -s "linux-headers-${arch}" >/dev/null 2>&1
      fi
      ;;
    amzn|amazon)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

apply_kernel_auto_now() {
  case "$OS_ID" in
    ubuntu)
      kernel_meta_ready && return 0
      bash -c "$PKG_INSTALL linux-aws linux-headers-aws"
      ;;
    debian)
      local arch="${SYSTEM_ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
      kernel_meta_ready && return 0
      if apt-cache show "linux-image-cloud-${arch}" >/dev/null 2>&1; then
        bash -c "$PKG_INSTALL linux-image-cloud-${arch} linux-headers-cloud-${arch}"
      else
        bash -c "$PKG_INSTALL linux-image-${arch} linux-headers-${arch}"
      fi
      ;;
    amzn|amazon)
      return 0
      ;;
  esac
}

reboot_required_now() {
  case "$OS_ID" in
    ubuntu|debian)
      [[ -f /var/run/reboot-required ]]
      ;;
    amzn|amazon)
      if check_command needs-restarting; then
        needs-restarting -r >/dev/null 2>&1
      else
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

write_connection_tuning_files() {
  cat > "$NET_TUNING_FILE" <<'EONET'
# PrimeVPN network tuning
# Adaptado de um perfil de VPS/VPN, mas aplicado de forma segura e reversível.
# Não força DNS e não desativa IPv6.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=50000
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_tw_reuse=1
fs.file-max=2097152
EONET

  mkdir -p /etc/security/limits.d
  cat > "$LIMITS_FILE" <<'EOLIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOLIMITS
}

remove_connection_tuning_files() {
  rm -f "$NET_TUNING_FILE" "$LIMITS_FILE"
}


badvpn_binary_path() {
  if [[ -x /usr/local/bin/badvpn-udpgw ]]; then
    echo "/usr/local/bin/badvpn-udpgw"
  elif command -v badvpn-udpgw >/dev/null 2>&1; then
    command -v badvpn-udpgw
  else
    echo "/usr/local/bin/badvpn-udpgw"
  fi
}

badvpn_is_installed() {
  [[ -x "$(badvpn_binary_path)" ]]
}

badvpn_is_multiport() {
  [[ -f "$BADVPN_TEMPLATE_FILE" ]]
}

badvpn_is_optimized() {
  [[ -f "$BADVPN_SYSCTL_FILE" ]]
}

badvpn_parent_status() {
  if systemctl is-active --quiet badvpn; then
    echo "ATIVO"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^badvpn'; then
    echo "PARADO"
  else
    echo "NÃO INSTALADO"
  fi
}

badvpn_mode_label() {
  if ! badvpn_is_installed; then
    echo "N/D"
  elif badvpn_is_multiport; then
    echo "MULTIPORTA"
  else
    echo "PORTA ÚNICA"
  fi
}

badvpn_ports_display() {
  local ports=""
  if badvpn_is_multiport; then
    ports="$(systemctl list-units --type=service --state=running 2>/dev/null | awk '/badvpn@[0-9]+\.service/ { gsub(/.*@|\.service/, "", $1); print $1 }' | sort -n | tr '\n' ' ')"
    if [[ -z "$ports" ]]; then
      ports="${BADVPN_MULTI_PORTS[*]}"
    fi
  elif [[ -f "$BADVPN_SERVICE_FILE" ]]; then
    ports="$(systemctl cat badvpn 2>/dev/null | sed -n 's/.*--listen-addr [^:]*:\([0-9]\+\).*/\1/p' | head -n1)"
    [[ -z "$ports" ]] && ports="$BADVPN_SINGLE_PORT"
  fi
  if [[ -n "$ports" ]]; then
    echo "$ports"
  else
    echo "-"
  fi
}

install_badvpn_build_deps() {
  case "$OS_ID" in
    ubuntu|debian)
      bash -c "$PKG_INSTALL git cmake build-essential pkg-config make gcc g++" >> "$LOG_FILE" 2>&1
      ;;
    amzn|amazon)
      if check_command dnf; then
        bash -c "$PKG_INSTALL git cmake make gcc gcc-c++ pkgconf-pkg-config" >> "$LOG_FILE" 2>&1
      else
        bash -c "$PKG_INSTALL git cmake make gcc gcc-c++ pkgconfig" >> "$LOG_FILE" 2>&1
      fi
      ;;
  esac
}

sync_badvpn_source() {
  mkdir -p /usr/local/src
  if [[ -d "$BADVPN_SOURCE_DIR/.git" ]]; then
    git -C "$BADVPN_SOURCE_DIR" fetch --depth 1 origin >> "$LOG_FILE" 2>&1
    git -C "$BADVPN_SOURCE_DIR" reset --hard origin/master >> "$LOG_FILE" 2>&1
  else
    rm -rf "$BADVPN_SOURCE_DIR"
    git clone --depth 1 "$BADVPN_REPO_URL" "$BADVPN_SOURCE_DIR" >> "$LOG_FILE" 2>&1
  fi
}

build_install_badvpn_udpgw() {
  rm -rf "$BADVPN_BUILD_DIR"
  mkdir -p "$BADVPN_BUILD_DIR"
  cd "$BADVPN_BUILD_DIR"
  cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >> "$LOG_FILE" 2>&1
  cmake --build . -j"$(nproc)" >> "$LOG_FILE" 2>&1
  cmake --install . >> "$LOG_FILE" 2>&1
  test -x "$(badvpn_binary_path)"
}

badvpn_auto_detect_profile() {
  local ram_mb
  ram_mb="$(get_total_ram_mb 2>/dev/null || echo 0)"

  if (( ram_mb <= 0 )); then
    echo "MEDIUM"
  elif (( ram_mb <= 1024 )); then
    echo "LOW"
  elif (( ram_mb <= 4096 )); then
    echo "MEDIUM"
  else
    echo "HIGH"
  fi
}

badvpn_auto_detect_sndbuf() {
  case "$(badvpn_auto_detect_profile)" in
    LOW) echo "1048576" ;;
    MEDIUM) echo "2097152" ;;
    HIGH) echo "4194304" ;;
    *) echo "2097152" ;;
  esac
}

badvpn_auto_detect_max_clients() {
  case "$(badvpn_auto_detect_profile)" in
    LOW) echo "512" ;;
    MEDIUM) echo "1000" ;;
    HIGH) echo "2000" ;;
    *) echo "1000" ;;
  esac
}

badvpn_optimization_label() {
  if badvpn_is_optimized; then
    echo "AUTO $(badvpn_auto_detect_profile) $(badvpn_auto_detect_sndbuf)"
  else
    echo "INATIVA"
  fi
}

badvpn_buffer_arg() {
  # Auto detector por RAM do VPS.
  # Usa apenas parâmetro válido do badvpn-udpgw para evitar quebrar o serviço.
  if badvpn_is_optimized; then
    echo " --client-socket-sndbuf $(badvpn_auto_detect_sndbuf)"
  else
    echo ""
  fi
}

badvpn_max_clients_arg() {
  echo "$(badvpn_auto_detect_max_clients)"
}

write_badvpn_single_service() {
  local buffer_arg
  buffer_arg="$(badvpn_buffer_arg)"
  cat > "$BADVPN_SERVICE_FILE" <<EOF
[Unit]
Description=BadVPN UDPGW Service
After=network.target

[Service]
Type=simple
ExecStart=$(badvpn_binary_path) --listen-addr 0.0.0.0:${BADVPN_SINGLE_PORT} --max-clients $(badvpn_max_clients_arg)${buffer_arg} --loglevel warning
Restart=always
RestartSec=3
KillMode=process
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_badvpn_template_service() {
  local buffer_arg
  buffer_arg="$(badvpn_buffer_arg)"
  cat > "$BADVPN_TEMPLATE_FILE" <<EOF
[Unit]
Description=BadVPN UDPGW (%i)
After=network.target

[Service]
Type=simple
ExecStart=$(badvpn_binary_path) --listen-addr 0.0.0.0:%i --max-clients $(badvpn_max_clients_arg)${buffer_arg} --loglevel warning
Restart=always
RestartSec=3
KillMode=process
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_badvpn_parent_multi_service() {
  local requires=""
  local port
  for port in "${BADVPN_MULTI_PORTS[@]}"; do
    requires+="badvpn@${port}.service "
  done
  requires="${requires% }"
  cat > "$BADVPN_SERVICE_FILE" <<EOF
[Unit]
Description=BadVPN UDPGW (Multi-Port)
After=network.target
Requires=${requires}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF
}

badvpn_disable_all_units() {
  local port
  systemctl stop badvpn >> "$LOG_FILE" 2>&1 || true
  systemctl disable badvpn >> "$LOG_FILE" 2>&1 || true
  for port in "${BADVPN_MULTI_PORTS[@]}"; do
    systemctl stop "badvpn@${port}" >> "$LOG_FILE" 2>&1 || true
    systemctl disable "badvpn@${port}" >> "$LOG_FILE" 2>&1 || true
  done
}

apply_badvpn_single_mode() {
  badvpn_disable_all_units
  rm -f "$BADVPN_TEMPLATE_FILE"
  write_badvpn_single_service
  systemctl daemon-reload >> "$LOG_FILE" 2>&1
  systemctl enable badvpn >> "$LOG_FILE" 2>&1
  systemctl restart badvpn >> "$LOG_FILE" 2>&1
}

apply_badvpn_multiport_mode() {
  local port
  badvpn_disable_all_units
  write_badvpn_template_service
  write_badvpn_parent_multi_service
  systemctl daemon-reload >> "$LOG_FILE" 2>&1
  for port in "${BADVPN_MULTI_PORTS[@]}"; do
    systemctl enable "badvpn@${port}" >> "$LOG_FILE" 2>&1
    systemctl restart "badvpn@${port}" >> "$LOG_FILE" 2>&1
  done
  systemctl enable badvpn >> "$LOG_FILE" 2>&1
  systemctl restart badvpn >> "$LOG_FILE" 2>&1
}

write_badvpn_optimization_file() {
  local profile rmem wmem backlog udp_mem
  profile="$(badvpn_auto_detect_profile)"

  case "$profile" in
    LOW)
      rmem=4194304
      wmem=4194304
      backlog=10000
      udp_mem="32768 65536 131072"
      ;;
    MEDIUM)
      rmem=8388608
      wmem=8388608
      backlog=25000
      udp_mem="65536 131072 262144"
      ;;
    HIGH)
      rmem=16777216
      wmem=16777216
      backlog=50000
      udp_mem="65536 131072 262144"
      ;;
    *)
      rmem=8388608
      wmem=8388608
      backlog=25000
      udp_mem="65536 131072 262144"
      ;;
  esac

  cat > "$BADVPN_SYSCTL_FILE" <<EOF
# PrimeVPN BadVPN tuning
# Perfil automático detectado: ${profile}
net.core.rmem_max = ${rmem}
net.core.wmem_max = ${wmem}
net.core.netdev_max_backlog = ${backlog}
net.ipv4.udp_mem = ${udp_mem}
EOF
}

remove_badvpn_optimization_file() {
  rm -f "$BADVPN_SYSCTL_FILE"
}

install_or_update_badvpn() {
  header
  echo -e "${BOLD}Instalar/atualizar BadVPN${NC}"
  line

  local keep_multi="false"
  badvpn_is_multiport && keep_multi="true"

  progress_start 5
  run_step "Instalando dependências de build" "install_badvpn_build_deps"
  run_step "Sincronizando código-fonte do BadVPN" "sync_badvpn_source"
  run_step "Compilando e instalando badvpn-udpgw" "build_install_badvpn_udpgw"
  if [[ "$keep_multi" == "true" ]]; then
    run_step "Restaurando modo multiporta" "apply_badvpn_multiport_mode"
  else
    run_step "Criando serviço BadVPN" "apply_badvpn_single_mode"
  fi
  run_step "Validando serviço BadVPN" "systemctl status badvpn --no-pager"
  echo
  ok "BadVPN instalado/atualizado com sucesso."
  pause
}

restart_badvpn_current() {
  header
  echo -e "${BOLD}Reiniciar BadVPN${NC}"
  line

  if ! badvpn_is_installed || [[ ! -f "$BADVPN_SERVICE_FILE" ]]; then
    warn "BadVPN ainda não está instalado."
    pause
    return
  fi

  progress_start 2
  if badvpn_is_multiport; then
    run_step "Reiniciando serviço pai e instâncias" "apply_badvpn_multiport_mode"
  else
    run_step "Reiniciando serviço BadVPN" "systemctl restart badvpn"
  fi
  run_step "Validando status" "systemctl status badvpn --no-pager"
  echo
  ok "BadVPN reiniciado."
  pause
}

enable_badvpn_multiport() {
  header
  echo -e "${BOLD}Ativar modo multiporta${NC}"
  line

  if ! badvpn_is_installed; then
    warn "Instale o BadVPN primeiro."
    pause
    return
  fi

  progress_start 3
  run_step "Criando template multiporta" "write_badvpn_template_service && write_badvpn_parent_multi_service"
  run_step "Ativando portas ${BADVPN_MULTI_PORTS[*]}" "apply_badvpn_multiport_mode"
  run_step "Validando portas do serviço" "systemctl status badvpn --no-pager"
  echo
  ok "Modo multiporta ativo em: ${BADVPN_MULTI_PORTS[*]}"
  pause
}

restart_badvpn_multiport() {
  header
  echo -e "${BOLD}Reiniciar multiporta${NC}"
  line

  if ! badvpn_is_multiport; then
    warn "O modo multiporta não está ativo."
    pause
    return
  fi

  progress_start 2
  run_step "Reiniciando instâncias multiporta" "apply_badvpn_multiport_mode"
  run_step "Validando portas ativas" "systemctl status badvpn --no-pager"
  echo
  ok "Multiporta reiniciado."
  pause
}

remove_badvpn_multiport() {
  header
  echo -e "${BOLD}Remover multiporta e voltar para porta única${NC}"
  line

  if ! badvpn_is_installed; then
    warn "BadVPN ainda não está instalado."
    pause
    return
  fi

  progress_start 3
  run_step "Desativando modo multiporta" "apply_badvpn_single_mode"
  run_step "Limpando template multiporta" "rm -f '$BADVPN_TEMPLATE_FILE' && systemctl daemon-reload"
  run_step "Validando porta única ${BADVPN_SINGLE_PORT}" "systemctl status badvpn --no-pager"
  echo
  ok "BadVPN voltou para porta única ${BADVPN_SINGLE_PORT}."
  pause
}

toggle_badvpn_optimization() {
  header
  echo -e "${BOLD}Aplicar/reverter otimização do BadVPN${NC}"
  line

  if ! badvpn_is_installed; then
    warn "Instale o BadVPN primeiro."
    pause
    return
  fi

  if badvpn_is_optimized; then
    progress_start 4
    run_step "Removendo tuning do BadVPN" "remove_badvpn_optimization_file"
    if badvpn_is_multiport; then
      run_step "Regenerando serviço multiporta sem buffer extra" "apply_badvpn_multiport_mode"
    else
      run_step "Regenerando serviço simples sem buffer extra" "apply_badvpn_single_mode"
    fi
    run_step "Recarregando parâmetros de rede" "sysctl --system"
    run_step "Concluindo reversão" "true"
    echo
    ok "Otimização do BadVPN revertida."
  else
    progress_start 4
    run_step "Aplicando tuning dedicado do BadVPN" "write_badvpn_optimization_file"
    if badvpn_is_multiport; then
      run_step "Regenerando serviço multiporta otimizado" "apply_badvpn_multiport_mode"
    else
      run_step "Regenerando serviço simples otimizado" "apply_badvpn_single_mode"
    fi
    run_step "Recarregando parâmetros de rede" "sysctl --system"
    run_step "Concluindo aplicação" "true"
    echo
    ok "Otimização do BadVPN aplicada."
  fi
  pause
}

uninstall_badvpn_completely() {
  header
  echo -e "${BOLD}Remover BadVPN${NC}"
  line

  progress_start 5
  run_step "Parando e desabilitando serviços" "badvpn_disable_all_units"
  run_step "Removendo units do systemd" "rm -f '$BADVPN_SERVICE_FILE' '$BADVPN_TEMPLATE_FILE' && systemctl daemon-reload"
  run_step "Removendo tuning dedicado" "remove_badvpn_optimization_file && sysctl --system"
  run_step "Removendo binário e fonte" "rm -f /usr/local/bin/badvpn-udpgw && rm -rf '$BADVPN_SOURCE_DIR' '$BADVPN_BUILD_DIR'"
  run_step "Concluindo remoção" "systemctl daemon-reexec || true"
  echo
  ok "BadVPN removido do sistema."
  pause
}

badvpn_menu_header() {
  header
  echo -e "${BOLD}Gerenciar BadVPN${NC}"
  line
  echo -e "${CYAN}Status:${NC} $(badvpn_parent_status)    ${CYAN}Modo:${NC} $(badvpn_mode_label)"
  echo -e "${CYAN}Portas:${NC} $(badvpn_ports_display)    ${CYAN}Otimização:${NC} $(badvpn_is_optimized && echo ATIVA || echo INATIVA)"
  line
  echo
}

badvpn_menu() {
  while true; do
    local width top mid bot status modo portas optim
    status="$(badvpn_parent_status)"
    modo="$(badvpn_mode_label)"
    portas="$(badvpn_ports_display | xargs)"
    optim="$(badvpn_optimization_label)"

    header
    width="$(menu_width)"
    top="╔$(hline $((width-2)))╗"
    mid="╠$(hline $((width-2)))╣"
    bot="╚$(hline $((width-2)))╝"

    echo "  $top"
    echo "  $(center_line "${WHITE}${BOLD}GERENCIAR BADVPN${NC}" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "Status [${status}]" "Modo [${modo}]" "$width")"
    echo "  $(two_col_line "Portas [${portas:-N/D}]" "Otimização [${optim}]" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "$(menu_item 1 'Instalar/atualizar BadVPN')" "$(menu_item 6 'Toggle otimização')" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Reiniciar BadVPN')" "$(menu_item 7 'Remover BadVPN')" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Ativar multiporta')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 4 'Reiniciar multiporta')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 5 'Remover multiporta')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Voltar')" "" "$width")"
    echo "  $bot"
    echo
    printf "${CYAN}Escolha somente a opção: ${NC}"
    wait_key_menu

    case "$MENU_KEY" in
      1) install_or_update_badvpn ;;
      2) restart_badvpn_current ;;
      3) enable_badvpn_multiport ;;
      4) restart_badvpn_multiport ;;
      5) remove_badvpn_multiport ;;
      6) toggle_badvpn_optimization ;;
      7) uninstall_badvpn_completely ;;
      0) return 0 ;;
      *) warn "Opção inválida."; pause ;;
    esac
  done
}

auto_prepare_system() {
  header
  echo -e "${BOLD}Preparação automática do sistema${NC}"
  echo -e "${DIM}Hostname fixo: ${CONFIG_HOSTNAME} | Timezone fixa: ${CONFIG_TIMEZONE}${NC}"
  line

  local swap_rec kernel_ready_before
  swap_rec="$(recommended_swap_mb "$(get_total_ram_mb)")"
  kernel_ready_before='no'
  kernel_meta_ready && kernel_ready_before='yes'
  log "PREPARE: hostname=$CONFIG_HOSTNAME timezone=$CONFIG_TIMEZONE swap_recommended=${swap_rec}MB kernel_meta_ready_before=${kernel_ready_before}"

  progress_start 6
  run_step "Atualizando repositórios" "$PKG_UPDATE"
  run_step "Atualizando pacotes do sistema" "$PKG_UPGRADE"
  run_step "Instalando utilitários base" "install_base_tools"
  run_step "Definindo hostname para ${CONFIG_HOSTNAME}" "apply_hostname_now"
  run_step "Definindo timezone para São Paulo" "timedatectl set-timezone '${CONFIG_TIMEZONE}'"
  run_step "Ativando swap e validando kernel somente se necessário" "apply_swap_auto_now && apply_kernel_auto_now && sysctl --system"
  echo
  ok "Preparação automática concluída."
  if reboot_required_now; then
    warn "Há uma reinicialização pendente para aplicar kernel e/ou atualizações do sistema."
  fi
  pause
}

change_root_password() {
  header
  echo -e "${BOLD}Alterar senha do root${NC}"
  line

  ask_root_password

  progress_start 2
  run_step "Aplicando nova senha do root" "echo 'root:${ROOT_PASSWORD}' | chpasswd"
  ROOT_PASSWORD=""
  run_step "Concluindo alteração" "true"
  echo
  ok "Senha do root alterada com sucesso."
  pause
}

toggle_connection_improvements() {
  header
  echo -e "${BOLD}Aplicar/reverter melhorias de conexão${NC}"
  line

  if [[ -f "$NET_TUNING_FILE" ]]; then
    progress_start 3
    run_step "Removendo tuning de rede" "remove_connection_tuning_files"
    run_step "Recarregando parâmetros do sistema" "sysctl --system"
    run_step "Concluindo reversão" "true"
    echo
    ok "Melhorias de conexão revertidas."
  else
    progress_start 4
    run_step "Aplicando parâmetros de rede" "write_connection_tuning_files"
    run_step "Recarregando parâmetros do sistema" "sysctl --system"
    run_step "Validando congestion control" "sysctl net.ipv4.tcp_congestion_control"
    run_step "Concluindo aplicação" "true"
    echo
    ok "Melhorias de conexão aplicadas."
  fi

  echo -e "${DIM}Status atual: $(connection_tuning_status)${NC}"
  pause
}

dragoncore_installed() {
  [[ -x "/opt/DragonCore/menu" || -x "/bin/menu" ]]
}

dragoncore_systemd_installed() {
  [[ -f "$DRAGONCORE_SYSTEMD_SERVICE" ]]
}

prune_dragoncore_cron_autostart() {
  local current_cron filtered
  current_cron="$(crontab -l 2>/dev/null || true)"
  filtered="$(printf '%s
' "$current_cron" | grep -Fv '@reboot sleep 30 && /usr/bin/php /opt/DragonCore/menu.php autostart' || true)"
  if [[ "$current_cron" != "$filtered" ]]; then
    if [[ -n "$filtered" ]]; then
      printf '%s
' "$filtered" | crontab -
    else
      crontab -r >/dev/null 2>&1 || true
    fi
  fi
}

write_dragoncore_systemd_service() {
  cat > "$DRAGONCORE_SYSTEMD_SERVICE" <<'EOF'
[Unit]
Description=DragonCoreSSH Autostart
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=/opt/DragonCore
ExecStart=/usr/bin/php /opt/DragonCore/menu.php autostart
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

sync_dragoncore_systemd() {
  if dragoncore_installed && [[ -f /opt/DragonCore/menu.php ]] && check_command php; then
    write_dragoncore_systemd_service
    prune_dragoncore_cron_autostart
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    systemctl enable dragoncore-autostart >> "$LOG_FILE" 2>&1 || true
    systemctl start dragoncore-autostart >> "$LOG_FILE" 2>&1 || true
  else
    systemctl stop dragoncore-autostart >> "$LOG_FILE" 2>&1 || true
    systemctl disable dragoncore-autostart >> "$LOG_FILE" 2>&1 || true
    rm -f "$DRAGONCORE_SYSTEMD_SERVICE"
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
  fi
}

checkuser_systemd_sync() {
  local service_file="/etc/systemd/system/checkuser.service"
  local binary_file="/usr/local/bin/checkuser"

  if [[ -f "$service_file" && -x "$binary_file" ]]; then
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    systemctl enable checkuser >> "$LOG_FILE" 2>&1 || true
    systemctl restart checkuser >> "$LOG_FILE" 2>&1 || systemctl start checkuser >> "$LOG_FILE" 2>&1 || true
  elif [[ -f "$service_file" && ! -x "$binary_file" ]]; then
    systemctl stop checkuser >> "$LOG_FILE" 2>&1 || true
    systemctl disable checkuser >> "$LOG_FILE" 2>&1 || true
    rm -f "$service_file"
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
  fi
}

sync_external_systemd_integrations() {
  sync_dragoncore_systemd
  checkuser_systemd_sync
}

prepare_swap_ready() {
  local current_swap rec_mb ram_mb
  ram_mb="$(get_total_ram_mb)"
  current_swap="$(get_total_swap_mb)"
  rec_mb="$(recommended_swap_mb "$ram_mb")"
  (( current_swap >= rec_mb && current_swap > 0 ))
}

prepare_kernel_ready() {
  case "$OS_ID" in
    ubuntu|debian)
      kernel_meta_ready && return 0
      ;;
    amzn|amazon)
      rpm -q kernel >/dev/null 2>&1 && return 0
      ;;
  esac
  return 1
}

prepare_system_status() {
  local score=0
  local tz_now host_now
  host_now="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo '-')"
  tz_now="$(timedatectl show --property=Timezone --value 2>/dev/null || echo '-')"

  [[ "$host_now" == "$CONFIG_HOSTNAME" ]] && score=$((score+1))
  [[ "$tz_now" == "$CONFIG_TIMEZONE" ]] && score=$((score+1))
  prepare_swap_ready && score=$((score+1))
  prepare_kernel_ready && score=$((score+1))

  if (( score == 4 )); then
    echo 'PRONTO'
  elif (( score == 0 )); then
    echo 'PENDENTE'
  else
    echo "${score}/4 OK"
  fi
}

root_password_status() {
  local status
  status="$(passwd -S root 2>/dev/null | awk '{print $2}' | head -n1)"
  case "$status" in
    P|PS) echo 'DEFINIDA' ;;
    L|LK|NL) echo 'BLOQUEADA' ;;
    NP) echo 'SEM SENHA' ;;
    *) echo 'DESCONHECIDO' ;;
  esac
}

badvpn_menu_status() {
  if ! badvpn_is_installed; then
    echo 'NÃO INSTALADO'
  elif badvpn_is_multiport; then
    echo "MULTI $(badvpn_ports_display | xargs)"
  else
    echo "PORTA $(badvpn_ports_display | xargs)"
  fi
}

dragoncore_menu_status() {
  if dragoncore_installed; then
    if dragoncore_systemd_installed && systemctl is-enabled --quiet dragoncore-autostart 2>/dev/null; then
      echo 'INSTALADO+SYSTEMD'
    else
      echo 'INSTALADO'
    fi
  else
    echo 'NÃO INSTALADO'
  fi
}

checkuser_installed() {
  [[ -x "/usr/local/bin/checkuser" || -f "/etc/systemd/system/checkuser.service" ]]
}

checkuser_menu_status() {
  if checkuser_installed; then
    local prefix='INSTALADO'
    systemctl is-enabled --quiet checkuser 2>/dev/null && prefix='INSTALADO+SYSTEMD'
    if [[ -x "/usr/local/bin/checkuser" ]]; then
      local ver
      ver="$(/usr/local/bin/checkuser --version 2>/dev/null | awk 'NR==1{print $2}' | tr -d '[:space:]')"
      if [[ -n "${ver:-}" ]]; then
        echo "${prefix} ${ver}"
      else
        echo "$prefix"
      fi
    else
      echo "$prefix"
    fi
  else
    echo 'NÃO INSTALADO'
  fi
}

checkuser_open_menu() {
  launch_external_menu "Menu CheckUser DTunnel" "install_base_tools && bash <(curl -sL '${CHECKUSER_INSTALL_URL}')"
  checkuser_systemd_sync
}

reinstaller_installed() {
  [[ -x "/usr/local/bin/vps-reinstaller" ]]
}

reinstaller_menu_status() {
  if reinstaller_installed; then
    echo 'INSTALADO'
  else
    echo 'NÃO INSTALADO'
  fi
}

launch_external_menu() {
  local title="$1"
  local cmd="$2"

  header
  echo -e "${BOLD}${title}${NC}"
  line
  echo -e "${DIM}Abrindo o menu oficial desta ferramenta...${NC}"
  line

  log "EXTERNAL MENU: $title | CMD: $cmd"
  if bash -lc "$cmd"; then
    stty sane >/dev/null 2>&1 || true
    echo
    ok "Menu finalizado."
  else
    local rc=$?
    stty sane >/dev/null 2>&1 || true
    echo
    warn "O menu retornou com código ${rc}. Verifique se a ferramenta já estava instalada corretamente."
  fi
  pause
}

reinstaller_open_menu() {
  header
  echo -e "${BOLD}Formatar Servidor${NC}"
  line

  if reinstaller_installed; then
    launch_external_menu "Menu Formatar Servidor" "/usr/local/bin/vps-reinstaller"
    return
  fi

  echo -e "${DIM}O reinstalador ainda não está instalado. Instalando agora e abrindo o menu em seguida...${NC}"
  line
  progress_start 5
  run_step "Garantindo dependências mínimas" "install_base_tools && (${PKG_INSTALL} wget curl git jq || true)"
  run_step "Baixando instalador VPS Reinstaller" "curl -fsSL '${REINSTALLER_INSTALL_URL}' >/dev/null"
  run_step "Executando instalador remoto" "cd /root && bash <(wget -qO- '${REINSTALLER_INSTALL_URL}')"
  run_step "Publicando binário no sistema" "test -x /root/vps-reinstaller && install -m 0755 /root/vps-reinstaller /usr/local/bin/vps-reinstaller"
  run_step "Validando instalação" "test -x /usr/local/bin/vps-reinstaller"
  echo
  ok "Reinstalador instalado. Abrindo o menu agora..."
  sleep 0.2
  launch_external_menu "Menu Formatar Servidor" "/usr/local/bin/vps-reinstaller"
}

render_menu_item() {
  local number="$1"
  local title="$2"
  local status="$3"
  local color
  color="$(status_color "$status")"
  printf '%s %s %b[%s]%b' "$(format_option "$number")" "$title" "$color" "$status" "$NC"
}

render_menu_item_plain() {
  local number="$1"
  local title="$2"
  printf '%s %s' "$(format_option "$number")" "$title"
}

dragoncore_open_menu() {
  header
  echo -e "${BOLD}DragonCoreSSH-Beta${NC}"
  line

  if dragoncore_installed; then
    launch_external_menu "Menu DragonCoreSSH-Beta" "if [ -x /opt/DragonCore/menu ]; then /opt/DragonCore/menu; elif [ -x /bin/menu ]; then bash /bin/menu; else exit 1; fi"
    sync_dragoncore_systemd
    return
  fi

  echo -e "${DIM}O DragonCore ainda não está instalado. Instalando agora e abrindo o menu em seguida...${NC}"
  line
  progress_start 4
  run_step "Garantindo dependências mínimas" "install_base_tools && (${PKG_INSTALL} wget curl git || true)"
  run_step "Baixando instalador DragonCoreSSH-Beta" "wget -q --spider '${DRAGONCORE_INSTALL_URL}'"
  run_step "Executando instalador remoto" "bash <(wget -qO- '${DRAGONCORE_INSTALL_URL}')"
  run_step "Validando instalação" "test -x /opt/DragonCore/menu -o -x /bin/menu"
  echo
  ok "DragonCoreSSH-Beta instalado. Abrindo o menu agora..."
  sleep 0.2
  launch_external_menu "Menu DragonCoreSSH-Beta" "if [ -x /opt/DragonCore/menu ]; then /opt/DragonCore/menu; elif [ -x /bin/menu ]; then bash /bin/menu; else exit 1; fi"
  sync_dragoncore_systemd
}


limiter_installed() {
  [[ -x "$LIMITER_BIN" || -f "$LIMITER_SERVICE_FILE" ]]
}

limiter_active() {
  systemctl is-active --quiet primevpn-limiter 2>/dev/null
}

limiter_user_count() {
  [[ -f "$LIMITER_DB" ]] || { echo 0; return; }
  awk 'NF >= 2 && $1 !~ /^#/ {count++} END {print count+0}' "$LIMITER_DB"
}

limiter_menu_status() {
  if limiter_active; then
    echo "ATIVO $(limiter_user_count)"
  elif limiter_installed; then
    echo "PARADO $(limiter_user_count)"
  else
    echo 'NÃO INSTALADO'
  fi
}

xray_binary_path() {
  local candidate
  for candidate in /usr/local/bin/xray /usr/bin/xray; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  if check_command xray; then
    command -v xray
    return 0
  fi
  return 1
}

xray_config_path() {
  local candidate
  for candidate in /usr/local/etc/xray/config.json /etc/xray/config.json; do
    [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  return 1
}

xray_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
    echo 'xray'
  else
    echo 'xray'
  fi
}

xray_installed() {
  xray_binary_path >/dev/null 2>&1 || xray_config_path >/dev/null 2>&1
}

xray_support_enabled() {
  local cfg
  cfg="$(xray_config_path 2>/dev/null || true)"
  [[ -n "$cfg" ]] || return 1
  jq -e '.stats != null and .api != null and ((.api.services // []) | index("StatsService")) != null' "$cfg" >/dev/null 2>&1
}

xray_test_config_file() {
  local file="$1"
  local xb
  xb="$(xray_binary_path 2>/dev/null || true)"
  [[ -n "$xb" ]] || return 0
  "$xb" run -test -config "$file" >/dev/null 2>&1 && return 0
  "$xb" -test -config "$file" >/dev/null 2>&1 && return 0
  return 1
}

xray_enable_api_and_stats() {
  local cfg tmp backup svc
  cfg="$(xray_config_path)"
  tmp="$(mktemp)"
  backup="${cfg}.primevpn.bak.$(date +%s)"
  svc="$(xray_service_name)"

  cp -f "$cfg" "$backup"

  jq '
    .stats = (.stats // {}) |
    .api = ((.api // {}) + {tag:"api"}) |
    .api.services = (((.api.services // []) + ["StatsService"]) | unique) |
    .policy = (.policy // {}) |
    .policy.system = ((.policy.system // {}) + {
      statsInboundUplink: true,
      statsInboundDownlink: true,
      statsOutboundUplink: true,
      statsOutboundDownlink: true
    }) |
    .policy.levels = (
      if (.policy.levels // null) == null or ((.policy.levels | keys | length) == 0) then
        {"0": {statsUserUplink: true, statsUserDownlink: true, statsUserOnline: true}}
      else
        (.policy.levels | with_entries(.value = ((.value // {}) + {
          statsUserUplink: true,
          statsUserDownlink: true,
          statsUserOnline: true
        })))
      end
    ) |
    .inbounds = ((.inbounds // []) |
      if map(.tag == "api") | any then .
      else . + [{"listen":"127.0.0.1","port":10085,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"},"tag":"api"}]
      end) |
    .routing = (.routing // {}) |
    .routing.rules = ((.routing.rules // []) |
      if map((.outboundTag // "") == "api") | any then .
      else . + [{"type":"field","inboundTag":["api"],"outboundTag":"api"}]
      end)
  ' "$cfg" > "$tmp"

  xray_test_config_file "$tmp"
  cp -f "$tmp" "$cfg"
  rm -f "$tmp"
  systemctl restart "$svc" >> "$LOG_FILE" 2>&1 || true
}

xray_auto_tuning_active() {
  [[ -f "$XRAY_TUNING_MARKER" ]]
}

xray_auto_tuning_targets_summary() {
  local cfg
  cfg="$(xray_config_path 2>/dev/null || true)"
  [[ -n "$cfg" && -f "$cfg" ]] || { echo "SEM ALVO"; return 0; }

  python3 - "$cfg" <<'PYCODE'
import json, sys
src = sys.argv[1]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)
found = {"xhttp_tls": 0, "tcp_tls": 0, "reality": 0}

def match(node):
    if not isinstance(node, dict):
        return None
    if str(node.get('protocol', '')).lower() != 'vless':
        return None
    ss = node.get('streamSettings')
    if not isinstance(ss, dict):
        return None
    network = str(ss.get('network', '')).lower()
    security = str(ss.get('security', '')).lower()
    if network == 'xhttp' and security == 'tls':
        return 'xhttp_tls'
    if network in ('tcp', 'raw') and security == 'tls':
        return 'tcp_tls'
    if security == 'reality':
        return 'reality'
    return None

def walk(node):
    if isinstance(node, dict):
        kind = match(node)
        if kind:
            found[kind] += 1
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(data)
parts = []
if found['xhttp_tls']:
    parts.append(f"XHTTP/TLS:{found['xhttp_tls']}")
if found['tcp_tls']:
    parts.append(f"TCP/TLS:{found['tcp_tls']}")
if found['reality']:
    parts.append(f"REALITY:{found['reality']}")
print(' | '.join(parts) if parts else 'SEM ALVO')
PYCODE
}

xray_auto_tuning_status() {
  if ! xray_installed; then
    echo "SEM XRAY"
  elif xray_auto_tuning_active; then
    echo "ATIVO"
  else
    echo "INATIVO"
  fi
}

xray_apply_auto_tuning_core() {
  local cfg tmp meta_json
  cfg="$(xray_config_path)"
  tmp="$(mktemp)"
  mkdir -p "$XRAY_TUNING_DIR"

  cp -f "$cfg" "$XRAY_TUNING_BACKUP"

  meta_json="$(python3 - "$cfg" "$tmp" "$XRAY_TUNING_META" <<'PYCODE'
import json, sys
src, dst, meta = sys.argv[1:4]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)
counts = {"xhttp_tls": 0, "tcp_tls": 0, "reality": 0}

def match(node):
    if not isinstance(node, dict):
        return None, None
    if str(node.get('protocol', '')).lower() != 'vless':
        return None, None
    ss = node.get('streamSettings')
    if not isinstance(ss, dict):
        return None, None
    network = str(ss.get('network', '')).lower()
    security = str(ss.get('security', '')).lower()
    if network == 'xhttp' and security == 'tls':
        return 'xhttp_tls', ss
    if network in ('tcp', 'raw') and security == 'tls':
        return 'tcp_tls', ss
    if security == 'reality':
        return 'reality', ss
    return None, None

def apply_sockopt(ss, kind):
    sock = ss.setdefault('sockopt', {})
    sock['tcpCongestion'] = 'bbr'
    sock['tcpKeepAliveIdle'] = 300
    sock['tcpKeepAliveInterval'] = 30
    sock['tcpUserTimeout'] = 10000
    if kind in ('tcp_tls', 'reality'):
        sock['tcpWindowClamp'] = 600

def walk(node):
    if isinstance(node, dict):
        kind, ss = match(node)
        if kind:
            apply_sockopt(ss, kind)
            counts[kind] += 1
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(data)
if sum(counts.values()) < 1:
    raise SystemExit(11)
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('
')
with open(meta, 'w', encoding='utf-8') as f:
    json.dump(counts, f, ensure_ascii=False)
print(json.dumps(counts, ensure_ascii=False))
PYCODE
)"

  xray_test_config_file "$tmp"
  cp -f "$tmp" "$cfg"
  rm -f "$tmp"
  touch "$XRAY_TUNING_MARKER"
  printf '%s
' "$meta_json" > "$XRAY_TUNING_META"
}

xray_revert_auto_tuning_core() {
  local cfg tmp
  cfg="$(xray_config_path)"
  tmp="$(mktemp)"
  mkdir -p "$XRAY_TUNING_DIR"

  if [[ -f "$XRAY_TUNING_BACKUP" ]]; then
    cp -f "$XRAY_TUNING_BACKUP" "$tmp"
  else
    python3 - "$cfg" "$tmp" <<'PYCODE'
import json, sys
src, dst = sys.argv[1:3]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)
expected = {
    'tcpCongestion': 'bbr',
    'tcpKeepAliveIdle': 300,
    'tcpKeepAliveInterval': 30,
    'tcpUserTimeout': 10000,
    'tcpWindowClamp': 600,
}

def walk(node):
    if isinstance(node, dict):
        if str(node.get('protocol', '')).lower() == 'vless':
            ss = node.get('streamSettings')
            if isinstance(ss, dict):
                sock = ss.get('sockopt')
                if isinstance(sock, dict):
                    for key, value in expected.items():
                        if sock.get(key) == value:
                            sock.pop(key, None)
                    if not sock:
                        ss.pop('sockopt', None)
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(data)
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('
')
PYCODE
  fi

  xray_test_config_file "$tmp"
  cp -f "$tmp" "$cfg"
  rm -f "$tmp"
  rm -f "$XRAY_TUNING_MARKER" "$XRAY_TUNING_META" "$XRAY_TUNING_BACKUP"
}

restart_xray_if_present() {

  local svc
  svc="$(xray_service_name)"
  if systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
    systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
    systemctl restart "$svc" >> "$LOG_FILE" 2>&1
    systemctl is-active --quiet "$svc"
  else
    return 0
  fi
}

toggle_xray_auto_tuning() {
  header
  echo -e "${BOLD}Aplicar/reverter melhorador XRAY automático${NC}"
  line

  if ! xray_installed; then
    warn "XRAY não encontrado neste servidor."
    pause
    return
  fi

  progress_start 4
  run_step "Garantindo dependências do melhorador XRAY" "install_base_tools && (${PKG_INSTALL} python3 jq >/dev/null 2>&1 || true)"
  run_step "Preparando suporte API/Stats do XRAY" "xray_enable_api_and_stats || true"

  if xray_auto_tuning_active; then
    run_step "Revertendo melhorador XRAY automático" "xray_revert_auto_tuning_core"
  else
    run_step "Aplicando melhorador XRAY automático" "xray_apply_auto_tuning_core"
  fi

  run_step "Validando e reiniciando o XRAY" "restart_xray_if_present"
  run_step "Concluindo" "true"
  echo

  if xray_auto_tuning_active; then
    ok "Melhorador XRAY automático ativado."
    [[ -f "$XRAY_TUNING_META" ]] && echo -e "${DIM}Alvos ajustados: $(xray_auto_tuning_targets_summary)${NC}"
  else
    ok "Melhorador XRAY automático revertido."
  fi
  pause
}

dragoncore_php_entry() {
  if [[ -f /opt/DragonCore/menu.php ]]; then
    echo '/opt/DragonCore/menu.php'
    return 0
  fi
  return 1
}

dragoncore_cli_ready() {
  check_command php && dragoncore_php_entry >/dev/null 2>&1
}

dragoncore_limit_for_user() {
  local user="$1"
  local out php_entry
  php_entry="$(dragoncore_php_entry 2>/dev/null || true)"
  [[ -n "$php_entry" ]] || return 1
  out="$(php "$php_entry" printlim2 "$user" 2>/dev/null || true)"
  awk 'match($0,/[0-9]+/){print substr($0,RSTART,RLENGTH); exit}' <<< "$out"
}

limiter_candidate_users() {
  {
    [[ -f /root/usuarios.db ]] && awk 'NF >= 1 && $1 !~ /^#/ {print $1}' /root/usuarios.db
    awk -F: '$3 >= 1000 && $1 != "nobody" && $7 !~ /(nologin|false)/ {print $1}' /etc/passwd
  } | awk 'NF' | sort -u
}

sync_limiter_db_from_dragoncore() {
  local tmp user limit count=0
  mkdir -p "$LIMITER_DIR"
  tmp="$(mktemp)"

  while IFS= read -r user; do
    [[ -n "$user" ]] || continue
    limit="$(dragoncore_limit_for_user "$user" 2>/dev/null || true)"
    [[ -n "$limit" ]] || continue
    [[ "$limit" =~ ^[0-9]+$ ]] || continue
    (( limit > 0 )) || continue
    printf '%s %s both\n' "$user" "$limit" >> "$tmp"
    count=$((count+1))
  done < <(limiter_candidate_users)

  if (( count > 0 )); then
    mv -f "$tmp" "$LIMITER_DB"
  else
    rm -f "$tmp"
    return 1
  fi
}

write_limiter_core_script() {
  mkdir -p "$LIMITER_DIR"
  cat > "$LIMITER_BIN" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DB="/etc/primevpn/limiter/limits.db"
STATUS_FILE="/etc/primevpn/limiter/status.tsv"
LOGFILE="/var/log/primevpn-limiter.log"
INTERVAL=2
XRAY_API_SERVER="127.0.0.1:10085"

mkdir -p /etc/primevpn/limiter
: > "$LOGFILE"

log(){
  echo "[$(date '+%F %T')] $*" >> "$LOGFILE"
}

detect_xray_bin(){
  local c
  for c in /usr/local/bin/xray /usr/bin/xray; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  command -v xray 2>/dev/null || return 1
}

refresh_xray_cache(){
  XRAY_STATS_CACHE=""
  local xb
  xb="$(detect_xray_bin 2>/dev/null || true)"
  [[ -n "$xb" ]] || return 0
  XRAY_STATS_CACHE="$($xb api statsquery --server="$XRAY_API_SERVER" 2>/dev/null || true)"
}

xray_online_from_cache(){
  local user="$1" line
  [[ -n "${XRAY_STATS_CACHE:-}" ]] || { echo 0; return; }
  line="$(printf '%s\n' "$XRAY_STATS_CACHE" | grep -F "user>>>${user}>>>online" | head -n1 || true)"
  if [[ "$line" =~ value:[[:space:]]*([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 0
  fi
}

ssh_pids_for_user(){
  local user="$1"
  ps -u "$user" -o pid=,comm= 2>/dev/null | awk '$2 ~ /^sshd$/ {print $1}'
}

count_ssh_sessions(){
  local user="$1"
  ssh_pids_for_user "$user" | awk 'NF{count++} END{print count+0}'
}

kill_excess_ssh(){
  local user="$1" allowed="$2" count killn
  mapfile -t pids < <(ssh_pids_for_user "$user")
  count="${#pids[@]}"
  (( count > allowed )) || return 0
  killn=$((count - allowed))
  local i
  for ((i=0; i<killn; i++)); do
    kill -9 "${pids[$i]}" 2>/dev/null || true
  done
  log "$user SSH_LIMIT_EXCEEDED total=$count allowed=$allowed encerradas=$killn"
}

write_status_header(){
  : > "$STATUS_FILE"
  printf '# user\tlimit\tmode\tssh\txray\ttotal\n' >> "$STATUS_FILE"
}

process_user(){
  local user="$1" limit="$2" mode="$3"
  local ssh_count xray_online total allowed_ssh
  id "$user" >/dev/null 2>&1 || return 0
  ssh_count="$(count_ssh_sessions "$user")"
  xray_online=0
  [[ "$mode" == "xray" || "$mode" == "both" ]] && xray_online="$(xray_online_from_cache "$user")"
  total=$((ssh_count + xray_online))

  case "$mode" in
    ssh)
      allowed_ssh="$limit"
      ;;
    xray)
      allowed_ssh="$ssh_count"
      ;;
    both|*)
      allowed_ssh=$((limit - xray_online))
      (( allowed_ssh < 0 )) && allowed_ssh=0
      ;;
  esac

  if [[ "$mode" == "ssh" || "$mode" == "both" ]]; then
    kill_excess_ssh "$user" "$allowed_ssh"
    ssh_count="$(count_ssh_sessions "$user")"
    total=$((ssh_count + xray_online))
  fi

  if [[ "$mode" == "xray" || "$mode" == "both" ]]; then
    if (( total > limit )) && (( ssh_count == 0 )) && (( xray_online > 0 )); then
      log "$user XRAY_LIMIT_OBSERVED total=$total limit=$limit (sem ação direta no xray)"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$user" "$limit" "$mode" "$ssh_count" "$xray_online" "$total" >> "$STATUS_FILE"
}

main_loop(){
  while true; do
    [[ -f "$DB" ]] || { sleep "$INTERVAL"; continue; }
    refresh_xray_cache
    write_status_header
    while read -r user limit mode _; do
      [[ -n "${user:-}" && -n "${limit:-}" ]] || continue
      [[ "$user" =~ ^# ]] && continue
      [[ "$limit" =~ ^[0-9]+$ ]] || continue
      mode="${mode:-both}"
      process_user "$user" "$limit" "$mode"
    done < "$DB"
    sleep "$INTERVAL"
  done
}

main_loop
EOF
  chmod +x "$LIMITER_BIN"
}

write_limiter_service() {
  cat > "$LIMITER_SERVICE_FILE" <<EOF
[Unit]
Description=PrimeVPN Limiter SSH/XRAY
After=network-online.target ssh.service sshd.service xray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash ${LIMITER_BIN}
Restart=always
RestartSec=3
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

install_activate_limiter() {
  header
  echo -e "${BOLD}Limiter SSH/XRAY${NC}"
  line

  local steps=5
  if xray_installed; then
    steps=6
  fi

  progress_start "$steps"
  run_step "Garantindo dependências do limiter" "install_base_tools && (${PKG_INSTALL} jq procps php curl || true)"
  run_step "Sincronizando limites com DragonCore" "dragoncore_cli_ready && sync_limiter_db_from_dragoncore"
  run_step "Gerando core do limiter" "write_limiter_core_script && write_limiter_service"

  if xray_installed; then
    run_step "Ativando suporte XRAY" "xray_enable_api_and_stats && xray_support_enabled"
  fi

  run_step "Ativando serviço do limiter" "systemctl daemon-reload && systemctl enable primevpn-limiter && systemctl restart primevpn-limiter"
  run_step "Validando serviço ativo" "systemctl is-active --quiet primevpn-limiter"
  echo
  ok "Limiter SSH/XRAY ativado."
  if xray_installed; then
    ok "Suporte XRAY ativado junto com o limiter."
  else
    warn "XRAY não encontrado. O limiter ficou ativo para SSH e será expandido para XRAY quando ele estiver instalado."
  fi
  pause
}

restart_limiter_service() {
  header
  echo -e "${BOLD}Reiniciar limiter${NC}"
  line

  if ! limiter_installed; then
    warn "O limiter ainda não está instalado."
    pause
    return
  fi

  progress_start 2
  run_step "Reiniciando serviço do limiter" "systemctl restart primevpn-limiter"
  run_step "Validando serviço ativo" "systemctl is-active --quiet primevpn-limiter"
  echo
  ok "Limiter reiniciado."
  pause
}

remove_limiter_service() {
  header
  echo -e "${BOLD}Desativar/desinstalar limiter${NC}"
  line

  if ! limiter_installed; then
    warn "O limiter não está instalado."
    pause
    return
  fi

  progress_start 4
  run_step "Parando e desabilitando serviço" "systemctl stop primevpn-limiter || true && systemctl disable primevpn-limiter || true"
  run_step "Removendo unit do systemd" "rm -f '${LIMITER_SERVICE_FILE}' && systemctl daemon-reload"
  run_step "Removendo binário do limiter" "rm -f '${LIMITER_BIN}'"
  run_step "Concluindo remoção" "true"
  echo
  ok "Limiter desativado e desinstalado. O banco de limites foi preservado em ${LIMITER_DB}."
  pause
}

sync_limiter_limits_menu() {
  header
  echo -e "${BOLD}Sincronizar limites do DragonCore${NC}"
  line

  if ! dragoncore_cli_ready; then
    warn "DragonCore não encontrado ou PHP indisponível."
    pause
    return
  fi

  progress_start 3
  run_step "Coletando usuários candidatos" "mkdir -p '${LIMITER_DIR}'"
  run_step "Lendo limites no DragonCore" "sync_limiter_db_from_dragoncore"
  run_step "Recarregando limiter se estiver ativo" "if systemctl is-active --quiet primevpn-limiter; then systemctl restart primevpn-limiter; else true; fi"
  echo
  ok "Limites sincronizados. Usuários no banco: $(limiter_user_count)"
  pause
}

show_limiter_status() {
  header
  echo -e "${BOLD}Status do limiter SSH/XRAY${NC}"
  line
  echo -e "${CYAN}Serviço:${NC} $(limiter_active && echo ATIVO || echo PARADO)"
  echo -e "${CYAN}Banco de limites:${NC} ${LIMITER_DB}"
  echo -e "${CYAN}Usuários sincronizados:${NC} $(limiter_user_count)"
  echo -e "${CYAN}XRAY API:${NC} $(xray_support_enabled && echo PRONTA || echo INATIVA)"
  line
  if [[ -f "$LIMITER_DB" ]]; then
    echo -e "${WHITE}${BOLD}limits.db${NC}"
    awk '{printf "%-18s limite=%-4s modo=%s\n", $1, $2, ($3==""?"both":$3)}' "$LIMITER_DB"
    echo
  fi
  if [[ -f "$LIMITER_STATUS_FILE" ]]; then
    echo -e "${WHITE}${BOLD}Status em tempo real${NC}"
    awk -F'\t' 'NR==1{next} {printf "%-18s limite=%-4s modo=%-6s ssh=%-3s xray=%-3s total=%s\n", $1, $2, $3, $4, $5, $6}' "$LIMITER_STATUS_FILE"
  else
    echo -e "${DIM}Nenhum status gerado ainda. Ative o serviço e aguarde alguns segundos.${NC}"
  fi
  pause
}

toggle_limiter_installation() {
  if limiter_installed || limiter_active; then
    remove_limiter_service
  else
    install_activate_limiter
  fi
}

limiter_menu() {
  while true; do
    local width top mid bot action_label xray_state users_count
    action_label="Instalar limiter"
    if limiter_installed || limiter_active; then
      action_label="Remover limiter"
    fi
    xray_state="$(xray_support_enabled && echo PRONTO || echo INATIVO)"
    users_count="$(limiter_user_count)"

    header
    width="$(menu_width)"
    top="╔$(hline $((width-2)))╗"
    mid="╠$(hline $((width-2)))╣"
    bot="╚$(hline $((width-2)))╝"

    echo "  $top"
    echo "  $(center_line "${WHITE}${BOLD}LIMITER SSH/XRAY${NC}" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "Status [$(limiter_menu_status)]" "XRAY [${xray_state}]" "$width")"
    echo "  $(two_col_line "Banco [$(fit_colored_text "$LIMITER_DB" 24)]" "Usuários [${users_count}]" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "$(menu_item 1 "$action_label")" "" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Reiniciar limiter')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Sincronizar limites')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 4 'Ver status')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Voltar')" "" "$width")"
    echo "  $bot"
    echo
    printf "${CYAN}Escolha somente a opção: ${NC}"
    wait_key_menu

    case "$MENU_KEY" in
      1) toggle_limiter_installation ;;
      2) restart_limiter_service ;;
      3) sync_limiter_limits_menu ;;
      4) show_limiter_status ;;
      0) return 0 ;;
      *) warn "Opção inválida."; pause ;;
    esac
  done
}
main_menu() {
  while true; do
    local width top mid bot
    header
    width="$(menu_width)"
    top="╔$(hline $((width-2)))╗"
    mid="╠$(hline $((width-2)))╣"
    bot="╚$(hline $((width-2)))╝"

    echo "  $top"
    echo "  $(center_line "${WHITE}${BOLD}MENU PRINCIPAL${NC}" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "M/Conexão: [$(connection_tuning_status)]" "BadVPN [$(fit_colored_text "$(badvpn_menu_status)" 18)]" "$width")"
    echo "  $(two_col_line "DragonCore: [$(fit_colored_text "$(dragoncore_menu_status)" 16)]" "CheckUser: [$(fit_colored_text "$(checkuser_menu_status)" 16)]" "$width")"
    echo "  $(two_col_line "Limiter: [$(fit_colored_text "$(limiter_menu_status)" 18)]" "M/XRAY: [$(fit_colored_text "$(xray_auto_tuning_status)" 18)]" "$width")"
    echo "  $mid"
    echo "  $(two_col_line "$(menu_item 1 'Atualizar Sistema')" "$(menu_item 6 'CheckUser DTunnel')" "$width")"
    echo "  $(two_col_line "$(menu_item 2 'Alterar senha root')" "$(menu_item 7 'Limiter SSH/XRAY')" "$width")"
    echo "  $(two_col_line "$(menu_item 3 'Melhorias de conexão')" "$(menu_item 8 'Formatar Servidor')" "$width")"
    echo "  $(two_col_line "$(menu_item 4 'Gerenciar BadVPN')" "$(menu_item 9 'Melhorador XRAY')" "$width")"
    echo "  $(two_col_line "$(menu_item 5 'DragonCoreSSH-Beta')" "" "$width")"
    echo "  $(two_col_line "$(menu_item 0 'Sair')" "" "$width")"
    echo "  $bot"
    echo
    printf "   ${CYAN}DIGITE A OPÇÃO: ${NC}"
    wait_key_menu

    case "$MENU_KEY" in
      1) auto_prepare_system ;;
      2) change_root_password ;;
      3) toggle_connection_improvements ;;
      4) badvpn_menu ;;
      5) dragoncore_open_menu ;;
      6) checkuser_open_menu ;;
      7) limiter_menu ;;
      8) reinstaller_open_menu ;;
      9) toggle_xray_auto_tuning ;;
      0) clear; exit 0 ;;
      *) warn "Opção inválida."; pause ;;
    esac
  done
}

need_root
detect_os
main_menu
