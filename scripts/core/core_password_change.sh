#!/bin/bash
# ============================================================================
# Core Script: core_password_change.sh
# SeederLinux Lite - Troca de Senha do Active Directory
# ============================================================================
# Instala um aplicativo gráfico (Zenity) para troca de senha no AD.
# É executado pelo bundle para instalar o script; a troca de senha
# em si é feita pelo usuário quando desejar.
# ============================================================================

(
set -e

source /usr/local/lib/seederlinux/diag.sh 2>/dev/null || true
SCRIPT_ID="20-password-change"

echo "============================================================"
echo "Instalar aplicativo de troca de senha AD"
echo "============================================================"

INSTALL_PASSWORD_CHANGER="{{INSTALL_PASSWORD_CHANGER}}"

if [ "$INSTALL_PASSWORD_CHANGER" != "true" ]; then
    log_nivel INFO "Instalacao do trocador de senha desativada. Pulando."
    log_nivel INFO "[16] Trocador de senha ignorado."
    echo "============================================================"
    exit 0
fi

DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"

log_nivel INFO "Instalando aplicativo de troca de senha..."

# Criar o script de troca de senha
cat > /usr/local/bin/trocar-senha << 'EOFSCRIPT'
#!/bin/bash
# ============================================================================
# Troca de Senha - Active Directory
# Interface gráfica com Zenity para alteração de senha no domínio
# ============================================================================

DOMINIO="{{DOMINIO}}"
OM_ACRONYM="{{OM_ACRONYM}}"

trocar_senha() {
    IFS='|' read -r OldPasswd NewPasswd1 NewPasswd2 <<< \
    $(zenity --forms --title="Trocar Senha do Usuário" \
        --text="Usuário: $USER\nDomínio: $DOMINIO" \
        --add-password="Senha atual" \
        --add-password="Nova Senha" \
        --add-password="Confirme a nova senha" \
        --width=450 \
        --height=250)

    if [ -z "$OldPasswd" ] || [ -z "$NewPasswd1" ]; then
        zenity --error --title="Erro" --text="Todos os campos devem ser preenchidos."
        return 1
    fi

    while [ "$NewPasswd1" != "$NewPasswd2" ]; do
        NewPasswd1=$(zenity --entry \
            --title="Trocar Senha" \
            --text="As senhas não coincidem!\n\nDigite a nova senha:" \
            --hide-text \
            --width=400)

        if [ -z "$NewPasswd1" ]; then
            zenity --error --title="Erro" --text="Operação cancelada."
            return 1
        fi

        NewPasswd2=$(zenity --entry \
            --title="Trocar Senha" \
            --text="Confirme a nova senha:" \
            --hide-text \
            --width=400)
    done

    if [ ${#NewPasswd1} -lt 7 ]; then
        zenity --error \
            --title="Senha muito curta" \
            --text="A nova senha deve ter no mínimo 7 caracteres.\n\nRequisitos do Active Directory:\n• Mínimo 7 caracteres\n• Pelo menos 3 dos 4 tipos:\n  - Maiúsculas (A-Z)\n  - Minúsculas (a-z)\n  - Números (0-9)\n  - Símbolos (@#\$% etc)"
        return 1
    fi

    DC_ONLINE=""
    for DC in $(host -t SRV _ldap._tcp.$DOMINIO 2>/dev/null | awk '{print $NF}' | sed 's/\.$//'); do
        if ping -c 1 -W 2 "$DC" > /dev/null 2>&1; then
            DC_ONLINE="$DC"
            break
        fi
    done

    if [ -z "$DC_ONLINE" ]; then
        DC_ONLINE="dc-${OM_ACRONYM,,}.$DOMINIO"
    fi

    echo -e "$OldPasswd\n$NewPasswd1\n$NewPasswd1" | smbpasswd -r "$DC_ONLINE" -U "$USER" > /tmp/password-change.log 2>&1

    if grep -q "Password changed" /tmp/password-change.log; then
        zenity --info \
            --title="Sucesso" \
            --text="Senha alterada com sucesso!\n\nA nova senha entrará em vigor imediatamente.\nRecomenda-se fazer logoff e login novamente." \
            --width=400
        rm -f /tmp/password-change.log
        return 0
    else
        ERRO=$(cat /tmp/password-change.log 2>/dev/null | tail -5)
        zenity --error \
            --title="Erro ao trocar senha" \
            --text="Não foi possível alterar a senha.\n\nMotivos possíveis:\n• Senha atual incorreta\n• Senha nova não atende aos requisitos\n• Controlador de domínio indisponível\n\nDetalhes técnicos:\n$ERRO" \
            --width=500
        rm -f /tmp/password-change.log
        return 1
    fi
}

if ! command -v zenity &>/dev/null; then
    echo "Erro: zenity não está instalado."
    echo "Execute: sudo apt-get install -y zenity"
    exit 1
fi

if ! command -v smbpasswd &>/dev/null; then
    echo "Erro: smbpasswd não está instalado."
    echo "Execute: sudo apt-get install -y samba-common-bin"
    exit 1
fi

trocar_senha

exit $?
EOFSCRIPT

chmod 755 /usr/local/bin/trocar-senha
log_nivel INFO "Script de troca de senha instalado em /usr/local/bin/trocar-senha"

# Criar entrada no menu de aplicativos
cat > /usr/share/applications/trocar-senha.desktop << EOF
[Desktop Entry]
Version=1.0
Name=Trocar Senha
Name[pt_BR]=Trocar Senha
Comment=Alterar senha do Active Directory
Comment[pt_BR]=Alterar senha do Active Directory
Exec=/usr/local/bin/trocar-senha
Icon=dialog-password
Terminal=false
Type=Application
Categories=System;Settings;
StartupNotify=true
EOF

log_nivel INFO "Atalho no menu criado"

# Criar atalho na área de trabalho (todos os usuários futuros via /etc/skel)
if [ -d /etc/skel ]; then
    mkdir -p /etc/skel/Desktop
    cp /usr/share/applications/trocar-senha.desktop /etc/skel/Desktop/
    chmod +x /etc/skel/Desktop/trocar-senha.desktop 2>/dev/null || true
fi

# Criar atalho para usuários existentes com diretório home em /home
for USER_HOME in /home/*/; do
    if [ -d "${USER_HOME}Desktop" ]; then
        cp /usr/share/applications/trocar-senha.desktop "${USER_HOME}Desktop/"
        chmod +x "${USER_HOME}Desktop/trocar-senha.desktop" 2>/dev/null || true
    fi
done

log_nivel INFO "Atalhos na area de trabalho criados"
log_nivel OK "Aplicativo de troca de senha instalado!"
echo "============================================================"
)
