#!/bin/bash
# ============================================================================
# SeederLinux Lite - Installation Script (Debian 13 Ready)
# ============================================================================
# Instalador consciente do estado: detecta banco existente, oferece
# atualizar (schema idempotente, sem perder dados) / recriar / pular.
# Nunca dropa o usuário `seeder` — sempre CREATE ou ALTER USER.
# ============================================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PROJECT_NAME="seederlinux-lite"
INSTALL_DIR="/var/www/${PROJECT_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

DB_NAME="seederlinux"
DB_USER="seeder"

# ============================================================
# DB_PASS: persistir em ${INSTALL_DIR}/.env
#
# Regra: se .env existe, LER a senha de lá (fonte de verdade).
# Se não existe, GERAR uma nova. Nunca regenerar quando o banco
# já existe — isso quebrava o setup anterior (senha nova em
# memória vs. senha antiga no PostgreSQL -> auth falhava).
# ============================================================
ENV_FILE="${INSTALL_DIR}/.env"
DB_PASS=""
if [ -f "$ENV_FILE" ] && grep -q '^DB_PASS=' "$ENV_FILE"; then
    DB_PASS="$(grep '^DB_PASS=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
fi
if [ -z "$DB_PASS" ]; then
    DB_PASS="$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)"
fi

APACHE_USER="www-data"
APACHE_GROUP="www-data"
SERVER_NAME="localhost"

print_header() {
    echo -e "\n${CYAN}${BOLD}============================================================================${NC}"
    echo -e "${CYAN}${BOLD}$1${NC}"
    echo -e "${CYAN}${BOLD}============================================================================${NC}\n"
}

print_step()   { echo -e "${BLUE}[➤]${NC} $1"; }
print_success(){ echo -e "${GREEN}[✓]${NC} $1"; }
print_warning(){ echo -e "${YELLOW}[!]${NC} $1"; }
print_error()  { echo -e "${RED}[✗]${NC} $1"; }


# ============================================================
# _psql_file: aplica um arquivo SQL como superusuário 'postgres'.
#
# Por que 'postgres' e não 'seeder':
#   O schema.sql contém comandos ALTER ... OWNER TO e GRANT que
#   só podem ser executados pelo owner atual dos objetos ou por
#   um superusuário. Rodando como 'seeder', esses comandos falham
#   quando o objeto foi criado por outro usuário (ex.: em execuções
#   anteriores do install rodando como postgres).
#
#   O teste de conexão no final do setup_database continua
#   rodando como 'seeder' — é ele que prova que a aplicação
#   consegue acessar.
# ============================================================
_psql_file() {
    local file="$1"
    local log="$2"
    local rc=0

    if sudo -u postgres psql -d "${DB_NAME}" \
            -v ON_ERROR_STOP=1 -f "$file" >"$log" 2>&1; then
        rc=0
    else
        rc=$?
    fi

    # Filtra avisos cosméticos (idempotência esperada). Erros reais
    # continuam visíveis no log e no terminal.
    grep -vE 'already exists|já existe|não existe, ignorando|já existe, ignorada|não existe' \
        "$log" | sed 's/^/    /' || true

    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Execute como root: sudo $0"
        exit 1
    fi
}

configure_sources() {
    print_header "CONFIGURANDO REPOSITÓRIOS"

    if [ -f /etc/debian_version ]; then
        DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
        case "$DEBIAN_VERSION" in
            13) CODENAME="trixie" ;;
            12) CODENAME="bookworm" ;;
            11) CODENAME="bullseye" ;;
            *)  CODENAME="trixie" ;;
        esac
    else
        DEBIAN_VERSION="desconhecida"
        CODENAME="trixie"
    fi
    print_step "Debian detectado: ${CODENAME}"

    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        print_step "Removendo debian.sources conflitante..."
        rm -f /etc/apt/sources.list.d/debian.sources
    fi

    for f in /etc/apt/sources.list.d/*.list; do
        if [ -f "$f" ]; then
            mv "$f" "${f}.bak" 2>/dev/null || true
        fi
    done

    cat > /etc/apt/sources.list << EOF
# Debian ${DEBIAN_VERSION} (${CODENAME}) - Repositórios Oficiais
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware

deb http://deb.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware
EOF

    apt-get update -qq
    print_success "Repositórios configurados para Debian ${CODENAME}"
}

install_system_packages() {
    print_header "INSTALANDO PACOTES DO SISTEMA"

    print_step "Instalando utilitários básicos..."
    apt-get install -y -qq curl wget git unzip ca-certificates apt-transport-https

    print_step "Instalando PostgreSQL..."
    apt-get install -y -qq postgresql postgresql-contrib

    print_step "Instalando PHP e extensões..."
    apt-get install -y -qq \
        php \
        php-cli \
        php-fpm \
        php-pgsql \
        php-mbstring \
        php-xml \
        php-curl \
        php-zip \
        php-gd \
        sudo \
        libapache2-mod-php

    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION."."; echo PHP_MINOR_VERSION;' 2>/dev/null || echo "desconhecida")
    print_success "PHP ${PHP_VER} instalado"

    print_step "Instalando Apache2..."
    apt-get install -y -qq apache2

    print_step "Habilitando módulos do Apache..."
    a2enmod rewrite headers ssl

    print_success "Pacotes instalados"
}

# ============================================================
# _ensure_db_user: garante que o usuário existe E tem a senha correta.
# Chamado SOMENTE quando vamos tocar no banco (criar/atualizar/recriar).
# NÃO é chamado em "pular" — o operador que escolhe pular espera que
# o banco e o usuário fiquem intocados.
# ============================================================
_ensure_db_user() {
    local exists
    exists="$(sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null || echo "")"

    if [ "$exists" = "1" ]; then
        print_step "Usuário '${DB_USER}' existe - sincronizando senha..."
        sudo -u postgres psql -c \
            "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null
    else
        print_step "Criando usuário '${DB_USER}'..."
        sudo -u postgres psql -c \
            "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" >/dev/null
    fi
    print_success "Usuário '${DB_USER}' pronto"
}

# ============================================================
# _backup_database: pg_dump antes de qualquer operação destrutiva
# ============================================================
_backup_database() {
    local prefix="$1"
    local backup_dir="/var/backups/seederlinux"
    mkdir -p "$backup_dir"
    local backup="${backup_dir}/${prefix}-$(date +%Y%m%d-%H%M%S).sql"
    print_step "Backup: ${backup}"
    if ! sudo -u postgres pg_dump "${DB_NAME}" > "$backup"; then
        print_error "Falha no backup. Abortando por segurança."
        exit 1
    fi
    print_success "Backup concluído"
}

# ============================================================
# _apply_schema: schema.sql idempotente — é a "migração" do projeto
# ============================================================
_apply_schema() {
    print_header "APLICANDO SCHEMA DO BANCO DE DADOS"

    local schema_file="${SCRIPT_DIR}/schema.sql"
    if [ ! -f "$schema_file" ]; then
        print_error "schema.sql nao encontrado em ${SCRIPT_DIR}"
        exit 1
    fi

    print_step "Aplicando schema: $(basename "$schema_file")"
    if _psql_file "$schema_file" "/tmp/schema-apply.log"; then
        print_success "Schema aplicado"
    else
        print_error "Falha ao aplicar schema.sql. Veja /tmp/schema-apply.log"
        cat /tmp/schema-apply.log 2>/dev/null || true
        exit 1
    fi
}

# ============================================================
# _load_core_scripts: carrega os 24 scripts core de provisionamento
# ============================================================
_load_core_scripts() {
    local core_file="${SCRIPT_DIR}/insert_core_scripts.sql"
    if [ ! -f "$core_file" ]; then
        print_warning "Arquivo insert_core_scripts.sql nao encontrado — scripts Core nao foram carregados"
        return 0
    fi

    print_step "Carregando scripts Core de provisionamento..."
    if _psql_file "$core_file" "/tmp/insert-core-apply.log"; then
        print_success "Scripts Core carregados com sucesso"
    else
        print_error "Falha ao aplicar insert_core_scripts.sql. Veja /tmp/insert-core-apply.log"
        cat /tmp/insert-core-apply.log 2>/dev/null || true
        exit 1
    fi
}

# ============================================================
# _create_initial_factory_version: cria versão 'factory' inicial
# em script_versions para cada script core, e aponta
# scripts.current_version_id pra ela.
#
# Sem isso, um servidor recém-instalado fica com
# current_version_id=NULL, e o getScriptContent da API pode cair
# em fallback imprevisível.
#
# Idempotente: só cria factory se ainda não existe nenhuma para
# o script.
# ============================================================
_create_initial_factory_version() {
    print_step "Criando versão factory inicial em script_versions..."

    sudo -u postgres psql -d "${DB_NAME}" <<'SQL'
BEGIN;

INSERT INTO script_versions
    (script_id, version_name, version_number, content, changelog,
     version_type, is_active)
SELECT
    s.id,
    s.filename || ' - Factory v1',
    1,
    s.content,
    'Criado pelo install.sh no setup inicial',
    'factory',
    TRUE
FROM scripts s
WHERE s.is_core = TRUE
  AND s.content IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM script_versions sv
      WHERE sv.script_id = s.id
        AND sv.version_type = 'factory'
  );

UPDATE scripts s
SET current_version_id = latest_factory.id
FROM (
    SELECT DISTINCT ON (sv.script_id) sv.script_id, sv.id
    FROM script_versions sv
    JOIN scripts core_script ON core_script.id = sv.script_id
    WHERE core_script.is_core = TRUE
      AND sv.version_type = 'factory'
    ORDER BY sv.script_id, sv.version_number DESC, sv.id DESC
) latest_factory
WHERE s.id = latest_factory.script_id
  AND s.current_version_id IS DISTINCT FROM latest_factory.id;

COMMIT;
SQL

    print_success "Versão factory inicial criada"
}

# ============================================================
# setup_database: menu de 3 opções + schema idempotente
#
# Ordem de operações:
#   1) Detecta estado do banco
#   2) Menu (se interativo e banco existe)
#   3) Só então decide o que tocar:
#      - criar:     _ensure_db_user → CREATE DB → schema → scripts → factory
#      - atualizar: _ensure_db_user → schema → scripts → factory
#      - recriar:   _ensure_db_user → backup → DROP DB → CREATE DB → ...
#      - pular:     NADA. Não toca usuário, não toca banco.
#   4) Testa conexão (só se não pulou)
# ============================================================
setup_database() {
    print_header "CONFIGURANDO POSTGRESQL"

    print_step "Iniciando serviço PostgreSQL..."
    systemctl start postgresql
    systemctl enable postgresql

    # ============================================================
    # Detectar estado do banco (não toca nada ainda)
    # ============================================================
    DB_EXISTE=false
    if sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null \
        | grep -q 1; then
        DB_EXISTE=true
    fi

    AUTO_MODE=false
    for arg in "$@"; do
        [ "$arg" = "--auto" ] && AUTO_MODE=true
    done

    if [ "$DB_EXISTE" = "false" ]; then
        print_step "Banco '${DB_NAME}' nao existe - criando do zero."
        DB_ACAO="criar"

    elif [ "$AUTO_MODE" = "true" ]; then
        print_step "Banco existe + --auto - atualizando."
        DB_ACAO="atualizar"

    else
        echo ""
        echo "============================================================"
        echo "Banco '${DB_NAME}' ja existe."
        echo "============================================================"
        echo ""
        echo "  [1] Atualizar (aplica schema idempotente - NAO perde dados)"
        echo "  [2] Recriar do zero (APAGA TODOS OS DADOS)"
        echo "  [3] Pular (nao toca no banco, so atualiza arquivos)"
        echo ""
        read -p "Escolha [1/2/3] (Enter = 1): " DB_OPCAO
        DB_OPCAO="${DB_OPCAO:-1}"

        case "$DB_OPCAO" in
            1) DB_ACAO="atualizar" ;;
            2) DB_ACAO="recriar" ;;
            3) DB_ACAO="pular" ;;
            *) print_error "Opcao invalida. Abortando."; exit 1 ;;
        esac
    fi

    # ============================================================
    # Executar ação escolhida
    # ============================================================

    if [ "$DB_ACAO" = "pular" ]; then
        print_step "Pulando banco (opcao 3). Nenhuma alteracao no PostgreSQL."
        return 0
    fi

    # A partir daqui, VAMOS tocar no banco. Garantir usuário primeiro.
    _ensure_db_user

    case "$DB_ACAO" in

        criar)
            print_step "Criando banco: ${DB_NAME}"
            sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
            sudo -u postgres psql -d "${DB_NAME}" -c \
                "GRANT ALL ON SCHEMA public TO ${DB_USER};" 2>/dev/null || true

            _apply_schema
            _load_core_scripts
            _create_initial_factory_version
            ;;

        atualizar)
            # schema.sql é idempotente: não apaga nada, só adiciona
            # o que falta. É a "migração" deste projeto.
            _apply_schema
            _load_core_scripts
            _create_initial_factory_version
            ;;

        recriar)
            echo ""
            echo "============================================================"
            echo "ATENCAO: isso vai APAGAR todos os dados de '${DB_NAME}'."
            echo "============================================================"
            read -p 'Digite exatamente "RECRIAR" para confirmar: ' CONF

            if [ "$CONF" != "RECRIAR" ]; then
                print_warning "Cancelado."
                exit 1
            fi

            _backup_database "pre-recreate"

            print_step "Removendo banco existente (usuario seeder preservado)..."
            sudo -u postgres dropdb --if-exists "${DB_NAME}"

            print_step "Recriando banco: ${DB_NAME}"
            sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
            sudo -u postgres psql -d "${DB_NAME}" -c \
                "GRANT ALL ON SCHEMA public TO ${DB_USER};" 2>/dev/null || true

            _apply_schema
            _load_core_scripts
            _create_initial_factory_version
            ;;

    esac

    # Testar conexão (só chegamos aqui se não foi "pular")
    print_step "Testando conexão..."
    if PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" \
            -c "SELECT 1;" > /dev/null 2>&1; then
        print_success "Conexão com PostgreSQL OK"
    else
        print_error "Falha ao conectar ao PostgreSQL"
        print_error "Verifique: senha em ${ENV_FILE} vs. senha em pg_roles"
        exit 1
    fi
}

setup_project_files() {
    print_header "CONFIGURANDO ARQUIVOS DO PROJETO"

    print_step "Criando diretório: ${INSTALL_DIR}"
    mkdir -p "${INSTALL_DIR}"

    print_step "Copiando arquivos do projeto..."
    cp -r "${PROJECT_ROOT}"/* "${INSTALL_DIR}/"

    print_step "Criando diretórios de armazenamento..."
    mkdir -p "${INSTALL_DIR}/storage/logs"
    mkdir -p "${INSTALL_DIR}/downloads"
    print_step "Criando diretórios do Mirror..."
    mkdir -p /var/lib/seederlinux/mirror/{tmp,log,cache,public,quarantine}

    print_step "Criando arquivo .env..."
    cat > "${INSTALL_DIR}/.env" <<EOF
DB_HOST=localhost
DB_PORT=5432
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
APP_NAME=SeederLinux Lite
APP_ENV=production
APP_DEBUG=false
EOF

    print_success "Arquivos configurados"
}

setup_permissions() {
    print_header "CONFIGURANDO PERMISSÕES"

    print_step "Ajustando proprietário..."
    chown -R ${APACHE_USER}:${APACHE_GROUP} "${INSTALL_DIR}"

    print_step "Permissões de diretórios..."
    find "${INSTALL_DIR}" -type d -exec chmod 755 {} \;

    print_step "Permissões de arquivos..."
    find "${INSTALL_DIR}" -type f -exec chmod 644 {} \;

    chmod +x "${INSTALL_DIR}/downloads/"*.py 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/mirror-sync.sh" 2>/dev/null || true

    chmod -R 775 "${INSTALL_DIR}/storage"
    chown -R ${APACHE_USER}:${APACHE_GROUP} /var/lib/seederlinux/mirror
    chmod -R 775 /var/lib/seederlinux/mirror

    chmod 600 "${INSTALL_DIR}/.env"

    print_success "Permissões configuradas"
}

configure_apache() {
    print_header "CONFIGURANDO APACHE"

    print_step "Criando VirtualHost com SSL..."

    cat > "/etc/apache2/sites-available/${PROJECT_NAME}.conf" <<EOF
<IfModule mod_ssl.c>
    <VirtualHost *:443>
        ServerName ${SERVER_NAME}

        DocumentRoot ${INSTALL_DIR}

        <Directory ${INSTALL_DIR}>
            Options -Indexes +FollowSymLinks
            AllowOverride All
            Require all granted
        </Directory>

        <Directory ${INSTALL_DIR}/storage>
            Require all denied
        </Directory>

        <Directory ${INSTALL_DIR}/lib>
            Require all denied
        </Directory>

        <Directory ${INSTALL_DIR}/includes>
            Require all denied
        </Directory>

        Alias /mirror /var/lib/seederlinux/mirror/public
        <Directory /var/lib/seederlinux/mirror/public>
            Options +Indexes +FollowSymLinks
            AllowOverride None
            Require all granted
        </Directory>

        <IfModule mod_headers.c>
            Header always set X-Content-Type-Options nosniff
            <FilesMatch "\.deb$">
                Header set Cache-Control "public, max-age=604800, immutable"
            </FilesMatch>
        </IfModule>

        SSLEngine on
        SSLCertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
        SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key

        ErrorLog \${APACHE_LOG_DIR}/${PROJECT_NAME}_error.log
        CustomLog \${APACHE_LOG_DIR}/${PROJECT_NAME}_access.log combined
    </VirtualHost>
</IfModule>

<VirtualHost *:80>
    ServerName ${SERVER_NAME}
    Redirect permanent / https://${SERVER_NAME}/
</VirtualHost>
EOF

    print_step "Desabilitando site padrão..."
    a2dissite 000-default.conf 2>/dev/null || true

    print_step "Habilitando site ${PROJECT_NAME}..."
    a2ensite "${PROJECT_NAME}.conf"

    print_step "Testando configuração do Apache..."
    if apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        print_success "Configuração do Apache OK"
    else
        print_warning "Problema na configuração do Apache:"
        apache2ctl configtest
        print_warning "Verifique se o módulo ssl está habilitado"
    fi

    print_step "Reiniciando Apache..."
    systemctl restart apache2
    systemctl enable apache2

    print_success "Apache configurado"
}

show_summary() {
    print_header "INSTALAÇÃO CONCLUÍDA"

    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║           SEEDERLINUX LITE - INSTALAÇÃO COMPLETA               ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "\n${BOLD}Acesso Web:${NC}"
    echo -e "  URL:   https://${SERVER_NAME}/"
    echo -e "  Login: https://${SERVER_NAME}/login.html"
    echo -e "  Admin: https://${SERVER_NAME}/admin.html"

    echo -e "\n${BOLD}Credenciais Padrão:${NC}"
    echo -e "  Usuário: ${YELLOW}admin${NC}"
    echo -e "  Senha:   ${YELLOW}admin123${NC}"
    echo -e "  ${RED}⚠ ALTERE A SENHA APÓS O PRIMEIRO LOGIN!${NC}"

    echo -e "\n${BOLD}Banco de Dados:${NC}"
    echo -e "  Database: ${DB_NAME}"
    echo -e "  User:     ${DB_USER}"
    echo -e "  Host:     localhost:5432"
    echo -e "  Env file: ${ENV_FILE}"

    echo -e "\n${YELLOW}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║                    CREDENCIAIS DO BANCO                        ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║  Database: %-52s║\n" "${DB_NAME}"
    printf "║  Usuario:  %-52s║\n" "${DB_USER}"
    echo "║  Senha: armazenada no arquivo .env (não exibida aqui)          ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  Para consultar em sessão administrativa:                      ║"
    echo "║    sudo grep '^DB_PASS=' ${ENV_FILE}                            ║"
    echo "║  Evite compartilhar saídas de terminal com credenciais.         ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "\n${BOLD}Arquivos:${NC}"
    echo -e "  Diretório: ${INSTALL_DIR}"
    echo -e "  Schema:    ${INSTALL_DIR}/install/schema.sql"
    echo -e "  Config:    ${ENV_FILE}"

    echo -e "\n${BOLD}Logs:${NC}"
    echo -e "  Apache:  /var/log/apache2/${PROJECT_NAME}_error.log"
    echo -e "  Sistema: ${INSTALL_DIR}/storage/logs/"

    echo -e "\n${GREEN}Instalação concluída com sucesso!${NC}\n"
}

main() {
    clear 2>/dev/null || true
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║       SEEDERLINUX LITE - INSTALADOR v1.0.0 (Debian 13)        ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    check_root

    echo -e "${YELLOW}Este script irá:${NC}"
    echo "  • Configurar repositórios (Debian 13)"
    echo "  • Instalar Apache2, PHP, PostgreSQL"
    echo "  • Criar/atualizar banco (sem perder dados se ja existir)"
    echo "  • Aplicar schema idempotente + scripts core"
    echo "  • Criar versao factory inicial em script_versions"
    echo "  • Configurar VirtualHost com SSL"
    echo "  • Copiar arquivos para ${INSTALL_DIR}"
    echo ""
    echo "  Flag --auto: atualiza banco existente sem perguntas interativas"
    echo ""
    AUTO_MODE=false
    for arg in "$@"; do
        [ "$arg" = "--auto" ] && AUTO_MODE=true
    done
    if [ "$AUTO_MODE" != "true" ]; then
        read -p "Deseja continuar? (s/N): " -n 1 -r
        echo
        if [[ ! ${REPLY:-} =~ ^[Ss]$ ]]; then
            echo "Instalação cancelada."
            exit 0
        fi
    fi

    configure_sources
    install_system_packages

    # Gerar o SQL a partir das fontes Core ANTES de carregar o banco,
    # para que scripts.content e as versões factory nasçam sincronizados.
    if [ -f "${SCRIPT_DIR}/gen_insert_core.py" ]; then
        print_header "REGENERANDO SCRIPTS CORE A PARTIR DA FONTE"
        print_step "Executando gen_insert_core.py..."
        if python3 "${SCRIPT_DIR}/gen_insert_core.py"; then
            print_success "insert_core_scripts.sql regenerado"
        else
            print_error "Falha ao executar gen_insert_core.py"
            exit 1
        fi
    else
        print_error "gen_insert_core.py nao encontrado em ${SCRIPT_DIR}"
        exit 1
    fi

    setup_database "$@"

    setup_project_files
    setup_permissions
    configure_apache
    show_summary
}

main "$@"
