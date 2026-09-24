#!/bin/bash
# ============================================================================
# SeederLinux Lite - Installation Script (Debian 13 Ready)
# Corrigido - Mescla do original funcional com schema consolidado
# ============================================================================

set -e

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
DB_PASS=$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)

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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Execute como root: sudo $0"
        exit 1
    fi
}

configure_sources() {
    print_header "CONFIGURANDO REPOSITÓRIOS"

    # Detectar versão do Debian
    if [ -f /etc/debian_version ]; then
        DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
        case "$DEBIAN_VERSION" in
            13) CODENAME="trixie" ;;
            12) CODENAME="bookworm" ;;
            11) CODENAME="bullseye" ;;
            *)  CODENAME="trixie" ;; # fallback
        esac
    else
        CODENAME="trixie"
    fi
    print_step "Debian detectado: ${CODENAME}"

    # Remover arquivos conflitantes do sources.list.d
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        print_step "Removendo debian.sources conflitante..."
        rm -f /etc/apt/sources.list.d/debian.sources
    fi
    
    # Desabilitar outros arquivos .list que possam conflitar
    for f in /etc/apt/sources.list.d/*.list; do
        if [ -f "$f" ]; then
            mv "$f" "${f}.bak" 2>/dev/null || true
        fi
    done

    # Escrever sources.list correto
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

    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "desconhecida")
    print_success "PHP ${PHP_VER} instalado"

    print_step "Instalando Apache2..."
    apt-get install -y -qq apache2

    print_step "Habilitando módulos do Apache..."
    a2enmod rewrite headers ssl

    print_success "Pacotes instalados"
}

setup_postgresql() {
    print_header "CONFIGURANDO POSTGRESQL"

    print_step "Iniciando serviço PostgreSQL..."
    systemctl start postgresql
    systemctl enable postgresql

    if sudo -u postgres psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "${DB_NAME}"; then
        print_warning "Banco '${DB_NAME}' já existe"
        read -p "Recriar banco? (s/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            print_step "Removendo banco existente..."
            sudo -u postgres dropdb --if-exists "${DB_NAME}"
            sudo -u postgres dropuser --if-exists "${DB_USER}"
        else
            print_step "Mantendo banco existente"
            return 0
        fi
    fi

    print_step "Criando usuário: ${DB_USER}"
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" 2>/dev/null || true

    print_step "Criando banco: ${DB_NAME}"
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"

    print_step "Concedendo privilégios..."
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
    
    # PostgreSQL 15+ precisa de permissões no schema public
    sudo -u postgres psql -d "${DB_NAME}" -c "GRANT ALL ON SCHEMA public TO ${DB_USER};" 2>/dev/null || true

    print_step "Testando conexão..."
    if PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT 1;" > /dev/null 2>&1; then
        print_success "Conexão com PostgreSQL OK"
    else
        print_error "Falha ao conectar ao PostgreSQL"
        exit 1
    fi
}

apply_database_schema() {
    print_header "APLICANDO SCHEMA DO BANCO DE DADOS"

    SCHEMA_FILE="${SCRIPT_DIR}/schema.sql"
    if [ ! -f "$SCHEMA_FILE" ]; then
        print_error "schema.sql nao encontrado em ${SCRIPT_DIR}"
        exit 1
    fi

    print_step "Aplicando schema: $(basename "$SCHEMA_FILE")"
    if PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f "$SCHEMA_FILE" 2>&1 | tee /tmp/schema-apply.log | grep -v "already exists"; then
        if grep -qiE "ERROR|ERRO" /tmp/schema-apply.log; then
            print_error "schema.sql teve erros. Veja /tmp/schema-apply.log"
            cat /tmp/schema-apply.log
            exit 1
        fi
        print_success "Schema aplicado"
    else
        print_error "Falha ao aplicar schema.sql"
        cat /tmp/schema-apply.log 2>/dev/null
        exit 1
    fi

    # Garantir constraint UNIQUE em scripts.filename antes de carregar os scripts
    # (necessaria para o ON CONFLICT (filename) do insert_core_scripts.sql)
    print_step "Garantindo constraint UNIQUE em scripts.filename..."
    PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -c \
        "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'scripts_filename_key') THEN ALTER TABLE scripts ADD CONSTRAINT scripts_filename_key UNIQUE (filename); END IF; END \$\$;"

    # Carregar scripts Core de provisionamento
    if [ -f "${SCRIPT_DIR}/insert_core_scripts.sql" ]; then
        print_step "Carregando scripts Core de provisionamento..."
        if PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f "${SCRIPT_DIR}/insert_core_scripts.sql" 2>&1 | tee /tmp/insert-core-apply.log | grep -v "already exists"; then
            if grep -qiE "ERROR|ERRO" /tmp/insert-core-apply.log; then
                print_error "insert_core_scripts.sql teve erros. Veja /tmp/insert-core-apply.log"
                cat /tmp/insert-core-apply.log
                exit 1
            fi
            print_success "Scripts Core carregados com sucesso"
        else
            print_error "Falha ao aplicar insert_core_scripts.sql"
            cat /tmp/insert-core-apply.log 2>/dev/null
            exit 1
        fi
    else
        print_warning "Arquivo insert_core_scripts.sql nao encontrado — scripts Core nao foram carregados"
    fi

    print_success "Schema aplicado com sucesso"
}

regenerate_core_scripts() {
    print_header "REGENERANDO SCRIPTS CORE NO BANCO"

    if [ ! -f "${SCRIPT_DIR}/gen_insert_core.py" ]; then
        print_error "gen_insert_core.py nao encontrado em ${SCRIPT_DIR}"
        exit 1
    fi

    print_step "Executando gen_insert_core.py..."
    if python3 "${SCRIPT_DIR}/gen_insert_core.py" 2>&1; then
        print_success "insert_core_scripts.sql regenerado"
    else
        print_error "Falha ao executar gen_insert_core.py"
        exit 1
    fi

    if [ ! -f "${SCRIPT_DIR}/insert_core_scripts.sql" ]; then
        print_error "insert_core_scripts.sql nao foi gerado"
        exit 1
    fi

    print_step "Aplicando insert_core_scripts.sql no banco..."
    if PGPASSWORD="${DB_PASS}" psql -h localhost -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -f "${SCRIPT_DIR}/insert_core_scripts.sql" 2>&1 | tee /tmp/insert-core-regen.log | grep -v "already exists"; then
        if grep -qiE "ERROR|ERRO" /tmp/insert-core-regen.log; then
            print_error "insert_core_scripts.sql teve erros. Veja /tmp/insert-core-regen.log"
            cat /tmp/insert-core-regen.log
            exit 1
        fi
        print_success "Scripts Core atualizados no banco"
    else
        print_error "Falha ao aplicar insert_core_scripts.sql"
        cat /tmp/insert-core-regen.log 2>/dev/null
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

    # Scripts executáveis
    chmod +x "${INSTALL_DIR}/downloads/"*.py 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/"*.sh 2>/dev/null || true
    chmod +x "${INSTALL_DIR}/scripts/mirror-sync.sh" 2>/dev/null || true

    # Storage com permissão de escrita
    chmod -R 775 "${INSTALL_DIR}/storage"
    chown -R ${APACHE_USER}:${APACHE_GROUP} /var/lib/seederlinux/mirror
    chmod -R 775 /var/lib/seederlinux/mirror
    
    # Arquivo .env protegido
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

        # Proteger diretórios sensíveis
        <Directory ${INSTALL_DIR}/storage>
            Require all denied
        </Directory>

        <Directory ${INSTALL_DIR}/lib>
            Require all denied
        </Directory>

        <Directory ${INSTALL_DIR}/includes>
            Require all denied
        </Directory>

        # Mirror: servir arquivos estáticos via Apache (sem PHP)
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
    echo -e "  Pass:     ${DB_PASS}"
    echo -e "  Host:     localhost:5432"

    echo -e "\n${RED}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║              GUARDE ESTA SENHA EM LOCAL SEGURO!               ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    printf "║  Banco:   %-54s║\n" "${DB_NAME}"
    printf "║  Usuario: %-54s║\n" "${DB_USER}"
    printf "║  Senha:   %-54s║\n" "${DB_PASS}"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║  Necessaria para manutencao e backup do sistema.              ║"
    echo "║  Nao sera exibida novamente apos o fechamento deste terminal. ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "\n${BOLD}Arquivos:${NC}"
    echo -e "  Diretório: ${INSTALL_DIR}"
    echo -e "  Schema:    ${INSTALL_DIR}/install/schema.sql"
    echo -e "  Config:    ${INSTALL_DIR}/.env"

    echo -e "\n${BOLD}Logs:${NC}"
    echo -e "  Apache:  /var/log/apache2/${PROJECT_NAME}_error.log"
    echo -e "  Sistema: ${INSTALL_DIR}/storage/logs/"

    echo -e "\n${GREEN}Instalação concluída com sucesso!${NC}\n"
}

main() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║       SEEDERLINUX LITE - INSTALADOR v1.0.0 (Debian 13)        ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    check_root

    echo -e "${YELLOW}Este script irá:${NC}"
    echo "  • Configurar repositórios (Debian 13)"
    echo "  • Instalar Apache2, PHP, PostgreSQL"
    echo "  • Criar banco e usuário"
    echo "  • Aplicar schema consolidado"
    echo "  • Configurar VirtualHost com SSL"
    echo "  • Copiar arquivos para ${INSTALL_DIR}"
    echo ""
    read -p "Deseja continuar? (s/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Ss]$ ]]; then
        echo "Instalação cancelada."
        exit 0
    fi

    configure_sources
    install_system_packages
    setup_postgresql
    apply_database_schema
    regenerate_core_scripts
    setup_project_files
    setup_permissions
    configure_apache
    show_summary
}

main "$@"
