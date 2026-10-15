#!/bin/bash
# ============================================================================
# SeederLinux Lite - Atualizador de Scripts Core no Banco
# Rodar manualmente apos editar qualquer arquivo em scripts/core/*.sh
# Use --dry-run para simular; --force confirma a sincronizacao com overrides ativos.
# ============================================================================
# NOTA: scripts/permanent/* (ex.: seederlinux-sync-ntp + o .service) NAO passa
# por aqui. Esses componentes rodam fora do bundle e sao embutidos/instalados
# pelo header do bundle gerado (BUNDLE_HEADER em api/index.php, via heredoc).
# Este script cuida somente de scripts/core/*.sh e da tabela 'scripts'.
# ============================================================================
set -e

cd "$(dirname "$0")"

FORCE=false
DRY_RUN=false
for arg in "$@"; do
	case "$arg" in
		--force) FORCE=true ;;
		--dry-run) DRY_RUN=true ;;
		*)
			echo "Uso: $0 [--force] [--dry-run]" >&2
			exit 2
			;;
	esac
done

echo "[+] Gerando insert_core_scripts.sql a partir de scripts/core/*.sh..."
if [ "$DRY_RUN" = "true" ]; then
	dry_run_sql="/tmp/insert-core-dry-run-$$.sql"
	if python3 gen_insert_core.py --output "$dry_run_sql"; then
		rm -f "$dry_run_sql"
	else
		rm -f "$dry_run_sql"
		exit 1
	fi
else
	python3 gen_insert_core.py
fi

echo "[+] Verificando overrides GAP/OM ativos..."
override_count=$(sudo -u postgres psql -d seederlinux -tA -c "
	SELECT COUNT(*) FROM (
		SELECT sv.id
		FROM script_versions sv
		JOIN scripts s ON s.id = sv.script_id
		WHERE s.is_core = TRUE
			AND sv.version_type = 'gap_default'
			AND sv.is_active = TRUE
		UNION ALL
		SELECT osv.id
		FROM om_script_versions osv
		JOIN scripts s ON s.id = osv.script_id
		WHERE s.is_core = TRUE
			AND osv.is_active = TRUE
	) active_overrides;
")

if (( override_count > 0 )); then
	echo "[AVISO] Encontrados ${override_count} overrides GAP/OM ativos:"
	override_rows=$(sudo -u postgres psql -d seederlinux -F '|' -tA -c "
		SELECT s.filename, 'GAP', sv.version_number, octet_length(sv.content)
		FROM script_versions sv
		JOIN scripts s ON s.id = sv.script_id
		WHERE s.is_core = TRUE AND sv.version_type = 'gap_default'
			AND sv.is_active = TRUE
		UNION ALL
		SELECT s.filename, COALESCE(o.acronym, 'OM'), osv.version_number, COALESCE(octet_length(osv.content), 0)
		FROM om_script_versions osv
		JOIN scripts s ON s.id = osv.script_id
		JOIN organizations o ON o.id = osv.organization_id
		WHERE s.is_core = TRUE AND osv.is_active = TRUE
		ORDER BY 1, 2;
	")
	while IFS='|' read -r filename scope version size; do
		[ -n "$filename" ] && printf '  - %s: %s v%s (%s bytes)\n' "$filename" "$scope" "$version" "$size"
	done <<< "$override_rows"
fi

print_overwrite_preview() {
	local script_rows filename db_size source_file disk_size

	echo "[+] Conteúdo que a sincronização substituiria (banco -> disco):"
	script_rows=$(sudo -u postgres psql -d seederlinux -F '|' -tA -c "
		SELECT filename, octet_length(content)
		FROM scripts
		WHERE is_core = TRUE
		ORDER BY execution_order, filename;
	")
	while IFS='|' read -r filename db_size; do
		[ -n "$filename" ] || continue
		source_file="${SCRIPT_DIR}/../scripts/core/${filename}"
		if [ "$(basename "$filename")" = "$filename" ] && [ -f "$source_file" ]; then
			disk_size=$(wc -c < "$source_file" | tr -d ' ')
			printf '  - %s: %s bytes -> %s bytes\n' "$filename" "$db_size" "$disk_size"
		else
			printf '  - %s: %s bytes -> fonte ausente no disco\n' "$filename" "$db_size"
		fi
	done <<< "$script_rows"
}

if [ "$DRY_RUN" = "true" ]; then
	echo "[DRY-RUN] Nenhuma escrita será feita no banco."
	print_overwrite_preview
	if (( override_count > 0 )) && [ "$FORCE" != "true" ]; then
		echo "[DRY-RUN] A execução normal abortaria; use --force para confirmar a sincronização."
	else
		echo "[DRY-RUN] Seriam aplicados os scripts do disco e sincronizadas as versões factory."
	fi
	exit 0
fi

if (( override_count > 0 )) && [ "$FORCE" != "true" ]; then
	print_overwrite_preview
	echo "[ERRO] Operação abortada: overrides ativos seriam colocados em risco." >&2
	echo "[ERRO] Revise a lista acima e rode novamente com --force para prosseguir." >&2
	exit 1
fi

if [ "$FORCE" = "true" ]; then
	print_overwrite_preview
fi

echo "[+] Aplicando insert_core_scripts.sql no banco..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -d seederlinux -f insert_core_scripts.sql

echo "[+] Sincronizando versoes factory com scripts.content..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -d seederlinux <<'SQL'
BEGIN;

INSERT INTO script_versions
		(script_id, version_name, version_number, content, changelog, version_type, is_active)
SELECT
		s.id,
		s.filename || ' - Factory v' || (
				COALESCE((
						SELECT MAX(sv.version_number)
						FROM script_versions sv
						WHERE sv.script_id = s.id
				), 0) + 1
		),
		COALESCE((
				SELECT MAX(sv.version_number)
				FROM script_versions sv
				WHERE sv.script_id = s.id
		), 0) + 1,
		s.content,
		'Sincronizado por install/update_scripts.sh',
		'factory',
		TRUE
FROM scripts s
WHERE s.is_core = TRUE
	AND s.content IS NOT NULL
	AND NOT EXISTS (
			SELECT 1
			FROM script_versions latest_factory
			WHERE latest_factory.id = (
					SELECT sv.id
					FROM script_versions sv
					WHERE sv.script_id = s.id
						AND sv.version_type = 'factory'
					ORDER BY sv.version_number DESC, sv.id DESC
					LIMIT 1
			)
				AND latest_factory.content IS NOT DISTINCT FROM s.content
	);

UPDATE scripts s
SET current_version_id = latest_factory.id
FROM (
		SELECT DISTINCT ON (sv.script_id) sv.script_id, sv.id
		FROM script_versions sv
		JOIN scripts core_script ON core_script.id = sv.script_id
		WHERE core_script.is_core = TRUE
			AND sv.version_type = 'factory'
		ORDER BY sv.script_id, sv.version_number DESC, sv.id DESC
) latest_factory
WHERE s.id = latest_factory.script_id
	AND s.current_version_id IS DISTINCT FROM latest_factory.id;

COMMIT;
SQL

echo ""
echo "Scripts e versoes factory sincronizados no banco com sucesso."
echo "Gere um bundle novo pelo painel admin para aplicar as estacoes."
