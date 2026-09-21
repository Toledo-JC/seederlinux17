# Auditoria Completa — SeederLinux Lite 19/08/2026
####################################################

## Resumo Executivo

O SeederLinux Lite é um sistema funcional em estágio MVP avançado, com gestão multi-organizacional, versionamento de scripts, geração de bundles e auditoria operacionais. No entanto, acumula **dívida técnica significativa** em segurança (CORS aberto, ausência de CSRF, senhas em base64, tokens de estação em texto plano), performance (varredura O(n) de tokens, ausência de transações em pontos críticos) e manutenibilidade (API monolítica de 3.146 linhas, migrações de schema executadas em runtime). A página pública comunica o propósito do sistema de forma razoável, mas peca por jargão técnico e falta de didática para um profissional de TI que não conhece o produto. As 10 ações prioritárias estão listadas ao final.

---

## 1. Estrutura e Organização do Código

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 1.1 | Alto | `api/index.php` (3.146 linhas) | Arquivo monolítico com ~60 handlers, funções auxiliares e roteamento em único arquivo. | Difícil manutenção, merge conflicts, testes isolados inviáveis. | Extrair handlers por domínio (`handlers/auth.php`, `handlers/bundle.php`, etc.) mantendo o roteador central. |
| 1.2 | Médio | `api/index.php:880-911` (`ensureOmScriptVersionSchema`) | Migração de schema executada em runtime em toda chamada a `handleGetOrgScripts`, `handleSaveScriptOmVersion`, etc. | Overhead por request; lógica de migração fora do lugar correto. | Mover para `install/schema.sql` (já feito parcialmente) e remover a função. |
| 1.3 | Médio | `api/index.php:5-24` (`get_server_url_by_org`, `sanitize_org_urls`) | Funções definidas no topo do arquivo, antes do roteador, sem namespace. | Poluição do escopo global. | Mover para `lib/functions.php` ou um `lib/org.php`. |
| 1.4 | Baixo | `lixeira/` | Diretório com migrações e código substituído. `lixeira/sql/migration_soft_delete_acronym.sql` já está incorporado em `schema.sql`. | Confusão sobre qual é a fonte da verdade. | Confirmar que está em `schema.sql` e remover `lixeira/`. |
| 1.5 | Baixo | `public/assets/css/styles copy.css`, `public/assets/js/script copy.js`, `public/index copy.php` | Arquivos duplicados com sufixo "copy". | Confusão, risco de editar o arquivo errado. | Remover os arquivos "copy". |
| 1.6 | Baixo | `assets/js/app.js` vs `public/assets/js/script.js` | Lógica de tema e carregamento de bundles públicos duplicada entre dois arquivos. | Drift entre as duas páginas públicas (classic vs modern). | Extrair para um `assets/js/public-common.js` compartilhado. |
| 1.7 | Médio | `api/index.php` (múltiplos handlers) | Padrão de erro inconsistente: alguns usam `jsonError()`, outros fazem `http_response_code()` + `echo json_encode()` manual com `return`. | Comportamento de erro imprevisível; alguns retornam 200 com `success:false`, outros 500. | Padronizar todos os handlers para usar `jsonError()`/`jsonSuccess()`. |

---

## 2. Banco de Dados

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 2.1 | Alto | `schema.sql` — `user_tokens` | Sem índice em `token_hash`. `requireAuth()` faz `SELECT` de todos os tokens ativos e itera com `password_verify` (bcrypt) — O(n) por request. | DoS com poucos milhares de tokens; latência alta em cada autenticação. | Adicionar coluna `token_prefix CHAR(8)` indexada, filtrar por prefixo antes de `password_verify`. |
| 2.2 | Alto | `schema.sql` — `stations.token` | Token de estação armazenado em TEXT em texto plano. | Comprometimento do DB = impersonação de todas as estações. | Armazenar hash (SHA-256) do token; comparar por hash. |
| 2.3 | Médio | `schema.sql` — `users.organization_id` | `ON DELETE SET NULL` em vez de `ON DELETE RESTRICT` ou `CASCADE`. | Usuários órfãos se OM é deletada (mesmo com soft-delete, FK fica NULL silenciosamente). | Usar `ON DELETE RESTRICT` e forçar reatribuição antes de excluir. |
| 2.4 | Médio | `schema.sql` — `deploy_bundles.content` | Conteúdo do bundle (potencialmente > 1 MB) armazenado como TEXT, carregado inteiro em RAM no download. | OOM com bundles grandes ou muitos downloads concorrentes. | Considerar `pg_lo` (large objects) ou armazenar em filesystem com referência no DB. |
| 2.5 | Médio | `schema.sql` — `audit_events` | Sem retenção/rotação. Cresce indefinidamente. | Degradação de performance em consultas de auditoria após meses/anos. | Particionar por mês ou adicionar job de purga (ex: manter 365 dias). |
| 2.6 | Baixo | `schema.sql` — booleanos | Sem `CHECK` constraints em colunas booleanas (`is_active`, `is_core`, `is_required`). | Aceita valores não-booleanos em INSERTs diretos. | Adicionar `CHECK (is_active IN (TRUE, FALSE))` onde aplicável. |
| 2.7 | Baixo | `schema.sql` — `script_versions` | `UNIQUE(script_id, version_number)` mas `om_script_versions` não tem constraint equivalente. | Inconsistência entre escopos de versionamento. | Adicionar `UNIQUE(organization_id, script_id, version_number)` em `om_script_versions`. |
| 2.8 | Resolvido | ~~`supabase/migrations/`~~ | Diretório `supabase/migrations/` removido. O projeto usa PostgreSQL local e `schema.sql` é a única fonte de verdade. | — | — |

---

## 3. Backend (api/index.php e lib/)

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 3.1 | Crítico | `api/index.php:28` | `Access-Control-Allow-Origin: *` em todos os endpoints, incluindo autenticados. | Qualquer site pode fazer requisições cross-origin à API. | Restringir a origins confiáveis (configurável) ou usar credenciais com origin específica. |
| 3.2 | Crítico | `api/index.php` (todos POST/PUT/DELETE) | Ausência total de proteção CSRF. | Ataques CSRF em todas as mutações (criar OM, gerar bundle, excluir usuário). | Implementar token CSRF (double-submit cookie ou Synchronizer Token Pattern). |
| 3.3 | Crítico | `api/index.php:2116-2215` (`handleStationCheckin`) | Endpoint sem autenticação. Qualquer um pode registrar estações, receber token e baixar bundles. | Vazamento de bundles (contêm senhas em base64) para qualquer atacante que conheça um acrônimo de OM. | Exigir token de estação pré-existente ou credencial de operador para primeiro check-in. |
| 3.4 | Alto | `lib/functions.php:20-51` (`requireAuth`) | Varredura O(n) com `password_verify` (bcrypt) sobre todos os tokens ativos. | DoS com volume moderado de tokens; latência de 100-500ms por request autenticado. | Adicionar `token_prefix` indexado; filtrar candidatos antes de `password_verify`. |
| 3.5 | Alto | `api/index.php` (múltiplos handlers) | `PDOException` exposto ao cliente: `'Erro: ' . $e->getMessage()` com `file` e `line`. | Vazamento de estrutura interna, nomes de tabela, detalhes de conexão. | Logar erro internamente; retornar mensagem genérica ao cliente. |
| 3.6 | Alto | `api/index.php:1916-1931` (`handleDownloadBundle`) | `bundle-by-id` está no switch público (sem `requireAuth` no case), mas chama `requireAuth()` internamente. A página pública linka diretamente para ele. | Inconsistência: ou é público ou é privado. Se privado, a página pública quebra. | Definir claramente: bundles públicos vs privados. Se públicos, validar que a OM marcou o bundle como público. |
| 3.7 | Alto | `api/index.php:1612-1914` (`handleGenerateBundle`) | Geração de bundle sem transação envolvendo INSERT + UPDATE de desativação de bundles anteriores. | Race condition: dois bundles ativos simultâneos se gerados concorrentemente. | Envolver em `beginTransaction()`/`commit()`. |
| 3.8 | Médio | `api/index.php:748-806` (`handleUpdateVariables`) | Loop de UPDATEs sem transação. | Atualização parcial se uma falha no meio. | Envolver em transação. |
| 3.9 | Médio | `api/index.php:1577-1609` (`handleUploadScript`) | Sem validação de MIME do arquivo enviado (apenas tamanho 500KB). | Upload de arquivo malicioso disfarçado de script. | Validar MIME real com `finfo_file()` (como já feito em uploads de imagem). |
| 3.10 | Médio | `lib/functions.php:14` (`sanitizeInput`) | Apenas `trim()`. Sem validação de tipo (IP, URL, porta, inteiro). | Valores inválidos chegam ao DB e ao bundle. | Adicionar validação por tipo usando o campo `type` de `variable_definitions`. |
| 3.11 | Médio | `api/index.php:2700-2725` (`handleToggleBundleActive`) | Passa string `'true'`/`'false'` para coluna BOOLEAN. | Funciona no PostgreSQL por coerção, mas é frágil. | Passar booleano PHP real: `$newStatus`. |
| 3.12 | Baixo | `api/index.php:346-434` (`handleLogin`) | Rate limit baseado em `audit_events` (COUNT por IP). | Consulta em tabela que cresce indefinidamente; sem índice composto em `(action, ip_address, created_at)`. | Adicionar índice ou usar tabela dedicada de rate limit. |
| 3.13 | Baixo | `api/index.php:436-447` (`handleLogout`) | Deleta todos os tokens do usuário, incluindo o de outros dispositivos. | Logout em um dispositivo derruba todas as sessões. | Deletar apenas o token atual (passado no header Authorization). |

---

## 4. Frontend

### 4.1 Segurança e Robustez

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 4.1.1 | Alto | `assets/js/app.js:45-60` (`Toast.show`) | Usa `innerHTML` com `${String(message)}` sem escape. | XSS se mensagem de erro incluir HTML controlado por atacante. | Usar `textContent` ou `Utils.escapeHtml(message)`. |
| 4.1.2 | Médio | `assets/js/admin.js` (várias funções) | Mistura `Utils.escapeHtml()` com `innerHTML` em template literals. Ex: `showReorderModal` usa `escapeHtml` em nomes, mas outros pontos usam interpolação direta. | XSS potencial em dados vindos da API (nomes de OM, descrições de bundle). | Padronizar: todo conteúdo dinâmico em `innerHTML` deve passar por `escapeHtml`. |
| 4.1.3 | Médio | `login.html` | Página de login não tem CSP, nem proteção contra clickjacking. | Phishing por iframe. | Adicionar `X-Frame-Options: DENY` (já em `.htaccess`, mas não em headers PHP). |

### 4.2 UX e Acessibilidade

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 4.2.1 | Médio | `admin.js:311-330` (`saveScriptOrder`) | Usa `confirm()` nativo para reordenar scripts. | UX inconsistente com o resto do painel (que usa modais). | Substituir por modal HTML. |
| 4.2.2 | Médio | `admin.js` (geração de bundle) | Descrição do bundle coletada via `prompt()` nativo. | UX ruim, impossível de estilizar, quebra em mobile. | Substituir por modal com `<textarea>`. |
| 4.2.3 | Baixo | `admin.html` / `index.html` | Sem indicadores de carregamento (skeleton/spinner) em várias views. | Usuário não sabe se algo está carregando ou travado. | Adicionar spinners consistentes. |
| 4.2.4 | Baixo | `admin.html` | Navegação por tabs não gerencia estado de URL (hash ou history). | Não é possível linkar diretamente para uma view. | Usar `history.pushState` ou hash routing. |

### 4.3 Página Pública (`index.html` — ótica de TI que não conhece o sistema)

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 4.3.1 | Alto | `index.html` (hero) | Headline "Padronize e gerencie estacoes Linux com bundles autonomos" usa jargão ("bundles autonomos") sem explicar. | Profissional de TI que não conhece o sistema não entende o que é um "bundle" no primeiro contato. | Reformular: "Prepare qualquer estação Linux em minutos, com a mesma configuração — toda vez." Explicar bundle depois. |
| 4.3.2 | Médio | `index.html` (seção "O que é") | Texto denso, parágrafos longos, sem bullets. | Leitura difícil; mensagem se perde. | Usar bullets curtos: "O que era: scripts soltos. O que é agora: processo controlado." |
| 4.3.3 | Médio | `index.html` (seção "Como funciona") | 3 passos genéricos ("Configure. Gere. Execute.") sem detalhes práticos. | Não responde "como começar de verdade". | Adicionar: "1. Acesse o painel. 2. Selecione sua OM. 3. Preencha as variáveis. 4. Baixe o bundle. 5. Rode `sudo bash bundle.sh` na estação." |
| 4.3.4 | Médio | `index.html` (tabela de bundles) | Coluna "Arquivo" mostra `bundle_OM_20260820_143022.sh` — técnico e não amigável. | Usuário de TI não sabe o que fazer com isso. | Adicionar coluna "Distribuição" ou "Compatibilidade" (Debian/Ubuntu/Mint). |
| 4.3.5 | Baixo | `index.html` (doc-links) | Links para `README.md`, `SERVIDOR.md`, `APRESENTACAO.md` — documentos técnicos em Markdown, servidos como texto plano. | Acessibilidade ruim; não é didático. | Renderizar como HTML ou criar uma página de docs própria. |
| 4.3.6 | Baixo | `index.html` | Sem CTA claro para "como testar" ou "demo". | Visitante não tem próximo passo acionável além de "baixar agente". | Adicionar "Solicitar acesso ao painel" ou "Ver documentação de implantação". |

---

## 5. Scripts Core (scripts/core/)

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 5.1 | Alto | `core_apps.sh` (bloco OnlyOffice, linhas ~100-120) | Aninhamento de `if/else/fi` inconsistente — há `fi` que fecha `if` de `wget` mas o `else` interno não fecha corretamente. | Falha de sintaxe em alguns interpretadores; comportamento imprevisível. | Revisar estrutura `if/else/fi` do bloco OnlyOffice. |
| 5.2 | Alto | `core_password_change.sh` (linhas ~20-30) | Heredoc `<< 'EOFSCRIPT'` (com aspas) impede substituição de `{{DOMINIO}}` e `{{OM_ACRONYM}}` dentro do script gerado. | Variáveis ficam literais no `/usr/local/bin/trocar-senha` em vez de substituídas. | Usar heredoc sem aspas `<< EOFSCRIPT` ou injetar variáveis via `sed` após criação. |
| 5.3 | Médio | `core_dns.sh`, `core_ssh.sh`, `core_branding.sh`, `core_config.sh`, `core_proxy.sh` | Usam `set -e` no nível raiz do script (sem subshell). | Qualquer falha aborta todo o bundle. Scripts com `(set -e ...)` em subshell são mais resilientes. | Padronizar: todos os scripts Core devem usar subshell `(set -e ...)` para isolamento. |
| 5.4 | Médio | `core_domain.sh` (linhas ~250-300) | `kinit` com senha via `echo "$ADMIN_PASSWORD" | kinit` — senha passa por pipe, visível em `/proc`. | Senha AD exposta brevemente no processo do bundle. | Usar `kinit` com keytab ou `expect` em vez de pipe. |
| 5.5 | Médio | `core_domain.sh` (linha ~15) | `ADMIN_PASSWORD_B64="__ADMIN_PASSWORD_B64__"` — placeholder especial (não `{{}}`) que depende de substituição específica na API. | Se a API não fizer o `str_replace`, a senha fica literal `__ADMIN_PASSWORD_B64__`. | Documentar claramente este contrato especial ou padronizar para `{{ADMIN_PASSWORD_B64}}`. |
| 5.6 | Médio | Vários scripts | Falta idempotência: `core_dns.sh` sobrescreve `/etc/resolv.conf` e `/etc/hosts` sem verificar se já está correto. | Re-execução do bundle reconfigura DNS temporário desnecessariamente. | Adicionar guards (`grep -q` antes de escrever). |
| 5.7 | Baixo | `core_session_lightdm.sh`, `core_session_gdm3.sh`, `core_session_sddm.sh` | Usam `return 0` dentro de script executado em subshell. | Funciona, mas `return` fora de função é não-padrão em alguns shells. | Usar `exit 0`. |
| 5.8 | Baixo | `core_agent.sh` | Cron hardcoded com `--no-check-certificate`. | SSL sempre desabilitado no agente cron, mesmo se `AGENT_NO_CHECK_CERT=false`. | Parametrizar com a variável. |

---

## 6. Agente Python (downloads/agent.py)

| # | Severidade | Local | Descrição | Impacto | Sugestão |
|---|---|---|---|---|---|
| 6.1 | Crítico | `agent.py` (`download_bundle`, `checkin`) | `--no-check-certificate` desabilita SSL por padrão (`AGENT_NO_CHECK_CERT` default `true`). | MITM trivial em trânsito; bundle (com senhas) pode ser interceptado. | Default `false`; exigir flag explícita para desabilitar. |
| 6.2 | Alto | `agent.py` (`execute_bundle`) | Executa bundle baixado sem verificação de integridade/assinatura. | Bundle adulterado em trânsito executa como root. | Implementar hash SHA-256 ou assinatura GPG; verificar antes de executar. |
| 6.3 | Alto | `agent.py` (`save_token`) | Token de estação salvo em `/etc/seeder/station_token` em texto plano (perm 600). | Comprometimento do filesystem = impersonação da estação. | Hash do token antes de salvar; comparar por hash no check-in. |
| 6.4 | Médio | `agent.py` (`collect_system_info`) | Coleta MAC via `uuid.getnode()` que pode retornar MAC aleatório. | Identificação inconsistente da estação. | Usar `psutil` ou ler `/sys/class/net/*/address`. |
| 6.5 | Baixo | `agent.py` (`main`) | `exit_code = 0` mesmo quando check-in falha (rede indisponível). | Falhas silenciosas; difícil diagnosticar. | Logar warning mas considerar exit code != 0 para falhas persistentes. |

---

## 7. Segurança — Resumo Priorizado

### P0 — Críticos (bloqueiam produção)

| # | Problema | Local |
|---|---|---|
| S1 | CORS `*` em API autenticada | `api/index.php:28` |
| S2 | CSRF ausente em todas as mutações | `api/index.php` (todos POST/PUT/DELETE) |
| S3 | `handleStationCheckin` sem auth — vazamento de bundles | `api/index.php:2116` |
| S4 | Senha admin default `admin123` | `schema.sql` (seed) |
| S5 | `ADMIN_PASSWORD_B64` e `VNC_PASSWORD_B64` em base64 (não criptografia) | `schema.sql` (variáveis) + bundle |
| S6 | Agente com SSL desabilitado por padrão | `agent.py` + `core_agent.sh` |
| S7 | Bundle executado sem verificação de integridade | `agent.py:execute_bundle` |

### P1 — Altos

| # | Problema | Local |
|---|---|---|
| S8 | `requireAuth` O(n) com bcrypt — DoS | `lib/functions.php:20` |
| S9 | `PDOException` exposto ao cliente | Múltiplos handlers |
| S10 | Token de estação em texto plano no DB e no disco | `schema.sql` + `agent.py` |
| S11 | Sem CSP / HSTS | `.htaccess` (parcial) |
| S12 | XSS via `Toast.show` (`innerHTML`) | `assets/js/app.js:45` |
| S13 | Upload de script sem validação MIME | `api/index.php:1577` |
| S14 | Rate limit baseado em `audit_events` sem índice | `api/index.php:357` |
| S15 | `.env` com segredos em texto plano | `.env` |

### P2 — Médios

| # | Problema |
|---|---|
| S16 | Sem transações em `handleUpdateVariables` e `handleGenerateBundle` |
| S17 | `sanitizeInput` sem validação de tipo |
| S18 | `ON DELETE SET NULL` em `users.organization_id` |
| S19 | Sem retenção de `audit_events` |
| S20 | `handleLogout` derruba todas as sessões |

---

## 8. Performance e Escalabilidade

| # | Severidade | Local | Descrição | Sugestão |
|---|---|---|---|---|
| 8.1 | Alto | `lib/functions.php:20` (`requireAuth`) | Cada request autenticada varre todos os tokens com bcrypt. | Índice `token_prefix` + filtragem antes de `password_verify`. |
| 8.2 | Médio | `api/index.php:2185` (`handleStationCheckin`) | Query `SELECT id FROM deploy_bundles ... ORDER BY generated_at DESC LIMIT 1` por check-in. | Índice composto `(organization_id, is_active, generated_at DESC)` — já existe mas não cobre `is_active` no filtro. |
| 8.3 | Médio | `api/index.php:1916` (`handleDownloadBundle`) | Carrega bundle inteiro em string e faz `echo`. | Usar `stream_get_contents` ou `fpassthru` com chunks. |
| 8.4 | Médio | `api/index.php:581-589` (`handleGetOrganizations`) | N+1: para cada OM, faz query separada para buscar `LOGO_URL`. | JOIN único com `LATERAL` ou subquery correlacionada. |
| 8.5 | Baixo | `api/index.php:1017-1081` (`handleGetOrgScripts`) | N+1: para cada script, 3 queries (local, gap, factory). | Consolidar em uma query com `LATERAL JOIN`. |
| 8.6 | Baixo | `schema.sql` — `audit_events` | Sem particionamento. Cresce indefinidamente. | Particionar por mês. |

---

## 9. Documentação e Identidade Visual

| # | Severidade | Local | Descrição | Sugestão |
|---|---|---|---|---|
| 9.1 | Médio | `STATUS.md`, `memory/PRD.md` | Referenciam "19 scripts Core" — agora são 22. | Atualizar contagem e tabela. |
| 9.2 | Médio | `README.md`, `SERVIDOR.md`, `index.html`, `public/index.php` | URLs de GitHub inconsistentes: `Toledo-JC/SeederLinux_14`, `julioefefe/SeederLinux15`, `JcDevToledoHot/SeederLinux_13`. | Padronizar para um repositório. |
| 9.3 | Baixo | `INIT_CHECKLIST.md` | Referencia `/workspaces/SeederLinux_13` mas `SERVIDOR.md` diz `/opt/SeederLinux_14`. | Padronizar caminho. |
| 9.4 | Baixo | `index.html` (logo) | `seederlinux-logo.png` com `onerror` fallback para `.svg` — mas ambos existem. | Usar SVG diretamente (melhor para responsividade). |
| 9.5 | Baixo | `public/assets/css/styles.css` | Fontes `DM Mono` + `Manrope` carregadas do Google Fonts. | Em ambiente offline (militar), fontes não carregam. Self-hostar. |

---

## Top 10 Ações Recomendadas

| # | Ação | Severidade | Esforço | Benefício |
|---|---|---|---|---|
| 1 | **Fechar CORS** para origins confiáveis e **implementar CSRF tokens** em todas as mutações | Crítico | Médio | Elimina vetor de ataque mais explorável |
| 2 | **Autenticar `handleStationCheckin`** — exigir token prévio ou credencial de operador | Crítico | Baixo | Fecha vazamento de bundles (com senhas) para qualquer atacante |
| 3 | **Indexar `user_tokens`** por prefixo e filtrar antes de `password_verify` | Alto | Baixo | Resolve DoS de autenticação; latência de 100ms → <1ms |
| 4 | **Hash de tokens de estação** (SHA-256) no DB e no disco | Alto | Médio | Comprometimento do DB/filesystem não vira impersonação |
| 5 | **Remover exposição de `PDOException`** — logar internamente, retornar mensagem genérica | Alto | Baixo | Cessa vazamento de estrutura interna |
| 6 | **Criptografar senhas** (`ADMIN_PASSWORD_B64`, `VNC_PASSWORD_B64`) com AES + chave no `.env`, decodificar só no bundle | Crítico | Médio | Base64 não é criptografia; hoje é equivalente a texto plano |
| 7 | **Assinar bundles** (SHA-256 ou GPG) e **verificar no agente** antes de executar | Alto | Médio | Previne execução de bundle adulterado como root |
| 8 | **Corrigir `core_password_change.sh`** (heredoc com aspas impede substituição) e **revisar `core_apps.sh`** (aninhamento if/fi) | Alto | Baixo | Scripts que falham silenciosamente em produção |
| 9 | **Adicionar transações** em `handleGenerateBundle` e `handleUpdateVariables` | Médio | Baixo | Elimina race conditions e atualizações parciais |
| 10 | **Reescrever hero da página pública** em linguagem não-técnica + adicionar fluxo "como começar" passo a passo | Médio | Baixo | Profissional de TI entende o produto em 10 segundos |

---

Esta auditoria não alterou nenhum arquivo. As correções das ações 1-7 devem preceder qualquer deploy em produção; as ações 8-10 melhoram robustez e comunicação sem risco de quebra.
