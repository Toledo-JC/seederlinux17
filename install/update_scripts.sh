#!/bin/bash
# ============================================================================
# SeederLinux Lite - Atualizador de Scripts Core no Banco
# Rodar manualmente apos editar qualquer arquivo em scripts/core/*.sh
# ============================================================================
# NOTA: scripts/permanent/* (ex.: seederlinux-sync-ntp + o .service) NAO passa
# por aqui. Esses componentes rodam fora do bundle e sao embutidos/instalados
# pelo header do bundle gerado (BUNDLE_HEADER em api/index.php, via heredoc).
# Este script cuida somente de scripts/core/*.sh e da tabela 'scripts'.
# ============================================================================
set -e

cd "$(dirname "$0")"

echo "[+] Gerando insert_core_scripts.sql a partir de scripts/core/*.sh..."
python3 gen_insert_core.py

echo "[+] Verificando versões que podem ter prioridade sobre scripts.content..."
gap_default_count=$(sudo -u postgres psql -d seederlinux -tA -c "
		SELECT COUNT(*)
		FROM script_versions sv
		JOIN scripts s ON s.id = sv.script_id
		WHERE s.is_core = TRUE
			AND sv.version_type = 'gap_default'
			AND sv.is_active = TRUE
			AND sv.content IS NOT NULL
			AND sv.content <> '';
")
factory_count=$(sudo -u postgres psql -d seederlinux -tA -c "
		SELECT COUNT(*)
		FROM script_versions sv
		JOIN scripts s ON s.id = sv.script_id
		WHERE s.is_core = TRUE
			AND sv.version_type = 'factory'
			AND sv.content IS NOT NULL
			AND sv.content <> '';
")
om_override_count=$(sudo -u postgres psql -d seederlinux -tA -c "
		SELECT COUNT(*)
		FROM om_script_versions osv
		JOIN scripts s ON s.id = osv.script_id
		WHERE s.is_core = TRUE
			AND osv.is_active = TRUE
			AND osv.content IS NOT NULL
			AND osv.content <> '';
")

if (( gap_default_count > 0 || factory_count > 0 || om_override_count > 0 )); then
		echo "[AVISO] Fontes prioritarias encontradas para scripts core:"
		echo "[AVISO] GAP defaults ativos: ${gap_default_count}; factories selecionaveis: ${factory_count}; overrides OM ativos: ${om_override_count}."
		echo "[AVISO] As factories serao sincronizadas com scripts.content; GAP defaults e overrides OM permanecem intactos e podem continuar vencendo no bundle."
fi

echo "[+] Aplicando insert_core_scripts.sql no banco..."
sudo -u postgres psql -d seederlinux -f insert_core_scripts.sql

echo "[+] Sincronizando versoes factory com scripts.content..."
sudo -u postgres psql -d seederlinux <<'SQL'
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
