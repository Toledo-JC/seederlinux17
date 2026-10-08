# Documento de Continuidade — SeederLinux Lite

Este documento resume a ordem de provisionamento e os contratos do Core Pipeline V2 para continuidade do desenvolvimento e da operação.

## Ordem canônica dos 24 scripts

| Ordem | Script | Responsabilidade |
|---:|---|---|
| 01 | `core_dns.sh` | DNS, hosts e hostname |
| 02 | `core_ntp.sh` | NTP adaptativo (cascata de 5 clientes) |
| 03 | `core_repositories.sh` | Repositórios APT |
| 04 | `core_packages.sh` | Pacotes base, autenticação e display manager |
| 05 | `core_legados.sh` | Java 8 e Firefox 52.7 legado |
| 06 | `core_apps.sh` | Chrome e OnlyOffice |
| 07 | `core_domain.sh` | Ingresso AD (Fase 2 DNS) |
| 08 | `core_ssh.sh` | SSH e grupos permitidos (AllowGroups) |
| 09 | `core_browser.sh` | Políticas de navegador |
| 10 | `core_inventory.sh` | OCS Inventory |
| 11 | `core_printers.sh` | CUPS e impressoras |
| 12 | `core_vnc.sh` | x11vnc |
| 13 | `core_conky.sh` | Conky |
| 14 | `core_config.sh` | Configurações persistentes (`config.env`) |
| 15 | `core_branding.sh` | Wallpaper, logo e tema |
| 16 | `core_session_lightdm.sh` | Sessão LightDM |
| 17 | `core_session_gdm3.sh` | Sessão GDM3 |
| 18 | `core_session_sddm.sh` | Sessão SDDM |
| 19 | `core_logon.sh` | Logon minimalista |
| 20 | `core_password_change.sh` | Troca de senha AD |
| 21 | `core_logoff.sh` | Logoff minimalista |
| 22 | `core_proxy.sh` | Proxy CLI |
| 23 | `core_agent.sh` | Agente SeederLinux |
| 24 | `core_sync.sh` | seeder-sync (GPO-like) |

Os números de ordem não devem ser codificados nos textos dos scripts: a ordem é definida pelos metadados e pelo bundle gerado. Os scripts de sessão verificam o display manager e só executam quando correspondem à estação.

## Contrato de fases

- **Fase 1 (scripts 01..06):** DNS de internet ativo; `apt` e `wget` disponíveis para instalar dependências.
- **Fase 2 (script 07):** troca o DNS para o Active Directory e ingressa a estação no domínio.
- **Fase 3 (scripts 08..24):** DNS do AD ativo; não deve depender de instalação via `apt`.

A ordem de `core_dns.sh` antes de `core_ntp.sh` e de ambos antes de `core_domain.sh` é necessária: a sincronização de horário deve preceder Kerberos, e a Fase 1 fornece conectividade para instalar clientes NTP alternativos quando necessário.

## Core Pipeline V2 (refactor 2026-10)

### Infraestrutura de log

- O cabeçalho do bundle instala `lib/diag.sh` em `/usr/local/lib/seederlinux/diag.sh`.
- O bundle exporta `$BUNDLE_LOG` em `/var/log/seederlinux/bundle-<data>.log` e envia a saída do processo para tela e arquivo.
- O sumário final apresenta contadores `[OK]`, `[AVISO]` e `[ERRO]`, além das ocorrências de erro com referência de linha no log.
- Os oito níveis de log são `INFO`, `TESTE`, `TENT`, `OK`, `AVISO`, `DIAG`, `ACAO` e `ERRO`.

### Ordem de execução, versionamento e dependências

- `execution_order` registra a ordem de execução dos scripts no banco; o catálogo de `install/gen_insert_core.py` gera os registros SQL iniciais.
- A coluna `depends_on` (`TEXT[]`) declara dependências por nome de arquivo.
- A geração do bundle valida que a ordem é sequencial, sem lacunas ou duplicados, e rejeita dependências ausentes ou posicionadas depois do script dependente.
- A UI permite reordenar scripts. A validação do backend durante a geração do bundle é a proteção contra uma ordem inválida; a UI ainda pode evoluir para bloquear ordens incompatíveis antes de salvar.
- Overrides por OM podem definir ordens efetivas diferentes. A ordem efetiva precisa continuar compatível com as dependências.

### NTP adaptativo

- `core_ntp.sh` tenta os clientes nesta cascata: `systemd-timesyncd` → `chrony` → `ntpsec` → `ntp` → `ntpdate+cron`.
- Cada tentativa de sincronização aguarda até 20 segundos antes de avançar.
- O cliente vencedor e o servidor ficam registrados em `/etc/seederlinux/ntp-state.env`.
- `/usr/local/bin/seederlinux-sync-ntp` reaproveita o cliente vencedor e é instalado junto com `seederlinux-sync-ntp.service` pelo cabeçalho do bundle.
- A unidade systemd é habilitada para o boot; `core_logon.sh` também chama o sincronizador com timeout de 3 segundos para não bloquear o login.

## Scripts permanentes

Além dos 24 scripts do bundle, o cabeçalho instala componentes permanentes no sistema:

- `/usr/local/lib/seederlinux/diag.sh`: funções de log estruturado usadas pelos scripts core.
- `/usr/local/bin/seederlinux-sync-ntp`: sincronização rápida com o cliente NTP vencedor.
- `/etc/systemd/system/seederlinux-sync-ntp.service`: unidade executada no boot.

O sincronizador NTP lê `/etc/seederlinux/ntp-state.env`, criado pelo `core_ntp.sh`. A atualização periódica pelo timer do seeder-sync ainda é um requisito futuro; atualmente os pontos documentados de execução são boot e logon.

## Operação e fonte dos dados

O schema de instalação é aplicado por `install/schema.sql`; o catálogo inicial de scripts é gerado por `install/gen_insert_core.py` em `install/insert_core_scripts.sql`. Ao alterar ordem ou dependências, manter esses artefatos e a documentação sincronizados. Os requisitos ainda não implementados estão listados em `REQUISITOS-V2.md`.
