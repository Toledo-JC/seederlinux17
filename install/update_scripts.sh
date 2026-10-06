#!/bin/bash
# ============================================================================
# SeederLinux Lite - Atualizador de Scripts Core no Banco
# Rodar manualmente apos editar qualquer arquivo em scripts/core/*.sh
# ============================================================================
# NOTA: scripts/permanent/* (ex.: seederlinux-sync-ntp + o .service) NAO passa
# por aqui. Esses componentes rodam fora do bundle e sao embutidos/instalados
# pelo header do bundle gerado (BUNDLE_HEADER em api/index.php, via heredoc).
# Este script cuida somente de scripts/core/*.sh e da tabela 'scripts'.
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
