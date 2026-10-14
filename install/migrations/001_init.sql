-- SeederLinux Lite - Migration 001: baseline
-- Cria a tabela de controle de migrations.
-- O schema completo esta em install/schema.sql (idempotente).
-- Esta migration so marca o estado inicial.

CREATE TABLE IF NOT EXISTS schema_migrations (
    version VARCHAR(20) PRIMARY KEY,
    applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO schema_migrations (version)
VALUES ('001')
ON CONFLICT (version) DO NOTHING;
