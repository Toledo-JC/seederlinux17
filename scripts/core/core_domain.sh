#!/bin/bash
# ============================================================================
# Core Script: core_domain.sh (v5 - DNS swap incondicional + resolv.conf imutavel)
# SeederLinux Lite - Gerenciador de Estado do Active Directory
# ============================================================================
# Implementa uma máquina de estados para diagnosticar, classificar e
# corrigir o ingresso no AD, suportando SSSD (realm join) e Winbind
# (net ads join) como fallback.
#
# Estagios: 1) Diagnostico  2) Classificacao  3) Decisao
#           4) Execucao (somente se necessario)  5) Pos-ingresso + Validacao
#
# CONTRATO DE FASES DO BUNDLE (INVARIANTE):
#   Fase 1 (scripts 01..05): DNS de internet ativo. apt/wget funcionam.
#   Fase 2 (ESTE script, PRIMEIRA coisa): troca /etc/resolv.conf para
#     apontar SOMENTE para DNS_PRIMARIO + DNS_SECUNDARIO do AD, e TRAVA
#     o arquivo com chattr +i para o NetworkManager/dhclient nao
#     sobrescreverem em lease renewal.
#   Fase 3 (scripts 07..23): DNS do AD mantido, sem apt-get.
#
# Este script aplica a Fase 2 DE FORMA INCONDICIONAL - independente do
# estado da estacao (nova, ingressada, corrompida). Motivo: o
# core_dns.sh (script 01) SEMPRE reescreve /etc/resolv.conf colocando
# DNS_INTERNET na frente; se a estacao ja esta ingressada, a maquina
# de estados pula o bloco de join e ninguem remove o 8.8.8.8 de novo.
# Consequencia em producao: glibc nao tenta o proximo nameserver em
# NXDOMAIN (so em timeout), entao consultas SRV/LDAP do SSSD falham
# silenciosamente e nomes internos (ex: seederlinux.comara.intraer)
# deixam de resolver apos o ingresso.
#
# O core_dns.sh (script 01) foi ajustado para comecar com
# `chattr -i /etc/resolv.conf 2>/dev/null || true` - isso permite que
# a Fase 1 da proxima execucao escreva no arquivo mesmo se ele estiver
# travado por esta Fase 2. Por isso o `chattr +i` no fim da Fase 2
# (abaixo) agora e' seguro: a trava e' levantada na proxima passagem
# pelo script 01, antes de qualquer escrita.
#
# Os placeholders {{VARIAVEL}} sao substituidos automaticamente
# pelo sistema na geracao do bundle. Variaveis sensiveis usam o
# formato  (substituicao separada, nunca em texto plano
# no restante do bundle).
# ============================================================================

set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="07-domain"

echo "============================================================"
echo "Gerenciador de Estado do Active Directory"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
DNS_PRIMARIO="{{DNS_PRIMARIO}}"
DNS_SECUNDARIO="{{DNS_SECUNDARIO}}"
OU_PADRAO="{{OU_PADRAO}}"
GRUPO_ADMIN="{{GRUPO_ADMIN}}"
GRUPO_ADMIN_AD="{{GRUPO_ADMIN_AD}}"
GRUPO_ADMIN_LINUX="{{GRUPO_ADMIN_LINUX}}"
GRUPO_DASTI="{{GRUPO_DASTI}}"
OFFLINE_AUTH_ENABLED="{{OFFLINE_AUTH_ENABLED}}"
OFFLINE_AUTH_DAYS="{{OFFLINE_AUTH_DAYS}}"
ADMIN_USERNAME="{{ADMIN_USERNAME}}"
ADMIN_PASSWORD_B64="__ADMIN_PASSWORD_B64__"
AUTH_METHOD="{{AUTH_METHOD}}"

# ============================================================
# Checagem de sanidade: o backend PHP deve ter substituido os
# placeholders criticos antes de gerar o bundle. Se algum deles
# aparecer literal aqui, e bug do backend (nao deste script) -
# abortar cedo com mensagem clara em vez de deixar o kinit falhar
# silenciosamente mais adiante.
# ============================================================
if [[ "$ADMIN_USERNAME" == *"{{"* ]]; then
    log_nivel ERRO "placeholder ADMIN_USERNAME nao foi substituido pelo backend."
    exit 1
fi
if [[ "$ADMIN_PASSWORD_B64" == "__"* && "$ADMIN_PASSWORD_B64" == *"__" ]]; then
    log_nivel ERRO "placeholder ADMIN_PASSWORD_B64 nao foi substituido pelo backend."
    exit 1
fi

ADMIN_PASSWORD=""
if [ -n "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD=$(printf '%s' "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null) || ADMIN_PASSWORD=""
fi
unset ADMIN_PASSWORD_B64

NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
if [ "$NON_INTERACTIVE" = "true" ]; then
    log_nivel INFO "Modo não interativo ativado."
fi

log_nivel INFO "Dominio: $DOMINIO"
log_nivel INFO "NetBIOS: $DOMINIO_NETBIOS"
log_nivel INFO "DC principal: $DC_IP"
[ -n "$DC_IP_LIST" ] && echo ">>> DCs adicionais: $DC_IP_LIST"

# ============================================================
# ============================================================
# FASE 2 — TROCA DE DNS (INCONDICIONAL)
# ============================================================
# Esta secao PRECISA rodar sempre, ANTES de qualquer comando que
# dependa do AD (host, realm, kinit, net ads, sssd, adcli, ldapsearch).
#
# Era o bug principal da versao anterior: a troca de DNS estava
# dentro do `if [ "$ESTADO" = "NAO_INGRESSADO" ]` do ESTAGIO 4. Numa
# estacao ja ingressada, o ESTAGIO 4 nunca executava e o
# /etc/resolv.conf ficava com o DNS_INTERNET (8.8.8.8) que o
# core_dns.sh (script 01) tinha escrito - resultando em NXDOMAIN
# para todo nome interno e SRV do AD.
#
# Idempotente: pode rodar N vezes sem efeito colateral.
# ============================================================
echo "============================================================"
log_nivel INFO "FASE 2: Aplicando DNS do AD (incondicional)"
echo "============================================================"

# Guarda o resolv.conf da Fase 1 para auditoria/debug
if [ -s /etc/resolv.conf ]; then
    cp -f /etc/resolv.conf /etc/resolv.conf.fase1.bak 2>/dev/null || true
fi

# -- Validar que temos pelo menos um DNS do AD definido.
#    Se nao tiver, e erro de configuracao da OM - abortar, porque
#    sem DNS do AD nao ha como ingressar nem manter o ingresso.
if [ -z "$DNS_PRIMARIO" ] || [ "$DNS_PRIMARIO" = "" ]; then
    if [ -n "$DC_IP" ] && [ "$DC_IP" != "" ]; then
        log_nivel AVISO "DNS_PRIMARIO vazio - usando DC_IP ($DC_IP) como fallback."
        DNS_PRIMARIO="$DC_IP"
    else
        log_nivel ERRO "DNS_PRIMARIO e DC_IP vazios. Ingresso impossivel."
        log_nivel INFO "Configure DNS_PRIMARIO na OM antes de gerar o bundle."
        exit 1
    fi
fi

# -- Neutralizar systemd-resolved: o stub 127.0.0.53 nao encaminha
#    consultas SRV (_ldap._tcp.dc._msdcs.$DOMINIO) para o AD, o que
#    quebra a descoberta automatica do SSSD.
systemctl disable --now systemd-resolved 2>/dev/null || true
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable --now systemd-resolved-monitor.socket 2>/dev/null || true
systemctl disable --now systemd-resolved-varlink.socket 2>/dev/null || true

# -- Remover imutabilidade eventualmente deixada por uma execucao
#    anterior deste script (idempotencia defensiva).
chattr -i /etc/resolv.conf 2>/dev/null || true

# -- Reescrever /etc/resolv.conf com SOMENTE os DNS do AD.
#    Nao usamos DC_IP_LIST aqui - DC_IP_LIST e a lista de
#    controladores de dominio redundantes; DNS_PRIMARIO/DNS_SECUNDARIO
#    sao os servidores DNS propriamente ditos, que podem ter IPs
#    distintos dos DCs.
rm -f /etc/resolv.conf
{
    echo "# SeederLinux - Fase 2 (DNS do AD). NAO EDITAR."
    echo "# Gerado por core_domain.sh em $(date -Is)"
    echo "search ${DOMINIO}"
    echo "nameserver ${DNS_PRIMARIO}"
    if [ -n "$DNS_SECUNDARIO" ] && [ "$DNS_SECUNDARIO" != "" ]; then
        echo "nameserver ${DNS_SECUNDARIO}"
    fi
    echo "options timeout:2 attempts:2 rotate"
} > /etc/resolv.conf

log_nivel INFO "/etc/resolv.conf agora:"
sed 's/^/    /' /etc/resolv.conf

# -- Travar /etc/resolv.conf com chattr +i.
#
#    Motivo: em estacoes com DHCP (NetworkManager), o arquivo e'
#    reescrito a cada renovacao de lease. Sem a trava, o DNS do AD
#    configurado aqui volta a ter o DNS do DHCP (que pode ser
#    8.8.8.8 ou qualquer outro) sem bundle nenhum rodar - e a
#    estacao ingressada comeca a falhar consultas internas
#    silenciosamente.
#
#    Seguranca da trava: o core_dns.sh (script 01) foi ajustado para
#    comecar com `chattr -i /etc/resolv.conf 2>/dev/null || true`
#    antes de escrever. Ou seja, na proxima execucao do bundle, a
#    Fase 1 consegue levantar a trava, escrever o DNS temporario, e
#    a Fase 2 reaplica a trava no fim. Sem essa contrapartida, o
#    `chattr +i` faria o bundle abortar sob `set -e` na proxima
#    execucao.
#
#    Idempotente: chattr +i em arquivo ja imutavel e' no-op.
chattr +i /etc/resolv.conf 2>/dev/null || true

if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
    log_nivel INFO "/etc/resolv.conf travado (chattr +i) - NetworkManager nao pode sobrescrever"
else
    log_nivel AVISO "chattr +i nao aplicou (filesystem sem suporte? ex: overlayfs em container)"
fi

# -- Gate: confirmar que o DNS do AD responde ao SRV do dominio
#    antes de seguir. Melhor abortar aqui (erro claro) do que deixar
#    a estacao meio-ingressada.
if command -v host >/dev/null 2>&1; then
    log_nivel INFO "[DNS] Validando SRV _ldap._tcp.dc._msdcs.${DOMINIO} ..."
    if ! host -t SRV "_ldap._tcp.dc._msdcs.${DOMINIO}" >/dev/null 2>&1; then
        # Heuristica: se ja ha artefatos de ingresso, apenas avisar
        # (a estacao pode estar ingressada e o DNS e' "menos bom"
        # que o ideal, mas nao vamos abortar re-provisionamento de
        # uma estacao em producao por isso).
        ALREADY_JOINED_HEURISTIC=false
        if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
            ALREADY_JOINED_HEURISTIC=true
        fi
        if [ -f /etc/sssd/sssd.conf ] && \
           grep -qE '^[[:space:]]*domains[[:space:]]*=' /etc/sssd/sssd.conf 2>/dev/null; then
            ALREADY_JOINED_HEURISTIC=true
        fi

        if [ "$ALREADY_JOINED_HEURISTIC" = "true" ]; then
            log_nivel AVISO "SRV nao resolve, mas a estacao parece ja ingressada"
            log_nivel DIAG "Verificar DNS_PRIMARIO/DNS_SECUNDARIO no painel"
            log_nivel DIAG "Seguindo para validacao do estado atual"
        else
            log_nivel ERRO "SRV _ldap._tcp.dc._msdcs.${DOMINIO} nao resolve"
            log_nivel DIAG "DNS configurado: ${DNS_PRIMARIO} / ${DNS_SECUNDARIO:-<vazio>}"
            log_nivel DIAG "O core_ntp.sh deveria ter rodado antes e sincronizado o relogio"
            log_nivel DIAG "mas o DNS do AD tambem depende de conectividade L3"
            log_nivel ACAO "Verificar conectividade L3 com o DC: ping $DC_IP"
            log_nivel ACAO "Verificar DNS: host $DOMINIO  (deve responder o IP do DC)"
            log_nivel ACAO "Se DNS nao responde: revisar DNS_PRIMARIO no painel"
            exit 1
        fi
    else
        log_nivel OK "[DNS] SRV OK - dominio visivel via DNS do AD"
    fi
else
    log_nivel AVISO "comando 'host' nao encontrado - pulando gate de SRV."
    log_nivel INFO "(isso nao deveria acontecer: 'dnsutils' e' pacote base do bundle)"
fi

log_nivel INFO "[FASE 2] DNS do AD aplicado."
echo "============================================================"

# ============================================================
# ESTÁGIO 1: DIAGNÓSTICO
# ============================================================
echo "============================================================"
log_nivel INFO "ESTÁGIO 1: Diagnóstico do ambiente AD"
echo "============================================================"

# Funções de diagnóstico
check_dns() {
    if host "$DOMINIO" > /dev/null 2>&1; then
        echo "DNS............. OK ($DOMINIO resolve)"
        return 0
    else
        echo "DNS............. FALHA ($DOMINIO não resolve)"
        return 1
    fi
}

check_kerberos_config() {
    if [ -f /etc/krb5.conf ]; then
        echo "Kerberos........ OK (configurado)"
        return 0
    else
        echo "Kerberos........ FALHA (não configurado)"
        return 1
    fi
}

check_ticket() {
    if klist -s 2>/dev/null; then
        echo "Ticket.......... OK ($(klist | grep 'Default principal' | awk '{print $3}'))"
        return 0
    else
        echo "Ticket.......... NÃO (sem ticket ativo)"
        return 1
    fi
}

check_realm() {
    if realm list 2>/dev/null | grep -q "$DOMINIO"; then
        echo "Realm........... OK (associado)"
        return 0
    else
        echo "Realm........... NÃO (não associado)"
        return 1
    fi
}

check_sssd() {
    if systemctl is-active --quiet sssd 2>/dev/null; then
        echo "SSSD............ OK (ativo)"
        return 0
    else
        echo "SSSD............ NÃO (parado)"
        return 1
    fi
}

check_winbind() {
    if systemctl is-active --quiet winbind 2>/dev/null; then
        echo "Winbind......... OK (ativo)"
        return 0
    else
        echo "Winbind......... NÃO (parado)"
        return 1
    fi
}

check_keytab() {
    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "Keytab.......... OK (presente)"
        return 0
    else
        echo "Keytab.......... NÃO (ausente ou vazio)"
        return 1
    fi
}

check_machine_account() {
    if systemctl is-active --quiet winbind 2>/dev/null; then
        if net ads testjoin > /dev/null 2>&1; then
            echo "Conta AD........ OK (net ads testjoin / winbind)"
            return 0
        fi
    fi

    if systemctl is-active --quiet sssd 2>/dev/null; then
        if realm list 2>/dev/null | grep -q "$DOMINIO" && klist -s 2>/dev/null; then
            echo "Conta AD........ OK (sssd + realm + klist)"
            return 0
        fi
    fi

    if adcli testjoin --domain="$DOMINIO" > /dev/null 2>&1; then
        echo "Conta AD........ OK (adcli)"
        return 0
    fi

    echo "Conta AD........ NÃO (não verificada)"
    return 1
}

check_time_sync() {
    if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
        echo "Sinc. Tempo..... OK"
        return 0
    else
        echo "Sinc. Tempo..... NÃO (pode afetar Kerberos)"
        return 1
    fi
}

# Executar diagnóstico
echo ""
echo "--- Coletando informações ---"
DNS_OK=true && check_dns || DNS_OK=false
KRB5_OK=true && check_kerberos_config || KRB5_OK=false
TICKET_OK=true && check_ticket || TICKET_OK=false
REALM_OK=true && check_realm || REALM_OK=false
SSSD_OK=true && check_sssd || SSSD_OK=false
WINBIND_OK=true && check_winbind || WINBIND_OK=false
KEYTAB_OK=true && check_keytab || KEYTAB_OK=false
MACHINE_OK=true && check_machine_account || MACHINE_OK=false
TIME_OK=true && check_time_sync || TIME_OK=false
echo "================================"

# ============================================================
# Helpers de saida do dominio - sempre com senha via stdin (ou
# /dev/null se nao houver) para nunca ficar esperando prompt
# interativo em execucao via cron/push remoto.
# ============================================================
realm_leave_safe() {
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "$ADMIN_PASSWORD" | realm leave "$DOMINIO" -U "$ADMIN_USERNAME" 2>/dev/null || true
    else
        realm leave "$DOMINIO" -U "$ADMIN_USERNAME" < /dev/null 2>/dev/null || true
    fi
}

net_ads_leave_safe() {
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "$ADMIN_PASSWORD" | net ads leave -U "$ADMIN_USERNAME" 2>/dev/null || true
    else
        net ads leave -U "$ADMIN_USERNAME" < /dev/null 2>/dev/null || true
    fi
}

# ============================================================
# ESTÁGIO 2: CLASSIFICAR ESTADO
# ============================================================
echo ""
log_nivel INFO "ESTÁGIO 2: Classificando estado atual"

if [ "$REALM_OK" = "true" ] && [ "$SSSD_OK" = "true" ] && [ "$KEYTAB_OK" = "true" ]; then
    if [ "$WINBIND_OK" = "true" ]; then
        ESTADO="INGRESSADO_HIBRIDO"
    else
        ESTADO="INGRESSADO_SSSD"
    fi
elif [ "$WINBIND_OK" = "true" ] && [ "$MACHINE_OK" = "true" ]; then
    ESTADO="INGRESSADO_WINBIND"
elif [ "$REALM_OK" = "false" ] && [ "$WINBIND_OK" = "false" ] && [ "$MACHINE_OK" = "false" ] && [ "$KEYTAB_OK" = "false" ]; then
    ESTADO="NAO_INGRESSADO"
elif [ "$REALM_OK" = "true" ] && [ "$KEYTAB_OK" = "false" ]; then
    ESTADO="CORROMPIDO"
elif [ "$REALM_OK" = "true" ] && [ "$SSSD_OK" = "false" ]; then
    ESTADO="PARCIAL"
elif [ "$MACHINE_OK" = "true" ] || [ "$KEYTAB_OK" = "true" ]; then
    # Ha vestigios de um ingresso anterior (conta AD e/ou keytab) que nao
    # bate com nenhum padrao "limpo" acima - tratar como CORROMPIDO em vez
    # de INDETERMINADO, para passar pela limpeza (leave + remove keytab)
    # antes de tentar um join novo. Evita duplicar a conta no AD.
    ESTADO="CORROMPIDO"
else
    ESTADO="INDETERMINADO"
fi

log_nivel INFO "Estado detectado: $ESTADO"

# ============================================================
# Bloqueio preventivo: tempo quebrado antes de tentar ingresso.
# (DNS nao entra mais aqui - ja foi corrigido na FASE 2 acima.
#  Se ainda estiver quebrado, o gate de SRV ja abortou.)
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ] || [ "$ESTADO" = "INDETERMINADO" ]; then
    if [ "$TIME_OK" = "false" ]; then
        echo ""
        log_nivel AVISO "relogio fora de sincronia (Kerberos rejeita diferenca > 5min)."
        log_nivel INFO "O kinit provavelmente vai falhar com 'Clock skew too great'."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            log_nivel INFO "Modo nao interativo: prosseguindo mesmo assim (provavel falha adiante)."
        else
            read -p ">>> Deseja continuar mesmo assim? (s/N): " CONTINUE_APESAR_DE
            if [[ ! "$CONTINUE_APESAR_DE" =~ ^[Ss]$ ]]; then
                log_nivel INFO "Instalação abortada pelo usuário."
                exit 1
            fi
        fi
    fi
fi

# ============================================================
# ESTÁGIO 3: DECISÃO
# ============================================================
echo ""
log_nivel INFO "ESTÁGIO 3: Decisão sobre ação necessária"

case "$ESTADO" in
    INGRESSADO_SSSD|INGRESSADO_HIBRIDO)
        log_nivel INFO "A máquina já está ingressada via SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REINGRESSAR="n"
        else
            read -p ">>> Deseja reingressar (remover e ingressar novamente)? (s/N): " REINGRESSAR
        fi
        if [[ "$REINGRESSAR" =~ ^[Ss]$ ]]; then
            log_nivel INFO "Removendo ingresso existente..."
            realm_leave_safe
            net_ads_leave_safe
            ESTADO="NAO_INGRESSADO"
        else
            log_nivel INFO "Mantendo ingresso existente. Pulando ingresso."
        fi
        ;;

    INGRESSADO_WINBIND)
        log_nivel INFO "A máquina está ingressada via Winbind (método legado)."
        log_nivel INFO "Recomenda-se migrar para SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            MIGRAR="s"
        else
            read -p ">>> Deseja migrar para SSSD (remover Winbind e ingressar via realm)? (S/n): " MIGRAR
        fi
        if [[ ! "$MIGRAR" =~ ^[Nn]$ ]]; then
            log_nivel INFO "Removendo ingresso Winbind..."
            net_ads_leave_safe
            systemctl stop winbind 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
        else
            log_nivel INFO "Mantendo Winbind. Pulando ingresso."
        fi
        ;;

    CORROMPIDO|PARCIAL)
        log_nivel AVISO "Estado inconsistente detectado ($ESTADO)."
        log_nivel INFO "Possíveis causas: keytab ausente, SSSD parado, ou ingresso parcial."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REPARAR="s"
        else
            read -p ">>> Deseja reparar automaticamente? (S/n): " REPARAR
        fi
        if [[ ! "$REPARAR" =~ ^[Nn]$ ]]; then
            log_nivel INFO "Executando limpeza completa..."
            realm_leave_safe
            net_ads_leave_safe
            rm -f /etc/krb5.keytab
            systemctl stop sssd 2>/dev/null || true
            systemctl stop winbind 2>/dev/null || true
            # Limpar caches
            rm -rf /var/lib/sss/db/* 2>/dev/null || true
            rm -rf /var/lib/sss/mc/* 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
            log_nivel INFO "Limpeza concluída."
        else
            log_nivel INFO "Prosseguindo sem reparar (pode falhar)."
        fi
        ;;

    INDETERMINADO)
        log_nivel INFO "Estado indeterminado. Tentando ingresso como máquina nova."
        ESTADO="NAO_INGRESSADO"
        ;;
esac

# ============================================================
# ESTÁGIO 4: EXECUÇÃO (apenas se necessário)
# ============================================================
# NOTA: a troca de DNS NAO fica mais aqui - foi movida para a FASE 2
# incondicional, no topo do script. Isso garante que mesmo uma
# estacao ja ingressada (que pula este bloco inteiro) fique com o
# /etc/resolv.conf correto apos o bundle rodar.
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ]; then
    echo ""
    log_nivel INFO "ESTÁGIO 4: Executando ingresso no domínio"

    # Configurar Kerberos
    log_nivel INFO "Configurando Kerberos..."
    REALM="${DOMINIO^^}"
    # CORRECAO: dns_lookup_kdc=false (era true) - nao depender de SRV
    # ja que acabamos de desativar o encaminhamento via
    # systemd-resolved; kdc listado por FQDN E IP como redundancia;
    # default_ccache_name para integracao com keyring do systemd;
    # kpasswd_server para permitir troca de senha pelo usuario.
    cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    ticket_lifetime = 24h
    forwardable = yes
    renew_lifetime = 7d
    udp_preference_limit = 0
    default_ccache_name = KEYRING:persistent:%{uid}

[realms]
    ${REALM} = {
        kdc = dc-${OM_ACRONYM,,}.${DOMINIO}
        kdc = ${DC_IP}
        admin_server = dc-${OM_ACRONYM,,}.${DOMINIO}
        kpasswd_server = dc-${OM_ACRONYM,,}.${DOMINIO}
    }

[domain_realm]
    .${DOMINIO} = ${REALM}
    ${DOMINIO} = ${REALM}
EOF

    # Configurar Samba
    log_nivel INFO "Configurando Samba..."
    cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = ${DOMINIO_NETBIOS}
    realm = ${DOMINIO}
    security = ads
    dns forwarder = ${DC_IP}
    kerberos method = secrets and keytab
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config ${DOMINIO_NETBIOS} : backend = rid
    idmap config ${DOMINIO_NETBIOS} : range = 10000-999999
    template shell = /bin/bash
    template homedir = /home/%D/%U
    winbind use default domain = true
    winbind offline logon = false
    winbind nss info = rfc2307
    winbind enum users = no
    winbind enum groups = no
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
EOF

    # Obter ticket Kerberos
    log_nivel INFO "Obtendo ticket Kerberos..."
    KINIT_OK=false

    # Tentar com pipe se ADMIN_PASSWORD estiver disponível
    if [ -n "$ADMIN_PASSWORD" ]; then
        log_nivel INFO "Tentando obter ticket com senha pre-definida..."
        KINIT_HAS_PWFILE=false
        if kinit --help 2>&1 | grep -q -- '--password-file'; then
            KINIT_HAS_PWFILE=true
        fi
        log_nivel INFO "suporte a --password-file: $KINIT_HAS_PWFILE"

        for TRY_USER in \
            "${ADMIN_USERNAME}@${REALM}" \
            "${ADMIN_USERNAME}@${DOMINIO_NETBIOS}" \
            "${ADMIN_USERNAME,,}@${REALM}" \
            "${ADMIN_USERNAME,,}@${DOMINIO,,}"; do
            log_nivel INFO "tentando kinit para ${TRY_USER}..."
            if [ "$KINIT_HAS_PWFILE" = "true" ]; then
                if printf '%s\n' "$ADMIN_PASSWORD" | kinit --password-file=- "$TRY_USER" >/tmp/kinit-out.txt 2>&1; then
                    KINIT_OK=true
                    log_nivel INFO "OK"
                    break
                else
                    log_nivel INFO "falhou: $(head -3 /tmp/kinit-out.txt 2>/dev/null | tr '\n' ' ')"
                fi
            else
                if printf '%s\n' "$ADMIN_PASSWORD" | kinit "$TRY_USER" >/tmp/kinit-out.txt 2>&1; then
                    KINIT_OK=true
                    log_nivel INFO "OK"
                    break
                else
                    log_nivel INFO "falhou: $(head -3 /tmp/kinit-out.txt 2>/dev/null | tr '\n' ' ')"
                fi
            fi
        done
        rm -f /tmp/kinit-out.txt
    elif [ "$NON_INTERACTIVE" = "true" ]; then
        log_nivel ERRO "ADMIN_PASSWORD nao definido em modo nao interativo."
    fi

    # Modo interativo se pipe falhou
    if [ "$KINIT_OK" != "true" ] && [ "$NON_INTERACTIVE" != "true" ]; then
        log_nivel INFO "Não foi possível obter ticket automaticamente."
        log_nivel INFO "Solicitando credenciais interativamente..."
        while [ "$KINIT_OK" != "true" ]; do
            if [ -z "$ADMIN_USERNAME" ] || [ "$ADMIN_USERNAME" = "Administrator" ]; then
                read -p ">>> Usuário do domínio: " input_user
                [ -n "$input_user" ] && ADMIN_USERNAME="$input_user"
            else
                log_nivel INFO "Usuário: ${ADMIN_USERNAME}"
            fi

            log_nivel INFO "Tentando kinit para ${ADMIN_USERNAME}@${REALM} ..."
            if kinit "${ADMIN_USERNAME}@${REALM}"; then
                KINIT_OK=true
            else
                log_nivel INFO "Falhou. Verifique a senha e conectividade com o DC."
                read -p ">>> Tentar novamente? (S/n): " try_again
                [[ "$try_again" =~ ^[Nn]$ ]] && break
                ADMIN_USERNAME=""
            fi
        done
    fi

    # Abortar em non-interactive quando kinit falha - sem isso o
    # script segue com JOIN_METHOD=nenhum e deixa a estacao em estado
    # "meio-ingressada" (pior cenario para depurar).
    if [ "$KINIT_OK" != "true" ]; then
        log_nivel ERRO "Falha ao obter ticket Kerberos."
        log_nivel INFO "Verifique as credenciais e conectividade com o DC."
        exit 1
    fi
    log_nivel OK "Ticket Kerberos obtido com sucesso!"

    # Tentar ingresso via realm join (SSSD)
    JOIN_OK=false
    JOIN_METHOD=""

    # --computer-ou so e passado quando definido; vazio faz o AD
    # usar a OU padrao de computadores em vez de rejeitar o join
    REALM_JOIN_ARGS=(--user="$ADMIN_USERNAME" --verbose)
    if [ -n "$OU_PADRAO" ]; then
        REALM_JOIN_ARGS+=(--computer-ou="$OU_PADRAO")
    fi

    log_nivel INFO "Ingressando no dominio via realm join (SSSD)..."
    if echo "$ADMIN_PASSWORD" | realm join "$DOMINIO" "${REALM_JOIN_ARGS[@]}" 2>&1; then
        JOIN_OK=true
        JOIN_METHOD="sssd"
        log_nivel OK "Ingresso via SSSD (realm join) bem-sucedido!"
    else
        log_nivel ERRO "realm join falhou"
        log_nivel DIAG "Kerberos rejeitou o ticket antes de validar a senha"
        log_nivel DIAG "3 causas provaveis, em ordem de probabilidade:"
        log_nivel DIAG "  1. Clock skew > 5min (servidor e estacao fora de sincronia)"
        log_nivel DIAG "  2. Senha do admin de ingresso incorreta no painel"
        log_nivel DIAG "  3. Conta bloqueada ou sem permissao para ingresso"
        log_nivel ACAO "Confirmar horario: seederlinux-sync-ntp  (ou 'date' vs horario do AD)"
        log_nivel ACAO "Se senha: refazer bundle no painel com a senha correta"
        log_nivel ACAO "Se conta: desbloquear no AD (ADUC / Set-ADAccount -Enabled)"
    fi

    # Fallback: net ads join (Winbind)
    if [ "$JOIN_OK" != "true" ]; then
        log_nivel INFO "Tentando fallback com net ads join (Winbind)..."

        if ! grep -q "kerberos method" /etc/samba/smb.conf; then
            sed -i '/\[global\]/a\    kerberos method = secrets and keytab' /etc/samba/smb.conf
        fi

        # -S aceita IP diretamente; usar DC_IP em vez de tentar
        # adivinhar o hostname do DC por convencao de nome
        NET_JOIN_ARGS=(-U "$ADMIN_USERNAME" -S "$DC_IP")
        if [ -n "$OU_PADRAO" ]; then
            NET_JOIN_ARGS+=(createcomputer="$OU_PADRAO")
        fi

        if echo "$ADMIN_PASSWORD" | net ads join "$DOMINIO" "${NET_JOIN_ARGS[@]}" 2>&1; then
            JOIN_OK=true
            JOIN_METHOD="winbind"
            log_nivel OK "Ingresso via Winbind (net ads join) bem-sucedido!"

            # net ads join NAO gera o keytab de maquina sozinho.
            # Como ja temos um ticket Kerberos valido em cache (kinit
            # acima), "net ads keytab create" usa esse cache
            # automaticamente - nao aceita/precisa de senha via -P.
            log_nivel INFO "Gerando keytab..."
            if ! net ads keytab create 2>/dev/null; then
                log_nivel INFO "net ads keytab create falhou. Tentando via adcli..."
                echo "$ADMIN_PASSWORD" | adcli join "$DOMINIO" \
                    --login-user="$ADMIN_USERNAME" \
                    ${OU_PADRAO:+--domain-ou="$OU_PADRAO"} \
                    --stdin-password 2>&1 || {
                    log_nivel AVISO "Falha ao gerar keytab. Login offline pode nao funcionar."
                }
            fi
        else
            log_nivel ERRO "net ads join falhou"
            log_nivel DIAG "SSSD falhou E Winbind tambem falhou - problema e' mais fundo"
            log_nivel DIAG "Provavel: DNS do AD nao resolve, ou firewall L3 bloqueando,"
            log_nivel DIAG "         ou conta de maquina ja existe no AD (duplicata)"
            log_nivel ACAO "Verificar: host -t SRV _ldap._tcp.dc._msdcs.$DOMINIO"
            log_nivel ACAO "Verificar: ping ao DC e portas 389/445/88 abertas"
            log_nivel ACAO "Se conta duplicada: remover do AD e reexecutar bundle"
        fi
    fi

    if [ "$JOIN_OK" != "true" ]; then
        log_nivel ERRO "Falha ao ingressar no domínio com todos os métodos."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            CONTINUE="s"
        else
            read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
        fi
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            log_nivel INFO "Instalação abortada pelo usuário."
            exit 1
        fi
        JOIN_METHOD="nenhum"
    fi
fi  # Fim do bloco de ingresso

# ============================================================
# ESTÁGIO 5: CONFIGURAÇÃO PÓS-INGRESSO E VALIDAÇÃO
# ============================================================
echo ""
log_nivel INFO "ESTÁGIO 5: Configuração e validação"

# Configurar SSSD (se método for sssd)
if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    log_nivel INFO "Configurando SSSD..."
    OFFLINE_CACHE=""
    if [ "$OFFLINE_AUTH_ENABLED" = "true" ]; then
        OFFLINE_CACHE="$(printf '    cache_credentials = true\n    krb5_store_password_if_offline = true\n    offline_credentials_expiration = %s' "${OFFLINE_AUTH_DAYS:-3}")"
    fi

    # ad_hostname: evitar duplicar o dominio se o hostname atual ja
    # vier como FQDN (ex: se um core_dns.sh anterior setou
    # hostnamectl com FQDN completo). Sem isso, sssd.conf fica com
    # "host.dominio.dominio" e o SSSD nao sobe.
    _HN_NOW="$(hostname)"

    # Se o hostname ja termina com .$DOMINIO, e FQDN real — usa como esta.
    # Senao, pega so a primeira parte (antes do primeiro ponto) e
    # adiciona o dominio. Isso evita que hostnames como
    # "seeder-client11.2" virem "seeder-client11.2" no ad_hostname,
    # quando o SPN no AD e "seeder-client11".
    if echo "$_HN_NOW" | grep -q "\.${DOMINIO}$"; then
        SSSD_AD_HOSTNAME="$_HN_NOW"
    else
        _HN_SHORT="${_HN_NOW%%.*}"
        SSSD_AD_HOSTNAME="${_HN_SHORT}.${DOMINIO}"
    fi

    # /home/%u (nao /home/%d/%u): o snap do Firefox no Ubuntu 24.04+
    # usa AppArmor que restringe /home/*/snap — /home/dominio/usuario/snap
    # nao bate com o pattern e o snap falha com Permission denied.
    cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam, sudo
config_file_version = 2
domains = ${DOMINIO}

[domain/${DOMINIO}]
    id_provider = ad
    ad_domain = ${DOMINIO}
    ad_server = dc-${OM_ACRONYM,,}.${DOMINIO}
    ad_backup_server = ${DC_IP}
    krb5_server = ${DC_IP}
    krb5_backup_server = ${DC_IP}
    ad_hostname = ${SSSD_AD_HOSTNAME}
    ldap_id_mapping = true
    ldap_schema = ad
    ldap_user_principal = userPrincipalName
    ldap_user_name = sAMAccountName
    ldap_user_gecos = displayName
    ldap_user_home_directory = unixHomeDirectory
    ldap_user_shell = loginShell
    enumerate = false
    use_fully_qualified_names = false
    fallback_homedir = /home/%u
    default_shell = /bin/bash
    krb5_use_fast = never
${OFFLINE_CACHE}
    dyndns_update = false
EOF

    chmod 600 /etc/sssd/sssd.conf
    log_nivel INFO "SSSD configurado (ad_hostname=${SSSD_AD_HOSTNAME})"

    # SSSD 2.9+ (Ubuntu 24.04+): o aviso "Misconfiguration found for
    # the 'nss' responder" entre services= e socket activation e'
    # COSMETICO — nao impede o sssd.service de subir. NAO desabilitar
    # os sockets: no Ubuntu 24.04 o sssd.service depende deles para
    # alguns responders e disable --now quebra o start.
    # Mantemos services = nss, pam, sudo E os sockets convivendo.
    log_nivel INFO "SSSD: mantendo socket activation (nao desabilitar sockets)."
fi

# Configurar NSS
log_nivel INFO "Configurando NSS..."
if [ "$JOIN_METHOD" = "winbind" ]; then
    cat > /etc/nsswitch.conf <<EOF
passwd:     files systemd winbind
shadow:     files winbind
group:      files systemd winbind
gshadow:    files

hosts:      files dns

services:   files
netgroup:   files
sudoers:    files

automount:  files
EOF
else
    cat > /etc/nsswitch.conf <<EOF
passwd:     files systemd sss
shadow:     files sss
group:      files systemd sss
gshadow:    files

hosts:      files dns

services:   files sss
netgroup:   files sss
sudoers:    files sss

automount:  files sss
EOF
fi

log_nivel INFO "NSS configurado"

# Configurar PAM (mkhomedir)
log_nivel INFO "Configurando PAM e mkhomedir..."
pam-auth-update --enable mkhomedir --force 2>/dev/null || true

if [ -f /etc/pam.d/common-session ]; then
    grep -q "pam_mkhomedir" /etc/pam.d/common-session || \
        echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session
fi

log_nivel INFO "PAM configurado"

# Configurar sudo para grupos do domínio
log_nivel INFO "Configurando sudo..."
SUDO_FILE="/etc/sudoers.d/seederlinux-domain"
_sudo_candidatos=()

if [ -n "${GRUPO_ADMIN_LINUX:-}" ]; then
    IFS=',' read -ra _tmp <<< "$GRUPO_ADMIN_LINUX"
    for _g in "${_tmp[@]}"; do
        _g="$(echo "$_g" | xargs)"
        [ -n "$_g" ] && _sudo_candidatos+=("$_g")
    done
fi

_sudo_candidatos+=("_dasti" "admins. do domínio")

_sudo_deduplicados=()
while IFS= read -r _g; do
    _sudo_deduplicados+=("$_g")
done < <(printf '%s\n' "${_sudo_candidatos[@]}" | awk '!seen[$0]++')
_sudo_candidatos=("${_sudo_deduplicados[@]}")

# ============================================================
# Aquecer o cache do SSSD antes de consultar getent group.
# Motivo: logo apos restart do sssd, o cache pode estar vazio -
# o getent retorna vazio para grupos que existem no AD, e o
# sudoers fica sem regra (bug observado em campo).
#
# Sentinela: o USUÁRIO de ingresso (ADMIN_USERNAME), que sempre
# existe no AD depois de um kinit bem-sucedido. NÃO usar o
# primeiro grupo da lista de candidatos — alguns podem não
# existir no AD (ex: linux-admins) e o retry giraria 30s à toa.
#
# Estratégia: reinicia sssd, aguarda até 30s com retry no
# sentinela. Se o sentinela resolver, prossegue; se não, avisa
# mas continua (alguns grupos podem não existir mesmo).
# ============================================================
log_nivel INFO "Aguardando cache do SSSD popular..."
systemctl restart sssd 2>/dev/null || true
sleep 3

if [ -n "${ADMIN_USERNAME:-}" ]; then
    _tent=0
    while [ "$_tent" -lt 15 ]; do
        if getent passwd "$ADMIN_USERNAME" >/dev/null 2>&1; then
            log_nivel INFO "Cache populado (usuario '$ADMIN_USERNAME' resolvido)"
            break
        fi
        _tent=$((_tent + 1))
        sleep 2
    done
    if [ "$_tent" -ge 15 ]; then
        log_nivel AVISO "cache do SSSD nao populou '$ADMIN_USERNAME' em 30s"
        log_nivel DIAG  "Pode ser que o SSSD esteja com problema, ou o AD inacessivel"
    fi
else
    log_nivel AVISO "ADMIN_USERNAME vazio - pulando aquecimento do cache"
fi

{
    echo "# SeederLinux - Acesso sudo para grupos do dominio"
    echo "# Regras por GID numerico para evitar problemas com case,"
    echo "# espacos e acentos nos nomes de grupo do AD."
    echo ""

    _sudo_gids_adicionados=0
    for _grupo_nome in "${_sudo_candidatos[@]}"; do
        _gid="$(getent group "$_grupo_nome" 2>/dev/null | cut -d: -f3)"
        if [ -n "$_gid" ]; then
            echo "%#${_gid}    ALL=(ALL:ALL) ALL  # $_grupo_nome"
            _sudo_gids_adicionados=$((_sudo_gids_adicionados + 1))
            echo ">>> Sudoers: grupo '$_grupo_nome' (gid=$_gid) adicionado" >&2
        else
            echo ">>> Sudoers: grupo '$_grupo_nome' nao existe - pulado" >&2
        fi
    done
} > "$SUDO_FILE"

chmod 440 "$SUDO_FILE"
if [ "$_sudo_gids_adicionados" -gt 0 ]; then
    visudo -cf "$SUDO_FILE" || {
        log_nivel ERRO "sintaxe do sudoers inválida"
        exit 1
    }
else
    log_nivel AVISO "nenhum grupo de sudo encontrado no AD."
    log_nivel AVISO "Nenhum usuario de dominio tera sudo nesta estacao."
fi

log_nivel INFO "Sudo configurado"

# Reiniciar serviços
log_nivel INFO "Reiniciando serviços..."
if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    systemctl restart sssd 2>/dev/null || true
    systemctl enable sssd
fi

if [ "$JOIN_METHOD" = "winbind" ] || [ "$ESTADO" = "INGRESSADO_WINBIND" ]; then
    systemctl restart winbind 2>/dev/null || true
    systemctl enable winbind
fi

systemctl restart samba 2>/dev/null || true

# ============================================================
# VALIDAÇÃO FINAL
# ============================================================
echo ""
log_nivel INFO "Validação final..."

VALIDATION_OK=true

if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    echo "--- Testes SSSD ---"
    if systemctl is-active --quiet sssd; then
        echo "✔ SSSD ativo"
    else
        echo "✘ SSSD NÃO está ativo"
        VALIDATION_OK=false
    fi

    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "✔ Keytab presente"
    else
        echo "✘ Keytab ausente ou vazio"
        VALIDATION_OK=false
    fi

    if realm list 2>/dev/null | grep -q "$DOMINIO"; then
        echo "✔ Realm associado"
    else
        echo "✘ Realm NÃO associado"
        VALIDATION_OK=false
    fi
fi

if [ "$JOIN_METHOD" = "winbind" ] || [ "$ESTADO" = "INGRESSADO_WINBIND" ]; then
    echo "--- Testes Winbind ---"
    if systemctl is-active --quiet winbind; then
        echo "✔ Winbind ativo"
    else
        echo "✘ Winbind NÃO está ativo"
        VALIDATION_OK=false
    fi

    if net ads testjoin > /dev/null 2>&1; then
        echo "✔ Testjoin OK"
    else
        echo "✘ Testjoin FALHOU"
        VALIDATION_OK=false
    fi

    if [ -f /etc/krb5.keytab ] && [ -s /etc/krb5.keytab ]; then
        echo "✔ Keytab presente"
    else
        echo "✘ Keytab ausente ou vazio (login offline pode nao funcionar)"
        VALIDATION_OK=false
    fi
fi

if [ "$VALIDATION_OK" = "false" ]; then
    echo ""
    log_nivel AVISO "Alguns testes de validação falharam."
    log_nivel INFO "O ingresso pode não estar completamente funcional."
    if [ "$NON_INTERACTIVE" = "true" ]; then
        CONTINUE="s"
    else
        read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
    fi
fi

echo ""
log_nivel INFO "Gerenciamento de AD concluído! Método: ${JOIN_METHOD:-$ESTADO}"
echo "============================================================="