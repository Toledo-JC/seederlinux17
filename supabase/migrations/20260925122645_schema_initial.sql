-- ============================================================================
-- SeederLinux Lite - Canonical Database Schema (PostgreSQL 16+)
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS mirror;

CREATE TABLE IF NOT EXISTS organizations (
    id SERIAL PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    acronym VARCHAR(20) NOT NULL,
    domain VARCHAR(100),
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    serial_config BIGINT DEFAULT 1,
    logo_url TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'organizations' AND column_name = 'serial_config'
          AND data_type = 'integer'
    ) THEN
        ALTER TABLE organizations ALTER COLUMN serial_config TYPE BIGINT;
    END IF;
END $$;

INSERT INTO organizations (id, name, acronym, domain, description)
VALUES (1, 'OM Padrao', 'OM', 'om.local', 'Organizacao padrao do sistema')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(200),
    email VARCHAR(200),
    role VARCHAR(50) NOT NULL DEFAULT 'operador_om',
    organization_id INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO users (username, password_hash, full_name, email, role, organization_id)
VALUES ('admin', '$2y$12$aclfbpmKYX0DoMcu8EmQeO1xyziOBv9/WjuWR6y3/ovgF74QTaLhC', 'Administrator', 'admin@seeder.local', 'admin_gap', NULL)
ON CONFLICT (username) DO NOTHING;

CREATE TABLE IF NOT EXISTS user_tokens (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL,
    expires_at TIMESTAMP NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_tokens_user ON user_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_user_tokens_expires ON user_tokens(expires_at);

CREATE TABLE IF NOT EXISTS variable_definitions (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) UNIQUE NOT NULL,
    placeholder VARCHAR(150) UNIQUE,
    description TEXT,
    type VARCHAR(50) DEFAULT 'string',
    category VARCHAR(100),
    is_required BOOLEAN DEFAULT false,
    default_value TEXT,
    display_order INTEGER DEFAULT 0
);

ALTER TABLE organizations DROP CONSTRAINT IF EXISTS organizations_acronym_key;
DROP INDEX IF EXISTS organizations_acronym_key;
CREATE UNIQUE INDEX IF NOT EXISTS idx_organizations_acronym_active ON organizations (acronym) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_var_defs_category ON variable_definitions(category);
CREATE INDEX IF NOT EXISTS idx_var_defs_type ON variable_definitions(type);

INSERT INTO variable_definitions (name, placeholder, description, type, category, is_required, default_value, display_order) VALUES
('DOMINIO', '{{DOMINIO}}', 'Dominio AD completo', 'domain', 'dominio', TRUE, 'om.local', 1),
('DOMINIO_NETBIOS', '{{DOMINIO_NETBIOS}}', 'Nome NetBIOS do dominio', 'netbios', 'dominio', TRUE, 'OM', 2),
('DC_IP', '{{DC_IP}}', 'IP do Controlador de Dominio', 'ip', 'dominio', TRUE, '10.0.0.1', 3),
('DC_SECUNDARIO_IP', '{{DC_SECUNDARIO_IP}}', 'IP do Controlador de Dominio secundario', 'ip', 'dominio', FALSE, '10.0.0.2', 4),
('DNS_INTERNET', '{{DNS_INTERNET}}', 'DNS publico para internet (fallback, ex: 8.8.8.8 ou 1.1.1.1). Deve ser um DNS publico, nao o DNS do dominio local.', 'ip', 'rede', TRUE, '8.8.8.8', 5),
('DNS_PRIMARIO', '{{DNS_PRIMARIO}}', 'DNS primario para resolucao de nomes', 'ip', 'rede', TRUE, '10.0.0.1', 6),
('DNS_SECUNDARIO', '{{DNS_SECUNDARIO}}', 'DNS secundario (fallback)', 'ip', 'rede', FALSE, '10.0.0.2', 7),
('NTP_SERVER', '{{NTP_SERVER}}', 'Servidor NTP para sincronizacao de horario', 'ip', 'dominio', FALSE, 'pool.ntp.org', 8),
('OU_PADRAO', '{{OU_PADRAO}}', 'Unidade Organizacional padrao no AD', 'string', 'dominio', FALSE, 'OU=Estacoes,DC=om,DC=local', 9),
('GRUPO_ADMIN', '{{GRUPO_ADMIN}}', 'Grupo administrador do dominio', 'string', 'dominio', TRUE, 'Domain Admins', 10),
('AUTH_METHOD', '{{AUTH_METHOD}}', 'Metodo de autenticacao: sssd, winbind ou both (SSSD com fallback Winbind)', 'select', 'dominio', FALSE, 'sssd', 11),
('OFFLINE_AUTH_ENABLED', '{{OFFLINE_AUTH_ENABLED}}', 'Habilitar autenticacao offline', 'boolean', 'dominio', FALSE, 'true', 12),
('OFFLINE_AUTH_DAYS', '{{OFFLINE_AUTH_DAYS}}', 'Dias para cache de credenciais offline', 'string', 'dominio', FALSE, '30', 13),
('ADMIN_PASSWORD_B64', '{{ADMIN_PASSWORD_B64}}', 'Senha do administrador do dominio (codificada em base64)', 'password', 'dominio', FALSE, '', 14),
('BASE_URL', '{{BASE_URL}}', 'URL base do repositorio de scripts (o proprio servidor SeederLinux)', 'url', 'rede', TRUE, 'https://seederlinux.om.local', 20),
('REPOSITORY_MODE', '{{REPOSITORY_MODE}}', 'Modo de repositorio: PUBLIC, MIRROR, HYBRID, CUSTOM', 'select', 'repositorios', TRUE, 'MIRROR', 21),
('REPOSITORY_URL', '{{REPOSITORY_URL}}', 'URL do repositorio espelho', 'url', 'repositorios', FALSE, '', 22),
('REPOSITORY_FALLBACK', '{{REPOSITORY_FALLBACK}}', 'URL de repositorio fallback (internet)', 'url', 'repositorios', FALSE, 'http://deb.debian.org/debian', 23),
('REPOSITORY_DEBIAN_ENABLED', '{{REPOSITORY_DEBIAN_ENABLED}}', 'Habilitar mirror para Debian?', 'boolean', 'repositorios', FALSE, 'false', 24),
('REPOSITORY_DEBIAN_URL', '{{REPOSITORY_DEBIAN_URL}}', 'URL do mirror Debian (ex: http://mirror.om.local/debian)', 'url', 'repositorios', FALSE, '', 25),
('REPOSITORY_UBUNTU_ENABLED', '{{REPOSITORY_UBUNTU_ENABLED}}', 'Habilitar mirror para Ubuntu?', 'boolean', 'repositorios', FALSE, 'false', 26),
('REPOSITORY_UBUNTU_URL', '{{REPOSITORY_UBUNTU_URL}}', 'URL do mirror Ubuntu (ex: http://mirror.om.local/ubuntu)', 'url', 'repositorios', FALSE, '', 27),
('REPOSITORY_MINT_ENABLED', '{{REPOSITORY_MINT_ENABLED}}', 'Habilitar mirror para Linux Mint?', 'boolean', 'repositorios', FALSE, 'false', 28),
('REPOSITORY_MINT_URL', '{{REPOSITORY_MINT_URL}}', 'URL do mirror Linux Mint (ex: http://mirror.om.local/mint)', 'url', 'repositorios', FALSE, '', 29),
('REPOSITORY_ZORIN_ENABLED', '{{REPOSITORY_ZORIN_ENABLED}}', 'Habilitar mirror para Zorin OS?', 'boolean', 'repositorios', FALSE, 'false', 30),
('REPOSITORY_ZORIN_URL', '{{REPOSITORY_ZORIN_URL}}', 'URL do mirror Zorin OS (ex: http://mirror.om.local/zorin)', 'url', 'repositorios', FALSE, '', 31),
('OCS_SERVER', '{{OCS_SERVER}}', 'Servidor OCS Inventory', 'url', 'inventario', TRUE, '', 30),
('OCS_TAG', '{{OCS_TAG}}', 'Tag OCS da organizacao', 'string', 'inventario', TRUE, 'OM-ESTACOES', 31),
('GLPI_SERVER', '{{GLPI_SERVER}}', 'Servidor GLPI para inventario', 'url', 'inventario', FALSE, '', 32),
('INVENTORY_ENABLED', '{{INVENTORY_ENABLED}}', 'Habilitar inventario automatico', 'boolean', 'inventario', FALSE, 'true', 33),
('PRINT_SERVER', '{{PRINT_SERVER}}', 'Servidor de impressao', 'ip', 'rede', FALSE, '', 40),
('DEFAULT_PRINTER', '{{DEFAULT_PRINTER}}', 'Impressora padrao', 'string', 'impressoras', FALSE, '', 41),
('PRINTERS', '{{PRINTERS}}', 'Lista de impressoras (adicione uma por vez)', 'tags', 'impressoras', FALSE, '', 42),
('PROXY_HTTP', '{{PROXY_HTTP}}', 'Proxy HTTP corporativo', 'ip', 'proxy', FALSE, '', 50),
('PROXY_PORTA', '{{PROXY_PORTA}}', 'Porta do proxy', 'port', 'proxy', FALSE, '', 51),
('PROXY_URL', '{{PROXY_URL}}', 'URL completa do proxy', 'url', 'proxy', FALSE, '', 52),
('PROXY_MODE', '{{PROXY_MODE}}', 'Modo de proxy: NONE, MANUAL, PAC', 'select', 'navegador', FALSE, 'NONE', 53),
('PAC_URL', '{{PAC_URL}}', 'URL do arquivo PAC (Proxy Auto-Config)', 'url', 'navegador', FALSE, '', 54),
('NO_PROXY', '{{NO_PROXY}}', 'Lista de excecoes de proxy (adicione uma por vez)', 'tags', 'navegador', FALSE, 'localhost,127.0.0.1,om.local', 55),
('HOMEPAGE', '{{HOMEPAGE}}', 'Pagina inicial do portal', 'url', 'navegador', FALSE, 'www.om.local', 60),
('GRUPO_ADMIN_AD', '{{GRUPO_ADMIN_AD}}', 'Grupo admin no AD para sudo', 'string', 'seguranca', TRUE, 'Dominio\ Admins', 70),
('GRUPO_ADMIN_LINUX', '{{GRUPO_ADMIN_LINUX}}', 'Grupo local para sudo', 'string', 'seguranca', TRUE, 'linux-admins', 71),
('GRUPO_DASTI', '{{GRUPO_DASTI}}', 'Grupo DASTI para sudo', 'string', 'seguranca', FALSE, '_DASTI', 72),
('OM_ACRONYM', '{{OM_ACRONYM}}', 'Sigla da Organizacao Militar', 'string', 'branding', FALSE, 'OM', 80),
('OM_NAME', '{{OM_NAME}}', 'Nome completo da Organizacao Militar', 'string', 'branding', FALSE, 'Organizacao Padrao', 81),
('DISPLAY_NAME', '{{DISPLAY_NAME}}', 'Nome de exibicao da OM', 'string', 'branding', FALSE, 'OM Padrao', 82),
('WALLPAPER_URL', '{{WALLPAPER_URL}}', 'URL do wallpaper da area de trabalho', 'image', 'assets', FALSE, '/assets/wallpapers/default.jpg', 83),
('WALLPAPER_LOGIN_URL', '{{WALLPAPER_LOGIN_URL}}', 'URL do wallpaper da tela de login', 'image', 'assets', FALSE, '', 84),
('LOGO_URL', '{{LOGO_URL}}', 'URL do logo da OM', 'image', 'assets', FALSE, '/assets/logos/default.png', 85),
('GREETER_URL', '{{GREETER_URL}}', 'URL do greeter personalizado (tela de boas-vindas)', 'image', 'assets', FALSE, '', 86),
('THEME', '{{THEME}}', 'Tema GTK a ser aplicado', 'string', 'branding', FALSE, 'DEFAULT', 87),
('CONKY_PROFILE', '{{CONKY_PROFILE}}', 'Perfil base do Conky (default, minimal, full, custom)', 'select', 'monitoramento', FALSE, 'default', 88),
('CONKY_CONFIG', '{{CONKY_CONFIG}}', 'Configuracao avancada do Conky (JSON com cores, posicao, modulos exibidos)', 'json_conky', 'monitoramento', FALSE, '{"position":"top_right","transparent":true,"color_text":"#FFFFFF","color_bg":"#000000","font_size":10,"gap_x":10,"gap_y":40,"show_cpu":true,"show_ram":true,"show_disk":true,"disk_partition":"/","show_network":true,"network_interface":"eth0","show_top_processes":true,"show_datetime":true,"update_interval":1.0}', 89),
('DESKTOP_ENV', '{{DESKTOP_ENV}}', 'Ambiente grafico: cinnamon, mate, gnome, xfce, kde, lxde (opcional, apenas se INSTALL_DESKTOP=true)', 'select', 'ambiente', FALSE, '', 90),
('DISPLAY_MANAGER', '{{DISPLAY_MANAGER}}', 'Gerenciador de sessao: lightdm, gdm3, sddm (opcional, detectado automaticamente se vazio)', 'select', 'ambiente', FALSE, '', 91),
('INSTALL_DESKTOP', '{{INSTALL_DESKTOP}}', 'Instalar ambiente grafico? Se false, usa o ja instalado na estacao', 'boolean', 'ambiente', FALSE, 'false', 92),
('DC_IP_LIST', '{{DC_IP_LIST}}', 'Lista de IPs dos Controladores de Dominio (separados por virgula ou espaco)', 'string', 'dominio', FALSE, '10.0.0.1,10.0.0.2', 93),
('ADMIN_USERNAME', '{{ADMIN_USERNAME}}', 'Nome do usuario administrador do dominio para ingresso no AD', 'string', 'dominio', FALSE, 'Administrator', 94),
('SERVIDOR_ARQUIVOS', '{{SERVIDOR_ARQUIVOS}}', 'Servidor de arquivos (SMB/NFS)', 'ip', 'arquivos', FALSE, '', 100),
('COMPARTILHAMENTOS', '{{COMPARTILHAMENTOS}}', 'Lista de compartilhamentos (adicione um por vez)', 'tags', 'arquivos', FALSE, 'publico,usuarios,setores', 101),
('MOUNT_BASE', '{{MOUNT_BASE}}', 'Base de montagem para compartilhamentos', 'string', 'arquivos', FALSE, '/mnt/servidor', 102),
('INSTALL_ONLYOFFICE', '{{INSTALL_ONLYOFFICE}}', 'Instalar OnlyOffice Desktop Editors?', 'boolean', 'aplicacoes', FALSE, 'true', 110),
('INSTALL_CHROME', '{{INSTALL_CHROME}}', 'Instalar Google Chrome?', 'boolean', 'aplicacoes', FALSE, 'true', 111),
('INSTALL_CHROMIUM', '{{INSTALL_CHROMIUM}}', 'Instalar Chromium?', 'boolean', 'aplicacoes', FALSE, 'false', 112),
('INSTALL_JAVA8', '{{INSTALL_JAVA8}}', 'Instalar Java 8 para sistemas legados?', 'boolean', 'aplicacoes', FALSE, 'false', 113),
('INSTALL_FIREFOX52', '{{INSTALL_FIREFOX52}}', 'Instalar Firefox 52.7 ESR para sistemas legados?', 'boolean', 'aplicacoes', FALSE, 'false', 114),
('INSTALL_PASSWORD_CHANGER', '{{INSTALL_PASSWORD_CHANGER}}', 'Instalar aplicativo grafico (Zeny) para troca de senha no AD', 'boolean', 'aplicacoes', FALSE, 'true', 115),
('JAVA_EXCEPTIONS', '{{JAVA_EXCEPTIONS}}', 'Excecoes de seguranca para Java (URLs autorizadas)', 'array', 'seguranca', FALSE, '', 116),
('REMOVER_LIBREOFFICE', '{{REMOVER_LIBREOFFICE}}', 'Remover LibreOffice pre-instalado', 'boolean', 'aplicacoes', FALSE, 'false', 117),
('REMOTE_METHOD', '{{REMOTE_METHOD}}', 'Metodo de acesso remoto (ssh, xrdp, anydesk)', 'select', 'acesso_remoto', FALSE, 'ssh', 120),
('SSH_PORT', '{{SSH_PORT}}', 'Porta SSH (padrao: 22)', 'port', 'acesso_remoto', FALSE, '22', 121),
('SSH_GROUPS', '{{SSH_GROUPS}}', 'Grupos do dominio com acesso SSH (um por linha)', 'array', 'seguranca', FALSE, 'linux-admins', 124),
('VNC_ENABLED', '{{VNC_ENABLED}}', 'Habilitar servidor VNC (x11vnc)?', 'boolean', 'acesso_remoto', FALSE, 'false', 122),
('VNC_PASSWORD_B64', '{{VNC_PASSWORD_B64}}', 'Senha do servidor VNC (em branco = aleatoria)', 'password', 'acesso_remoto', FALSE, '', 123),
('CERTIFICATE_BUNDLE', '{{CERTIFICATE_BUNDLE}}', 'URL para download do pacote de certificados CA institucionais (formato .tar.gz). Deixe vazio se nao houver certificados personalizados.', 'url', 'oculto', FALSE, '', 130),
('CERTIFICATE_AUTO_INSTALL', '{{CERTIFICATE_AUTO_INSTALL}}', 'Instalar certificados automaticamente', 'boolean', 'certificados', FALSE, 'true', 131),
('SEEDER_SERVER', '{{SEEDER_SERVER}}', 'URL base do servidor SeederLinux para check-in do agente. Configure este FQDN no DNS ou adicione ao /etc/hosts das estacoes.', 'url', 'rede', FALSE, 'https://seederlinux.om.local', 140),
('INSTALL_AGENT', '{{INSTALL_AGENT}}', 'Instalar agente de check-in periodico', 'boolean', 'agente', FALSE, 'true', 150),
('AGENT_NO_CHECK_CERT', '{{AGENT_NO_CHECK_CERT}}', 'Permitir certificado autoassinado no agente', 'boolean', 'agente', FALSE, 'true', 151),
('NON_INTERACTIVE', '{{NON_INTERACTIVE}}', 'Modo nao-interativo: true para execucao automatica, false para permitir prompts do usuario', 'boolean', 'avancado', FALSE, 'true', 160),
('APT_POLICY', '{{APT_POLICY}}', 'Politica de proxy para apt-get: DIRECT, PROXY_NO_AUTH, PROXY_WITH_AUTH, MIRROR_LOCAL_SEEDER, MIRROR_LOCAL_OM, MIRROR_OFFICIAL', 'select', 'proxy', FALSE, 'DIRECT', 56),
('CLI_POLICY', '{{CLI_POLICY}}', 'Politica de proxy para wget/curl/git: DIRECT, PROXY_NO_AUTH, PROXY_WITH_AUTH, PAC', 'select', 'proxy', FALSE, 'DIRECT', 57),
('BROWSER_POLICY', '{{BROWSER_POLICY}}', 'Politica de proxy para browsers: DIRECT, PROXY_NO_AUTH, PROXY_WITH_AUTH, PAC, SYSTEM', 'select', 'proxy', FALSE, 'DIRECT', 58),
('APT_PROXY_NAME', '{{APT_PROXY_NAME}}', 'Nome do proxy para APT (vazio = proxy padrao da OM)', 'string', 'proxy', FALSE, '', 59),
('CLI_PROXY_NAME', '{{CLI_PROXY_NAME}}', 'Nome do proxy para CLI (vazio = proxy padrao da OM)', 'string', 'proxy', FALSE, '', 60),
('BROWSER_PROXY_NAME', '{{BROWSER_PROXY_NAME}}', 'Nome do proxy para browsers (vazio = proxy padrao da OM)', 'string', 'proxy', FALSE, '', 61),
('PROXY_USER', '{{PROXY_USER}}', 'Usuario do proxy (apenas se alguma policy = PROXY_WITH_AUTH)', 'string', 'proxy', FALSE, '', 62),
('PROXY_PASSWORD_B64', '{{PROXY_PASSWORD_B64}}', 'Senha do proxy codificada em base64 (apenas se alguma policy = PROXY_WITH_AUTH)', 'password', 'proxy', FALSE, '', 63),
('MIRROR_LOCAL_SEEDER_PATH', '{{MIRROR_LOCAL_SEEDER_PATH}}', 'Path do mirror local no SeederLinux (default: /mirror/)', 'string', 'proxy', FALSE, '/mirror/', 64),
('MIRROR_LOCAL_OM_URL', '{{MIRROR_LOCAL_OM_URL}}', 'URL do mirror da OM (apenas se APT_POLICY = MIRROR_LOCAL_OM)', 'url', 'proxy', FALSE, '', 65),
('LEGACY_ALLOW_EXTERNAL', '{{LEGACY_ALLOW_EXTERNAL}}', 'Permite que a estacao baixe Firefox 52.7 / Java 8 diretamente da Mozilla/Adoptium quando nao estiverem hospedados no SeederLinux. Deixe desligado em ambientes isolados.', 'boolean', 'aplicacoes', FALSE, 'false', 118)
ON CONFLICT (name) DO NOTHING;

UPDATE variable_definitions
SET
    description = 'URL para download do pacote de certificados CA institucionais (formato .tar.gz). Deixe vazio se nao houver certificados personalizados.',
    category = 'oculto'
WHERE name = 'CERTIFICATE_BUNDLE';

CREATE TABLE IF NOT EXISTS organization_variables (
    id SERIAL PRIMARY KEY,
    organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    variable_id INTEGER NOT NULL REFERENCES variable_definitions(id) ON DELETE CASCADE,
    value TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(organization_id, variable_id)
);

CREATE INDEX IF NOT EXISTS idx_org_vars_org ON organization_variables(organization_id);
CREATE INDEX IF NOT EXISTS idx_org_vars_var ON organization_variables(variable_id);

INSERT INTO organization_variables (organization_id, variable_id, value)
SELECT 1, id, COALESCE(default_value, '') FROM variable_definitions
ON CONFLICT (organization_id, variable_id) DO NOTHING;

INSERT INTO organization_variables (organization_id, variable_id, value)
SELECT 1, id, '10.0.0.1,10.0.0.2' FROM variable_definitions WHERE name = 'DC_IP_LIST'
ON CONFLICT (organization_id, variable_id) DO NOTHING;

INSERT INTO organization_variables (organization_id, variable_id, value)
SELECT 1, id, 'Administrator' FROM variable_definitions WHERE name = 'ADMIN_USERNAME'
ON CONFLICT (organization_id, variable_id) DO NOTHING;

INSERT INTO organization_variables (organization_id, variable_id, value)
SELECT 1, id, 'false' FROM variable_definitions WHERE name = 'INSTALL_DESKTOP'
ON CONFLICT (organization_id, variable_id) DO NOTHING;

INSERT INTO organization_variables (organization_id, variable_id, value)
SELECT 1, id, 'https://seederlinux.om.local' FROM variable_definitions WHERE name = 'SEEDER_SERVER'
ON CONFLICT (organization_id, variable_id) DO NOTHING;

INSERT INTO organization_variables (organization_id, variable_id, value)
SELECT 1, id, 'true' FROM variable_definitions WHERE name = 'NON_INTERACTIVE'
ON CONFLICT (organization_id, variable_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS scripts (
    id SERIAL PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    filename VARCHAR(200),
    description TEXT,
    content TEXT NOT NULL,
    is_core BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    execution_order INTEGER DEFAULT 0,
    version INTEGER DEFAULT 1,
    organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
    current_version_id INTEGER,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_scripts_filename ON scripts(filename);
CREATE INDEX IF NOT EXISTS idx_scripts_core ON scripts(is_core, execution_order);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'scripts_filename_key') THEN
        ALTER TABLE scripts ADD CONSTRAINT scripts_filename_key UNIQUE (filename);
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS script_versions (
    id SERIAL PRIMARY KEY,
    script_id INTEGER NOT NULL REFERENCES scripts(id) ON DELETE CASCADE,
    version_name VARCHAR(200) NOT NULL,
    version_number INTEGER NOT NULL,
    content TEXT NOT NULL,
    changelog TEXT DEFAULT '',
    version_type VARCHAR(20) NOT NULL DEFAULT 'factory' CHECK (version_type IN ('factory', 'gap_default', 'om_specific')),
    organization_id INTEGER REFERENCES organizations(id),
    is_active BOOLEAN DEFAULT true,
    created_by INTEGER REFERENCES users(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(script_id, version_number)
);

CREATE INDEX IF NOT EXISTS idx_script_versions_script ON script_versions(script_id);
CREATE INDEX IF NOT EXISTS idx_script_versions_type ON script_versions(version_type);
CREATE INDEX IF NOT EXISTS idx_script_versions_org ON script_versions(organization_id);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints WHERE constraint_name = 'scripts_current_version_id_fkey' AND table_name = 'scripts') THEN
        ALTER TABLE scripts ADD CONSTRAINT scripts_current_version_id_fkey
            FOREIGN KEY (current_version_id) REFERENCES script_versions(id);
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS om_script_versions (
    id SERIAL PRIMARY KEY,
    organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    script_id INTEGER NOT NULL REFERENCES scripts(id) ON DELETE CASCADE,
    version_id INTEGER REFERENCES script_versions(id) ON DELETE CASCADE,
    content TEXT,
    execution_order INTEGER NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    version_number INTEGER NOT NULL DEFAULT 0,
    created_by INTEGER REFERENCES users(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_om_script_versions_org ON om_script_versions(organization_id);
CREATE INDEX IF NOT EXISTS idx_om_script_versions_script ON om_script_versions(script_id);
CREATE INDEX IF NOT EXISTS idx_om_script_versions_active ON om_script_versions(organization_id, script_id, is_active);

CREATE TABLE IF NOT EXISTS deploy_bundles (
    id SERIAL PRIMARY KEY,
    organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    filename VARCHAR(255),
    description TEXT,
    content TEXT NOT NULL,
    script_ids TEXT,
    scripts_count INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    generated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'deploy_bundles' AND column_name = 'description'
    ) THEN
        ALTER TABLE deploy_bundles ADD COLUMN description TEXT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_deploy_bundles_org ON deploy_bundles(organization_id);
CREATE INDEX IF NOT EXISTS idx_deploy_bundles_date ON deploy_bundles(generated_at DESC);
CREATE INDEX IF NOT EXISTS idx_bundles_org_active_date 
ON deploy_bundles(organization_id, is_active, generated_at DESC);

CREATE TABLE IF NOT EXISTS stations (
    id SERIAL PRIMARY KEY,
    organization_id INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    hostname VARCHAR(200),
    ip_address VARCHAR(50),
    mac_address VARCHAR(50),
    os_name VARCHAR(100),
    os_version VARCHAR(50),
    last_checkin TIMESTAMP,
    status VARCHAR(50) DEFAULT 'never_connected',
    serial_aplicado INTEGER DEFAULT 0,
    token TEXT UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_stations_org ON stations(organization_id);
CREATE INDEX IF NOT EXISTS idx_stations_token ON stations(token);
CREATE INDEX IF NOT EXISTS idx_stations_checkin ON stations(last_checkin DESC);

CREATE TABLE IF NOT EXISTS audit_events (
    id SERIAL PRIMARY KEY,
    organization_id INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
    user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
    entity VARCHAR(50) NOT NULL,
    entity_id INTEGER,
    action VARCHAR(50) NOT NULL,
    details JSONB DEFAULT '{}',
    ip_address VARCHAR(45),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_audit_events_org ON audit_events(organization_id);
CREATE INDEX IF NOT EXISTS idx_audit_events_user ON audit_events(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_events_entity ON audit_events(entity, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_events_date ON audit_events(created_at DESC);

CREATE TABLE IF NOT EXISTS settings (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_by INTEGER REFERENCES users(id) ON DELETE SET NULL
);

INSERT INTO settings (key, value)
VALUES ('public_theme', 'classic')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS mirror.config (
    id SERIAL PRIMARY KEY,
    enabled BOOLEAN DEFAULT FALSE,
    tool VARCHAR(20) DEFAULT 'aptly',
    mirror_base_path VARCHAR(255) NOT NULL DEFAULT '/var/lib/seederlinux/mirror',
    mirror_url_base VARCHAR(255) NOT NULL DEFAULT '',
    path_locked BOOLEAN DEFAULT FALSE,
    verify_gpg BOOLEAN DEFAULT TRUE,
    sync_interval_hours INTEGER DEFAULT 24,
    auto_cleanup_enabled BOOLEAN DEFAULT TRUE,
    retention_snapshots INTEGER DEFAULT 2,
    quarantine_days INTEGER DEFAULT 7,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mirror.distros (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    codename VARCHAR(50) NOT NULL,
    base_distro_id INTEGER NULL REFERENCES mirror.distros(id) ON DELETE SET NULL,
    active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mirror.versions (
    id SERIAL PRIMARY KEY,
    distro_id INTEGER REFERENCES mirror.distros(id) ON DELETE CASCADE,
    version VARCHAR(50) NOT NULL,
    active BOOLEAN DEFAULT TRUE,
    status VARCHAR(20) DEFAULT 'current',
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mirror.jobs (
    id SERIAL PRIMARY KEY,
    job_type VARCHAR(20) NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    details TEXT,
    gpg_verified BOOLEAN DEFAULT FALSE,
    started_at TIMESTAMP DEFAULT NOW(),
    finished_at TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mirror.organization_repository_settings (
    id SERIAL PRIMARY KEY,
    organization_id INTEGER NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    use_local_mirror BOOLEAN DEFAULT FALSE,
    mirror_priority INTEGER DEFAULT 100,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_mirror_distros_name_codename
    ON mirror.distros(name, codename);
CREATE UNIQUE INDEX IF NOT EXISTS idx_mirror_distros_name
    ON mirror.distros(name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_mirror_versions_distro_version
    ON mirror.versions(distro_id, version);
CREATE UNIQUE INDEX IF NOT EXISTS idx_org_repository_settings_org
    ON mirror.organization_repository_settings(organization_id);

INSERT INTO mirror.config (id, enabled, tool, mirror_base_path, path_locked, verify_gpg,
                           sync_interval_hours, auto_cleanup_enabled, retention_snapshots, quarantine_days)
SELECT 1, FALSE, 'aptly', '/var/lib/seederlinux/mirror', FALSE, TRUE, 24, TRUE, 2, 7
WHERE NOT EXISTS (SELECT 1 FROM mirror.config);

INSERT INTO mirror.distros (name, codename) VALUES
    ('Debian', 'debian'),
    ('Ubuntu', 'ubuntu'),
    ('Linux Mint', 'mint'),
    ('Zorin', 'zorin')
ON CONFLICT (name) DO NOTHING;

UPDATE mirror.distros AS child
SET base_distro_id = base.id
FROM mirror.distros AS base
WHERE child.name = 'Linux Mint'
    AND base.name = 'Ubuntu';

UPDATE mirror.distros AS child
SET base_distro_id = base.id
FROM mirror.distros AS base
WHERE child.name = 'Zorin'
    AND base.name = 'Ubuntu';

INSERT INTO mirror.versions (distro_id, version, status)
SELECT d.id, seed.version, seed.status
FROM mirror.distros d
JOIN (VALUES
    ('Debian', 'bookworm', 'old'),
    ('Debian', 'trixie', 'current'),
    ('Debian', 'forky', 'future'),
    ('Ubuntu', 'jammy', 'old'),
    ('Ubuntu', 'noble', 'current'),
    ('Linux Mint', 'wilma', 'current'),
    ('Zorin', 'jammy', 'old')
) AS seed(name, version, status) ON seed.name = d.name
ON CONFLICT (distro_id, version) DO NOTHING;

CREATE TABLE IF NOT EXISTS om_proxies (
    id              BIGSERIAL PRIMARY KEY,
    organization_id BIGINT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name            VARCHAR(64) NOT NULL,
    url             TEXT NOT NULL,
    username        VARCHAR(128) DEFAULT '',
    password_enc    TEXT DEFAULT '',
    pac_url         TEXT DEFAULT '',
    no_proxy        TEXT DEFAULT '',
    is_default      BOOLEAN NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_om_proxies_org_name
    ON om_proxies (organization_id, name);

CREATE UNIQUE INDEX IF NOT EXISTS uq_om_proxies_org_default
    ON om_proxies (organization_id)
    WHERE is_default = true;

CREATE INDEX IF NOT EXISTS idx_om_proxies_org
    ON om_proxies (organization_id);

INSERT INTO organization_variables (organization_id, variable_id, value)
SELECT o.id, vd.id, vd.default_value
FROM organizations o
CROSS JOIN variable_definitions vd
WHERE vd.name IN ('APT_POLICY', 'CLI_POLICY', 'BROWSER_POLICY', 'APT_PROXY_NAME', 'CLI_PROXY_NAME', 'BROWSER_PROXY_NAME', 'PROXY_USER', 'PROXY_PASSWORD_B64', 'MIRROR_LOCAL_SEEDER_PATH', 'MIRROR_LOCAL_OM_URL', 'LEGACY_ALLOW_EXTERNAL')
ON CONFLICT (organization_id, variable_id) DO NOTHING;