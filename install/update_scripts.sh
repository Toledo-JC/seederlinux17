#!/bin/bash
# ============================================================================
# SeederLinux Lite - Atualizador de Scripts Core no Banco
# Rodar manualmente apos editar qualquer arquivo em scripts/core/*.sh
# ============================================================================
set -e

cd "$(dirname "$0")"

echo "[+] Gerando insert_core_scripts.sql a partir de scripts/core/*.sh..."
python3 gen_insert_core.py

echo "[+] Aplicando insert_core_scripts.sql no banco..."
sudo -u postgres psql -d seederlinux -f insert_core_scripts.sql

echo ""
echo "Scripts atualizados no banco com sucesso."
echo "Gere um bundle novo pelo painel admin para aplicar as estacoes."
