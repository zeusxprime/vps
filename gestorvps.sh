#!/usr/bin/env bash
# Tokens GitHub para instaladores privados.
# Troque apenas o texto dentro das aspas pelo token real de cada repositório.
CHECKUSER_GITHUB_TOKEN="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"
DRAGONSSH_GITHUB_TOKEN="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"
BOT_GITHUB_TOKEN="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"

# Gestor VPS - menu principal modular.
# Instala em /opt/.gestorvps e cria o comando global: gestorvps

set -u

APP_NAME="Gestor VPS"
TITLE="GESTOR VPS"
INSTALL_DIR="/opt/.gestorvps"
CONFIG_FILE="/etc/gestorvps.conf"
COMMAND_BIN="/usr/local/bin/gestorvps"
SCRIPTS_DIR="${INSTALL_DIR}/scripts"
SCRIPT_GIT="${SCRIPTS_DIR}/git.sh"
SCRIPT_AWS="${SCRIPTS_DIR}/aws.sh"
LOG_FILE="/var/log/gestorvps.log"

# Tokens dos repositórios privados no GitHub.
# Troque apenas o texto entre aspas pelo token correto de cada instalador.
# Se o instalador estiver público, pode deixar como está.
GESTORVPS_GITHUB_TOKEN="TOKEN_DO_VPS"

is_placeholder_token() {
  case "${1:-}" in
    ""|TOKEN_DO_*|SEU_TOKEN*|tokenaqui|TOKEN_AQUI) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_github_tokens() {
  local var val
  for var in GESTORVPS_GITHUB_TOKEN CHECKUSER_GITHUB_TOKEN DRAGONSSH_GITHUB_TOKEN BOT_GITHUB_TOKEN; do
    val="${!var:-}"
    if is_placeholder_token "$val"; then
      printf -v "$var" '%s' ""
    fi
  done
}

normalize_github_tokens

# Cores do layout, seguindo o padrão visual do menu Git/Gitea.
GREEN_FG=$'\e[1;32m'
YELLOW_FG=$'\e[1;33m'
RED_FG=$'\e[1;31m'
CYAN_FG=$'\e[1;36m'
WHITE_FG=$'\e[1;97m'
DIM_FG=$'\e[2m'
CYAN_BG=$'\e[48;5;19m'
RESET_FMT=$'\e[0m'
BOLD=$'\e[1m'

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || true
  fi

  [[ -z "${TITLE:-}" ]] && TITLE="GESTOR VPS"
  [[ -z "${INSTALL_DIR:-}" ]] && INSTALL_DIR="/opt/.gestorvps"
  SCRIPTS_DIR="${INSTALL_DIR}/scripts"
  [[ -z "${SCRIPT_GIT:-}" ]] && SCRIPT_GIT="${SCRIPTS_DIR}/git.sh"
  [[ -z "${SCRIPT_AWS:-}" ]] && SCRIPT_AWS="${SCRIPTS_DIR}/aws.sh"
}

save_config() {
  umask 077
  {
    printf 'TITLE=%q\n' "$TITLE"
    printf 'INSTALL_DIR=%q\n' "$INSTALL_DIR"
    printf 'SCRIPT_GIT=%q\n' "$SCRIPT_GIT"
    printf 'SCRIPT_AWS=%q\n' "$SCRIPT_AWS"
  } > "$CONFIG_FILE"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Execute como root. Exemplo: sudo bash $0"
    exit 1
  fi
}

safe_clear() {
  command -v clear >/dev/null 2>&1 && clear || true
}

pause() {
  echo
  read -r -p "Enter para continuar..." _ || true
}

menu_width() {
  local cols width
  cols="$(tput cols 2>/dev/null || echo 80)"
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
    printf '%s' "${plain:0:max-3}..."
  else
    printf '%s' "${plain:0:max}"
  fi
}

format_option() {
  local num="$1"
  # Menus de até 9 opções usam 1 dígito: 1, 2, 3...
  printf '%s%s %d %s' "$CYAN_BG" "$WHITE_FG" "$num" "$RESET_FMT"
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

status_file_label() {
  local path="$1"
  if [[ -f "$path" ]]; then
    printf '%sOK%s' "$GREEN_FG" "$RESET_FMT"
  else
    printf '%sNÃO ENCONTRADO%s' "$YELLOW_FG" "$RESET_FMT"
  fi
}

get_os_label() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}"
  else
    printf 'Linux'
  fi
}

get_cpu_usage() {
  local cpu user nice system idle iowait irq softirq steal total1 total2 idle1 idle2 totald idled usage
  read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat 2>/dev/null || { echo "0%"; return; }
  total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle1=$((idle + iowait))
  sleep 0.03
  read -r cpu user nice system idle iowait irq softirq steal _ < /proc/stat 2>/dev/null || { echo "0%"; return; }
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

get_ram_swap_display() {
  free -h 2>/dev/null | awk '
    /^Mem:/ {mem=$3"/"$2}
    /^Swap:/ {swap=$3"/"$2}
    END {if (mem=="") mem="N/D"; if (swap=="") swap="0B/0B"; print mem " (" swap ")"}'
}

get_disk_display() {
  df -h --output=used,size / 2>/dev/null | awk 'NR==2 {print $1"/"$2; found=1} END {if (!found) print "N/D"}'
}

show_menu() {
  local width top mid bot
  local os_label kernel cpu ram disk git_status aws_status

  safe_clear
  load_config

  width="$(menu_width)"
  top="╔$(hline $((width - 2)))╗"
  mid="╠$(hline $((width - 2)))╣"
  bot="╚$(hline $((width - 2)))╝"

  os_label="$(get_os_label)"
  kernel="$(uname -r 2>/dev/null || echo N/D)"
  cpu="$(get_cpu_usage)"
  ram="$(get_ram_swap_display)"
  disk="$(get_disk_display)"
  git_status="$(status_file_label "$SCRIPT_GIT")"
  aws_status="$(status_file_label "$SCRIPT_AWS")"

  echo "  $top"
  echo "  $(center_line "${WHITE_FG}${BOLD}${TITLE}${RESET_FMT}" "$width")"
  echo "  $mid"
  echo "  $(two_col_line "Sistema [${os_label}]" "Kernel [${kernel}]" "$width")"
  echo "  $(two_col_line "CPU [${cpu}]" "RAM/SWAP [${ram}]" "$width")"
  echo "  $(two_col_line "Disco [${disk}]" "" "$width")"
  echo "  $mid"
  echo "  $(two_col_line "$(menu_item 1 'Atualizar servidor')" "$(menu_item 6 'DragonSSH')" "$width")"
  echo "  $(two_col_line "$(menu_item 2 'Reiniciar servidor')" "$(menu_item 7 'Gestor Bot')" "$width")"
  echo "  $(two_col_line "$(menu_item 3 'CheckUser')" "$(menu_item 8 'Gerenciar BadVPN')" "$width")"
  echo "  $(two_col_line "$(menu_item 4 'Gerenciar Git')" "" "$width")"
  echo "  $(two_col_line "$(menu_item 5 'Gerenciar VPS')" "" "$width")"
  echo "  $mid"
  echo "  $(two_col_line "$(menu_item 0 'Sair')" "" "$width")"
  echo "  $bot"
  echo
}

read_menu_option() {
  local prompt="${1:-Opção: }"
  local first=""

  # Limpa qualquer tecla pendente no buffer para evitar leitura invertida.
  while IFS= read -r -s -n 1 -t 0.001 _ < /dev/tty 2>/dev/null; do :; done

  printf '%s%s%s' "$CYAN_FG" "$prompt" "$RESET_FMT" > /dev/tty

  while true; do
    IFS= read -r -s -n 1 first < /dev/tty || true
    case "$first" in
      $'\x1b')
        read -r -s -n 2 -t 0.001 _ < /dev/tty || true
        ;;
      [0-9])
        printf '%s\n' "$first" > /dev/tty
        printf '%s' "$first"
        return 0
        ;;
      *)
        ;;
    esac
  done
}
progress_line() {
  local percent="$1"
  local message="$2"
  local cols width filled empty bar prefix max_msg msg line

  (( percent < 0 )) && percent=0
  (( percent > 100 )) && percent=100

  cols="$(tput cols 2>/dev/null || echo 80)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  (( cols < 32 )) && cols=32

  width=22
  (( cols < 64 )) && width=14
  (( cols < 48 )) && width=10

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
  printf '\r\033[2K%s' "$line"
}

run_progress_command() {
  local start_percent="$1" end_percent="$2" message="$3" cmd="$4"
  local pid percent spinner spin_idx=0 step_span elapsed=0
  spinner='|/-\\'

  (( start_percent < 0 )) && start_percent=0
  (( end_percent > 100 )) && end_percent=100
  (( end_percent < start_percent )) && end_percent="$start_percent"
  step_span=$((end_percent - start_percent))

  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  bash -lc "$cmd" >> "$LOG_FILE" 2>&1 &
  pid=$!

  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( step_span > 0 )); then
      percent=$(( start_percent + (elapsed % (step_span + 1)) ))
    else
      percent="$start_percent"
    fi
    progress_line "$percent" "$message ${spinner:$spin_idx:1}"
    spin_idx=$(( (spin_idx + 1) % ${#spinner} ))
    elapsed=$((elapsed + 1))
    sleep 0.18
  done

  if wait "$pid"; then
    progress_line "$end_percent" "$message"
    return 0
  fi

  progress_line "$start_percent" "Falha: $message"
  printf '\n'
  echo "Erro na execução. Últimas linhas do log:"
  tail -n 12 "$LOG_FILE" 2>/dev/null || true
  pause
  return 1
}

update_server() {
  local os_id="" pkg_update="" pkg_upgrade="" pkg_clean="" confirm=""

  safe_clear
  echo "ATUALIZAR SERVIDOR"
  echo
  echo "Essa ação vai atualizar os pacotes do sistema."
  echo
  read -r -p "Confirmar atualização? [s/N]: " confirm || true
  [[ ! "$confirm" =~ ^[sS]$ ]] && { echo "Cancelado."; pause; return; }

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
  fi

  case "$os_id" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      pkg_update="apt-get update"
      pkg_upgrade="apt-get -y full-upgrade"
      pkg_clean="apt-get -y autoremove && apt-get clean"
      ;;
    amzn|amazon|fedora|centos|rhel|rocky|almalinux)
      if command -v dnf >/dev/null 2>&1; then
        pkg_update="dnf -y makecache"
        pkg_upgrade="dnf -y upgrade --refresh"
        pkg_clean="dnf -y autoremove || true"
      elif command -v yum >/dev/null 2>&1; then
        pkg_update="yum -y makecache"
        pkg_upgrade="yum -y update"
        pkg_clean="yum -y autoremove || true"
      else
        echo "Gerenciador de pacotes não encontrado."
        pause
        return
      fi
      ;;
    *)
      echo "Sistema não suportado para atualização automática: ${os_id:-desconhecido}"
      pause
      return
      ;;
  esac

  printf '\033[?25l' 2>/dev/null || true
  trap 'printf "\033[?25h" 2>/dev/null || true' RETURN

  run_progress_command 5 30 "Atualizando repositórios" "$pkg_update" || return
  run_progress_command 30 85 "Atualizando pacotes" "$pkg_upgrade" || return
  run_progress_command 85 100 "Limpando pacotes antigos" "$pkg_clean" || return
  progress_line 100 "Servidor atualizado."
  printf '\n'
}

reboot_server() {
  local confirm i

  safe_clear
  echo "REINICIAR SERVIDOR"
  echo
  echo "Essa ação vai reiniciar a VPS imediatamente."
  echo
  read -r -p "Confirmar reinicialização? [s/N]: " confirm || true
  [[ ! "$confirm" =~ ^[sS]$ ]] && { echo "Cancelado."; pause; return; }

  printf '\033[?25l' 2>/dev/null || true
  trap 'printf "\033[?25h" 2>/dev/null || true' RETURN

  for i in 5 15 30 45 60 75 90 100; do
    progress_line "$i" "Preparando reinicialização do servidor..."
    sleep 0.18
  done
  progress_line 100 "Reiniciando agora..."
  sleep 0.5

  if command -v systemctl >/dev/null 2>&1; then
    systemctl reboot -i
  else
    reboot
  fi
}

fix_one_script() {
  local path="$1"
  [[ -z "$path" || ! -f "$path" ]] && return 1
  sed -i 's/\r$//' "$path" 2>/dev/null || true
  chmod +x "$path" 2>/dev/null || true
  return 0
}




is_placeholder_token() {
  case "${1:-}" in
    ""|TOKEN_DO_*|SEU_TOKEN*|tokenaqui|TOKEN_AQUI) return 0 ;;
    *) return 1 ;;
  esac
}

urlencode_token() {
  printf '%s' "$1" | sed 's/%/%25/g; s/@/%40/g; s/:/%3A/g; s/#/%23/g; s/\//%2F/g; s/?/%3F/g; s/&/%26/g'
}

run_external_installer() {
  local label="$1" url="$2" after_cmds="${3:-}" preferred_fetcher="${4:-}" token_env="${5:-}"
  local tmp_installer="" token="" used_token="" encoded_token="" auth_url=""

  safe_clear
  echo "$label"
  echo
  echo "Baixando e iniciando instalador externo..."
  echo

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl não encontrado. Instale curl e tente novamente."
    pause
    return
  fi

  tmp_installer="$(mktemp /tmp/gestorvps-${label// /_}.XXXXXX.sh)" || {
    echo "Falha ao criar temporário."
    pause
    return
  }

  if [[ -n "$token_env" ]]; then
    token="${!token_env:-}"
  fi

  if is_placeholder_token "$token"; then
    token=""
  fi

  download_with_token() {
    local download_url="$1" output_file="$2" gh_token="$3"

    curl -fsSL \
      --retry 2 \
      --connect-timeout 10 \
      --max-time 60 \
      -H "Authorization: Bearer ${gh_token}" \
      -H "Accept: application/vnd.github.raw" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$download_url" \
      -o "$output_file" </dev/null
  }

  download_public() {
    local download_url="$1" output_file="$2"

    curl -fsSL \
      --retry 2 \
      --connect-timeout 10 \
      --max-time 60 \
      "$download_url" \
      -o "$output_file" </dev/null
  }

  # Para repositório privado, precisa usar token já aqui no gestorvps.
  # Se não tiver token, tenta público como fallback.
  if [[ -n "$token" ]]; then
    if download_with_token "$url" "$tmp_installer" "$token"; then
      used_token="$token"
    else
      echo
      echo "Falha ao baixar usando o token de ${token_env}."
      echo "Verifique se:"
      echo "1. o token está correto;"
      echo "2. o token tem acesso ao repositório certo;"
      echo "3. a permissão é Contents: Read-only;"
      echo "4. o arquivo existe nesse link:"
      echo "$url"
      rm -f "$tmp_installer" 2>/dev/null || true
      pause
      return
    fi
  else
    if download_public "$url" "$tmp_installer"; then
      used_token=""
    else
      echo
      echo "Falha ao baixar o instalador externo."
      echo "Esse instalador parece estar privado e não há token configurado em ${token_env}."
      echo "Link:"
      echo "$url"
      rm -f "$tmp_installer" 2>/dev/null || true
      pause
      return
    fi
  fi

  chmod +x "$tmp_installer" 2>/dev/null || true

  if [[ -n "$used_token" ]]; then
    encoded_token="$(urlencode_token "$used_token")"
    auth_url="https://x-access-token:${encoded_token}@github.com/"

    if ! env \
      GITHUB_TOKEN="$used_token" \
      "$token_env=$used_token" \
      GIT_TERMINAL_PROMPT=0 \
      GCM_INTERACTIVE=Never \
      GIT_CONFIG_COUNT=2 \
      GIT_CONFIG_KEY_0="url.${auth_url}.insteadOf" \
      GIT_CONFIG_VALUE_0="https://github.com/" \
      GIT_CONFIG_KEY_1="url.${auth_url}.insteadOf" \
      GIT_CONFIG_VALUE_1="http://github.com/" \
      bash "$tmp_installer"; then
      echo
      echo "O instalador externo retornou erro."
      echo "Se ele faz git clone interno, confira o token de ${token_env}."
      rm -f "$tmp_installer" 2>/dev/null || true
      pause
      return
    fi
  else
    if ! env \
      GIT_TERMINAL_PROMPT=0 \
      GCM_INTERACTIVE=Never \
      bash "$tmp_installer"; then
      echo
      echo "O instalador externo retornou erro."
      rm -f "$tmp_installer" 2>/dev/null || true
      pause
      return
    fi
  fi

  rm -f "$tmp_installer" 2>/dev/null || true

  if [[ -n "$after_cmds" ]]; then
    IFS='|' read -r -a _after_list <<< "$after_cmds"
    for cmd in "${_after_list[@]}"; do
      [[ -z "$cmd" ]] && continue
      if bash -lc "command -v ${cmd%% *} >/dev/null 2>&1 || [[ -x ${cmd%% *} ]]"; then
        clear || true
        bash -lc "$cmd"
        return
      fi
    done
  fi

  pause
}

run_script() {
  local label="$1" path="$2"

  safe_clear
  echo "$label"
  echo
  echo "Arquivo: $path"
  echo

  if [[ ! -f "$path" ]]; then
    echo "Arquivo não encontrado."
    pause
    return
  fi

  fix_one_script "$path" >/dev/null 2>&1 || true
  echo "Iniciando..."
  echo
  bash "$path"
  pause
}

run_badvpn_menu() {
  safe_clear
  echo "GERENCIAR BADVPN"
  echo

  if [[ ! -f "$SCRIPT_AWS" ]]; then
    echo "Arquivo aws.sh não encontrado."
    pause
    return
  fi

  fix_one_script "$SCRIPT_AWS" >/dev/null 2>&1 || true
  bash "$SCRIPT_AWS" --badvpn-menu
}

install_or_update() {
  local self src tmp_wrapper

  safe_clear
  echo "INSTALAR/ATUALIZAR GESTOR VPS"
  echo

  self="$(readlink -f "$0" 2>/dev/null || echo "$0")"
  src="$(dirname "$self")"

  mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/scripts"

  if [[ "$src" != "$INSTALL_DIR" ]]; then
    cp -a "$src/." "$INSTALL_DIR/"
  fi

  chmod +x "$INSTALL_DIR/gestorvps.sh" 2>/dev/null || true
  find "$INSTALL_DIR/scripts" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

  tmp_wrapper="${COMMAND_BIN}.tmp"
  cat > "$tmp_wrapper" <<EOFWRAP
#!/usr/bin/env bash
exec bash "${INSTALL_DIR}/gestorvps.sh" "\$@"
EOFWRAP
  chmod +x "$tmp_wrapper"
  mv -f "$tmp_wrapper" "$COMMAND_BIN"

  TITLE="GESTOR VPS"
  SCRIPT_GIT="${INSTALL_DIR}/scripts/git.sh"
  SCRIPT_AWS="${INSTALL_DIR}/scripts/aws.sh"
  save_config

  echo "Instalado com sucesso!"
  echo "Comando menu: gestorvps"
  pause
}

main_loop() {
  local opt
  load_config
  [[ -f "$CONFIG_FILE" ]] || save_config

  while true; do
    show_menu
    opt="$(read_menu_option "Opção: ")"

    case "$opt" in
      01|1) update_server ;;
      02|2) reboot_server ;;
      03|3) run_external_installer "CHECKUSER" "https://raw.githubusercontent.com/zeusxprime/checkuser/refs/heads/main/install.sh" "checkuser|/usr/local/bin/checkuser|/bin/checkuser|menu|/bin/menu" "curl -sL" "CHECKUSER_GITHUB_TOKEN" ;;
      04|4) run_script "GERENCIAR GIT" "$SCRIPT_GIT" ;;
      05|5) run_script "GERENCIAR VPS AWS" "$SCRIPT_AWS" ;;
      06|6) run_external_installer "DRAGONSSH" "https://raw.githubusercontent.com/zeusxprime/ssh/refs/heads/main/install.sh" "menu|/bin/menu|/opt/DragonCore/menu" "" "DRAGONSSH_GITHUB_TOKEN" ;;
      07|7) run_external_installer "GESTOR BOT" "https://raw.githubusercontent.com/zeusxprime/bot/refs/heads/main/bot.sh" "botmenu|/usr/local/bin/botmenu" "curl -sL" "BOT_GITHUB_TOKEN" ;;
      08|8) run_badvpn_menu ;;
      00|0) safe_clear; exit 0 ;;
      *) echo "Opção inválida."; sleep 0.3 ;;
    esac
  done
}

require_root
if [[ "${1:-}" == "--install" ]]; then
  load_config
  install_or_update
  exit 0
fi
main_loop
