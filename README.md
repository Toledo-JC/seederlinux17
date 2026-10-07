######################
## SeederLinux Lite.##
######################


O SeederLinux Lite automatiza a preparação e a personalização de estações Linux para ambientes corporativos multi-organizacionais. Ele monta bundles de instalação a partir de scripts Bash, grava configurações no PostgreSQL e disponibiliza a gestão por meio de painel web.

## Stack

- PHP para API e painel administrativo
- PostgreSQL para organizações, variáveis, scripts e auditoria
- Bash para scripts de instalação e configuração das estações
- HTML, CSS e JavaScript vanilla para as interfaces
- Python para o agente de check-in das estações

## Funcionalidades principais

- Gestão de múltiplas organizações (OMs) com isolamento de dados
- Catálogo de variáveis tipadas, com valores por organização
- 24 scripts Core de provisionamento
- Geração dinâmica de bundles com substituição de placeholders
- Edição e versionamento de scripts Core
- Overrides locais por OM com herança do padrão global
- Reordenação e ativação/desativação de scripts por OM
- Auditoria de ações administrativas
- Modo de execução não interativo (`NON_INTERACTIVE`)
- Sanitização de URLs, NTP, grupos SSH e assets

## Ordem canônica dos 24 scripts

O bundle inclui os 24 scripts Core na ordem abaixo. Os scripts de sessão (`core_session_*.sh`) são condicionais internamente: cada um verifica o display manager da estação e executa apenas o fluxo correspondente.

| Ordem | Script | Responsabilidade |
|---:|---|---|
| 1 | `core_dns.sh` | DNS, hosts e hostname |
| 2 | `core_ntp.sh` | Sincronização NTP adaptativa |
| 3 | `core_repositories.sh` | Repositórios APT |
| 4 | `core_packages.sh` | Pacotes base, autenticação e display manager |
| 5 | `core_legados.sh` | Java 8 e Firefox 52.7 legado |
| 6 | `core_apps.sh` | Chrome e OnlyOffice |
| 7 | `core_domain.sh` | Ingresso no domínio AD |
| 8 | `core_ssh.sh` | SSH e grupos permitidos |
| 9 | `core_browser.sh` | Políticas de navegadores |
| 10 | `core_inventory.sh` | OCS Inventory |
| 11 | `core_printers.sh` | CUPS e impressoras |
| 12 | `core_vnc.sh` | x11vnc |
| 13 | `core_conky.sh` | Monitor Conky |
| 14 | `core_config.sh` | Configurações persistentes |
| 15 | `core_branding.sh` | Wallpaper, logo e tema |
| 16 | `core_session_lightdm.sh` | Sessão LightDM |
| 17 | `core_session_gdm3.sh` | Sessão GDM3 |
| 18 | `core_session_sddm.sh` | Sessão SDDM |
| 19 | `core_logon.sh` | Ações de entrada do usuário |
| 20 | `core_password_change.sh` | Alteração de senha AD |
| 21 | `core_logoff.sh` | Ações de saída do usuário |
| 22 | `core_proxy.sh` | Proxy CLI |
| 23 | `core_agent.sh` | Agente SeederLinux |
| 24 | `core_sync.sh` | seeder-sync e políticas periódicas |

## Instalação

1. Instale PHP com os módulos de PostgreSQL, PostgreSQL, Bash, Git, cURL e `jq`.
2. Crie o banco PostgreSQL e aplique `install/schema.sql`.
3. Configure a conexão do banco no arquivo de configuração do servidor.
4. Publique o conteúdo do projeto no servidor web com suporte a PHP.
5. Acesse `login.html` para entrar no painel.
6. Crie ou selecione uma organização, preencha as variáveis e gere o bundle.

As informações específicas de infraestrutura, virtual host, permissões e operação ficam em [SERVIDOR.md](SERVIDOR.md).

## Gerar o catálogo de scripts

O catálogo inicial é gerado a partir dos arquivos em `scripts/core/`:

```bash
python3 install/gen_insert_core.py
```

Isso recria `install/insert_core_scripts.sql` com os 24 scripts e a ordem canônica. Depois, aplique o SQL no banco de instalação ou use o procedimento de sincronização descrito em `SERVIDOR.md`.

## Gerar um bundle

1. Entre no painel administrativo.
2. Selecione a organização.
3. Confira as variáveis obrigatórias, incluindo as senhas em base64 quando indicado pelo formulário.
4. Gere e baixe o bundle.

O sistema sanitiza automaticamente valores críticos para evitar erros comuns, como protocolos indevidos em `NTP_SERVER` ou espaços extras em `SSH_GROUPS`. Placeholders sem valor geram avisos, mas não bloqueiam a geração do bundle.

## Edição e versionamento de scripts

A edição de scripts é separada por escopo:

### Global — menu "Scripts Core"

Disponível para administradores GAP. As alterações feitas aqui valem para todas as OMs que **não** possuem configuração local própria.

- Salvar edição cria/ativa versão `gap_default`.
- "Reverter para Fábrica" restaura a versão original `factory`.

### Local — aba "Scripts Disponíveis" da OM

Disponível para operadores da OM. As alterações feitas aqui valem apenas para aquela OM.

- Salvar edição cria/ativa override em `om_script_versions`.
- "Usar Default do Servidor" remove o override local e volta a herdar o global.
- É possível alterar ordem, status e conteúdo por script.

### Regra de precedência

Ao gerar o bundle, o conteúdo efetivo de cada script segue a ordem:

1. Override local da OM (`om_script_versions`)  
2. Versão global `gap_default`  
3. Versão de fábrica (`factory`)  
4. Conteúdo base da tabela `scripts`

## Sincronizar scripts do GitHub

A sincronização atualiza no banco o conteúdo dos scripts versionados. O servidor pode ser informado por variável de ambiente ou por argumento:

```bash
SEEDER_SERVER=https://seu-servidor.example ./install/seeder-sync-scripts.sh
./install/seeder-sync-scripts.sh --server https://seu-servidor.example
```

O valor padrão operacional e os requisitos do servidor estão documentados em `SERVIDOR.md`.

## Estrutura principal

- `api/` — API PHP
- `assets/` — estilos, imagens e JavaScript
- `install/` — schema, gerador e scripts de instalação
- `scripts/core/` — scripts que compõem os bundles
- `downloads/` — agente distribuído às estações
- `SERVIDOR.md` — operação e infraestrutura
- `tests/` — testes automatizados
