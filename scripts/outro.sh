#!/usr/bin/env bash
set -u
clear 2>/dev/null || true
cat <<'TXT'
Outro script ainda não configurado.

Substitua este arquivo por outro módulo do Gestor VPS:
/opt/.gestorvps/scripts/outro.sh
TXT
echo
read -r -p "Enter para voltar..." _ || true
