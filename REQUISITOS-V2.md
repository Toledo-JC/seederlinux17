# Requisitos V2 — SeederLinux Lite

Itens identificados durante o refactor Core Pipeline V2 (2026-10)
que NÃO entraram na V1 por decisão de escopo. Ordem de prioridade
aproximada.

## 1. Log estruturado (evoluções)

- [ ] Log por script core (`bundle-<data>/01-dns.log`, etc) em vez
      de arquivo único
- [ ] `[COMO CONFIRMAR]` em cada erro, com comandos de verificação
- [ ] Rotação do `bundle-*.log` (manter N dias)
- [ ] Helpers específicos no lib/diag.sh:
      - `log_diag_comando` (imprime "[DIAG] rode: <cmd>")
      - `log_erro_com_saida` (imprime saída crua indentada)
- [ ] Timestamp opcional por linha

## 2. Diagnóstico

- [ ] `seederlinux-diag` CLI com:
      - `seederlinux-diag ntp` (testes em cascata + laudo)
      - `seederlinux-diag ad` (kinit, LDAP, SRV, keytab)
      - `seederlinux-diag all` (tudo, gera .tar.gz para suporte)
      - `seederlinux-diag ntp --fix` (aplica o fix)
- [ ] Adicionar `[DIAG]/[ACAO]` nos outros pontos críticos dos
      scripts core (não só nos 4 do core_domain.sh)
- [ ] `sync_ntp` no timer do `seeder-sync` (10 min), não só no boot
      e no logon

## 3. UI / Painel

- [ ] UI de reordenação de scripts consumindo `depends_on` (bloquear
      ordem inválida na hora de salvar)
- [ ] Preview da ordem efetiva (com overrides por OM)
- [ ] Botão "Restaurar ordem default"

## 4. NTP

- [ ] `core_ntp.sh` reporta no `audit_events` qual cliente venceu
- [ ] `seederlinux-sync-ntp` com flag `--force` para testes manuais
- [ ] Suporte a `minpoll`/`maxpoll` customizáveis por OM

## 5. Sudoers

- [ ] Se o painel expõe GRUPO_ADMIN_LINUX, a UI deve avisar quando
      o valor não existe no AD (consulta via LDAP ao gerar bundle)
- [ ] Suporte a `%#GID` no painel (ao invés de nome textual)

## 6. Documentação

- [ ] Documentar no `DOCUMENTO-DE-CONTINUIDADE.md` a seção
      "Ordem de execução × versionamento × dependências"
- [ ] Comando `seederlinux-diag docs` que gera md da ordem atual

## 7. Dívidas técnicas conhecidas

- [ ] `core_config.sh`: bug do `REPOSITORY_URL=""` no config.env
      (sanitização no header ≠ sanitização em substituir_placeholders)
- [ ] `api/index.php`: `substituir_placeholders` deixa `{{X}}` literal
      quando X não está no catálogo (P0 se operador adicionar
      placeholder novo)
- [ ] `core_packages.sh`: `DESKTOP_ENV=""` / `INSTALL_DESKTOP="false"`
      hardcoded
- [ ] Extensão Chrome CRX3: sed com padrão vazio (não injeta
      credenciais; foi corrigido com `__PROXY_AUTH_USER__` mas
      confirmar se chegou ao main)
- [ ] `agent.py` aplica bundle como root sem verificar assinatura
