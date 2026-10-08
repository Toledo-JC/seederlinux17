#!/bin/bash
# ============================================================================
# SeederLinux Lite - lib/diag.sh
# ============================================================================
# Biblioteca de log estruturado para os scripts core e scripts
# permanentes (seederlinux-logon, seederlinux-logoff, seeder-sync,
# seederlinux-sync-ntp).
#
# Instalada em runtime pelo header do bundle em:
#   /usr/local/lib/seederlinux/diag.sh
#
# Uso nos scripts core:
#   source /usr/local/lib/seederlinux/diag.sh
#   SCRIPT_ID="02-ntp"
#   log_nivel INFO "configurando NTP"
#   log_nivel OK   "NTP sincronizado"
#
# Uso nos scripts permanentes:
#   SCRIPT_ID="seederlinux-logon"
#   log_nivel DIAG "..."
#
# Níveis fixos (V1 - 8 níveis):
#   INFO   - informação geral
#   TESTE  - teste sendo executado
#   TENT   - "tentativa N/M" (curto)
#   OK     - sucesso
#   AVISO  - sucesso parcial ou condição degradada (bundle continua)
#   DIAG   - diagnóstico (dica técnica)
#   ACAO   - ação sugerida (comando para o técnico rodar)
#   ERRO   - falha bloqueante (bundle continua, mas login pode falhar)
#
# TODO V2: helpers específicos (log_diag_comando, log_erro_com_saida),
# rotação de log, timestamp opcional.
# ============================================================================

# Evita carregar duas vezes
if [ -n "${SEEDER_DIAG_LOADED:-}" ]; then
    return 0
fi
SEEDER_DIAG_LOADED=1

# ---------------------------------------------------------------------------
# Constantes de nível (para evitar erro de digitação nos scripts)
# ---------------------------------------------------------------------------
SEEDER_LOG_INFO="INFO"
SEEDER_LOG_TESTE="TESTE"
SEEDER_LOG_TENT="TENT"
SEEDER_LOG_OK="OK"
SEEDER_LOG_AVISO="AVISO"
SEEDER_LOG_DIAG="DIAG"
SEEDER_LOG_ACAO="ACAO"
SEEDER_LOG_ERRO="ERRO"

# ---------------------------------------------------------------------------
# log_nivel <NIVEL> <mensagem...>
#
# Função única de log. Prefixa com [NIVEL] [SCRIPT_ID].
# Se SCRIPT_ID não estiver definido, usa "[core]".
#
# Não valida o nível contra a lista - quem chama é responsável por usar
# uma das constantes SEEDER_LOG_*. Isso mantém a função em 3 linhas e
# permite níveis extras no futuro sem alterar a lib.
# ---------------------------------------------------------------------------
log_nivel() {
    local nivel="$1"
    shift
    local tag="${SCRIPT_ID:-core}"
    printf '[%-5s] [%s] %s\n' "$nivel" "$tag" "$*"
}
