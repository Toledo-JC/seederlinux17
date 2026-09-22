#!/usr/bin/env python3
"""
SeederLinux Lite - Provisioning Agent
=====================================

Faz check-in periódico com o servidor SeederLinux, enviando informações
da estação e baixando bundles de configuração quando disponíveis.

DISTINCAO IMPORTANTE ENTRE PROVISIONAMENTO E ATUALIZACAO
-------------------------------------------------------
- Estacao VIRGEM (sem /etc/seederlinux/config.env): executa o bundle
  completo (instalacao de pacotes, ingresso no AD, etc).
- Estacao JA PROVISIONADA: NAO executa o bundle. O agente extrai
  apenas o bloco de variaveis (header) do bundle baixado, atualiza
  /etc/seederlinux/config.env e chama /usr/local/bin/seeder-sync com
  o serial novo. O seeder-sync reaplica as politicas (branding,
  navegadores, proxy, conky, impressoras) de forma idempotente.

BYPASS DE PROXY
---------------
O agente so fala com o SEEDER_SERVER. Este host esta sempre no
NO_PROXY corporativo e nunca deve passar pelo proxy (que exige
autenticacao e devolve 407). Por isso, run_agent() remove as
variaveis http_proxy/https_proxy/all_proxy do ambiente do processo
Python antes de qualquer request HTTP. O urllib do Python nao
suporta wildcards no NO_PROXY (ex: *.intraer), entao depender so
das variaveis de ambiente nao basta - e' preciso remover para o
processo nao tentar usar o proxy.

Uso:
    # Primeiro check-in (registra a estação na OM):
    sudo seeder-agent --org COMARA

    # Check-ins seguintes (token já salvo):
    sudo seeder-agent

    # Dry-run (apenas coleta informações, sem check-in):
    sudo seeder-agent --dry-run

Configuração:
    /etc/seeder/agent.conf        - URL do servidor e opções
    /etc/seeder/station_token     - Token da estação (automático)
    /etc/seederlinux/config.env   - Configuracao persistente da estacao

Logs:
    /var/log/seeder/agent.log

Cron (recomendado a cada 15 minutos):
    */15 * * * * root /usr/local/bin/seeder-agent >> /var/log/seeder/agent.log 2>&1
"""

import argparse
import fcntl
import json
import os
import re
import sys
import platform
import socket
import ssl
import subprocess
import uuid
from configparser import ConfigParser
from datetime import datetime
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

# --- Constantes ---
CONFIG_DIR = "/etc/seeder"
CONFIG_FILE = os.path.join(CONFIG_DIR, "agent.conf")
TOKEN_FILE = os.path.join(CONFIG_DIR, "station_token")
LOG_FILE = "/var/log/seeder/agent.log"
BUNDLE_CACHE_DIR = "/var/cache/seeder"
BUNDLE_FILE = os.path.join(BUNDLE_CACHE_DIR, "bundle.sh")
LOCK_FILE = "/var/run/seeder-agent.lock"
CHECKIN_TIMEOUT = 30
DOWNLOAD_TIMEOUT = 60

# Configuracao persistente da estacao (gerada por core_config.sh)
STATION_CONFIG_FILE = "/etc/seederlinux/config.env"
SEEDER_SYNC_BIN = "/usr/local/bin/seeder-sync"


class SingleInstanceLock:
    """
    Impede que duas execucoes do agente rodem ao mesmo tempo.

    O cron dispara a cada 15min, mas execute_bundle() pode levar ate
    30min (timeout=1800) rodando de forma sincrona. Sem essa trava,
    um bundle demorado pode ainda estar rodando quando o proximo cron
    dispara, resultando em duas execucoes simultaneas.

    Usa fcntl.flock em vez de um PID-file simples: flock e liberado
    automaticamente pelo kernel quando o processo morre, entao nao ha
    risco de lock "preso" sobrevivendo a um agente que morreu sem
    limpar depois de si.
    """

    def __init__(self, path):
        self.path = path
        self.fd = None

    def acquire(self):
        self.fd = open(self.path, "w")
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.fd.close()
            self.fd = None
            return False
        self.fd.write(str(os.getpid()))
        self.fd.flush()
        return True

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            except OSError:
                pass
            self.fd.close()
            self.fd = None


def log(message, level="INFO"):
    """Escreve mensagem de log com timestamp."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{timestamp}] [{level}] {message}"
    print(line, flush=True)
    try:
        os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except (IOError, PermissionError):
        pass


def disable_proxy_for_process():
    """
    Remove todas as variaveis de proxy do ambiente do processo.

    Motivo: o agente so precisa falar com o SEEDER_SERVER, que esta
    sempre no NO_PROXY corporativo. Mas o urllib do Python nao
    suporta wildcards no NO_PROXY (ex: "*.intraer") - so entende
    hostnames exatos. Sem essa remocao, requests para o Seeder passam
    pelo proxy corporativo e recebem HTTP 407 Proxy Authentication
    Required, que aborta o check-in.

    Efeito: apenas este processo Python perde as variaveis. Nao afeta
    o sistema, outros processos, nem o /etc/environment. O agente
    nao usa proxy para nada, entao a remocao e' segura.

    Chamado no inicio de run_agent(), antes de qualquer request HTTP.
    """
    removed = []
    for _k in ("http_proxy", "https_proxy", "all_proxy",
               "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
        if _k in os.environ:
            removed.append(_k)
            os.environ.pop(_k, None)
    if removed:
        log(f"Proxy removido do processo: {', '.join(removed)}")


def load_config(config_path=CONFIG_FILE):
    """Carrega configuração do arquivo agent.conf."""
    config = {
        "url": "https://seederlinux.om.local",
        "no_check_certificate": False,
    }
    if not os.path.exists(config_path):
        return config
    parser = ConfigParser()
    parser.read(config_path)
    if parser.has_section("server"):
        if parser.has_option("server", "url"):
            config["url"] = parser.get("server", "url").strip()
        if parser.has_option("server", "no_check_certificate"):
            raw = parser.get("server", "no_check_certificate").strip().lower()
            config["no_check_certificate"] = raw in ("true", "1", "yes", "on")
    return config


def load_token():
    """Lê o token da estação salvo em disco."""
    if os.path.exists(TOKEN_FILE):
        try:
            with open(TOKEN_FILE, "r") as f:
                token = f.read().strip()
                if token:
                    return token
        except (IOError, PermissionError):
            pass
    return None


def save_token(token):
    """Salva o token da estação em disco."""
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        with open(TOKEN_FILE, "w") as f:
            f.write(token)
        os.chmod(TOKEN_FILE, 0o600)
        log("Token da estação salvo com sucesso")
    except (IOError, PermissionError) as e:
        log(f"Erro ao salvar token: {e}", "ERROR")


def load_current_serial():
    """
    Le o SERIAL_APLICADO atual do config.env da estacao.

    Retorna 0 se o arquivo nao existe (estacao virgem) ou se o valor
    nao pode ser lido. Este serial e' enviado ao servidor no
    check-in para que ele decida se realmente ha update disponivel.
    """
    if not os.path.exists(STATION_CONFIG_FILE):
        return 0
    try:
        with open(STATION_CONFIG_FILE, "r") as f:
            for line in f:
                if line.startswith("SERIAL_APLICADO="):
                    val = line.split("=", 1)[1].strip().strip('"').strip("'")
                    return int(val) if val.isdigit() else 0
    except (IOError, ValueError, PermissionError):
        pass
    return 0


def save_current_serial(serial):
    """
    Grava o SERIAL_APLICADO em /etc/seederlinux/config.env,
    preservando todas as outras linhas. Usado quando o agente executa
    o bundle completo (primeiro provisionamento): o bundle em si nao
    conhece o serial que esta sendo aplicado, entao o agente o grava
    apos a execucao bem-sucedida.
    """
    if not isinstance(serial, int):
        return
    try:
        lines = []
        replaced = False
        if os.path.exists(STATION_CONFIG_FILE):
            with open(STATION_CONFIG_FILE, "r") as f:
                for line in f:
                    if line.startswith("SERIAL_APLICADO="):
                        lines.append(f'SERIAL_APLICADO="{serial}"\n')
                        replaced = True
                    else:
                        lines.append(line)
        if not replaced:
            lines.append(f'SERIAL_APLICADO="{serial}"\n')
        with open(STATION_CONFIG_FILE, "w") as f:
            f.writelines(lines)
        log(f"SERIAL_APLICADO gravado em config.env: {serial}")
    except (IOError, PermissionError) as e:
        log(f"Erro ao gravar SERIAL_APLICADO: {e}", "ERROR")


def extract_bundle_serial(bundle_path):
    """
    Extrai o serial do header do bundle (linha '# Serial: N').

    Retorna None se nao conseguir. Esse serial e' o que o bundle
    aplica; usamos ele para (a) comparar com o local e evitar
    reexecucao desnecessaria e (b) passar para o seeder-sync.
    """
    try:
        with open(bundle_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("# Serial:"):
                    val = line.split(":", 1)[1].strip()
                    return int(val) if val.isdigit() else None
    except (IOError, ValueError):
        pass
    return None


def extract_bundle_header(bundle_path):
    """
    Extrai o bloco de variaveis (linhas 'export VAR=...') do header
    do bundle. Retorna uma string com essas linhas, ou None se o
    padrao nao for encontrado.

    O bundle gerado pelo painel tem a estrutura:
        # === VARIAVEIS ===
        ... (comentarios)
        export VAR1='valor1'
        export VAR2='valor2'
        ...
        # === SCRIPTS ===

    Extraimos apenas as linhas 'export ...' porque elas sao
    sintaticamente identicas ao formato de config.env (que tambem e'
    shell sourceable). O resto (comentarios) e' descartado.
    """
    try:
        with open(bundle_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except IOError:
        return None

    m = re.search(
        r'^# === VARIAVEIS ===\s*\n(.*?)\n# === SCRIPTS ===',
        content,
        re.MULTILINE | re.DOTALL,
    )
    if not m:
        return None

    export_lines = []
    for line in m.group(1).split("\n"):
        stripped = line.strip()
        if stripped.startswith("export "):
            export_lines.append(line)
    if not export_lines:
        return None
    return "\n".join(export_lines) + "\n"


def update_config_env(header_block, keep_serial):
    """
    Atualiza /etc/seederlinux/config.env a partir do header extraido
    do bundle, preservando SERIAL_APLICADO atual (nao grava o novo
    serial aqui - quem faz isso e' o seeder-sync, apos reaplicar as
    politicas com sucesso).

    Se keep_serial for None, usa 0 (estacao virgem).

    Formato de saida: identico ao que core_config.sh produz -
    variaveis shell 'VAR=valor' + SERIAL_APLICADO. Assim, o
    seeder-sync e os demais consumidores nao precisam saber que o
    arquivo foi gerado pelo agente em vez do bundle.
    """
    if keep_serial is None:
        keep_serial = 0
    try:
        os.makedirs(os.path.dirname(STATION_CONFIG_FILE), exist_ok=True)
        with open(STATION_CONFIG_FILE, "w") as f:
            f.write("# SeederLinux Lite - Configuracao Persistente\n")
            f.write("# Atualizado pelo seeder-agent em ")
            f.write(datetime.now().isoformat())
            f.write("\n")
            f.write("# NAO EDITAR MANUALMENTE\n\n")
            f.write(header_block)
            f.write("\n# Estado local (GPO)\n")
            f.write(f'SERIAL_APLICADO="{keep_serial}"\n')
        os.chmod(STATION_CONFIG_FILE, 0o644)
        log(f"config.env atualizado a partir do header do bundle "
            f"({len(header_block.splitlines())} variaveis)")
        return True
    except (IOError, PermissionError) as e:
        log(f"Erro ao atualizar config.env: {e}", "ERROR")
        return False


def is_provisioned():
    """
    Verifica se a estacao ja foi provisionada (tem config.env E o
    binario seeder-sync). Se faltar qualquer um dos dois, tratamos
    como estacao virgem e executamos o bundle completo.
    """
    return (
        os.path.exists(STATION_CONFIG_FILE)
        and os.path.exists(SEEDER_SYNC_BIN)
    )


def apply_incremental(bundle_path, remote_serial):
    """
    Aplica atualizacao em estacao ja provisionada SEM executar o
    bundle: extrai o header, atualiza config.env e chama seeder-sync.

    Retorna True se a aplicacao correu (nao necessariamente sem
    erros internos do sync - so se o fluxo chegou ao fim).
    """
    header = extract_bundle_header(bundle_path)
    if not header:
        log("Nao foi possivel extrair o header de variaveis do bundle", "ERROR")
        return False

    current = load_current_serial()
    if not update_config_env(header, keep_serial=current):
        return False

    # Chama seeder-sync passando o serial remoto. O sync compara com
    # SERIAL_APLICADO local (que acabamos de preservar = current) e,
    # como remote > current, aplica tudo e atualiza SERIAL_APLICADO.
    if remote_serial is None:
        log("Serial remoto desconhecido - executando seeder-sync em modo forcado", "WARNING")
        cmd = [SEEDER_SYNC_BIN, "--force"]
    else:
        cmd = [SEEDER_SYNC_BIN, str(remote_serial)]

    log(f"Executando: {' '.join(cmd)}")
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=900,
            env={**os.environ, "NON_INTERACTIVE": "true"},
        )
        if result.returncode == 0:
            log("seeder-sync concluido com sucesso")
            return True
        else:
            log(f"seeder-sync retornou {result.returncode}", "WARNING")
            if result.stderr:
                log(f"stderr: {result.stderr[:500]}", "WARNING")
            return True
    except subprocess.TimeoutExpired:
        log("seeder-sync excedeu 15 minutos", "ERROR")
        return False
    except (IOError, PermissionError, FileNotFoundError) as e:
        log(f"Erro ao executar seeder-sync: {e}", "ERROR")
        return False


def create_ssl_context(no_check=False):
    """Cria contexto SSL, opcionalmente sem verificação de certificado."""
    if no_check:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    return None


def collect_system_info():
    """Coleta informações do sistema para check-in."""
    hostname = socket.gethostname()

    # Obter IP
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip_address = s.getsockname()[0]
        s.close()
    except Exception:
        ip_address = "127.0.0.1"

    # Obter MAC
    try:
        mac = uuid.getnode()
        mac_address = ":".join(f"{(mac >> ele) & 0xff:02x}" for ele in range(40, -1, -8))
    except Exception:
        mac_address = "00:00:00:00:00:00"

    # Obter SO
    os_name = platform.system()
    os_version = platform.release()
    try:
        if os.path.exists("/etc/os-release"):
            with open("/etc/os-release", "r") as f:
                for line in f:
                    if line.startswith("NAME="):
                        os_name = line.split("=", 1)[1].strip().strip('"')
                    elif line.startswith("VERSION="):
                        os_version = line.split("=", 1)[1].strip().strip('"')
    except Exception:
        pass

    # Obter serial
    serial_number = ""
    try:
        result = subprocess.run(
            ["dmidecode", "-s", "system-serial-number"],
            capture_output=True, text=True, timeout=5
        )
        serial_number = result.stdout.strip()
    except Exception:
        pass

    return {
        "hostname": hostname,
        "os_name": os_name,
        "os_version": os_version,
        "ip_address": ip_address,
        "mac_address": mac_address,
        "serial_number": serial_number,
    }


def checkin(server_url, payload, no_check_cert=False):
    """Envia check-in para o servidor e retorna a resposta JSON."""
    url = f"{server_url}/api/?action=checkin"
    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "User-Agent": "SeederLinux-Agent/1.3",
    }

    # Adicionar token como Bearer se disponível
    if payload.get("station_token"):
        headers["Authorization"] = f"Bearer {payload['station_token']}"

    req = Request(url, data=data, headers=headers, method="POST")
    ctx = create_ssl_context(no_check_cert)

    try:
        with urlopen(req, timeout=CHECKIN_TIMEOUT, context=ctx) as response:
            body = response.read().decode("utf-8")
            return json.loads(body)
    except HTTPError as e:
        log(f"Erro HTTP {e.code}: {e.reason}", "ERROR")
        try:
            error_body = e.read().decode("utf-8")
            parsed = json.loads(error_body)
            log(f"Mensagem do servidor: {parsed.get('error', error_body)}", "ERROR")
        except Exception:
            pass
        return None
    except URLError as e:
        log(f"Erro de conexão: {e.reason}", "WARNING")
        return None
    except json.JSONDecodeError:
        log("Resposta inválida do servidor (JSON inválido)", "ERROR")
        return None


def download_bundle(server_url, bundle_id, station_token, no_check_cert=False):
    """Baixa um bundle de configuração do servidor."""
    url = f"{server_url}/api/?action=bundle-by-id&id={bundle_id}"
    headers = {"User-Agent": "SeederLinux-Agent/1.3"}
    if station_token:
        headers["Authorization"] = f"Bearer {station_token}"

    req = Request(url, headers=headers, method="GET")
    ctx = create_ssl_context(no_check_cert)

    try:
        with urlopen(req, timeout=DOWNLOAD_TIMEOUT, context=ctx) as response:
            return response.read()
    except HTTPError as e:
        log(f"Erro HTTP {e.code} ao baixar bundle: {e.reason}", "ERROR")
        return None
    except URLError as e:
        log(f"Erro de conexão ao baixar bundle: {e.reason}", "ERROR")
        return None


def execute_bundle(bundle_path, remote_serial=None):
    """
    Executa o bundle completo. Usado APENAS em estacao virgem
    (primeiro provisionamento).

    Apos execucao bem-sucedida, grava o serial do bundle em
    config.env. Isso e' necessario porque o bundle em si nao escreve
    o serial que aplicou (o core_config.sh preserva o valor
    existente) - sem essa gravacao, o agente nunca saberia qual
    serial esta aplicado e o servidor sempre responderia
    update_available=true, causando re-provisionamento em loop.
    """
    try:
        os.chmod(bundle_path, 0o755)
        log(f"Executando bundle (provisionamento inicial): {bundle_path}")
        env = os.environ.copy()
        env["NON_INTERACTIVE"] = "true"
        result = subprocess.run(
            ["bash", bundle_path],
            capture_output=True,
            text=True,
            timeout=1800,
            env=env,
        )
        if result.returncode == 0:
            log("Bundle executado com sucesso")
            if remote_serial is not None:
                save_current_serial(remote_serial)
            return True
        else:
            log(f"Bundle executado com erros (código {result.returncode})", "ERROR")
            if result.stderr:
                log(f"Erros: {result.stderr[:500]}", "ERROR")
            return False
    except subprocess.TimeoutExpired:
        log("Execução do bundle excedeu 30 minutos", "ERROR")
        return False
    except Exception as e:
        log(f"Erro ao executar bundle: {e}", "ERROR")
        return False


def main():
    parser = argparse.ArgumentParser(
        description="SeederLinux Lite - Agente de Provisionamento",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Exemplos:
  Primeiro check-in (registra estação na OM):
    sudo seeder-agent --org COMARA

  Check-ins seguintes (token já salvo):
    sudo seeder-agent

  Dry-run (apenas coleta informações):
    sudo seeder-agent --dry-run
        """,
    )
    parser.add_argument("--org", "-o", metavar="ACRONIMO",
                        help="Sigla da organização (obrigatório no primeiro check-in)")
    parser.add_argument("--server", "-s", metavar="URL",
                        help="URL do servidor SeederLinux (sobrescreve agent.conf)")
    parser.add_argument("--no-check-certificate", "-k", action="store_true",
                        help="Desabilitar verificação de certificado SSL")
    parser.add_argument("--dry-run", action="store_true",
                        help="Apenas coleta informações, sem check-in")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="Saída detalhada")
    parser.add_argument("--version", action="version", version="SeederLinux Agent 1.3.0")
    args = parser.parse_args()

    # Verificar root
    if os.geteuid() != 0:
        log("ERRO: Este script deve ser executado como root (sudo).", "ERROR")
        sys.exit(1)

    lock = SingleInstanceLock(LOCK_FILE)
    if not lock.acquire():
        log("Outra execucao do seeder-agent ja esta em andamento "
            "(lock ocupado). Pulando este ciclo.", "WARNING")
        return 0

    try:
        return run_agent(args)
    finally:
        lock.release()


def run_agent(args):
    log("=" * 60)
    log("SeederLinux Agent 1.3.0 - Iniciando")

    # ------------------------------------------------------------------
    # Bypass de proxy: o agente so fala com o SEEDER_SERVER, que esta
    # sempre no NO_PROXY corporativo. O urllib do Python nao suporta
    # wildcards tipo "*.intraer" - entao, mesmo com NO_PROXY configurado,
    # ele tentaria usar o proxy corporativo e receberia HTTP 407 Proxy
    # Authentication Required. Removemos as variaveis de proxy do
    # ambiente DESTE processo antes de qualquer request.
    #
    # Esta chamada precisa acontecer DEPOIS dos imports (os ja esta
    # disponivel) e ANTES de qualquer checkin()/download_bundle().
    # ------------------------------------------------------------------
    disable_proxy_for_process()

    config = load_config()
    server_url = args.server or config["url"]
    no_check_cert = args.no_check_certificate or config["no_check_certificate"]

    log(f"Servidor: {server_url}")

    system_info = collect_system_info()
    log(f"Hostname: {system_info['hostname']}")
    log(f"IP: {system_info['ip_address']}")
    log(f"SO: {system_info['os_name']} {system_info['os_version']}")

    if args.dry_run:
        log("Modo dry-run — pulando check-in")
        if args.verbose:
            log(f"Dados coletados: {json.dumps(system_info, indent=2)}")
        return 0

    station_token = load_token()
    is_first_run = station_token is None

    if is_first_run and not args.org:
        log("ERRO: Primeiro check-in requer --org <ACRONIMO>", "ERROR")
        log("Exemplo: sudo seeder-agent --org COMARA", "ERROR")
        return 1

    current_serial = load_current_serial()
    log(f"Serial aplicado localmente: {current_serial}")

    payload = system_info.copy()
    payload["serial_applied"] = current_serial

    if is_first_run:
        payload["organization_acronym"] = args.org.upper()
        log(f"Primeiro check-in — registrando na organização: {args.org.upper()}")
    else:
        payload["station_token"] = station_token
        log(f"Token encontrado: {station_token[:8]}...")

    log("Enviando check-in...")
    response = checkin(server_url, payload, no_check_cert)

    if response is None:
        log("Check-in falhou — rede pode estar indisponível", "WARNING")
        return 0

    if not response.get("success"):
        log(f"Check-in rejeitado: {response.get('error', 'Erro desconhecido')}", "ERROR")
        return 1

    data = response.get("data", {})
    log(f"Check-in OK. Station ID: {data.get('station_id', 'N/A')}")

    returned_token = data.get("station_token")
    if returned_token:
        save_token(returned_token)
        station_token = returned_token

    update_available = data.get("update_available", False)
    bundle_id = data.get("latest_bundle_id")

    if not update_available:
        log("Sistema atualizado. Nenhuma ação necessária.")
        return 0

    if not bundle_id:
        log("Atualização sinalizada mas sem bundle ID", "WARNING")
        return 0

    log(f"Atualização disponível! Baixando bundle ID: {bundle_id}")
    bundle_content = download_bundle(server_url, bundle_id, station_token, no_check_cert)

    if bundle_content is None:
        log("Falha ao baixar bundle", "ERROR")
        return 1

    try:
        os.makedirs(BUNDLE_CACHE_DIR, exist_ok=True)
        with open(BUNDLE_FILE, "wb") as f:
            f.write(bundle_content)
        log(f"Bundle salvo em {BUNDLE_FILE} ({len(bundle_content)} bytes)")
    except (IOError, PermissionError) as e:
        log(f"Erro ao salvar bundle: {e}", "ERROR")
        return 1

    # Extrai o serial do bundle e compara com o local. Protecao
    # client-side: mesmo que o servidor diga update_available=true
    # por engano (ex: backend nao recebeu/comparou serial_applied),
    # nao reexecutamos nada se o bundle nao for mais novo.
    remote_serial = extract_bundle_serial(BUNDLE_FILE)
    log(f"Serial do bundle remoto: {remote_serial}")

    if remote_serial is not None and remote_serial <= current_serial:
        log(f"Bundle remoto (serial {remote_serial}) nao e' mais novo "
            f"que o local ({current_serial}). Pulando.")
        return 0

    # Decide o modo de aplicacao: bundle completo (virgem) ou
    # incremental via seeder-sync (ja provisionada).
    if is_provisioned():
        log("Estacao ja provisionada - aplicando atualizacao incremental")
        success = apply_incremental(BUNDLE_FILE, remote_serial)
    else:
        log("Estacao virgem - executando bundle completo")
        success = execute_bundle(BUNDLE_FILE, remote_serial)

    if success:
        log("Atualizacao concluida com sucesso")
        return 0
    else:
        log("Atualizacao concluida com erros", "ERROR")
        return 1


if __name__ == "__main__":
    try:
        exit_code = main()
    except KeyboardInterrupt:
        log("Agente interrompido pelo usuário", "WARNING")
        exit_code = 0
    except Exception as e:
        log(f"Erro inesperado: {e}", "ERROR")
        exit_code = 1
    sys.exit(exit_code)
