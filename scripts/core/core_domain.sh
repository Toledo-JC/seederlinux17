#!/bin/bash
# ============================================================================
# Core Script: core_domain.sh (v3 - State Machine)
# SeederLinux Lite - Gerenciador de Estado do Active Directory
# ============================================================================
# Implementa uma máquina de estados para diagnosticar, classificar e
# corrigir o ingresso no AD, suportando SSSD (realm join) e Winbind
# (net ads join) como fallback.
#
# Estagios: 1) Diagnostico  2) Classificacao  3) Decisao
#           4) Execucao (somente se necessario)  5) Pos-ingresso + Validacao
#
# Os placeholders {{VARIAVEL}} sao substituidos automaticamente
# pelo sistema na geracao do bundle. Variaveis sensiveis usam o
# formato __VARIAVEL__ (substituicao separada, nunca em texto plano
# no restante do bundle).
# ============================================================================

set -e

echo "============================================================"
echo "04 - Gerenciador de Estado do Active Directory"
echo "============================================================"

# ============================================================
# Variáveis (substituídas no bundle)
# ============================================================
DOMINIO="{{DOMINIO}}"
DOMINIO_NETBIOS="{{DOMINIO_NETBIOS}}"
DC_IP="{{DC_IP}}"
DC_IP_LIST="{{DC_IP_LIST}}"
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
    echo ">>> ERRO: placeholder ADMIN_USERNAME nao foi substituido pelo backend."
    exit 1
fi
if [[ "$ADMIN_PASSWORD_B64" == "__"* && "$ADMIN_PASSWORD_B64" == *"__" ]]; then
    echo ">>> ERRO: placeholder ADMIN_PASSWORD_B64 nao foi substituido pelo backend."
    exit 1
fi

ADMIN_PASSWORD=""
if [ -n "$ADMIN_PASSWORD_B64" ]; then
    ADMIN_PASSWORD=$(printf '%s' "$ADMIN_PASSWORD_B64" | base64 -d 2>/dev/null) || ADMIN_PASSWORD=""
fi
unset ADMIN_PASSWORD_B64

NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
if [ "$NON_INTERACTIVE" = "true" ]; then
    echo ">>> Modo não interativo ativado."
fi

echo ">>> Dominio: $DOMINIO"
echo ">>> NetBIOS: $DOMINIO_NETBIOS"
echo ">>> DC principal: $DC_IP"
[ -n "$DC_IP_LIST" ] && echo ">>> DCs adicionais: $DC_IP_LIST"

# ============================================================
# ESTÁGIO 1: DIAGNÓSTICO
# ============================================================
echo "============================================================"
echo ">>> ESTÁGIO 1: Diagnóstico do ambiente AD"
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
    if net ads testjoin > /dev/null 2>&1; then
        echo "Conta AD........ OK (verificada)"
        return 0
    else
        if adcli testjoin --domain="$DOMINIO" > /dev/null 2>&1; then
            echo "Conta AD........ OK (adcli)"
            return 0
        else
            echo "Conta AD........ NÃO (não verificada)"
            return 1
        fi
    fi
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
echo ">>> ESTÁGIO 2: Classificando estado atual"

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

echo ">>> Estado detectado: $ESTADO"

# ============================================================
# Bloqueio preventivo: DNS/tempo quebrados antes de tentar ingresso
# Kerberos depende diretamente dos dois - sem isso, kinit/realm join
# falham de forma confusa la na frente. Avisamos aqui, cedo.
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ] || [ "$ESTADO" = "INDETERMINADO" ]; then
    if [ "$DNS_OK" = "false" ] || [ "$TIME_OK" = "false" ]; then
        echo ""
        echo ">>> AVISO: pre-requisitos do Kerberos com problema:"
        [ "$DNS_OK" = "false" ] && echo "    - DNS nao resolve $DOMINIO (verifique DC_IP/DNS_PRIMARIO)"
        [ "$TIME_OK" = "false" ] && echo "    - Relogio fora de sincronia (Kerberos rejeita diferenca > 5min)"
        if [ "$NON_INTERACTIVE" = "true" ]; then
            echo ">>> Modo nao interativo: prosseguindo mesmo assim (provavel falha adiante)."
        else
            read -p ">>> Deseja continuar mesmo assim? (s/N): " CONTINUE_APESAR_DE
            if [[ ! "$CONTINUE_APESAR_DE" =~ ^[Ss]$ ]]; then
                echo ">>> Instalação abortada pelo usuário."
                exit 1
            fi
        fi
    fi
fi

# ============================================================
# ESTÁGIO 3: DECISÃO
# ============================================================
echo ""
echo ">>> ESTÁGIO 3: Decisão sobre ação necessária"

case "$ESTADO" in
    INGRESSADO_SSSD|INGRESSADO_HIBRIDO)
        echo ">>> A máquina já está ingressada via SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REINGRESSAR="n"
        else
            read -p ">>> Deseja reingressar (remover e ingressar novamente)? (s/N): " REINGRESSAR
        fi
        if [[ "$REINGRESSAR" =~ ^[Ss]$ ]]; then
            echo ">>> Removendo ingresso existente..."
            realm_leave_safe
            net_ads_leave_safe
            ESTADO="NAO_INGRESSADO"
        else
            echo ">>> Mantendo ingresso existente. Pulando ingresso."
        fi
        ;;

    INGRESSADO_WINBIND)
        echo ">>> A máquina está ingressada via Winbind (método legado)."
        echo ">>> Recomenda-se migrar para SSSD."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            MIGRAR="s"
        else
            read -p ">>> Deseja migrar para SSSD (remover Winbind e ingressar via realm)? (S/n): " MIGRAR
        fi
        if [[ ! "$MIGRAR" =~ ^[Nn]$ ]]; then
            echo ">>> Removendo ingresso Winbind..."
            net_ads_leave_safe
            systemctl stop winbind 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
        else
            echo ">>> Mantendo Winbind. Pulando ingresso."
        fi
        ;;

    CORROMPIDO|PARCIAL)
        echo ">>> AVISO: Estado inconsistente detectado ($ESTADO)."
        echo ">>> Possíveis causas: keytab ausente, SSSD parado, ou ingresso parcial."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            REPARAR="s"
        else
            read -p ">>> Deseja reparar automaticamente? (S/n): " REPARAR
        fi
        if [[ ! "$REPARAR" =~ ^[Nn]$ ]]; then
            echo ">>> Executando limpeza completa..."
            realm_leave_safe
            net_ads_leave_safe
            rm -f /etc/krb5.keytab
            systemctl stop sssd 2>/dev/null || true
            systemctl stop winbind 2>/dev/null || true
            # Limpar caches
            rm -rf /var/lib/sss/db/* 2>/dev/null || true
            rm -rf /var/lib/sss/mc/* 2>/dev/null || true
            ESTADO="NAO_INGRESSADO"
            echo ">>> Limpeza concluída."
        else
            echo ">>> Prosseguindo sem reparar (pode falhar)."
        fi
        ;;

    INDETERMINADO)
        echo ">>> Estado indeterminado. Tentando ingresso como máquina nova."
        ESTADO="NAO_INGRESSADO"
        ;;
esac

# ============================================================
# ESTÁGIO 4: EXECUÇÃO (apenas se necessário)
# ============================================================
if [ "$ESTADO" = "NAO_INGRESSADO" ]; then
    echo ""
    echo ">>> ESTÁGIO 4: Executando ingresso no domínio"

    # ------------------------------------------------------------
    # Ajustar DNS para o(s) DC(s) - o DC principal primeiro, os
    # demais de DC_IP_LIST como fallback. Sem isso, se o DC_IP
    # unico estiver fora do ar, o ingresso falha desnecessariamente.
    # ------------------------------------------------------------
    echo ">>> Ajustando DNS para ingresso no dominio..."
    {
        echo "nameserver $DC_IP"
        for dc in $DC_IP_LIST; do
            [ "$dc" != "$DC_IP" ] && echo "nameserver $dc"
        done
        echo "search $DOMINIO"
    } > /etc/resolv.conf

    # Configurar Kerberos
    echo ">>> Configurando Kerberos..."
    REALM="${DOMINIO^^}"
    cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    rdns = false
    ticket_lifetime = 24h
    forwardable = yes
    renew_lifetime = 7d

[realms]
    ${REALM} = {
        kdc = ${DC_IP}
        admin_server = ${DC_IP}
    }

[domain_realm]
    .${DOMINIO} = ${REALM}
    ${DOMINIO} = ${REALM}
EOF

    # Configurar Samba
    echo ">>> Configurando Samba..."
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
    echo ">>> Obtendo ticket Kerberos..."
    KINIT_OK=false

        if [ -n "$ADMIN_PASSWORD" ]; then
        echo ">>> Tentando obter ticket com senha pre-definida..."
        # --password-file=STDIN e a unica forma confiavel de passar senha
        # ao kinit do MIT Kerberos. Um simples `echo "$SENHA" | kinit user`
        # NAO funciona de forma confiavel: kinit relê a senha de /dev/tty
        # quando o pipe nao esta no formato esperado, e cai em prompt
        # interativo (foi o que causou o "Password for ...@REALM:" no log).
        echo "$ADMIN_PASSWORD" | kinit --password-file=STDIN "${ADMIN_USERNAME}@${REALM}" 2>/dev/null && KINIT_OK=true
        [ "$KINIT_OK" != "true" ] && echo "$ADMIN_PASSWORD" | kinit --password-file=STDIN "${ADMIN_USERNAME}@${DOMINIO_NETBIOS}" 2>/dev/null && KINIT_OK=true
        [ "$KINIT_OK" != "true" ] && echo "$ADMIN_PASSWORD" | kinit --password-file=STDIN "${ADMIN_USERNAME,,}@${REALM}" 2>/dev/null && KINIT_OK=true
        [ "$KINIT_OK" != "true" ] && echo "$ADMIN_PASSWORD" | kinit --password-file=STDIN "${ADMIN_USERNAME,,}@${DOMINIO,,}" 2>/dev/null && KINIT_OK=true
    elif [ "$NON_INTERACTIVE" = "true" ]; then
        echo ">>> ERRO: ADMIN_PASSWORD nao definido em modo nao interativo."
    fi

    # Modo interativo se pipe falhou
    if [ "$KINIT_OK" != "true" ] && [ "$NON_INTERACTIVE" != "true" ]; then
        echo ">>> Não foi possível obter ticket automaticamente."
        echo ">>> Solicitando credenciais interativamente..."
        while [ "$KINIT_OK" != "true" ]; do
            if [ -z "$ADMIN_USERNAME" ] || [ "$ADMIN_USERNAME" = "Administrator" ]; then
                read -p ">>> Usuário do domínio: " input_user
                [ -n "$input_user" ] && ADMIN_USERNAME="$input_user"
            else
                echo ">>> Usuário: ${ADMIN_USERNAME}"
            fi

            echo ">>> Tentando kinit para ${ADMIN_USERNAME}@${REALM} ..."
            if kinit "${ADMIN_USERNAME}@${REALM}"; then
                KINIT_OK=true
            else
                echo ">>> Falhou. Verifique a senha e conectividade com o DC."
                read -p ">>> Tentar novamente? (S/n): " try_again
                [[ "$try_again" =~ ^[Nn]$ ]] && break
                ADMIN_USERNAME=""
            fi
        done
    fi

    if [ "$KINIT_OK" != "true" ]; then
        echo ">>> ERRO: Falha ao obter ticket Kerberos."
        echo ">>> Verifique as credenciais e conectividade com o DC."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            echo ">>> Modo não interativo: continuando sem pedir senha."
        else
            exit 1
        fi
    fi
    echo ">>> Ticket Kerberos obtido com sucesso!"

    # Tentar ingresso via realm join (SSSD)
    JOIN_OK=false
    JOIN_METHOD=""

    # --computer-ou so e passado quando definido; vazio faz o AD
    # usar a OU padrao de computadores em vez de rejeitar o join
    REALM_JOIN_ARGS=(--user="$ADMIN_USERNAME" --verbose)
    if [ -n "$OU_PADRAO" ]; then
        REALM_JOIN_ARGS+=(--computer-ou="$OU_PADRAO")
    fi

    echo ">>> Ingressando no domínio via realm join (SSSD)..."
    if echo "$ADMIN_PASSWORD" | realm join "$DOMINIO" "${REALM_JOIN_ARGS[@]}" 2>&1; then
        JOIN_OK=true
        JOIN_METHOD="sssd"
        echo ">>> Ingresso via SSSD (realm join) bem-sucedido!"
    else
        echo ">>> realm join falhou."
    fi

    # Fallback: net ads join (Winbind)
    if [ "$JOIN_OK" != "true" ]; then
        echo ">>> Tentando fallback com net ads join (Winbind)..."

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
            echo ">>> Ingresso via Winbind (net ads join) bem-sucedido!"

            # net ads join NAO gera o keytab de maquina sozinho.
            # Como ja temos um ticket Kerberos valido em cache (kinit
            # acima), "net ads keytab create" usa esse cache
            # automaticamente - nao aceita/precisa de senha via -P.
            echo ">>> Gerando keytab..."
            if ! net ads keytab create 2>/dev/null; then
                echo ">>> net ads keytab create falhou. Tentando via adcli..."
                echo "$ADMIN_PASSWORD" | adcli join "$DOMINIO" \
                    --login-user="$ADMIN_USERNAME" \
                    ${OU_PADRAO:+--domain-ou="$OU_PADRAO"} \
                    --stdin-password 2>&1 || {
                    echo ">>> AVISO: Falha ao gerar keytab. Login offline pode nao funcionar."
                }
            fi
        else
            echo ">>> net ads join falhou."
        fi
    fi

    if [ "$JOIN_OK" != "true" ]; then
        echo ">>> ERRO: Falha ao ingressar no domínio com todos os métodos."
        if [ "$NON_INTERACTIVE" = "true" ]; then
            CONTINUE="s"
        else
            read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
        fi
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            echo ">>> Instalação abortada pelo usuário."
            exit 1
        fi
        JOIN_METHOD="nenhum"
    fi
fi  # Fim do bloco de ingresso

# ============================================================
# ESTÁGIO 5: CONFIGURAÇÃO PÓS-INGRESSO E VALIDAÇÃO
# ============================================================
echo ""
echo ">>> ESTÁGIO 5: Configuração e validação"

# Configurar SSSD (se método for sssd)
if [ "$JOIN_METHOD" = "sssd" ] || [ "$ESTADO" = "INGRESSADO_SSSD" ] || [ "$ESTADO" = "INGRESSADO_HIBRIDO" ]; then
    echo ">>> Configurando SSSD..."
    OFFLINE_CACHE=""
    if [ "$OFFLINE_AUTH_ENABLED" = "true" ]; then
        DAYS="${OFFLINE_AUTH_DAYS:-3}"
        OFFLINE_CACHE="cache_credentials = true
        krb5_store_password_if_offline = true
        offline_credentials_expiration = ${DAYS}"
    fi

    cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam, sudo
config_file_version = 2
domains = ${DOMINIO}

[domain/${DOMINIO}]
    id_provider = ad
    ad_domain = ${DOMINIO}
    ad_server = ${DC_IP}
    ad_hostname = $(hostname).${DOMINIO}
    ldap_id_mapping = true
    enumerate = false
    use_fully_qualified_names = false
    fallback_homedir = /home/%d/%u
    default_shell = /bin/bash
    krb5_use_fast = false
    ${OFFLINE_CACHE}
    dyndns_update = false
    sudo_provider = ad
    ldap_sudo_search_base = OU=sudoers,${OU_PADRAO}
EOF

    chmod 600 /etc/sssd/sssd.conf
    echo ">>> SSSD configurado"
fi

# Configurar NSS
echo ">>> Configurando NSS..."
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

echo ">>> NSS configurado"

# Configurar PAM (mkhomedir)
echo ">>> Configurando PAM e mkhomedir..."
pam-auth-update --enable mkhomedir --force 2>/dev/null || true

if [ -f /etc/pam.d/common-session ]; then
    grep -q "pam_mkhomedir" /etc/pam.d/common-session || \
        echo "session required pam_mkhomedir.so skel=/etc/skel umask=0022" >> /etc/pam.d/common-session
fi

echo ">>> PAM configurado"

# Configurar sudo para grupos do domínio
echo ">>> Configurando sudo..."
SUDO_FILE="/etc/sudoers.d/seederlinux-domain"
cat > "$SUDO_FILE" <<EOF
# SeederLinux - Acesso sudo para grupos do domínio
%${GRUPO_ADMIN_AD}    ALL=(ALL:ALL) ALL
%${GRUPO_ADMIN_LINUX}  ALL=(ALL:ALL) ALL
EOF

if [ -n "$GRUPO_DASTI" ] && [ "$GRUPO_DASTI" != "" ]; then
    echo "%${GRUPO_DASTI}    ALL=(ALL:ALL) ALL" >> "$SUDO_FILE"
fi

chmod 440 "$SUDO_FILE"
visudo -cf "$SUDO_FILE" || {
    echo ">>> ERRO: sintaxe do sudoers inválida"
    exit 1
}

echo ">>> Sudo configurado"

# Reiniciar serviços
echo ">>> Reiniciando serviços..."
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
echo ">>> Validação final..."

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
    echo ">>> AVISO: Alguns testes de validação falharam."
    echo ">>> O ingresso pode não estar completamente funcional."
    if [ "$NON_INTERACTIVE" = "true" ]; then
        CONTINUE="s"
    else
        read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
    fi
fi

echo ""
echo ">>> [04] Gerenciamento de AD concluído! Método: ${JOIN_METHOD:-$ESTADO}"
echo "============================================================="
