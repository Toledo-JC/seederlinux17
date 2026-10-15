from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / 'install' / 'gen_insert_core.py'


def generate_sql(output: Path, *args: str) -> str:
    subprocess.run(
        [sys.executable, str(GENERATOR), *args, '--output', str(output)],
        check=True,
        capture_output=True,
        text=True,
    )
    return output.read_text(encoding='utf-8')


def test_insert_only_mode_never_updates_existing_scripts(tmp_path):
    sql = generate_sql(tmp_path / 'insert-only.sql', '--insert-only')

    assert sql.count('ON CONFLICT (filename) DO NOTHING;') == 24
    assert 'DO UPDATE SET' not in sql


def test_default_mode_still_updates_scripts_for_explicit_sync(tmp_path):
    sql = generate_sql(tmp_path / 'update.sql')

    assert sql.count('ON CONFLICT (filename) DO UPDATE SET') == 24
    assert 'content = EXCLUDED.content' in sql


def test_install_incrementally_loads_existing_core_scripts():
    installer = (ROOT / 'install' / 'install.sh').read_text(encoding='utf-8')

    assert 'SELECT COUNT(*) FROM scripts WHERE is_core = TRUE' in installer
    assert 'gen_insert_core.py" --insert-only' in installer
    assert 'AND s.current_version_id IS NULL;' in installer


def test_script_update_guard_and_om_metadata_fallback_are_wired():
    updater = (ROOT / 'install' / 'update_scripts.sh').read_text(encoding='utf-8')
    api = (ROOT / 'api' / 'index.php').read_text(encoding='utf-8')

    assert '--force) FORCE=true' in updater
    assert '--dry-run) DRY_RUN=true' in updater
    assert 'if (( override_count > 0 )) && [ "$FORCE" != "true" ]; then' in updater
    assert "'om_override'" in api
    assert "$localRow['organization_acronym'] . ' (override)'" in api
    assert "$localRow['om_version_number'] ?? 0" in api
