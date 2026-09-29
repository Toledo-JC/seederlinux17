# Proxy por Grupo do AD

## Modelo

Cada proxy cadastrado na OM pode ter um **grupo do AD** associado (`ad_group`).

- **Proxy SEM grupo** (`ad_group=''`) → **catch-all** (padrão).
  - O **Chrome** sempre usa este proxy, para todos os usuários da estação.
  - O **Firefox** usa este proxy como fallback para usuários que não pertencem a nenhum grupo com proxy específico.

- **Proxy COM grupo** (`ad_group='nome'`) → aplica-se **somente** ao **Firefox** de usuários membros desse grupo do AD, sobrepondo o padrão.

## Regras de negócio

1. **Cada usuário pertence a no máximo 1 grupo-com-proxy.** Se pertencer a mais de um, o comportamento é indefinido.
2. **O Chrome sempre usa o proxy padrão** (catch-all), independentemente do grupo do usuário.
3. **Mudanças de grupo exigem logoff/logon** — o Firefox recebe o novo proxy no próximo login.

## Aplicação

| Navegador | Quando | Como |
|---|---|---|
| Chrome | Provisionamento (root) | `core_browser.sh` escreve policy system-wide em `/etc/opt/chrome/policies/managed/` com o proxy catch-all |
| Firefox | Login do usuário | `core_logon.sh` escreve `user.js` em `~/.mozilla/firefox/*.default*/` com o proxy do grupo do usuário |

## Função compartilhada

`/usr/local/lib/seederlinux/resolve-proxy.sh` (gerado pelo `core_proxy.sh`) contém:

- `_resolver_proxy_index_para_usuario $user` → retorna o índice do proxy aplicável (grupo específico > catch-all > vazio)
- `_proxy_hostport_por_index $i` → retorna `host:port`
- `_proxy_no_proxy_por_index $i` → retorna a lista de bypass

## Como cadastrar

1. No painel admin, vá em **Rede e Proxy** → **Proxies cadastrados**.
2. Clique em **+ Novo Proxy**.
3. Preencha nome, URL, credenciais e bypass normalmente.
4. No campo **Grupo do AD**, deixe vazio para o proxy padrão (catch-all) ou preencha com o nome do grupo do AD (ex: `_DASTI`).
5. Salve.

## Bundle

O header do bundle exporta `PROXY_${i}_AD_GROUP` para cada proxy, que é consumido pelo `resolve-proxy.sh` em runtime.
