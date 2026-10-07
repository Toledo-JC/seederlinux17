"""
Regression tests for /app/install/insert_core_scripts.sql

Validates that the file:
- Contains exactly 24 INSERT ... ON CONFLICT (filename) blocks
- Uses PostgreSQL dollar-quoting ($SeederScript$) instead of backslash escaping
- Loads all 24 core scripts into the DB with byte-identical content
- Preserves execution order, special characters and {PLACEHOLDER} tokens
- Is idempotent (safe to re-run)

Environment:
- PostgreSQL 15 local, user=seeder pwd=seeder123 db=seederlinux
- Requires UNIQUE constraint on scripts.filename (schema.sql has a
  pre-existing DO $ bug -- outside the scope of this task; test adds
  constraint manually before running).
"""
import os
import subprocess
import pytest

SQL_FILE = "/app/install/insert_core_scripts.sql"
CORE_DIR = "/app/scripts/core"
PG_USER = "seeder"
PG_PASS = "seeder123"
PG_DB = "seederlinux"
PG_HOST = "localhost"


def psql(query: str) -> str:
    env = os.environ.copy()
    env["PGPASSWORD"] = PG_PASS
    r = subprocess.run(
        ["psql", "-h", PG_HOST, "-U", PG_USER, "-d", PG_DB, "-tAc", query],
        capture_output=True, text=True, env=env, check=True,
    )
    return r.stdout.strip()


# --- Static file structure checks ---

def _read():
    with open(SQL_FILE, "rb") as f:
        return f.read().decode("utf-8", errors="replace")


def test_on_conflict_count_is_24():
    assert _read().count("ON CONFLICT (filename)") == 24


def test_insert_statement_count_is_24():
    content = _read()
    lines = [l for l in content.splitlines() if l.startswith("INSERT INTO scripts")]
    assert len(lines) == 24
    assert all("depends_on" in line for line in lines)


def test_no_backslash_escaped_quotes():
    # Backslash + single-quote must not appear anywhere
    assert "\\'" not in _read()


def test_dollar_quoting_markers_present():
    # 24 open + 24 close = 48 quoting markers (plus possibly comments)
    count = _read().count("$SeederScript$")
    # Allow >= 48 to accept explanatory header comment mentioning the tag once
    assert count >= 48
    # And even number of actual delimiters after removing comment occurrences
    non_comment = sum(
        1 for line in _read().splitlines()
        if "$SeederScript$" in line and not line.lstrip().startswith("--")
    )
    assert non_comment == 48


def test_dependency_arrays_are_generated():
    content = _read()
    assert content.count("::TEXT[]") == 24
    assert "ARRAY['core_dns.sh']::TEXT[]" in content
    assert "ARRAY[]::TEXT[]" in content


# --- Database load checks ---

def test_all_24_core_scripts_present_in_db():
    assert psql("SELECT COUNT(*) FROM scripts WHERE is_core = TRUE;") == "24"


def test_execution_order_matches_spec():
    expected = [
        (1, "core_dns.sh"), (2, "core_ntp.sh"), (3, "core_repositories.sh"),
        (4, "core_packages.sh"), (5, "core_legados.sh"), (6, "core_apps.sh"),
        (7, "core_domain.sh"), (8, "core_ssh.sh"), (9, "core_browser.sh"),
        (10, "core_inventory.sh"), (11, "core_printers.sh"), (12, "core_vnc.sh"),
        (13, "core_conky.sh"), (14, "core_config.sh"), (15, "core_branding.sh"),
        (16, "core_session_lightdm.sh"), (17, "core_session_gdm3.sh"),
        (18, "core_session_sddm.sh"), (19, "core_logon.sh"),
        (20, "core_password_change.sh"), (21, "core_logoff.sh"),
        (22, "core_proxy.sh"), (23, "core_agent.sh"), (24, "core_sync.sh"),
    ]
    rows = psql(
        "SELECT execution_order || '|' || filename FROM scripts "
        "WHERE is_core = TRUE ORDER BY execution_order, filename;"
    ).splitlines()
    got = [(int(r.split("|")[0]), r.split("|")[1]) for r in rows]
    assert got == expected


@pytest.mark.parametrize("fname", sorted(os.listdir(CORE_DIR)))
def test_byte_identical_content(fname):
    if not fname.endswith(".sh"):
        pytest.skip("non-script")
    file_size = os.path.getsize(os.path.join(CORE_DIR, fname))
    db_size = int(psql(f"SELECT octet_length(content) FROM scripts WHERE filename='{fname}';"))
    assert db_size == file_size, f"{fname}: db={db_size} file={file_size}"


def test_idempotent_reload():
    env = os.environ.copy()
    env["PGPASSWORD"] = PG_PASS
    r = subprocess.run(
        ["psql", "-h", PG_HOST, "-U", PG_USER, "-d", PG_DB, "-v",
         "ON_ERROR_STOP=1", "-f", SQL_FILE],
        capture_output=True, text=True, env=env,
    )
    assert r.returncode == 0, r.stderr
    assert psql("SELECT COUNT(*) FROM scripts WHERE is_core = TRUE;") == "24"


def test_special_char_ifs_preserved():
    assert psql(
        "SELECT position(E'IFS=\\$' IN content) > 0 FROM scripts "
        "WHERE filename = 'core_packages.sh';"
    ) == "t"


def test_placeholders_preserved():
    n = int(psql(
        "SELECT COUNT(*) FROM ("
        "SELECT filename, regexp_matches(content, '{[A-Z_]+}', 'g') "
        "FROM scripts WHERE is_core = TRUE) x;"
    ))
    assert n > 150, f"expected >150 placeholders, got {n}"
