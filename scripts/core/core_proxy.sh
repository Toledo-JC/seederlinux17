#!/bin/bash
# ============================================================================
# Core Script: core_proxy.sh
# SeederLinux Lite - Proxy do sistema
# ============================================================================
# Configura o proxy HTTP/HTTPS no nivel do sistema (/etc/environment,
# /etc/apt/apt.conf.d) e em variaveis de ambiente globais.
# Os placeholders VARIAVEL são substituídos automaticamente
# pelo sistema na geração do bundle.
# ============================================================================

set -e

echo "============================================================"
echo "ATENCAO: Proxy sera configurado agora."
echo "Todos os pacotes ja foram instalados."
echo "A partir deste ponto, a internet pode exigir autenticacao."
echo "============================================================"
echo "17 - Configurar proxy do sistema"
echo "============================================================"

# ============================================================
# Variáveis
# ============================================================
PROXY_MODE="{{PROXY_MODE}}"
PROXY_HTTP="{{PROXY_HTTP}}"
PROXY_PORTA="{{PROXY_PORTA}}"
PROXY_URL="{{PROXY_URL}}"
PAC_URL="{{PAC_URL}}"
NO_PROXY="{{NO_PROXY}}"
SEEDER_SERVER="{{SEEDER_SERVER}}"

echo ">>> Modo de proxy: $PROXY_MODE"

# ============================================================
# Configurar conforme o modo
# ============================================================
case "$PROXY_MODE" in
    NONE)
        echo ">>> Proxy desativado (NONE)"
        # Remover configuracoes de proxy existentes
        rm -f /etc/apt/apt.conf.d/95seederlinux-proxy 2>/dev/null || true
        # Limpar /etc/environment de entradas de proxy
        if [ -f /etc/environment ]; then
            sed -i '/^http_proxy=/d; /^https_proxy=/d; /^ftp_proxy=/d; /^no_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^FTP_PROXY=/d; /^NO_PROXY=/d' /etc/environment || true
        fi
        echo ">>> Configuracoes de proxy removidas"
        ;;

    MANUAL)
        echo ">>> Configurando proxy manual: ${PROXY_HTTP}:${PROXY_PORTA}"

        # Construir URL do proxy
        if [ -n "$PROXY_URL" ] && [ "$PROXY_URL" != "" ]; then
            PROXY_FULL_URL="$PROXY_URL"
        else
            PROXY_FULL_URL="http://${PROXY_HTTP}:${PROXY_PORTA}"
        fi

        # Configurar APT
        cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy "${PROXY_FULL_URL}";
Acquire::https::Proxy "${PROXY_FULL_URL}";
Acquire::ftp::Proxy "${PROXY_FULL_URL}";
EOF

        # Garantir que o servidor Seeder esteja sempre no NO_PROXY - o
        # agente Python faz check-in nele e nao pode passar pelo proxy
        # corporativo (recebe 407 Proxy Authentication Required).
        SEEDER_HOST=""
        if [ -n "${SEEDER_SERVER:-}" ]; then
            SEEDER_HOST="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        fi
        if [ -n "$SEEDER_HOST" ]; then
            case ",$NO_PROXY," in
                *",$SEEDER_HOST,"*) ;;
                *) NO_PROXY="${NO_PROXY:+${NO_PROXY},}${SEEDER_HOST}" ;;
            esac
            echo ">>> SEEDER_HOST adicionado ao NO_PROXY: $SEEDER_HOST"
        fi

        # Configurar /etc/environment
        if [ -f /etc/environment ]; then
            # Remover entradas antigas
            sed -i '/^http_proxy=/d; /^https_proxy=/d; /^ftp_proxy=/d; /^no_proxy=/d; /^HTTP_PROXY=/d; /^HTTPS_PROXY=/d; /^FTP_PROXY=/d; /^NO_PROXY=/d' /etc/environment || true
        fi

        cat >> /etc/environment <<EOF
http_proxy="${PROXY_FULL_URL}"
https_proxy="${PROXY_FULL_URL}"
ftp_proxy="${PROXY_FULL_URL}"
HTTP_PROXY="${PROXY_FULL_URL}"
HTTPS_PROXY="${PROXY_FULL_URL}"
FTP_PROXY="${PROXY_FULL_URL}"
EOF

        if [ -n "$NO_PROXY" ] && [ "$NO_PROXY" != "" ]; then
            echo "no_proxy=\"${NO_PROXY}\"" >> /etc/environment
            echo "NO_PROXY=\"${NO_PROXY}\"" >> /etc/environment
        fi

        echo ">>> Proxy manual configurado"
        ;;

    PAC)
        echo ">>> Configurando proxy via PAC: ${PAC_URL}"

        if [ -z "$PAC_URL" ] || [ "$PAC_URL" = "" ]; then
            echo ">>> ERRO: PAC_URL nao definido para modo PAC"
            read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
            if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
                echo ">>> Instalacao abortada pelo usuario."
                exit 1
            fi
            echo ">>> Continuando apesar do erro..."
        fi

        # Configurar APT com PAC (apt suporta PAC via auto)
        cat > /etc/apt/apt.conf.d/95seederlinux-proxy <<EOF
Acquire::http::Proxy::Pac "${PAC_URL}";
Acquire::https::Proxy::Pac "${PAC_URL}";
EOF

        # Garantir que o servidor Seeder esteja sempre no NO_PROXY - o
        # agente Python faz check-in nele e nao pode passar pelo proxy
        # corporativo (recebe 407 Proxy Authentication Required).
        SEEDER_HOST=""
        if [ -n "${SEEDER_SERVER:-}" ]; then
            SEEDER_HOST="$(echo "$SEEDER_SERVER" | sed -E 's|https?://([^/]+).*|\1|')"
        fi
        if [ -n "$SEEDER_HOST" ]; then
            case ",$NO_PROXY," in
                *",$SEEDER_HOST,"*) ;;
                *) NO_PROXY="${NO_PROXY:+${NO_PROXY},}${SEEDER_HOST}" ;;
            esac
            echo ">>> SEEDER_HOST adicionado ao NO_PROXY: $SEEDER_HOST"
        fi

        # Para navegadores, o PAC sera configurado no core_browser.sh
        echo "PAC_URL=${PAC_URL}" > /etc/seederlinux/pac_url.conf 2>/dev/null || {
            mkdir -p /etc/seederlinux
            echo "PAC_URL=${PAC_URL}" > /etc/seederlinux/pac_url.conf
        }

        echo ">>> Proxy via PAC configurado"
        ;;

    *)
        echo ">>> ERRO: Modo de proxy invalido: $PROXY_MODE"
        read -p ">>> Deseja continuar mesmo assim? (S/n): " CONTINUE
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            echo ">>> Instalacao abortada pelo usuario."
            exit 1
        fi
        echo ">>> Continuando apesar do erro..."
        ;;
esac

echo ">>> [17] Proxy do sistema configurado!"
echo "============================================================"
