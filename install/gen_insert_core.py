#!/usr/bin/env python3
"""
Gera install/insert_core_scripts.sql a partir dos arquivos em scripts/core/.
Usa dollar-quoting do PostgreSQL ($SeederScript$) para eliminar escaping.
"""
import os
import sys

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'scripts', 'core')
OUTPUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'insert_core_scripts.sql')
TAG = '$SeederScript$'

# Ordem de execucao + nome legivel + descricao
# Ordem canonica (Core Pipeline V2, Commit 3a): core_ntp.sh entra no lugar 02 e
# os demais scripts deslocam +1. O order_index numerico vem da posicao no bundle.
# Keep this catalog synchronized with scripts/core and the official execution order.
CATALOG = [
    # (execution_order, filename, name, description)
    (1,  'core_dns.sh',              'DNS e resolucao de nomes',                 'Configura DNS temporario e /etc/hosts. Roda ANTES de repositorios para permitir apt-get update.'),
    (2,  'core_ntp.sh',              'Sincronizacao de Horario (NTP adaptativo)', 'Descobre o cliente NTP que funciona com o servidor da OM, sincroniza o relogio e persiste o cliente vencedor em /etc/seederlinux/ntp-state.env.'),
    (3,  'core_repositories.sh',     'Configuracao de Repositorios APT',          'Configura repositorios APT (oficial, espelho ou customizado) apos o DNS estar resolvendo.'),
    (4,  'core_packages.sh',         'Instalacao de Pacotes Essenciais',          'Instala TODOS os pacotes necessarios (sistema, OCS, CUPS, VNC, Conky, Java, etc).'),
    (5,  'core_legados.sh',          'Suporte a Sistemas Legados',                'Instala Java 8 e Firefox 52 ESR para compatibilidade com sistemas legados.'),
    (6,  'core_apps.sh',             'Instalacao de Aplicativos Extras',          'Instala aplicacoes extras (OnlyOffice, Chrome, etc).'),
    (7,  'core_domain.sh',           'Ingresso em Dominio AD',                    'Ingressa a estacao no Active Directory (SSSD/Winbind com fallback).'),
    (8,  'core_ssh.sh',              'Configuracao SSH',                          'Configura acesso SSH e politicas de seguranca.'),
    (9,  'core_browser.sh',          'Politicas de Navegadores',                  'Configura Firefox ESR e Chrome (homepage, proxy, bookmarks) via politicas corporativas.'),
    (10, 'core_inventory.sh',        'Inventario OCS',                            'Configura OCS Inventory Agent (sem apt-get; pacote instalado em core_packages.sh).'),
    (11, 'core_printers.sh',         'Configuracao de Impressoras',               'Configura CUPS e impressoras via servidor remoto.'),
    (12, 'core_vnc.sh',              'Configuracao VNC',                          'Configura x11vnc para acesso remoto assistido.'),
    (13, 'core_conky.sh',            'Configuracao do Conky',                     'Configura o Conky (monitor de sistema no desktop) com perfil dinamico via JSON.'),
    (14, 'core_config.sh',           'Configuracao Persistente',                  'Configuracoes diversas do sistema (sysctl, limits, etc).'),
    (15, 'core_branding.sh',         'Identidade Visual',                         'Aplica wallpaper, logo, tema GTK e branding da OM.'),
    (16, 'core_session_lightdm.sh',  'Sessao LightDM',                            'Configura LightDM como display manager (autoselecao via DISPLAY_MANAGER=lightdm).'),
    (17, 'core_session_gdm3.sh',     'Sessao GDM3',                               'Configura GDM3 como display manager (autoselecao via DISPLAY_MANAGER=gdm3).'),
    (18, 'core_session_sddm.sh',     'Sessao SDDM',                               'Configura SDDM como display manager (autoselecao via DISPLAY_MANAGER=sddm).'),
    (19, 'core_logon.sh',            'Logon Persistente',                         'Script executado a cada logon de usuario (multi-DE).'),
    (20, 'core_password_change.sh',  'Troca de Senha AD',                         'Configura a alteracao de senha do usuario no dominio.'),
    (21, 'core_logoff.sh',           'Logoff Persistente',                        'Script executado a cada logoff de usuario.'),
    (22, 'core_proxy.sh',            'Proxy de CLI',                              'Configura proxy corporativo no sistema (apt, curl, wget, env).'),
    (23, 'core_agent.sh',            'Agente SeederLinux',                        'Instala e configura o agente SeederLinux.'),
    (24, 'core_sync.sh',             'Aplicador de Politicas (seeder-sync)',      'Instala o seeder-sync e um timer systemd (10 em 10 minutos) que reaplica de forma idempotente toda a configuracao corporativa da OM (estilo GPO).'),
]

def escape_sql_literal(s: str) -> str:
    """Escapa apenas para strings SQL curtas (name/description). Duplica aspas simples."""
    return s.replace("'", "''")

def main():
    header = """-- ============================================================================
-- SeederLinux Lite - Insercao dos Scripts Core
-- ============================================================================
-- Este arquivo popula a tabela 'scripts' com todos os scripts Core.
-- Gerado automaticamente a partir dos arquivos em scripts/core/.
--
-- ESCAPING: Usa dollar-quoting do PostgreSQL ($SeederScript$) para o conteudo
-- dos scripts, eliminando problemas com aspas simples, aspas duplas,
-- backslashes e qualquer outro caractere especial no bash.
-- ============================================================================

-- Limpar scripts core existentes (opcional - descomente se necessario)
-- DELETE FROM scripts WHERE is_core = TRUE;

"""

    parts = [header]
    on_conflict = (
        "ON CONFLICT (filename) DO UPDATE SET\n"
        "    name = EXCLUDED.name,\n"
        "    description = EXCLUDED.description,\n"
        "    content = EXCLUDED.content,\n"
        "    execution_order = EXCLUDED.execution_order,\n"
        "    version = EXCLUDED.version,\n"
        "    is_active = EXCLUDED.is_active,\n"
        "    updated_at = CURRENT_TIMESTAMP;\n"
    )

    missing = []
    tag_collisions = []
    for order, filename, name, description in CATALOG:
        path = os.path.join(SCRIPTS_DIR, filename)
        if not os.path.isfile(path):
            missing.append(filename)
            continue

        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Verifica se a tag conflita com o conteudo
        if TAG in content:
            tag_collisions.append(filename)
            continue

        block = (
            f"-- ============================================================================\n"
            f"-- {name} (ordem {order}) - {filename}\n"
            f"-- ============================================================================\n"
            f"INSERT INTO scripts (name, filename, description, content, is_core, is_active, execution_order, version, organization_id)\n"
            f"VALUES (\n"
            f"    '{escape_sql_literal(name)}',\n"
            f"    '{escape_sql_literal(filename)}',\n"
            f"    '{escape_sql_literal(description)}',\n"
            f"    {TAG}{content}{TAG},\n"
            f"    TRUE,\n"
            f"    TRUE,\n"
            f"    {order},\n"
            f"    1,\n"
            f"    NULL\n"
            f") {on_conflict}\n"
        )
        parts.append(block)

    if missing:
        print("ERRO: Arquivos ausentes:", missing, file=sys.stderr)
        sys.exit(1)
    if tag_collisions:
        print("ERRO: Tag $SeederScript$ colide com conteudo em:", tag_collisions, file=sys.stderr)
        sys.exit(1)

    # Validacao da ordem canonica: 1..24, sem gaps nem duplicados
    orders = sorted(order for order, _f, _n, _d in CATALOG)
    expected = list(range(1, len(CATALOG) + 1))
    if orders != expected:
        print(f"ERRO: execution_order invalido (esperado {expected[0]}..{expected[-1]}): {orders}", file=sys.stderr)
        sys.exit(1)

    footer = """
-- ============================================================================
-- FIM: 24 scripts core inseridos.
-- Ordem de execucao:
--   01 core_dns.sh              (configura DNS ANTES de apt-get update)
--   02 core_ntp.sh              (NTP adaptativo; roda ANTES do core_domain)
--   03 core_repositories.sh     (agora tem DNS resolvendo)
--   04 core_packages.sh
--   05 core_legados.sh
--   06 core_apps.sh
--   07 core_domain.sh
--   08 core_ssh.sh
--   09 core_browser.sh
--   10 core_inventory.sh
--   11 core_printers.sh
--   12 core_vnc.sh
--   13 core_conky.sh
--   14 core_config.sh
--   15 core_branding.sh
--   16 core_session_lightdm.sh   (bundle mantem apenas 1 dos 3 conforme DISPLAY_MANAGER)
--   17 core_session_gdm3.sh
--   18 core_session_sddm.sh
--   19 core_logon.sh
--   20 core_password_change.sh
--   21 core_logoff.sh
--   22 core_proxy.sh
--   23 core_agent.sh
--   24 core_sync.sh              (seeder-sync + timer systemd: reaplica politicas)
-- ============================================================================
"""
    parts.append(footer)

    with open(OUTPUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(parts))

    print(f"OK: {OUTPUT} gerado com {len(CATALOG)} scripts.")

if __name__ == '__main__':
    main()
