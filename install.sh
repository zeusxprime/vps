#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="Gestor VPS"
INSTALL_DIR="/opt/.gestorvps"
BIN_PATH="/usr/local/bin/gestorvps"
TMP_DIR="$(mktemp -d)"

# Instalador compatível com:
# bash <(curl -sL https://raw.githubusercontent.com/zeusxprime/vps/main/install.sh)
# Não usa cd em /dev/fd ou /proc/... porque esse caminho pode sumir durante a execução.
RAW_BASE_PRIMARY="https://raw.githubusercontent.com/zeusxprime/vps/main"
RAW_BASE_FALLBACK="https://raw.githubusercontent.com/zeusxprime/vps/refs/heads/main"

NC=$'\e[0m'
CYAN=$'\e[1;36m'
RED=$'\e[1;31m'

cleanup() {
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  printf "\n%bErro:%b %s\n" "$RED" "$NC" "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "execute como root: sudo bash <(curl -sL https://raw.githubusercontent.com/zeusxprime/vps/main/install.sh)"
  fi
}

progress_bar() {
  local percent="$1"
  local msg="$2"
  local width=22
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local bar=""
  local i

  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="·"; done

  printf "\r%b[%s]%b %3d%% %s" "$CYAN" "$bar" "$NC" "$percent" "$msg"
}

progress_done() {
  local msg="$1"
  progress_bar 100 "$msg"
  printf "\n"
}

ensure_base_packages() {
  progress_bar 5 "Preparando dependências..."

  if ! command -v curl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      export NEEDRESTART_MODE=a
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y curl ca-certificates bash coreutils >/dev/null 2>&1 || fail "não foi possível instalar curl."
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y curl ca-certificates bash coreutils >/dev/null 2>&1 || fail "não foi possível instalar curl."
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl ca-certificates bash coreutils >/dev/null 2>&1 || fail "não foi possível instalar curl."
    else
      fail "curl não encontrado e não consegui detectar o gerenciador de pacotes."
    fi
  fi
}

curl_raw() {
  local url="$1"
  local output_path="$2"

  curl -fsSL \
    --retry 2 \
    --connect-timeout 10 \
    --max-time 35 \
    "$url" \
    -o "$output_path" </dev/null
}

download_raw() {
  local remote_path="$1"
  local output_path="$2"
  local url

  mkdir -p "$(dirname "$output_path")"

  url="${RAW_BASE_PRIMARY}/${remote_path}"
  if curl_raw "$url" "$output_path"; then
    return 0
  fi

  url="${RAW_BASE_FALLBACK}/${remote_path}"
  if curl_raw "$url" "$output_path"; then
    return 0
  fi

  return 1
}

download_required() {
  local remote_path="$1"
  local output_path="$2"
  download_raw "$remote_path" "$output_path" || fail "falha ao baixar: ${remote_path}"
}

download_optional() {
  local remote_path="$1"
  local output_path="$2"
  download_raw "$remote_path" "$output_path" >/dev/null 2>&1 || return 0
}

write_placeholder_outro() {
  cat > "$TMP_DIR/scripts/outro.sh" <<'EOS'
#!/usr/bin/env bash
clear
printf 'Módulo modelo do Gestor VPS.\n'
printf 'Substitua este arquivo por outro script quando precisar.\n\n'
read -r -p 'Enter para voltar...' _ || true
EOS
}

install_files() {
  progress_bar 15 "Baixando gestorvps.sh..."
  download_required "gestorvps.sh" "$TMP_DIR/gestorvps.sh"

  progress_bar 30 "Baixando git.sh..."
  download_required "scripts/git.sh" "$TMP_DIR/scripts/git.sh"

  progress_bar 45 "Baixando aws.sh..."
  download_required "scripts/aws.sh" "$TMP_DIR/scripts/aws.sh"

  progress_bar 55 "Baixando extra..."
  download_optional "scripts/outro.sh" "$TMP_DIR/scripts/outro.sh"
  [[ -f "$TMP_DIR/scripts/outro.sh" ]] || write_placeholder_outro

  progress_bar 65 "Baixando README..."
  download_optional "README.md" "$TMP_DIR/README.md"
  [[ -f "$TMP_DIR/README.md" ]] || printf '# Gestor VPS\n' > "$TMP_DIR/README.md"

  progress_bar 72 "Validando scripts..."
  bash -n "$TMP_DIR/gestorvps.sh" || fail "erro de sintaxe em gestorvps.sh"
  bash -n "$TMP_DIR/scripts/git.sh" || fail "erro de sintaxe em scripts/git.sh"
  bash -n "$TMP_DIR/scripts/aws.sh" || fail "erro de sintaxe em scripts/aws.sh"
  bash -n "$TMP_DIR/scripts/outro.sh" || true

  progress_bar 78 "Substituindo arquivos antigos..."
  mkdir -p "$INSTALL_DIR/scripts"

  # Atualização forçada: sempre substitui os módulos principais do Gestor VPS.
  # Não pergunta confirmação e não preserva versões antigas dentro da pasta final.
  rm -f \
    "$INSTALL_DIR/gestorvps.sh" \
    "$INSTALL_DIR/scripts/git.sh" \
    "$INSTALL_DIR/scripts/aws.sh" \
    "$INSTALL_DIR/scripts/outro.sh" \
    "$INSTALL_DIR/README.md" \
    "$BIN_PATH"

  progress_bar 84 "Instalando arquivos novos..."
  install -m 0755 "$TMP_DIR/gestorvps.sh" "$INSTALL_DIR/gestorvps.sh"
  install -m 0755 "$TMP_DIR/scripts/git.sh" "$INSTALL_DIR/scripts/git.sh"
  install -m 0755 "$TMP_DIR/scripts/aws.sh" "$INSTALL_DIR/scripts/aws.sh"
  install -m 0755 "$TMP_DIR/scripts/outro.sh" "$INSTALL_DIR/scripts/outro.sh"
  install -m 0644 "$TMP_DIR/README.md" "$INSTALL_DIR/README.md"

  chmod -R go-rwx "$INSTALL_DIR" 2>/dev/null || true

  progress_bar 92 "Criando comando global..."
  cat > "$BIN_PATH" <<EOFWRAP
#!/usr/bin/env bash
exec bash "$INSTALL_DIR/gestorvps.sh" "\$@"
EOFWRAP
  chmod 755 "$BIN_PATH"
  sync >/dev/null 2>&1 || true

  progress_done "Instalação concluída."
}

main() {
  require_root
  clear || true

  ensure_base_packages
  install_files

  sleep 0.5
  clear || true
  exec "$BIN_PATH"
}

main "$@"
