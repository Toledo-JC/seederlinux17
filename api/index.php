<?php
require_once __DIR__ . '/../lib/config.php';
require_once __DIR__ . '/../lib/db.php';
require_once __DIR__ . '/../lib/functions.php';
function get_server_url_by_org($acronym) {
    $sigla = strtolower(trim($acronym));
    return "https://seederlinux.$sigla.intraer";
}

function sanitize_org_urls($org) {
    $base_url = get_server_url_by_org($org['acronym']);
    
    if (empty($org['BASE_URL']) || strpos($org['BASE_URL'], 'softwarelivre') !== false || strpos($org['BASE_URL'], 'om.local') !== false || strpos($org['BASE_URL'], ' ') !== false) {
        $org['BASE_URL'] = $base_url;
    }
    if (empty($org['SEEDER_SERVER']) || strpos($org['SEEDER_SERVER'], 'om.local') !== false) {
        $org['SEEDER_SERVER'] = $base_url;
    }
    if (empty($org['REPOSITORY_URL']) || strpos($org['REPOSITORY_URL'], 'softwarelivre') !== false) {
        $org['REPOSITORY_URL'] = $base_url;
    }
    
    return $org;
}


header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type, Authorization');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') exit(0);

$action = $_GET['action'] ?? '';
$id = isset($_GET['id']) ? (int)$_GET['id'] : null;
$method = $_SERVER['REQUEST_METHOD'];

// Parse input
$input = [];
if ($method === 'POST' || $method === 'PUT') {
    $contentType = $_SERVER['CONTENT_TYPE'] ?? '';
    if (strpos($contentType, 'multipart/form-data') !== false) {
        $input = $_POST;
    } else {
        $raw = file_get_contents('php://input');
        $input = json_decode($raw, true) ?? [];
    }
}

// Prioriza organization_id (novo), mantém compatibilidade com org_id e JSON body
$orgId = $_GET['organization_id'] ?? $_GET['org_id'] ?? $input['organization_id'] ?? null;
$orgId = $orgId !== null ? (int)$orgId : null;

try {
    switch ($action) {
        // Auth
        case 'login':
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleLogin($input);
            break;
        case 'logout':
            handleLogout();
            break;
        case 'session':
            handleSessionCheck();
            break;

        // Dashboard (global or per-org)
        case 'dashboard':
            requireAuth();
            handleDashboard($orgId);
            break;

        // Mirror status (GAP administrators only)
        case 'mirror-status':
            requireAuth();
            if (($_SESSION['role'] ?? null) !== 'admin_gap') {
                jsonError('Acesso restrito ao administrador GAP', 403);
            }
            if ($method !== 'GET') jsonError('Method not allowed', 405);
            handleMirrorStatus();
            break;
        case 'mirror-save-config':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorSaveConfig($input);
            break;
        case 'mirror-save-org-settings':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorSaveOrgSettings($input);
            break;
        case 'mirror-estimate':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorEstimate($input);
            break;
        case 'mirror-add-distro':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorAddDistro($input);
            break;
        case 'mirror-update-distro':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorUpdateDistro($input);
            break;
        case 'mirror-toggle-distro':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorToggleDistro($input);
            break;
        case 'mirror-add-version':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorAddVersion($input);
            break;
        case 'mirror-update-version':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorUpdateVersion($input);
            break;
        case 'mirror-toggle-version':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorToggleVersion($input);
            break;
        case 'mirror-delete-version':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorDeleteVersion($input);
            break;
        case 'mirror-sync-now':
            requireMirrorAdmin($method, 'POST', $input);
            handleMirrorSyncNow();
            break;
        case 'mirror-job-status':
            requireMirrorAdmin($method, 'GET', [], false);
            handleMirrorJobStatus($_GET);
            break;

        // Organizations

/**
 * Gera URL baseada na sigla da organização
 */

/**
 * Sanitiza URLs do servidor para uma organização
 */
        case 'organizations':
            requireAuth();
            if ($method === 'GET') handleGetOrganizations();
            elseif ($method === 'POST') handleCreateOrganization($input);
            else jsonError('Method not allowed', 405);
            break;
        case 'organization':
            requireAuth();
            if (!$id) jsonError('ID required', 400);
            if ($method === 'GET') handleGetOrganization($id);
            elseif ($method === 'PUT') handleUpdateOrganization($id, $input);
            elseif ($method === 'DELETE') handleDeleteOrganization($id);
            else jsonError('Method not allowed', 405);
            break;

        // Variables
        case 'variables':
            requireAuth();
            handleGetVariables($id);
            break;
        case 'variables-update':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleUpdateVariables($input);
            break;
        case 'variable-add':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleAddVariable($input);
            break;

        // Scripts
        case 'scripts':
            requireAuth();
            handleGetScripts($orgId);
            break;
        case 'script':
            requireAuth();
            if ($method === 'GET' && $id) handleGetScript($id);
            elseif ($method === 'PUT' && $id) handleUpdateScript($id, $input);
            elseif ($method === 'DELETE' && $id) handleDeleteScript($id);
            elseif ($method === 'POST') handleCreateScript($input);
            else jsonError('Method not allowed', 405);
            break;
        case 'script-upload':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleUploadScript();
            break;
        case 'script-version':
            requireAuth();
            if ($method === 'POST') handleCreateScriptVersion($input);
            elseif ($method === 'GET' && $id) handleGetScriptVersions($id);
            else jsonError('Method not allowed', 405);
            break;
        case 'save-script-gap-version':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleSaveScriptGapVersion($input);
            break;
        case 'reset-script-factory':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleResetScriptFactory($input);
            break;
        case 'save-script-om-version':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleSaveScriptOmVersion($input);
            break;
        case 'reset-script-om-default':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleResetScriptOmDefault($input);
            break;
        case 'delete-script-om-override':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleDeleteScriptOmOverride($input);
            break;
        case 'om-script-versions':
            requireAuth();
            if ($method !== 'GET') jsonError('Method not allowed', 405);
            handleGetOmScriptVersions($_GET);
            break;
        case 'reactivate-om-version':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleReactivateOmVersion($input);
            break;
        case 'delete-om-version':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleDeleteOmVersion($input);
            break;
        case 'get-org-scripts':
            requireAuth();
            if ($method !== 'GET') jsonError('Method not allowed', 405);
            handleGetOrgScripts($orgId ?? (int)($_GET['organization_id'] ?? 0));
            break;

        // Bundle
        case 'generate-bundle':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleGenerateBundle($input);
            break;
        case 'bundle-by-id':
            handleDownloadBundle($id);
            break;
        case 'bundles':
            requireAuth();
            handleListBundles($orgId);
            break;
        case 'bundle-toggle':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleToggleBundleActive($input);
            break;
        case 'bundle':
            requireAuth();
            if ($_SERVER['REQUEST_METHOD'] === 'DELETE') {
                if (!$id) jsonError('ID required', 400);
                handleDeleteBundle($id);
            } elseif ($_SERVER['REQUEST_METHOD'] === 'PUT') {
                handleUpdateBundleDescription($input);
            } else {
                jsonError('Method not allowed', 405);
            }
            break;

        // Users
        case 'users':
            requireAuth();
            if ($method === 'GET') handleGetUsers();
            elseif ($method === 'POST') handleCreateUser($input);
            else jsonError('Method not allowed', 405);
            break;
        case 'user':
            requireAuth();
            if (!$id) jsonError('ID required', 400);
            if ($method === 'PUT') handleUpdateUser($id, $input);
            elseif ($method === 'DELETE') handleDeleteUser($id);
            elseif ($method === 'POST') handleToggleUserStatus($id);
            else jsonError('Method not allowed', 405);
            break;

        // Stations
        case 'stations':
            requireAuth();
            handleGetStations($orgId);
            break;
        case 'checkin':
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleStationCheckin($input);
            break;
        case 'sync-status':
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleStationSyncStatus($input);
            break;
        case 'sync-confirm':
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleStationSyncConfirm($input);
            break;

        // Audit
        case 'audit':
            requireAuth();
            handleGetAuditEvents();
            break;

        // Public (no auth)
        case 'public-bundles':
            handlePublicBundles();
            break;
        case 'public-theme':
            handleGetPublicTheme();
            break;
        case 'set-public-theme':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleSetPublicTheme($input);
            break;

        // Uploads
        case 'upload-wallpaper':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleUploadWallpaper();
            break;
        case 'upload-logo':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleUploadLogo();
            break;
        case 'wallpapers':
            requireAuth();
            handleGetWallpapers($orgId);
            break;
        case 'logos':
            requireAuth();
            handleGetLogos($orgId);
            break;
        case 'upload-asset':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleUploadAsset();
            break;
        case 'gallery-images':
            requireAuth();
            handleGetGalleryImages();
            break;
        case 'gallery-image':
            requireAuth();
            if ($method !== 'DELETE') jsonError('Method not allowed', 405);
            handleDeleteGalleryImage();
            break;

        // Script ordering
        case 'update-script-order':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleUpdateScriptOrder($input);
            break;
        case 'reset-script-order':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleResetScriptOrder();
            break;

        // Script versioning
        case 'script-versions':
            requireAuth();
            if (!$id) jsonError('ID required', 400);
            handleGetScriptVersions($id);
            break;
        case 'sync-script':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleSyncScript($input);
            break;
        case 'set-gap-default':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleSetGapDefault($input);
            break;
        case 'set-om-version':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleSetOmVersion($input);
            break;
        case 'reset-to-factory':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleResetToFactory($input);
            break;
        case 'delete-script-version':
            requireAuth();
            if ($method !== 'POST') jsonError('Method not allowed', 405);
            handleDeleteScriptVersion($input);
            break;

        // OM Proxies (multiplos proxies nomeados por OM)
        case 'om-proxies':
            requireAuth();
            if ($method === 'GET') handleGetOmProxies($orgId);
            elseif ($method === 'POST') handleCreateOmProxy($input);
            else jsonError('Method not allowed', 405);
            break;
        case 'om-proxy':
            requireAuth();
            if (!$id) jsonError('ID required', 400);
            if ($method === 'PUT') handleUpdateOmProxy($id, $input);
            elseif ($method === 'DELETE') handleDeleteOmProxy($id);
            else jsonError('Method not allowed', 405);
            break;

        default:
            jsonError('Endpoint invalido: ' . $action, 404);
    }
} catch (RuntimeException $e) {
    jsonError($e->getMessage());
} catch (Exception $e) {
    error_log('API Error: ' . $e->getMessage());
    jsonError('Erro interno do servidor', 500);
}

// ============ HANDLERS ============

function handleLogin($input) {
    $username = sanitizeInput($input['username'] ?? '');
    $password = $input['password'] ?? '';

    if (empty($username) || empty($password)) {
        jsonError('Username e senha obrigatorios');
    }

    try {
        // 1. Rate limiting: máximo 5 tentativas falhadas em 15 minutos por IP
        $ip = $_SERVER['REMOTE_ADDR'] ?? '0.0.0.0';
        $failedAttempts = Database::fetchOne(
            "SELECT COUNT(*) as count FROM audit_events WHERE action = 'LOGIN_FAILED' AND ip_address = ? AND created_at > NOW() - INTERVAL '15 minutes'",
            [$ip]
        );
        if ($failedAttempts && $failedAttempts['count'] >= 5) {
            http_response_code(429);
            echo json_encode(['success' => false, 'error' => 'Muitas tentativas de login. Tente novamente em 15 minutos.']);
            return;
        }

        $user = Database::fetchOne(
            "SELECT id, username, password_hash, full_name, email, role, organization_id, is_active FROM users WHERE username = ?",
            [$username]
        );

        // 2. Timing attack prevention: sempre executar password_verify
        $passwordValid = false;
        if ($user && $user['is_active']) {
            $passwordValid = password_verify($password, $user['password_hash']);
        } else {
            // Hash dummy para manter tempo constante mesmo se usuário não existe
            password_verify($password, '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2uheWG/igi.');
        }

        // Rejeitar se usuário inativo ou senha inválida
        if (!$user || !$user['is_active'] || !$passwordValid) {
            // Registrar tentativa falhada para rate limiting
            Database::execute(
                "INSERT INTO audit_events (organization_id, user_id, entity, action, details, ip_address, created_at)
                 VALUES (NULL, NULL, 'users', 'LOGIN_FAILED', ?, ?, NOW())",
                [json_encode(['username' => $username]), $ip]
            );
            jsonError('Credenciais invalidas', 401);
        }

        $_SESSION['user_id'] = $user['id'];
        $_SESSION['username'] = $user['username'];
        $_SESSION['role'] = $user['role'];
        $_SESSION['organization_id'] = $user['organization_id'];
        $_SESSION['full_name'] = $user['full_name'];

        $token = bin2hex(random_bytes(32));
        $tokenHash = password_hash($token, PASSWORD_DEFAULT);
        Database::execute(
            "INSERT INTO user_tokens (user_id, token_hash, expires_at) VALUES (?, ?, NOW() + INTERVAL '24 hours')",
            [$user['id'], $tokenHash]
        );

        $org = $user['organization_id'] ? Database::fetchOne("SELECT id, acronym, name, domain FROM organizations WHERE id = ?", [$user['organization_id']]) : null;

        log_audit('LOGIN', 'users', $user['id'], [
            'username' => $username,
            'full_name' => $user['full_name'],
            'organization_acronym' => $org['acronym'] ?? null
        ]);

            jsonSuccess([
            'id' => $user['id'],
            'username' => $user['username'],
            'full_name' => $user['full_name'],
            'email' => $user['email'],
            'role' => $user['role'],
            'token' => $token,
            'organization_id' => $user['organization_id'],
            'org_acronym' => $org['acronym'] ?? null,
            'org_name' => $org['name'] ?? null
        ], 'Login realizado com sucesso');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro no banco de dados: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function handleLogout() {
    $userId = $_SESSION['user_id'] ?? null;
    log_audit('LOGOUT', 'users', $userId, [
        'username' => $_SESSION['username'] ?? 'sistema',
        'full_name' => $_SESSION['full_name'] ?? null
    ]);
    if ($userId) {
        Database::execute("DELETE FROM user_tokens WHERE user_id = ?", [$userId]);
    }
    session_destroy();
    jsonSuccess(null, 'Logout realizado');
}

function handleSessionCheck() {
    if (isset($_SESSION['user_id'])) {
        $org = $_SESSION['organization_id'] ? Database::fetchOne("SELECT id, acronym, name, domain FROM organizations WHERE id = ?", [$_SESSION['organization_id']]) : null;
        jsonSuccess([
            'id' => $_SESSION['user_id'],
            'username' => $_SESSION['username'],
            'role' => $_SESSION['role'],
            'organization_id' => $_SESSION['organization_id'],
            'org_acronym' => $org['acronym'] ?? null,
            'org_name' => $org['name'] ?? null,
            'csrf_token' => getCsrfToken()
        ], 'Sessao ativa');
    }
    jsonResponse(['success' => false, 'error' => 'Not authenticated'], 200);
}

function handleMirrorStatus() {
    $config = Database::fetchOne(
        "SELECT enabled, tool, mirror_base_path, mirror_url_base, path_locked, verify_gpg, sync_interval_hours,
                auto_cleanup_enabled, retention_snapshots, quarantine_days
         FROM mirror.config ORDER BY id LIMIT 1"
    ) ?: [
        'enabled' => false,
        'tool' => 'aptly',
        'mirror_base_path' => '/var/lib/seederlinux/mirror',
        'mirror_url_base' => '',
        'path_locked' => false,
        'verify_gpg' => true,
        'sync_interval_hours' => 24,
        'auto_cleanup_enabled' => true,
        'retention_snapshots' => 2,
        'quarantine_days' => 7,
    ];

    $mirrorPath = $config['mirror_base_path'];
    if (!is_dir($mirrorPath)) {
        $mirrorPath = '/var';
    }

    $availableDistros = [];
    $distroRows = Database::fetchAll(
        "SELECT d.id, d.name, d.codename, d.active, d.base_distro_id,
            base.name AS base_name, base.codename AS base_codename,
            v.id AS version_id, v.version, v.status, v.active AS version_active
         FROM mirror.distros d
         LEFT JOIN mirror.versions v ON v.distro_id = d.id
         LEFT JOIN mirror.distros base ON base.id = d.base_distro_id
         ORDER BY d.name, d.id, v.version"
    );
    foreach ($distroRows as $row) {
        $distroKey = $row['name'];
        if (!isset($availableDistros[$distroKey])) {
            $availableDistros[$distroKey] = [
                'id' => (int)$row['id'],
                'name' => $row['name'],
                'codename' => $row['codename'],
                'active' => filter_var($row['active'], FILTER_VALIDATE_BOOLEAN),
                'base_distro' => $row['base_distro_id'] ? [
                    'id' => (int)$row['base_distro_id'],
                    'name' => $row['base_name'],
                    'codename' => $row['base_codename'],
                ] : null,
                'versions' => [],
            ];
        }
        if ($row['version'] !== null) {
            $availableDistros[$distroKey]['versions'][] = [
                'id' => (int)$row['version_id'],
                'version' => $row['version'],
                'status' => $row['status'],
                'active' => filter_var($row['version_active'], FILTER_VALIDATE_BOOLEAN),
            ];
        }
    }

    $lastJob = Database::fetchOne(
        "SELECT status FROM mirror.jobs WHERE job_type = 'sync'
         ORDER BY COALESCE(finished_at, started_at, created_at) DESC, id DESC LIMIT 1"
    );
    $hasJobs = (bool)Database::fetchOne('SELECT 1 FROM mirror.jobs LIMIT 1');
    $jobs = Database::fetchAll(
        "SELECT id, job_type, status, started_at, finished_at, details
         FROM mirror.jobs ORDER BY COALESCE(started_at, created_at) DESC, id DESC LIMIT 20"
    );
    $organizationUsage = Database::fetchOne(
        "SELECT COUNT(*) AS count FROM mirror.organization_repository_settings
         WHERE use_local_mirror = TRUE"
    );
    $organizationSettings = Database::fetchAll(
        "SELECT o.id, o.name, o.acronym,
                COALESCE(s.use_local_mirror, FALSE) AS use_local_mirror,
            COALESCE(s.mirror_priority, 100) AS mirror_priority,
            MAX(CASE WHEN vd.name = 'REPOSITORY_MODE' THEN ov.value END) AS repository_mode,
            MAX(CASE WHEN vd.name = 'REPOSITORY_DEBIAN_URL' THEN ov.value END) AS repository_debian_url,
            MAX(CASE WHEN vd.name = 'REPOSITORY_UBUNTU_URL' THEN ov.value END) AS repository_ubuntu_url,
            MAX(CASE WHEN vd.name = 'REPOSITORY_MINT_URL' THEN ov.value END) AS repository_mint_url,
            MAX(CASE WHEN vd.name = 'REPOSITORY_ZORIN_URL' THEN ov.value END) AS repository_zorin_url,
            MAX(CASE WHEN vd.name = 'REPOSITORY_FALLBACK' THEN ov.value END) AS repository_fallback
         FROM public.organizations o
         LEFT JOIN mirror.organization_repository_settings s ON s.organization_id = o.id
         LEFT JOIN public.organization_variables ov ON ov.organization_id = o.id
         LEFT JOIN public.variable_definitions vd ON vd.id = ov.variable_id
         WHERE o.is_active = TRUE
         GROUP BY o.id, o.name, o.acronym, s.use_local_mirror, s.mirror_priority
         ORDER BY o.acronym"
    );

    jsonSuccess([
        'enabled' => filter_var($config['enabled'], FILTER_VALIDATE_BOOLEAN),
        'tool' => $config['tool'],
        'mirror_base_path' => $config['mirror_base_path'],
        'mirror_url_base' => $config['mirror_url_base'],
        'path_locked' => filter_var($config['path_locked'], FILTER_VALIDATE_BOOLEAN)
            || filter_var($config['enabled'], FILTER_VALIDATE_BOOLEAN)
            || $hasJobs,
        'verify_gpg' => filter_var($config['verify_gpg'], FILTER_VALIDATE_BOOLEAN),
        'sync_interval_hours' => (int)$config['sync_interval_hours'],
        'auto_cleanup_enabled' => filter_var($config['auto_cleanup_enabled'], FILTER_VALIDATE_BOOLEAN),
        'retention_snapshots' => (int)$config['retention_snapshots'],
        'quarantine_days' => (int)$config['quarantine_days'],
        'disk_total_gb' => round((float)disk_total_space($mirrorPath) / 1073741824, 2),
        'disk_free_gb' => round((float)disk_free_space($mirrorPath) / 1073741824, 2),
        'available_distros' => array_values($availableDistros),
        'organization_settings' => $organizationSettings,
        'organization_usage' => (int)($organizationUsage['count'] ?? 0),
        'last_job_status' => $lastJob['status'] ?? null,
            'jobs' => $jobs,
    ]);
}

function requireMirrorAdmin($method, $expectedMethod = 'POST', $input = [], $validateCsrf = true) {
    requireAuth();
    if (($_SESSION['role'] ?? null) !== 'admin_gap') {
        jsonError('Acesso restrito ao administrador GAP', 403);
    }
    if ($method !== $expectedMethod) jsonError('Method not allowed', 405);
    if ($validateCsrf) requireCsrfToken($input);
}

function mirrorCatalogStatus($status) {
    return in_array($status, ['old', 'current', 'future'], true) ? $status : null;
}

function mirrorInputId($input, $keys) {
    foreach ($keys as $key) {
        if (isset($input[$key]) && $input[$key] !== '') {
            return filter_var($input[$key], FILTER_VALIDATE_INT);
        }
    }
    return false;
}

function mirrorInputBoolean($input, $key) {
    if (!array_key_exists($key, $input) || $input[$key] === '' || $input[$key] === null) {
        return null;
    }
    return filter_var($input[$key], FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
}

function mirrorDatabaseBoolean($value) {
    return $value ? 'true' : 'false';
}

function handleMirrorAddDistro($input) {
    $name = sanitizeInput($input['name'] ?? '');
    $codename = sanitizeInput($input['codename'] ?? '');
    $baseId = ($input['base_distro_id'] ?? '') === '' || $input['base_distro_id'] === null ? null : filter_var($input['base_distro_id'], FILTER_VALIDATE_INT);
    if ($name === '' || $codename === '') jsonError('Nome e codename sao obrigatorios');
    if ($baseId === false || ($baseId !== null && !Database::fetchOne('SELECT id FROM mirror.distros WHERE id = ?', [$baseId]))) jsonError('Distro base invalida');
    try {
        Database::execute('INSERT INTO mirror.distros (name, codename, base_distro_id) VALUES (?, ?, ?)', [$name, $codename, $baseId]);
    } catch (PDOException $e) {
        if ($e->getCode() === '23505') jsonError('Essa distro ja existe', 409);
        throw $e;
    }
    jsonSuccess(null, 'Distro adicionada');
}

function handleMirrorUpdateDistro($input) {
    $id = mirrorInputId($input, ['distro_id', 'id']);
    $name = sanitizeInput($input['name'] ?? '');
    $codename = sanitizeInput($input['codename'] ?? '');
    $baseId = ($input['base_distro_id'] ?? '') === '' || $input['base_distro_id'] === null ? null : filter_var($input['base_distro_id'], FILTER_VALIDATE_INT);
    if ($id === false || $id < 1 || $name === '' || $codename === '') jsonError('Dados da distro invalidos');
    if ($baseId === $id) jsonError('Uma distro nao pode ser sua propria base');
    if ($baseId === false || ($baseId !== null && !Database::fetchOne('SELECT id FROM mirror.distros WHERE id = ?', [$baseId]))) jsonError('Distro base invalida');
    Database::execute('UPDATE mirror.distros SET name = ?, codename = ?, base_distro_id = ? WHERE id = ?', [$name, $codename, $baseId, $id]);
    jsonSuccess(null, 'Distro atualizada');
}

function handleMirrorToggleDistro($input) {
    $id = mirrorInputId($input, ['distro_id', 'id']);
    if ($id === false || $id < 1) jsonError('Distro invalida');
    $distro = Database::fetchOne('SELECT active FROM mirror.distros WHERE id = ?', [$id]);
    if (!$distro) jsonError('Distro nao encontrada', 404);
    $active = mirrorInputBoolean($input, 'active');
    if ($active === null) {
        $active = !filter_var($distro['active'], FILTER_VALIDATE_BOOLEAN);
    }
    Database::execute('UPDATE mirror.distros SET active = ? WHERE id = ?', [mirrorDatabaseBoolean($active), $id]);
    jsonSuccess(['active' => $active], $active ? 'Distro ativada' : 'Distro desativada');
}

function handleMirrorAddVersion($input) {
    $distroId = mirrorInputId($input, ['distro_id', 'distro']);
    $version = sanitizeInput($input['version'] ?? '');
    $status = mirrorCatalogStatus(sanitizeInput($input['status'] ?? 'current'));
    if ($distroId === false || $distroId < 1 || $version === '' || $status === null) jsonError('Dados da versao invalidos');
    if (!Database::fetchOne('SELECT id FROM mirror.distros WHERE id = ?', [$distroId])) jsonError('Distro nao encontrada', 404);
    try {
        Database::execute('INSERT INTO mirror.versions (distro_id, version, status) VALUES (?, ?, ?)', [$distroId, $version, $status]);
    } catch (PDOException $e) {
        if ($e->getCode() === '23505') jsonError('Essa versao ja existe', 409);
        throw $e;
    }
    jsonSuccess(null, 'Versao adicionada');
}

function handleMirrorUpdateVersion($input) {
    $id = mirrorInputId($input, ['version_id', 'id']);
    $version = sanitizeInput($input['version'] ?? '');
    $status = mirrorCatalogStatus(sanitizeInput($input['status'] ?? ''));
    if ($id === false || $id < 1 || $version === '' || $status === null) jsonError('Dados da versao invalidos');
    Database::execute('UPDATE mirror.versions SET version = ?, status = ? WHERE id = ?', [$version, $status, $id]);
    jsonSuccess(null, 'Versao atualizada');
}

function handleMirrorToggleVersion($input) {
    $id = mirrorInputId($input, ['version_id', 'id']);
    if ($id === false || $id < 1) jsonError('Versao invalida');
    $version = Database::fetchOne('SELECT active FROM mirror.versions WHERE id = ?', [$id]);
    if (!$version) jsonError('Versao nao encontrada', 404);
    $active = mirrorInputBoolean($input, 'active');
    if ($active === null) {
        $active = !filter_var($version['active'], FILTER_VALIDATE_BOOLEAN);
    }
    Database::execute('UPDATE mirror.versions SET active = ? WHERE id = ?', [mirrorDatabaseBoolean($active), $id]);
    jsonSuccess(['active' => $active], $active ? 'Versao ativada' : 'Versao desativada');
}

function handleMirrorDeleteVersion($input) {
    $id = mirrorInputId($input, ['version_id', 'id']);
    if ($id === false || $id < 1) jsonError('Versao invalida');
    Database::execute('DELETE FROM mirror.versions WHERE id = ?', [$id]);
    jsonSuccess(null, 'Versao removida');
}

function handleMirrorSyncNow() {
    Database::execute("INSERT INTO mirror.jobs (job_type, status, started_at) VALUES ('sync', 'pending', NOW())");
    $jobId = (int)Database::lastInsertId();
    $worker = realpath(__DIR__ . '/../scripts/mirror-sync.sh');
    $launchStatus = 'queued';
    if ($worker && is_executable($worker) && function_exists('exec')) {
        $command = sprintf(
            'nohup %s %d >/dev/null 2>&1 &',
            escapeshellarg($worker),
            $jobId
        );
        exec($command);
        $launchStatus = 'started';
    }
    jsonSuccess(['job_id' => $jobId, 'status' => 'pending', 'worker' => $launchStatus], 'Sincronizacao enfileirada');
}

function handleMirrorJobStatus($input) {
    $jobId = mirrorInputId($input, ['job_id', 'id']);
    if ($jobId === false || $jobId < 1) jsonError('Job invalido');
    $job = Database::fetchOne(
        "SELECT id, job_type, status, details, gpg_verified, started_at, finished_at, created_at
         FROM mirror.jobs WHERE id = ?",
        [$jobId]
    );
    if (!$job) jsonError('Job nao encontrado', 404);
    jsonSuccess($job);
}

function handleMirrorSaveConfig($input) {
    $currentConfig = Database::fetchOne(
        "SELECT enabled, tool, mirror_base_path, mirror_url_base, path_locked, verify_gpg, sync_interval_hours,
                auto_cleanup_enabled, retention_snapshots, quarantine_days
         FROM mirror.config ORDER BY id LIMIT 1"
    ) ?: [];
    $enabled = array_key_exists('enabled', $input)
        ? mirrorInputBoolean($input, 'enabled')
        : filter_var($currentConfig['enabled'] ?? false, FILTER_VALIDATE_BOOLEAN);
    $verifyGpg = array_key_exists('verify_gpg', $input)
        ? mirrorInputBoolean($input, 'verify_gpg')
        : filter_var($currentConfig['verify_gpg'] ?? true, FILTER_VALIDATE_BOOLEAN);
    $autoCleanup = array_key_exists('auto_cleanup_enabled', $input)
        ? mirrorInputBoolean($input, 'auto_cleanup_enabled')
        : filter_var($currentConfig['auto_cleanup_enabled'] ?? true, FILTER_VALIDATE_BOOLEAN);
    $tool = sanitizeInput($input['tool'] ?? '');
    if ($tool === '') $tool = $currentConfig['tool'] ?? 'aptly';
    $mirrorUrlBase = array_key_exists('mirror_url_base', $input)
        ? rtrim(sanitizeInput($input['mirror_url_base']), '/')
        : ($currentConfig['mirror_url_base'] ?? '');
    $basePath = array_key_exists('mirror_base_path', $input)
        ? sanitizeInput($input['mirror_base_path'])
        : ($currentConfig['mirror_base_path'] ?? '/var/lib/seederlinux/mirror');
    $interval = filter_var(
        $input['sync_interval_hours'] ?? ($currentConfig['sync_interval_hours'] ?? 24),
        FILTER_VALIDATE_INT
    );
    $retentionSnapshots = filter_var(
        $input['retention_snapshots'] ?? ($currentConfig['retention_snapshots'] ?? 2),
        FILTER_VALIDATE_INT
    );
    $quarantineDays = filter_var(
        $input['quarantine_days'] ?? ($currentConfig['quarantine_days'] ?? 7),
        FILTER_VALIDATE_INT
    );

    if ($enabled === null || $verifyGpg === null || $autoCleanup === null) jsonError('Valores booleanos invalidos');
    if (!in_array($tool, ['aptly', 'apt-mirror'], true)) jsonError('Ferramenta de mirror invalida');
    if ($basePath === '' || strlen($basePath) > 255) jsonError('Caminho base invalido');
    if (strlen($mirrorUrlBase) > 255 || ($mirrorUrlBase !== '' && filter_var($mirrorUrlBase, FILTER_VALIDATE_URL) === false)) {
        jsonError('URL base do mirror invalida');
    }
    if ($interval === false || $interval < 1 || $interval > 8760) {
        jsonError('Intervalo deve estar entre 1 e 8760 horas');
    }
    if ($retentionSnapshots === false || $retentionSnapshots < 0 || $retentionSnapshots > 100) jsonError('Retencao de snapshots invalida');
    if ($quarantineDays === false || $quarantineDays < 0 || $quarantineDays > 3650) jsonError('Periodo de quarentena invalido');

    $currentPath = $currentConfig['mirror_base_path'] ?? '/var/lib/seederlinux/mirror';
    $pathLocked = filter_var($currentConfig['path_locked'] ?? false, FILTER_VALIDATE_BOOLEAN);
    $hasJobs = (bool)Database::fetchOne('SELECT 1 FROM mirror.jobs LIMIT 1');
    if (($pathLocked || filter_var($currentConfig['enabled'] ?? false, FILTER_VALIDATE_BOOLEAN) || $hasJobs)
        && $basePath !== $currentPath) {
        jsonError('O caminho base do mirror esta bloqueado porque o mirror esta ativo ou ja possui jobs', 409);
    }
    $nextPathLocked = $pathLocked || $hasJobs || $enabled;

    Database::execute(
        "INSERT INTO mirror.config (id, enabled, tool, mirror_base_path, mirror_url_base, path_locked, verify_gpg,
                                    sync_interval_hours, auto_cleanup_enabled, retention_snapshots, quarantine_days, updated_at)
         VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
         ON CONFLICT (id) DO UPDATE SET
             enabled = EXCLUDED.enabled,
             tool = EXCLUDED.tool,
             mirror_base_path = EXCLUDED.mirror_base_path,
             mirror_url_base = EXCLUDED.mirror_url_base,
             path_locked = EXCLUDED.path_locked,
             verify_gpg = EXCLUDED.verify_gpg,
             sync_interval_hours = EXCLUDED.sync_interval_hours,
             auto_cleanup_enabled = EXCLUDED.auto_cleanup_enabled,
             retention_snapshots = EXCLUDED.retention_snapshots,
             quarantine_days = EXCLUDED.quarantine_days,
             updated_at = NOW()",
        [mirrorDatabaseBoolean($enabled), $tool, $basePath, $mirrorUrlBase, mirrorDatabaseBoolean($nextPathLocked),
         mirrorDatabaseBoolean($verifyGpg), $interval, mirrorDatabaseBoolean($autoCleanup),
         $retentionSnapshots, $quarantineDays]
    );

    log_audit('UPDATE', 'mirror_config', 1, [
        'enabled' => $enabled,
        'tool' => $tool,
        'mirror_base_path' => $basePath,
        'mirror_url_base' => $mirrorUrlBase,
        'verify_gpg' => $verifyGpg,
        'sync_interval_hours' => $interval,
    ]);
    jsonSuccess(null, 'Configuracao global do mirror salva');
}

function handleMirrorSaveOrgSettings($input) {
    $organizationId = filter_var($input['organization_id'] ?? null, FILTER_VALIDATE_INT);
    $useLocalMirror = array_key_exists('use_local_mirror', $input) ? mirrorInputBoolean($input, 'use_local_mirror') : false;
    $priority = filter_var($input['mirror_priority'] ?? 100, FILTER_VALIDATE_INT);

    if ($organizationId === false || $organizationId < 1) jsonError('Organizacao invalida');
    if ($useLocalMirror === null) jsonError('Valor de mirror local invalido');
    if ($priority === false || $priority < 0 || $priority > 10000) jsonError('Prioridade invalida');
    if (!Database::fetchOne('SELECT id FROM public.organizations WHERE id = ? AND is_active = TRUE', [$organizationId])) {
        jsonError('Organizacao nao encontrada', 404);
    }

    $mirrorConfig = Database::fetchOne('SELECT mirror_url_base FROM mirror.config ORDER BY id LIMIT 1') ?: ['mirror_url_base' => ''];
    $mirrorUrlBase = rtrim(sanitizeInput($mirrorConfig['mirror_url_base'] ?? ''), '/');
    if ($useLocalMirror && $mirrorUrlBase === '') {
        jsonError('Configure a URL base do mirror antes de ativa-lo para uma OM');
    }

    $repositoryValues = $useLocalMirror ? [
        'REPOSITORY_MODE' => 'MIRROR',
        'REPOSITORY_DEBIAN_URL' => $mirrorUrlBase . '/debian',
        'REPOSITORY_UBUNTU_URL' => $mirrorUrlBase . '/ubuntu',
        'REPOSITORY_MINT_URL' => $mirrorUrlBase . '/mint',
        'REPOSITORY_ZORIN_URL' => $mirrorUrlBase . '/zorin',
    ] : [
        'REPOSITORY_MODE' => 'PUBLIC',
        'REPOSITORY_DEBIAN_URL' => '',
        'REPOSITORY_UBUNTU_URL' => '',
        'REPOSITORY_MINT_URL' => '',
        'REPOSITORY_ZORIN_URL' => '',
    ];
    $fallback = Database::fetchOne(
        "SELECT ov.value FROM public.organization_variables ov
         JOIN public.variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name = 'REPOSITORY_FALLBACK'",
        [$organizationId]
    );
    $repositoryValues['REPOSITORY_FALLBACK'] = !empty(trim($fallback['value'] ?? ''))
        ? $fallback['value']
        : 'http://deb.debian.org/debian';

    Database::beginTransaction();
    try {
        Database::execute(
            "INSERT INTO mirror.organization_repository_settings
                 (organization_id, use_local_mirror, mirror_priority, updated_at)
             VALUES (?, ?, ?, NOW())
             ON CONFLICT (organization_id) DO UPDATE SET
                 use_local_mirror = EXCLUDED.use_local_mirror,
                 mirror_priority = EXCLUDED.mirror_priority,
                 updated_at = NOW()",
            [$organizationId, mirrorDatabaseBoolean($useLocalMirror), $priority]
        );

        foreach ($repositoryValues as $name => $value) {
            $definition = Database::fetchOne('SELECT id FROM public.variable_definitions WHERE name = ?', [$name]);
            if (!$definition) continue;
            Database::execute(
                "INSERT INTO public.organization_variables (organization_id, variable_id, value, updated_at)
                 VALUES (?, ?, ?, NOW())
                 ON CONFLICT (organization_id, variable_id) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
                [$organizationId, $definition['id'], $value]
            );
        }
        Database::commit();
    } catch (Throwable $e) {
        Database::rollback();
        throw $e;
    }

    // Futuramente, ativar uma OM deverá definir REPOSITORY_MODE=MIRROR e preencher
    // automaticamente as variáveis REPOSITORY_*_URL correspondentes.
    log_audit('UPDATE', 'mirror_org_settings', $organizationId, [
        'use_local_mirror' => $useLocalMirror,
        'mirror_priority' => $priority,
    ], $organizationId);
    jsonSuccess(null, 'Preferencia de mirror da OM salva');
}

function handleMirrorEstimate($input) {
    $distroIds = array_filter(array_map('intval', $input['distros'] ?? []));
    $versionIds = array_filter(array_map('intval', $input['versions'] ?? []));
    $architectures = $input['architectures'] ?? [];
    $components = $input['components'] ?? [];

    $allowedArchitectures = ['amd64', 'i386', 'arm64'];
    $allowedComponents = ['main', 'contrib', 'non-free', 'restricted', 'universe', 'multiverse'];
    $architectures = array_values(array_intersect($allowedArchitectures, $architectures));
    $components = array_values(array_intersect($allowedComponents, $components));

    if ((empty($distroIds) && empty($versionIds)) || empty($architectures) || empty($components)) {
        jsonSuccess([
            'estimated_total_mb' => 0,
            'estimated_gb' => 0,
            'details' => [],
            'errors' => [],
            'calculation_possible' => false,
            'message' => 'Selecione distros/versoes, arquiteturas e componentes.'
        ]);
    }

    $cacheKey = md5(serialize([$distroIds, $versionIds, $architectures, $components]));
    $cacheFile = sys_get_temp_dir() . '/sl-mirror-est-' . $cacheKey . '.json';
    if (file_exists($cacheFile) && (time() - filemtime($cacheFile)) < 3600) {
        $cached = json_decode(@file_get_contents($cacheFile), true);
        if ($cached) { jsonSuccess($cached); return; }
    }

    $upstreamHosts = [
        'debian'     => 'deb.debian.org',
        'ubuntu'     => 'archive.ubuntu.com',
        'linux mint' => 'packages.linuxmint.com',
        'zorin'      => 'apt.zorin.com',
    ];
    $upstreamBasePaths = [
        'deb.debian.org'         => '/debian',
        'archive.ubuntu.com'     => '/ubuntu',
        'packages.linuxmint.com' => '',
        'apt.zorin.com'          => '',
    ];

    if (!empty($versionIds)) {
        $ph = implode(',', array_fill(0, count($versionIds), '?'));
        $versionRows = Database::fetchAll(
            "SELECT v.id, v.distro_id, v.version, d.name as distro_name
             FROM mirror.versions v JOIN mirror.distros d ON d.id = v.distro_id
             WHERE v.id IN ($ph)",
            $versionIds
        );
    } else {
        $ph = implode(',', array_fill(0, count($distroIds), '?'));
        $versionRows = Database::fetchAll(
            "SELECT v.id, v.distro_id, v.version, d.name as distro_name
             FROM mirror.versions v JOIN mirror.distros d ON d.id = v.distro_id
             WHERE v.active = TRUE AND v.distro_id IN ($ph)",
            $distroIds
        );
    }

    $details = [];
    $errors = [];
    $totalBytes = 0;
    $hasCurl = function_exists('curl_init');
    $hasShellExec = function_exists('shell_exec');

    foreach ($versionRows as $vr) {
        $distroLower = strtolower($vr['distro_name']);
        $matchedKey = null;
        foreach (array_keys($upstreamHosts) as $key) {
            if ($distroLower === $key || strpos($distroLower, $key) !== false) {
                $matchedKey = $key;
                break;
            }
        }
        if (!$matchedKey) {
            foreach ($architectures as $arch) {
                foreach ($components as $comp) {
                    $errors[] = [
                        'distro' => $vr['distro_name'], 'version' => $vr['version'],
                        'arch' => $arch, 'component' => $comp,
                        'error' => 'Distro sem upstream conhecido'
                    ];
                }
            }
            continue;
        }

        $host = $upstreamHosts[$matchedKey];
        $basePath = $upstreamBasePaths[$host] ?? '';
        $codename = $vr['version'];

        foreach ($architectures as $arch) {
            foreach ($components as $comp) {
                $urlBase = "https://{$host}{$basePath}/dists/{$codename}/{$comp}/binary-{$arch}/Packages";
                $fetched = false;
                $errorMsg = null;

                foreach (['.xz', '.gz', ''] as $ext) {
                    $url = $urlBase . $ext;

                    $parsed = parse_url($url);
                    if (!$parsed || !isset($parsed['host']) || strtolower($parsed['host']) !== $host) {
                        $errorMsg = 'URL invalida';
                        continue;
                    }

                    if (!$hasCurl) {
                        $errorMsg = 'Extensao curl indisponivel no servidor';
                        break;
                    }

                    $ch = curl_init();
                    curl_setopt_array($ch, [
                        CURLOPT_URL => $url,
                        CURLOPT_RETURNTRANSFER => true,
                        CURLOPT_TIMEOUT => 10,
                        CURLOPT_CONNECTTIMEOUT => 5,
                        CURLOPT_FOLLOWLOCATION => true,
                        CURLOPT_MAXREDIRS => 3,
                        CURLOPT_SSL_VERIFYPEER => false,
                        CURLOPT_SSL_VERIFYHOST => false,
                    ]);
                    $data = curl_exec($ch);
                    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
                    $curlError = curl_error($ch);
                    curl_close($ch);

                    if ($data === false || $httpCode !== 200) {
                        $errorMsg = $curlError ?: 'HTTP ' . $httpCode;
                        continue;
                    }

                    if ($ext === '.xz') {
                        if (!$hasShellExec) { $errorMsg = 'xz sem suporte no servidor'; continue; }
                        $tmp = @tempnam(sys_get_temp_dir(), 'pkg_');
                        if (!$tmp) { $errorMsg = 'Falha ao criar arquivo temporario'; continue; }
                        @file_put_contents($tmp, $data);
                        $data = @shell_exec('xz -dc ' . escapeshellarg($tmp) . ' 2>/dev/null');
                        @unlink($tmp);
                        if ($data === null || $data === '') { $errorMsg = 'Falha ao descompactar xz'; continue; }
                    } elseif ($ext === '.gz') {
                        $decoded = @gzdecode($data);
                        if ($decoded === false) { $errorMsg = 'Falha ao descompactar gz'; continue; }
                        $data = $decoded;
                    }

                    $pkgCount = 0;
                    $comboBytes = 0;
                    if (preg_match_all('/^Size:\s*(\d+)\s*$/m', $data, $matches)) {
                        foreach ($matches[1] as $size) {
                            $comboBytes += (int)$size;
                            $pkgCount++;
                        }
                    }

                    $totalBytes += $comboBytes;
                    $details[] = [
                        'distro' => $vr['distro_name'], 'version' => $vr['version'],
                        'arch' => $arch, 'component' => $comp,
                        'size_mb' => round($comboBytes / 1048576, 2),
                        'packages' => $pkgCount
                    ];
                    $fetched = true;
                    break;
                }

                if (!$fetched) {
                    $errors[] = [
                        'distro' => $vr['distro_name'], 'version' => $vr['version'],
                        'arch' => $arch, 'component' => $comp,
                        'error' => $errorMsg ?? 'Indice nao disponivel'
                    ];
                }
            }
        }
    }

    $estimatedMb = round($totalBytes / 1048576, 2);
    $estimatedGb = round($totalBytes / 1073741824, 2);
    $calculationPossible = count($details) > 0;
    $msg = $calculationPossible
        ? (empty($errors)
            ? sprintf('Estimativa: %.0f MB (%.2f GB) a partir dos indices upstream.', $estimatedMb, $estimatedGb)
            : sprintf('Estimativa parcial: %.0f MB (%.2f GB). Alguns indices nao puderam ser baixados.', $estimatedMb, $estimatedGb))
        : 'Nao foi possivel baixar nenhum indice upstream. Verifique a conexao do servidor.';

    $result = [
        'estimated_total_mb' => $estimatedMb,
        'estimated_gb' => $estimatedGb,
        'details' => $details,
        'errors' => $errors,
        'calculation_possible' => $calculationPossible,
        'message' => $msg
    ];

    @file_put_contents($cacheFile, json_encode($result));
    jsonSuccess($result);
}

function handleDashboard(?int $filterOrgId = null) {
    $userOrgId = getUserOrgId();
    $isAdmin = isAdminGap();

    // Determine effective org scope
    $scopeOrgId = null;
    if ($filterOrgId) {
        // Per-OM dashboard: admins can view any, operators only their own
        if ($userOrgId !== null && !$isAdmin && $userOrgId !== $filterOrgId) {
            jsonError('Sem permissao', 403);
        }
        $scopeOrgId = $filterOrgId;
    } elseif ($userOrgId !== null && !$isAdmin) {
        $scopeOrgId = $userOrgId;
    }

    $twoHoursAgo = date('Y-m-d H:i:s', strtotime('-2 hours'));

    $stats = [
        'organizations' => 0,
        'scripts' => 0,
        'variables' => 0,
        'bundles_this_month' => 0,
        'stations_online' => 0,
        'stations_outdated' => 0,
        'recent_stations' => [],
        'recent_orgs' => [],
        'org_id' => $scopeOrgId,
    ];

    if ($scopeOrgId) {
        // Scoped stats for a single org
        $stats['organizations'] = 1;
        $stats['scripts'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM scripts WHERE is_active = true AND (is_core = true OR organization_id = ?)",
            [$scopeOrgId]
        )['c'];
        $stats['variables'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM organization_variables WHERE organization_id = ?",
            [$scopeOrgId]
        )['c'];
        $stats['bundles_this_month'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM deploy_bundles WHERE organization_id = ? AND generated_at >= date_trunc('month', CURRENT_DATE)",
            [$scopeOrgId]
        )['c'];
        $stats['stations_online'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM stations WHERE organization_id = ? AND last_checkin >= ?",
            [$scopeOrgId, $twoHoursAgo]
        )['c'];
        $stats['stations_outdated'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM stations s
             JOIN organizations o ON o.id = s.organization_id
             WHERE s.organization_id = ? AND s.serial_aplicado < o.serial_config",
            [$scopeOrgId]
        )['c'];
        $stats['recent_stations'] = Database::fetchAll(
            "SELECT s.hostname, s.ip_address, s.last_checkin, o.acronym as org_acronym,
                    CASE WHEN s.serial_aplicado >= o.serial_config THEN 'Atualizado' ELSE 'Desatualizado' END as status
             FROM stations s
             JOIN organizations o ON o.id = s.organization_id
             WHERE s.organization_id = ?
             ORDER BY s.last_checkin DESC NULLS LAST LIMIT 10",
            [$scopeOrgId]
        );
        // Scripts for the org (core + custom)
        $stats['org_scripts'] = Database::fetchAll(
            "SELECT id, name, filename, is_core, version, execution_order FROM scripts
             WHERE is_active = TRUE AND (is_core = TRUE OR organization_id = ?)
             ORDER BY execution_order ASC, name",
            [$scopeOrgId]
        );
    } else {
        // Global stats
        $stats['organizations'] = (int)Database::fetchOne("SELECT COUNT(*) as c FROM organizations WHERE is_active = true")['c'];
        $stats['scripts'] = (int)Database::fetchOne("SELECT COUNT(*) as c FROM scripts WHERE is_active = true")['c'];
        $stats['variables'] = (int)Database::fetchOne("SELECT COUNT(*) as c FROM variable_definitions")['c'];
        $stats['bundles_this_month'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM deploy_bundles WHERE generated_at >= date_trunc('month', CURRENT_DATE)"
        )['c'];
        $stats['stations_online'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM stations WHERE last_checkin >= ?", [$twoHoursAgo]
        )['c'];
        $stats['stations_outdated'] = (int)Database::fetchOne(
            "SELECT COUNT(*) as c FROM stations s
             JOIN organizations o ON o.id = s.organization_id
             WHERE s.serial_aplicado < o.serial_config"
        )['c'];
        $stats['recent_stations'] = Database::fetchAll(
            "SELECT s.hostname, s.ip_address, s.last_checkin, o.acronym as org_acronym,
                    CASE WHEN s.serial_aplicado >= o.serial_config THEN 'Atualizado' ELSE 'Desatualizado' END as status
             FROM stations s
             JOIN organizations o ON o.id = s.organization_id
             ORDER BY s.last_checkin DESC NULLS LAST LIMIT 10"
        );
        $stats['recent_orgs'] = Database::fetchAll(
            "SELECT id, name, acronym, domain FROM organizations WHERE is_active = true ORDER BY created_at DESC LIMIT 5"
        );
    }

    jsonSuccess($stats);
}

function handleGetOrganizations() {
    $userOrgId = getUserOrgId();
    $isAdmin = isAdminGap();

    if ($userOrgId !== null && !$isAdmin) {
        $orgs = Database::fetchAll(
            "SELECT id, name, acronym, domain, description, is_active, created_at FROM organizations WHERE is_active = TRUE AND id = ? ORDER BY acronym",
            [$userOrgId]
        );
    } else {
        $orgs = Database::fetchAll(
            "SELECT id, name, acronym, domain, description, is_active, created_at FROM organizations WHERE is_active = TRUE ORDER BY acronym"
        );
    }

    foreach ($orgs as &$org) {
        $logo = Database::fetchOne(
            "SELECT ov.value FROM organization_variables ov
             JOIN variable_definitions vd ON vd.id = ov.variable_id
             WHERE ov.organization_id = ? AND vd.name = 'LOGO_URL'",
            [$org['id']]
        );
        $org['logo_url'] = $logo['value'] ?? null;
    }

    jsonSuccess($orgs);
}

function handleGetOrganization($id) {
    $org = Database::fetchOne("SELECT id, name, acronym, domain, description, is_active, created_at FROM organizations WHERE id = ?", [$id]);
    if (!$org) jsonError('Organizacao nao encontrada', 404);

    $logo = Database::fetchOne(
        "SELECT ov.value FROM organization_variables ov
         JOIN variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name = 'LOGO_URL'",
        [$id]
    );
    $org['logo_url'] = $logo['value'] ?? null;

    jsonSuccess($org);
}

function handleCreateOrganization($input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $name = sanitizeInput($input['name'] ?? '');
    $acronym = strtoupper(sanitizeInput($input['acronym'] ?? ''));
    $domain = sanitizeInput($input['domain'] ?? '');
    $description = sanitizeInput($input['description'] ?? '');
    $dcIp = sanitizeInput($input['dc_ip'] ?? '');
    $dnsPrimario = sanitizeInput($input['dns_primario'] ?? '');
    $dnsSecundario = sanitizeInput($input['dns_secundario'] ?? '');
    $proxyHttp = sanitizeInput($input['proxy_http'] ?? '');
    $proxyPorta = sanitizeInput($input['proxy_porta'] ?? '');

    if (empty($name) || empty($acronym)) jsonError('Nome e sigla obrigatorios');
    if ($domain && (empty($dcIp) || empty($dnsPrimario))) {
        jsonError('DC_IP e DNS Primario obrigatorios quando dominio informado');
    }

    try {
        if (Database::fetchOne("SELECT id FROM organizations WHERE acronym = ? AND is_active = TRUE", [$acronym])) {
            jsonError('Sigla ja cadastrada');
        }

        Database::beginTransaction();

        Database::execute(
            "INSERT INTO organizations (name, acronym, domain, description) VALUES (?, ?, ?, ?)",
            [$name, $acronym, $domain, $description]
        );

        $newOrgId = (int)Database::lastInsertId();

        Database::execute(
            "INSERT INTO organization_variables (organization_id, variable_id, value)
             SELECT ?, id, COALESCE(default_value, '') FROM variable_definitions",
            [$newOrgId]
        );

        generateDefaultVariables($newOrgId, $name, $acronym, $domain, $dcIp, $dnsPrimario, $dnsSecundario, $proxyHttp, $proxyPorta);

        Database::commit();

        log_audit('CREATE', 'organizations', $newOrgId, ['name' => $name, 'acronym' => $acronym]);
        log_event("Organizacao criada: $acronym (id=$newOrgId)", 'INFO');

        jsonSuccess(
            Database::fetchOne("SELECT id, name, acronym, domain, description FROM organizations WHERE id = ?", [$newOrgId]),
            'Organizacao criada com sucesso'
        );
    } catch (PDOException $e) {
        Database::rollback();
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao criar organização: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    } catch (Exception $e) {
        Database::rollback();
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao criar organização: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function handleUpdateOrganization($id, $input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $name = sanitizeInput($input['name'] ?? '');
    $domain = sanitizeInput($input['domain'] ?? '');
    $description = sanitizeInput($input['description'] ?? '');

    if (empty($name)) jsonError('Nome obrigatorio');

    Database::execute(
        "UPDATE organizations SET name = ?, domain = ?, description = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        [$name, $domain, $description, $id]
    );

    log_audit('UPDATE', 'organizations', $id, ['name' => $name]);
    jsonSuccess(null, 'Organizacao atualizada');
}

function handleDeleteOrganization($id) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $org = Database::fetchOne("SELECT acronym FROM organizations WHERE id = ?", [$id]);
    if (!$org) jsonError('Organizacao nao encontrada', 404);

    Database::execute("UPDATE organizations SET is_active = FALSE WHERE id = ?", [$id]);

    log_audit('DELETE', 'organizations', $id, ['acronym' => $org['acronym']]);
    jsonSuccess(null, 'Organizacao excluida');
}

// VARIABLES
function handleGetVariables($orgId) {
    $user = getCurrentUser();
    // operador_om só pode acessar sua própria OM
    if (!$orgId) {
        $orgId = getUserOrgId();
    }
    if ($user && $user['role'] === 'operador_om' && $orgId != $user['organization_id']) {
        jsonError('Acesso negado a esta organizacao', 403);
    }
    if (!$orgId) jsonError('Organization ID required', 400);

    try {
        $vars = Database::fetchAll(
            "SELECT vd.id, vd.name, vd.description, vd.category, vd.type, vd.is_required, vd.default_value,
                    COALESCE(ov.value, vd.default_value) as current_value
             FROM variable_definitions vd
             LEFT JOIN organization_variables ov ON ov.variable_id = vd.id AND ov.organization_id = ?
             ORDER BY vd.category, vd.name",
            [$orgId]
        );

        jsonSuccess(['variables' => $vars, 'organization_id' => $orgId]);
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao buscar variáveis: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function handleUpdateVariables($input) {
    $orgId = (int)($input['organization_id'] ?? 0);
    $variables = $input['variables'] ?? [];

    if (!$orgId) jsonError('Organization ID required');
    
    // Verificar escopo: operador_om não pode acessar dados de outra OM
    $user = getCurrentUser();
    if ($user && $user['role'] === 'operador_om' && $orgId != $user['organization_id']) {
        http_response_code(403);
        echo json_encode(['success' => false, 'error' => 'Acesso negado a esta organizacao']);
        return;
    }

    try {
        $organization = Database::fetchOne(
            "SELECT acronym FROM organizations WHERE id = ?",
            [$orgId]
        );
        $variableIds = array_map('intval', array_keys($variables));
        $changedVariables = [];
        $definitions = [];
        if ($variableIds) {
            $placeholders = implode(',', array_fill(0, count($variableIds), '?'));
            $definitions = Database::fetchAll(
                "SELECT id, name FROM variable_definitions WHERE id IN ({$placeholders}) ORDER BY name",
                $variableIds
            );
            $changedVariables = array_column($definitions, 'name');
        }

        $repositoryBooleanNames = [
            'REPOSITORY_DEBIAN_ENABLED',
            'REPOSITORY_UBUNTU_ENABLED',
            'REPOSITORY_MINT_ENABLED',
            'REPOSITORY_ZORIN_ENABLED',
        ];
        $definitionNamesById = [];
        foreach ($definitions as $definition) {
            $definitionNamesById[(int)$definition['id']] = $definition['name'];
        }

        // Validar politicas de proxy
        $newValues = [];
        foreach ($variables as $varId => $value) {
            $varName = $definitionNamesById[(int)$varId] ?? '';
            if ($varName) $newValues[$varName] = $value;
        }
        // Buscar valores atuais das variaveis de policy para validacao
        $policyNames = ['APT_POLICY', 'CLI_POLICY', 'BROWSER_POLICY', 'PROXY_URL', 'PROXY_USER', 'PROXY_PASSWORD_B64', 'PAC_URL', 'MIRROR_LOCAL_SEEDER_PATH', 'MIRROR_LOCAL_OM_URL'];
        $currentPolicyValues = [];
        foreach ($policyNames as $pn) {
            if (isset($newValues[$pn])) {
                $currentPolicyValues[$pn] = $newValues[$pn];
            } else {
                $row = Database::fetchOne(
                    "SELECT ov.value FROM organization_variables ov
                     JOIN variable_definitions vd ON vd.id = ov.variable_id
                     WHERE ov.organization_id = ? AND vd.name = ?",
                    [$orgId, $pn]
                );
                $currentPolicyValues[$pn] = $row['value'] ?? '';
            }
        }
        $aptPolicy = $currentPolicyValues['APT_POLICY'] ?? 'DIRECT';
        $cliPolicy = $currentPolicyValues['CLI_POLICY'] ?? 'DIRECT';
        $browserPolicy = $currentPolicyValues['BROWSER_POLICY'] ?? 'DIRECT';
        $proxyUrl = $currentPolicyValues['PROXY_URL'] ?? '';
        $proxyUser = $currentPolicyValues['PROXY_USER'] ?? '';
        $proxyPass = $currentPolicyValues['PROXY_PASSWORD_B64'] ?? '';
        $pacUrl = $currentPolicyValues['PAC_URL'] ?? '';
        $mirrorPath = $currentPolicyValues['MIRROR_LOCAL_SEEDER_PATH'] ?? '/mirror/';
        $mirrorOmUrl = $currentPolicyValues['MIRROR_LOCAL_OM_URL'] ?? '';

        $proxyPolicies = [$aptPolicy, $cliPolicy, $browserPolicy];
        $needsProxyUrl = false;
        $needsPac = false;
        foreach ($proxyPolicies as $p) {
            if (in_array($p, ['PROXY', 'PROXY_NO_AUTH', 'PROXY_WITH_AUTH'], true)) $needsProxyUrl = true;
            if ($p === 'PAC') $needsPac = true;
        }
        if ($aptPolicy === 'MIRROR_LOCAL_OM') $needsProxyUrl = false;
        if ($aptPolicy === 'MIRROR_LOCAL_SEEDER' || $aptPolicy === 'MIRROR_OFFICIAL') $needsProxyUrl = false;

        if ($needsPac && $pacUrl === '') jsonError('PAC_URL e obrigatorio quando alguma policy = PAC', 400);

        if ($aptPolicy === 'MIRROR_LOCAL_OM' && $mirrorOmUrl === '') jsonError('MIRROR_LOCAL_OM_URL e obrigatorio quando APT_POLICY = MIRROR_LOCAL_OM', 400);
        if ($aptPolicy === 'MIRROR_LOCAL_SEEDER') {
            if ($mirrorPath === '' || $mirrorPath[0] !== '/' || substr($mirrorPath, -1) !== '/') {
                jsonError('MIRROR_LOCAL_SEEDER_PATH deve comecar e terminar com /', 400);
            }
        }

        $policyVarNames = ['APT_POLICY', 'CLI_POLICY', 'BROWSER_POLICY'];
        foreach ($variables as $varId => $value) {
            $varName = $definitionNamesById[(int)$varId] ?? '';
            if (in_array($varName, $policyVarNames, true) && in_array($value, ['PROXY_NO_AUTH', 'PROXY_WITH_AUTH'], true)) {
                $value = 'PROXY';
            }
            if (in_array($varName, $repositoryBooleanNames, true)) {
                $normalized = mirrorInputBoolean(['value' => $value], 'value');
                if ($normalized === null) jsonError('Valor booleano invalido para ' . $definitionNamesById[(int)$varId]);
                $value = mirrorDatabaseBoolean($normalized);
            }
            Database::execute(
                "UPDATE organization_variables SET value = ?, updated_at = CURRENT_TIMESTAMP
                 WHERE organization_id = ? AND variable_id = ?",
                [$value, $orgId, $varId]
            );
        }

        // Nao logar PROXY_PASSWORD_B64 em audit_events
        $safeChanged = array_values(array_filter($changedVariables, function($n) {
            return $n !== 'PROXY_PASSWORD_B64';
        }));
        log_audit('UPDATE', 'variables', null, [
            'organization_id' => $orgId,
            'organization_acronym' => $organization['acronym'] ?? null,
            'count' => count($variables),
            'changed_variables' => $safeChanged,
            'username' => $_SESSION['username'] ?? 'system',
            'full_name' => $_SESSION['full_name'] ?? null
        ], $orgId);
        jsonSuccess(null, 'Variaveis salvas com sucesso');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao atualizar variáveis: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

// OM PROXIES (multiplos proxies nomeados por OM)
function getOrgIdForProxyScope() {
    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && !isAdminGap()) return $userOrgId;
    return null;
}

function resolveProxyOrgId($input, $fallback = null) {
    $explicit = (int)($input['organization_id'] ?? 0);
    if ($explicit) {
        $userOrgId = getUserOrgId();
        if ($userOrgId !== null && !isAdminGap() && $explicit !== $userOrgId) {
            jsonError('Sem permissao', 403);
        }
        return $explicit;
    }
    if ($fallback) return (int)$fallback;
    $userOrgId = getUserOrgId();
    if ($userOrgId !== null) return $userOrgId;
    jsonError('organization_id obrigatorio', 400);
}

function handleGetOmProxies($orgId) {
    $resolvedOrgId = resolveProxyOrgId([], $orgId);
    try {
        $proxies = Database::fetchAll(
            "SELECT id, organization_id, name, url, username, pac_url, no_proxy, is_default, created_at
             FROM om_proxies WHERE organization_id = ? ORDER BY is_default DESC, name ASC",
            [$resolvedOrgId]
        );
        jsonSuccess($proxies);
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode(['success' => false, 'error' => 'Erro ao buscar proxies: ' . $e->getMessage()]);
        return;
    }
}

function handleCreateOmProxy($input) {
    $orgId = resolveProxyOrgId($input);
    $name = trim($input['name'] ?? '');
    $url = trim($input['url'] ?? '');
    $username = trim($input['username'] ?? '');
    $password = $input['password'] ?? '';
    $pacUrl = trim($input['pac_url'] ?? '');
    $noProxy = trim($input['no_proxy'] ?? '');
    $isDefault = !empty($input['is_default']);

    if ($name === '') jsonError('Nome do proxy e obrigatorio', 400);

    $existing = Database::fetchOne(
        "SELECT id FROM om_proxies WHERE organization_id = ? AND name = ?",
        [$orgId, $name]
    );
    if ($existing) jsonError('Ja existe um proxy com este nome nesta OM', 400);

    $passwordEnc = '';
    if ($password !== '') {
        $passwordEnc = base64_encode($password);
    }

    try {
        if ($isDefault) {
            Database::execute("UPDATE om_proxies SET is_default = false WHERE organization_id = ?", [$orgId]);
        }
        Database::execute(
            "INSERT INTO om_proxies (organization_id, name, url, username, password_enc, pac_url, no_proxy, is_default)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [$orgId, $name, $url, $username, $passwordEnc, $pacUrl, $noProxy, $isDefault]
        );
        $proxyId = (int)Database::lastInsertId();
        log_audit('CREATE', 'om_proxies', $proxyId, [
            'organization_id' => $orgId,
            'name' => $name,
            'username' => $_SESSION['username'] ?? 'system'
        ], $orgId);
        jsonSuccess(['id' => $proxyId], 'Proxy criado com sucesso');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode(['success' => false, 'error' => 'Erro ao criar proxy: ' . $e->getMessage()]);
        return;
    }
}

function handleUpdateOmProxy($id, $input) {
    $proxy = Database::fetchOne("SELECT * FROM om_proxies WHERE id = ?", [$id]);
    if (!$proxy) jsonError('Proxy nao encontrado', 404);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && !isAdminGap() && (int)$proxy['organization_id'] !== $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    $name = trim($input['name'] ?? $proxy['name']);
    $url = trim($input['url'] ?? $proxy['url']);
    $username = trim($input['username'] ?? $proxy['username']);
    $pacUrl = trim($input['pac_url'] ?? $proxy['pac_url']);
    $noProxy = trim($input['no_proxy'] ?? $proxy['no_proxy']);
    $isDefault = isset($input['is_default']) ? !empty($input['is_default']) : (bool)$proxy['is_default'];

    if ($name === '') jsonError('Nome do proxy e obrigatorio', 400);

    $conflict = Database::fetchOne(
        "SELECT id FROM om_proxies WHERE organization_id = ? AND name = ? AND id != ?",
        [$proxy['organization_id'], $name, $id]
    );
    if ($conflict) jsonError('Ja existe um proxy com este nome nesta OM', 400);

    $passwordEnc = $proxy['password_enc'];
    if (array_key_exists('password', $input) && $input['password'] !== '') {
        $passwordEnc = base64_encode($input['password']);
    }

    try {
        if ($isDefault && !(bool)$proxy['is_default']) {
            Database::execute("UPDATE om_proxies SET is_default = false WHERE organization_id = ?", [$proxy['organization_id']]);
        }
        Database::execute(
            "UPDATE om_proxies SET name = ?, url = ?, username = ?, password_enc = ?, pac_url = ?, no_proxy = ?, is_default = ? WHERE id = ?",
            [$name, $url, $username, $passwordEnc, $pacUrl, $noProxy, $isDefault, $id]
        );
        log_audit('UPDATE', 'om_proxies', $id, [
            'organization_id' => $proxy['organization_id'],
            'name' => $name,
            'username' => $_SESSION['username'] ?? 'system'
        ], $proxy['organization_id']);
        jsonSuccess(null, 'Proxy atualizado com sucesso');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode(['success' => false, 'error' => 'Erro ao atualizar proxy: ' . $e->getMessage()]);
        return;
    }
}

function handleDeleteOmProxy($id) {
    $proxy = Database::fetchOne("SELECT * FROM om_proxies WHERE id = ?", [$id]);
    if (!$proxy) jsonError('Proxy nao encontrado', 404);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && !isAdminGap() && (int)$proxy['organization_id'] !== $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    // Bloquear exclusao se proxy esta em uso por alguma policy
    $proxyName = $proxy['name'];
    $policyVars = Database::fetchAll(
        "SELECT vd.name, ov.value
         FROM organization_variables ov
         JOIN variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name IN ('APT_PROXY_NAME', 'CLI_PROXY_NAME', 'BROWSER_PROXY_NAME')",
        [$proxy['organization_id']]
    );
    foreach ($policyVars as $pv) {
        if ($pv['value'] === $proxyName) {
            jsonError('Proxy em uso pela policy ' . $pv['name'] . '. Altere a policy antes de excluir.', 400);
        }
    }

    try {
        Database::execute("DELETE FROM om_proxies WHERE id = ?", [$id]);
        log_audit('DELETE', 'om_proxies', $id, [
            'organization_id' => $proxy['organization_id'],
            'name' => $proxyName,
            'username' => $_SESSION['username'] ?? 'system'
        ], $proxy['organization_id']);
        jsonSuccess(null, 'Proxy excluido com sucesso');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode(['success' => false, 'error' => 'Erro ao excluir proxy: ' . $e->getMessage()]);
        return;
    }
}

function handleAddVariable($input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $name = strtoupper(sanitizeInput($input['name'] ?? ''));
    $type = sanitizeInput($input['type'] ?? 'text');
    $value = sanitizeInput($input['value'] ?? '');
    $description = sanitizeInput($input['description'] ?? '');
    $category = sanitizeInput($input['category'] ?? 'generic');
    $isRequired = isset($input['is_required']) && $input['is_required'] ? true : false;

    if (empty($name)) jsonError('Nome da variavel obrigatorio');

    if (Database::fetchOne("SELECT id FROM variable_definitions WHERE name = ?", [$name])) {
        jsonError('Variavel ja existe');
    }

    Database::execute(
        "INSERT INTO variable_definitions (name, description, type, category, is_required, default_value)
         VALUES (?, ?, ?, ?, ?, ?)",
        [$name, $description, $type, $category, $isRequired, $value]
    );

    $varId = (int)Database::lastInsertId();

    $orgs = Database::fetchAll("SELECT id FROM organizations WHERE is_active = true");
    foreach ($orgs as $org) {
        Database::execute(
            "INSERT INTO organization_variables (organization_id, variable_id, value) VALUES (?, ?, ?)",
            [$org['id'], $varId, $value]
        );
    }

    log_audit('CREATE', 'variable_definitions', $varId, ['name' => $name]);
    jsonSuccess(['id' => $varId], 'Variavel criada');
}

// SCRIPTS
function handleGetScripts($orgId) {
    $userOrgId = getUserOrgId();
    $isAdmin = isAdminGap();

    try {
        if ($userOrgId !== null && !$isAdmin) {
            $scripts = Database::fetchAll(
                "SELECT id, name, filename, description, is_core, is_active, organization_id, version, execution_order, created_at
                 FROM scripts
                 WHERE is_active = TRUE AND (is_core = TRUE OR organization_id = ?)
                 ORDER BY execution_order ASC, name",
                [$userOrgId]
            );
        } else {
            $scripts = Database::fetchAll(
                "SELECT id, name, filename, description, is_core, is_active, organization_id, version, execution_order, created_at
                 FROM scripts
                 WHERE is_active = TRUE
                 ORDER BY execution_order ASC, name"
            );
        }

        jsonSuccess($scripts);
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao buscar scripts: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function ensureOmScriptVersionSchema() {
    $columns = Database::fetchAll(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'om_script_versions'"
    );
    $existing = array_map(static fn($col) => $col['column_name'], $columns);

    if (!in_array('content', $existing, true)) {
        Database::execute('ALTER TABLE om_script_versions ADD COLUMN content TEXT');
    }
    if (!in_array('execution_order', $existing, true)) {
        Database::execute('ALTER TABLE om_script_versions ADD COLUMN execution_order INTEGER NOT NULL DEFAULT 0');
    }
    if (!in_array('is_active', $existing, true)) {
        Database::execute('ALTER TABLE om_script_versions ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT TRUE');
    }
    if (!in_array('version_number', $existing, true)) {
        Database::execute('ALTER TABLE om_script_versions ADD COLUMN version_number INTEGER NOT NULL DEFAULT 0');
    }
    if (!in_array('created_by', $existing, true)) {
        Database::execute('ALTER TABLE om_script_versions ADD COLUMN created_by INTEGER REFERENCES users(id)');
    }

    // Drop UNIQUE(organization_id, script_id) if it exists, to allow multiple versions
    $uniqueConstraint = Database::fetchOne(
        "SELECT constraint_name FROM information_schema.table_constraints
         WHERE table_name = 'om_script_versions' AND constraint_type = 'UNIQUE'
         AND constraint_name = 'om_script_versions_organization_id_script_id_key'"
    );
    if ($uniqueConstraint) {
        Database::execute('ALTER TABLE om_script_versions DROP CONSTRAINT om_script_versions_organization_id_script_id_key');
    }
}

function ensureFactoryVersionForScript($scriptId) {
    $script = Database::fetchOne('SELECT id, filename, content FROM scripts WHERE id = ?', [$scriptId]);
    if (!$script) return null;

    $existingFactory = Database::fetchOne(
        "SELECT id, version_number, content FROM script_versions
         WHERE script_id = ? AND version_type = 'factory'
         ORDER BY version_number DESC LIMIT 1",
        [$scriptId]
    );
    if ($existingFactory) {
        return $existingFactory;
    }

    $maxVersion = Database::fetchOne(
        "SELECT COALESCE(MAX(version_number), 0) AS max_v FROM script_versions WHERE script_id = ?",
        [$scriptId]
    );
    $nextVersion = (int)$maxVersion['max_v'] + 1;
    $versionName = ($script['filename'] ?: 'script') . ' - Factory v' . $nextVersion;

    Database::execute(
        "INSERT INTO script_versions (script_id, version_name, version_number, content, version_type, is_active, created_by)
         VALUES (?, ?, ?, ?, 'factory', true, ?)",
        [$scriptId, $versionName, $nextVersion, $script['content'] ?? '', $_SESSION['user_id'] ?? null]
    );

    $newVersionId = (int)Database::lastInsertId();
    Database::execute(
        "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        [$newVersionId, $script['content'] ?? '', $scriptId]
    );

    return Database::fetchOne('SELECT id, version_number, content FROM script_versions WHERE id = ?', [$newVersionId]);
}

function resolveScriptSourceMetadataForOrg($orgId, $scriptId) {
    $scriptId = (int)$scriptId;
    $orgId = (int)$orgId;

    $localRow = Database::fetchOne(
        "SELECT osv.version_id, osv.content, sv.version_number
         FROM om_script_versions osv
         LEFT JOIN script_versions sv ON sv.id = osv.version_id
         WHERE osv.organization_id = ? AND osv.script_id = ? AND osv.is_active = true
         ORDER BY osv.id DESC LIMIT 1",
        [$orgId, $scriptId]
    );

    // Check for local override: either has version_id reference OR direct content
    if ($localRow && (!empty($localRow['version_id']) || !empty($localRow['content']))) {
        return [
            'source_type' => 'local',
            'version_number' => (int)($localRow['version_number'] ?? 0),
        ];
    }

    $gapRow = Database::fetchOne(
        "SELECT version_number FROM script_versions
         WHERE script_id = ? AND version_type = 'gap_default' AND is_active = true
         ORDER BY version_number DESC LIMIT 1",
        [$scriptId]
    );

    if ($gapRow) {
        return [
            'source_type' => 'gap_default',
            'version_number' => (int)($gapRow['version_number'] ?? 0),
        ];
    }

    $factoryRow = Database::fetchOne(
        "SELECT version_number FROM script_versions
         WHERE script_id = ? AND version_type = 'factory'
         ORDER BY version_number DESC LIMIT 1",
        [$scriptId]
    );

    return [
        'source_type' => 'factory',
        'version_number' => (int)($factoryRow['version_number'] ?? 0),
    ];
}

function handleGetOrgScripts($orgId) {
    $orgId = (int)($orgId ?? 0);
    if (!$orgId) jsonError('organization_id obrigatorio', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    ensureOmScriptVersionSchema();

    $scripts = Database::fetchAll(
        "SELECT id, name, filename, description, is_core, is_active, execution_order, organization_id, content
         FROM scripts
         WHERE is_active = TRUE AND (is_core = TRUE OR organization_id = ?)
         ORDER BY execution_order ASC, name",
        [$orgId]
    );

    $rows = [];
    foreach ($scripts as $script) {
        $scriptId = (int)$script['id'];
        $local = Database::fetchOne(
            "SELECT content, execution_order, is_active, version_id
             FROM om_script_versions
             WHERE organization_id = ? AND script_id = ? AND is_active = true
             ORDER BY id DESC LIMIT 1",
            [$orgId, $scriptId]
        );

        $gapDefault = Database::fetchOne(
            "SELECT id, content, version_number
             FROM script_versions
             WHERE script_id = ? AND version_type = 'gap_default' AND is_active = true
             ORDER BY version_number DESC LIMIT 1",
            [$scriptId]
        );

        $factory = Database::fetchOne(
            "SELECT id, content, version_number
             FROM script_versions
             WHERE script_id = ? AND version_type = 'factory'
             ORDER BY version_number DESC LIMIT 1",
            [$scriptId]
        );

        $effectiveContent = $script['content'] ?? '';
        $effectiveOrder = (int)($script['execution_order'] ?? 0);
        $effectiveIsActive = (bool)($script['is_active'] ?? true);
        $sourceType = 'factory';
        $hasLocalOverride = false;

        if ($local) {
            $hasLocalOverride = true;
            $sourceType = 'local';
            $effectiveContent = $local['content'] ?? $effectiveContent;
            $effectiveOrder = (int)($local['execution_order'] ?? $effectiveOrder);
            $effectiveIsActive = true;
        } elseif ($gapDefault) {
            $sourceType = 'gap_default';
            $effectiveContent = $gapDefault['content'] ?? $effectiveContent;
            $effectiveOrder = (int)($script['execution_order'] ?? 0);
            $effectiveIsActive = true;
        } elseif ($factory) {
            $sourceType = 'factory';
            $effectiveContent = $factory['content'] ?? $effectiveContent;
            $effectiveOrder = (int)($script['execution_order'] ?? 0);
            $effectiveIsActive = true;
        }

        $rows[] = [
            'id' => $scriptId,
            'name' => $script['name'],
            'filename' => $script['filename'],
            'description' => $script['description'],
            'is_core' => (bool)$script['is_core'],
            'is_active' => $effectiveIsActive,
            'execution_order' => $effectiveOrder,
            'content' => $effectiveContent,
            'has_local_override' => $hasLocalOverride,
            'source_type' => $sourceType,
            'version' => $script['version'] ?? 1,
            'organization_id' => $orgId
        ];
    }

    jsonSuccess($rows);
}

function handleSaveScriptGapVersion($input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $scriptId = (int)($input['script_id'] ?? 0);
    $content = $input['content'] ?? '';
    $changelog = sanitizeInput($input['changelog'] ?? '');

    if (!$scriptId || empty($content)) jsonError('script_id e content obrigatorios', 400);

    $script = Database::fetchOne('SELECT id, name, filename FROM scripts WHERE id = ? AND is_core = TRUE', [$scriptId]);
    if (!$script) jsonError('Script core nao encontrado', 404);

    // Capture factory version from scripts.content BEFORE overwriting it.
    // ensureFactoryVersionForScript creates a factory version from scripts.content
    // if none exists yet. If we don't call this before the UPDATE below, the
    // factory version would be created from the modified content.
    ensureFactoryVersionForScript($scriptId);

    Database::execute(
        "UPDATE script_versions SET is_active = false WHERE script_id = ? AND version_type = 'gap_default'",
        [$scriptId]
    );

    $maxVersion = Database::fetchOne(
        "SELECT COALESCE(MAX(version_number), 0) AS max_v FROM script_versions WHERE script_id = ?",
        [$scriptId]
    );
    $nextVersion = (int)$maxVersion['max_v'] + 1;
    $versionName = ($script['filename'] ?: 'script') . ' - GAP Default v' . $nextVersion;

    Database::execute(
        "INSERT INTO script_versions (script_id, version_name, version_number, content, changelog, version_type, is_active, created_by)
         VALUES (?, ?, ?, ?, ?, 'gap_default', true, ?)",
        [$scriptId, $versionName, $nextVersion, $content, $changelog, $_SESSION['user_id'] ?? null]
    );

    $newVersionId = (int)Database::lastInsertId();
    Database::execute(
        "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        [$newVersionId, $content, $scriptId]
    );

    log_audit('UPDATE', 'script_versions', $scriptId, [
        'action' => 'save_gap_default',
        'script_name' => $script['name'] ?? $script['filename'],
        'filename' => $script['filename'],
        'new_version' => $nextVersion,
        'version' => $nextVersion,
        'scope' => 'gap_default',
        'script_id' => $scriptId,
        'author' => $_SESSION['username'] ?? 'system',
        'username' => $_SESSION['username'] ?? 'system',
        'full_name' => $_SESSION['full_name'] ?? null
    ]);

    jsonSuccess(['version_id' => $newVersionId, 'version_number' => $nextVersion], 'Versao GAP salva com sucesso');
}

function handleResetScriptFactory($input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $scriptId = (int)($input['script_id'] ?? 0);
    if (!$scriptId) jsonError('script_id obrigatorio', 400);

    $factoryVersion = ensureFactoryVersionForScript($scriptId);
    if (!$factoryVersion) {
        jsonError('Nenhuma versao de fabrica encontrada para este script', 404);
    }

    Database::execute(
        "UPDATE script_versions SET is_active = false WHERE script_id = ? AND version_type = 'gap_default'",
        [$scriptId]
    );
    Database::execute(
        "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        [$factoryVersion['id'], $factoryVersion['content'], $scriptId]
    );

    log_audit('UPDATE', 'scripts', $scriptId, [
        'action' => 'reset_factory',
        'version' => $factoryVersion['version_number'],
        'scope' => 'global',
        'author' => $_SESSION['username'] ?? 'system'
    ]);

    jsonSuccess(null, 'Script revertido para versao de fabrica');
}

function handleSaveScriptOmVersion($input) {
    ensureOmScriptVersionSchema();

    $scriptId = (int)($input['script_id'] ?? 0);
    $orgId = (int)($input['organization_id'] ?? $input['org_id'] ?? 0);
    $content = $input['content'] ?? '';
    $executionOrder = isset($input['execution_order']) ? (int)$input['execution_order'] : 0;
    $isActive = isset($input['is_active']) ? (bool)$input['is_active'] : true;
    $changelog = sanitizeInput($input['changelog'] ?? '');

    if (!$scriptId || !$orgId) jsonError('script_id e organization_id obrigatorios', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    $script = Database::fetchOne('SELECT id, filename, content, execution_order FROM scripts WHERE id = ?', [$scriptId]);
    if (!$script) jsonError('Script nao encontrado', 404);

    $effectiveContent = $content !== '' ? $content : ($script['content'] ?? '');
    $targetOrder = $executionOrder > 0 ? $executionOrder : (int)($script['execution_order'] ?? 0);

    // Deactivate existing active versions for this org/script
    Database::execute(
        "UPDATE om_script_versions SET is_active = false WHERE organization_id = ? AND script_id = ?",
        [$orgId, $scriptId]
    );

    // Compute next version number
    $maxV = Database::fetchOne(
        "SELECT COALESCE(MAX(version_number), 0) AS max_v FROM om_script_versions WHERE organization_id = ? AND script_id = ?",
        [$orgId, $scriptId]
    );
    $nextV = (int)$maxV['max_v'] + 1;

    // Insert new version row (preserving history)
    Database::execute(
        "INSERT INTO om_script_versions (organization_id, script_id, content, execution_order, is_active, version_number, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)",
        [$orgId, $scriptId, $effectiveContent, $targetOrder, $isActive ? TRUE : FALSE, $nextV, $_SESSION['user_id'] ?? null]
    );

    log_audit('UPDATE', 'om_script_versions', $scriptId, [
        'action' => 'save_om_override',
        'organization_id' => $orgId,
        'script_id' => $scriptId,
        'version_number' => $nextV,
        'is_active' => $isActive,
        'execution_order' => $targetOrder,
        'author' => $_SESSION['username'] ?? 'system'
    ]);

    jsonSuccess(['version_number' => $nextV, 'execution_order' => $targetOrder, 'is_active' => $isActive], 'Override local salvo com sucesso');
}

function handleResetScriptOmDefault($input) {
    $scriptId = (int)($input['script_id'] ?? 0);
    $orgId = (int)($input['organization_id'] ?? $input['org_id'] ?? 0);

    if (!$scriptId || !$orgId) jsonError('script_id e organization_id obrigatorios', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    // Only deactivate — do NOT null content or version_id, so history is preserved
    Database::execute(
        "UPDATE om_script_versions
         SET is_active = false
         WHERE organization_id = ? AND script_id = ?",
        [$orgId, $scriptId]
    );

    log_audit('UPDATE', 'om_script_versions', $scriptId, [
        'action' => 'reset_om_default',
        'organization_id' => $orgId,
        'script_id' => $scriptId,
        'is_active' => false,
        'author' => $_SESSION['username'] ?? 'system'
    ]);

    jsonSuccess(['is_active' => false], 'Override local desativado. Script volta a usar o padrao do servidor');
}

function handleDeleteScriptOmOverride($input) {
    jsonError('Endpoint descontinuado. Use reset-script-om-default', 410);
}

function handleGetOmScriptVersions($params) {
    $scriptId = (int)($params['script_id'] ?? 0);
    $orgId = (int)($params['organization_id'] ?? 0);

    if (!$scriptId || !$orgId) jsonError('script_id e organization_id obrigatorios', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    ensureOmScriptVersionSchema();

    $versions = Database::fetchAll(
        "SELECT osv.id, osv.version_number, osv.content, osv.execution_order, osv.is_active, osv.created_at,
                u.username as created_by_username
         FROM om_script_versions osv
         LEFT JOIN users u ON u.id = osv.created_by
         WHERE osv.organization_id = ? AND osv.script_id = ?
         ORDER BY osv.version_number DESC, osv.created_at DESC",
        [$orgId, $scriptId]
    );

    $script = Database::fetchOne('SELECT name, filename FROM scripts WHERE id = ?', [$scriptId]);

    jsonSuccess([
        'script' => $script,
        'versions' => $versions
    ]);
}

function handleReactivateOmVersion($input) {
    $versionId = (int)($input['version_id'] ?? 0);
    $orgId = (int)($input['organization_id'] ?? 0);
    $scriptId = (int)($input['script_id'] ?? 0);

    if (!$versionId || !$orgId || !$scriptId) {
        jsonError('version_id, organization_id e script_id obrigatorios', 400);
    }

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    $version = Database::fetchOne(
        "SELECT id, content, execution_order FROM om_script_versions WHERE id = ? AND organization_id = ? AND script_id = ?",
        [$versionId, $orgId, $scriptId]
    );
    if (!$version) jsonError('Versao nao encontrada', 404);

    // Deactivate all other versions for this org/script
    Database::execute(
        "UPDATE om_script_versions SET is_active = false WHERE organization_id = ? AND script_id = ?",
        [$orgId, $scriptId]
    );

    // Activate the selected version
    Database::execute(
        "UPDATE om_script_versions SET is_active = true WHERE id = ?",
        [$versionId]
    );

    log_audit('UPDATE', 'om_script_versions', $scriptId, [
        'action' => 'reactivate_om_version',
        'organization_id' => $orgId,
        'script_id' => $scriptId,
        'version_id' => $versionId,
        'author' => $_SESSION['username'] ?? 'system'
    ]);

    jsonSuccess(null, 'Versao local reativada com sucesso');
}

function handleDeleteOmVersion($input) {
    if (!isAdminGap()) jsonError('Sem permissao: apenas admin_gap pode deletar versoes', 403);

    $versionId = (int)($input['version_id'] ?? 0);
    $orgId = (int)($input['organization_id'] ?? 0);
    $scriptId = (int)($input['script_id'] ?? 0);

    if (!$versionId || !$orgId || !$scriptId) {
        jsonError('version_id, organization_id e script_id obrigatorios', 400);
    }

    $version = Database::fetchOne(
        "SELECT id, is_active FROM om_script_versions WHERE id = ? AND organization_id = ? AND script_id = ?",
        [$versionId, $orgId, $scriptId]
    );
    if (!$version) jsonError('Versao nao encontrada', 404);

    Database::execute(
        "DELETE FROM om_script_versions WHERE id = ?",
        [$versionId]
    );

    log_audit('DELETE', 'om_script_versions', $scriptId, [
        'action' => 'delete_om_version',
        'organization_id' => $orgId,
        'script_id' => $scriptId,
        'version_id' => $versionId,
        'author' => $_SESSION['username'] ?? 'system'
    ]);

    jsonSuccess(null, 'Versao local deletada');
}

function handleGetScript($id) {
    $script = Database::fetchOne(
        "SELECT id, name, filename, description, content, is_core, is_active, organization_id, version, created_at, updated_at
         FROM scripts WHERE id = ? AND is_active = TRUE",
        [$id]
    );

    if (!$script) jsonError('Script nao encontrado', 404);

    $userOrgId = getUserOrgId();
    if (!$script['is_core'] && $userOrgId !== null && $script['organization_id'] != $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    jsonSuccess($script);
}

function handleCreateScript($input) {
    $name = sanitizeInput($input['name'] ?? '');
    $filename = sanitizeInput($input['filename'] ?? '');
    $description = sanitizeInput($input['description'] ?? '');
    $content = $input['content'] ?? '';
    $isCore = isset($input['is_core']) && $input['is_core'] ? true : false;

    if (empty($name) || empty($filename)) jsonError('Nome e arquivo obrigatorios');

    $userOrgId = getUserOrgId();
    if (!$isCore && $userOrgId === null && !isAdminGap()) {
        jsonError('Sem permissao para criar scripts', 403);
    }

    if (Database::fetchOne("SELECT id FROM scripts WHERE filename = ?", [$filename])) {
        jsonError('Arquivo ja existe');
    }

    Database::execute(
        "INSERT INTO scripts (name, filename, description, content, is_core, organization_id, is_active)
         VALUES (?, ?, ?, ?, ?, ?, TRUE)",
        [$name, $filename, $description, $content, $isCore, $userOrgId ?: null]
    );

    $scriptId = (int)Database::lastInsertId();
    log_audit('CREATE', 'scripts', $scriptId, ['name' => $name, 'filename' => $filename]);
    jsonSuccess(['id' => $scriptId], 'Script criado');
}

function handleUpdateScript($id, $input) {
    $script = Database::fetchOne("SELECT id, is_core, organization_id, current_version_id FROM scripts WHERE id = ?", [$id]);
    if (!$script) jsonError('Script nao encontrado', 404);
    if ($script['is_core']) jsonError('Scripts core nao podem ser alterados diretamente. Use a sincronizacao do GitHub (sync-script).', 403);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $script['organization_id'] != $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    if ($script['current_version_id']) {
        $version = Database::fetchOne(
            "SELECT version_type FROM script_versions WHERE id = ?",
            [$script['current_version_id']]
        );
        if ($version && $version['version_type'] === 'factory') {
            jsonError('Versoes de fabrica nao podem ser editadas diretamente. Use a sincronizacao do GitHub (sync-script) para criar nova versao factory.', 403);
        }
    }

    $name = sanitizeInput($input['name'] ?? '');
    $description = sanitizeInput($input['description'] ?? '');
    $content = $input['content'] ?? '';

    if (empty($name)) jsonError('Nome obrigatorio');

    Database::execute(
        "UPDATE scripts SET name = ?, description = ?, content = ?, version = version + 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        [$name, $description, $content, $id]
    );

    log_audit('UPDATE', 'scripts', $id, ['name' => $name]);
    jsonSuccess(null, 'Script atualizado');
}

function handleCreateScriptVersion($input) {
    $scriptId = (int)($input['script_id'] ?? 0);
    $content = $input['content'] ?? '';
    $changelog = sanitizeInput($input['changelog'] ?? '');
    $scope = sanitizeInput($input['scope'] ?? 'gap_default');
    $orgId = isset($input['organization_id']) ? (int)$input['organization_id'] : null;

    if (!$scriptId || empty($content)) {
        jsonError('script_id e content obrigatorios', 400);
    }

    $script = Database::fetchOne("SELECT id, filename, is_core, organization_id FROM scripts WHERE id = ?", [$scriptId]);
    if (!$script) jsonError('Script nao encontrado', 404);

    if (!in_array($scope, ['gap_default', 'om_specific'], true)) {
        jsonError('Escopo invalido', 400);
    }

    $userOrgId = getUserOrgId();
    if ($scope === 'om_specific') {
        if (($orgId === null || $orgId <= 0) && $userOrgId === null && !isAdminGap()) {
            jsonError('Organizacao obrigatoria para esta versao', 400);
        }
        $orgId = $orgId ?: $userOrgId;
        if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
            jsonError('Sem permissao', 403);
        }
    } elseif ($scope === 'gap_default' && !isAdminGap()) {
        jsonError('Sem permissao para salvar versao GAP', 403);
    }

    $lastVersion = Database::fetchOne(
        "SELECT COALESCE(MAX(version_number), 0) AS max_v FROM script_versions WHERE script_id = ?",
        [$scriptId]
    );
    $nextVersion = (int)$lastVersion['max_v'] + 1;
    $versionName = $script['filename'] . ' - ' . ($scope === 'gap_default' ? 'GAP Default' : 'OM Especifica') . ' v' . $nextVersion;

    if ($scope === 'gap_default') {
        // Capture factory version from scripts.content BEFORE overwriting it.
        ensureFactoryVersionForScript($scriptId);

        Database::execute(
            "UPDATE script_versions SET is_active = false WHERE script_id = ? AND version_type = 'gap_default'",
            [$scriptId]
        );
    } else {
        Database::execute(
            "UPDATE script_versions SET is_active = false WHERE script_id = ? AND version_type = 'om_specific' AND organization_id = ?",
            [$scriptId, $orgId]
        );
    }

    $userId = $_SESSION['user_id'] ?? null;
    Database::execute(
        "INSERT INTO script_versions (script_id, version_name, version_number, content, changelog, version_type, organization_id, is_active, created_by)
         VALUES (?, ?, ?, ?, ?, ?, ?, true, ?)",
        [$scriptId, $versionName, $nextVersion, $content, $changelog, $scope, $orgId, $userId]
    );

    $newVersionId = (int)Database::lastInsertId();

    if ($scope === 'om_specific') {
        ensureOmScriptVersionSchema();

        $existingOrder = (int)($script['execution_order'] ?? 0);

        Database::execute(
            "UPDATE om_script_versions SET is_active = false WHERE organization_id = ? AND script_id = ?",
            [$orgId, $scriptId]
        );

        $maxOsvV = Database::fetchOne(
            "SELECT COALESCE(MAX(version_number), 0) AS max_v FROM om_script_versions WHERE organization_id = ? AND script_id = ?",
            [$orgId, $scriptId]
        );
        $nextOsvV = (int)$maxOsvV['max_v'] + 1;

        Database::execute(
            "INSERT INTO om_script_versions (organization_id, script_id, version_id, content, execution_order, is_active, version_number, created_by, created_at)
             VALUES (?, ?, ?, ?, ?, true, ?, ?, CURRENT_TIMESTAMP)",
            [$orgId, $scriptId, $newVersionId, $content, $existingOrder, $nextOsvV, $userId]
        );
    }

    if ($scope === 'gap_default') {
        $factoryLatest = Database::fetchOne(
            "SELECT id, content FROM script_versions WHERE script_id = ? AND version_type = 'factory' ORDER BY version_number DESC LIMIT 1",
            [$scriptId]
        );
        $currentContent = ($factoryLatest && empty($content)) ? $factoryLatest['content'] : $content;

        Database::execute(
            "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            [$newVersionId, $currentContent, $scriptId]
        );
    }



    log_audit('UPDATE', 'script_versions', $scriptId, [
        'action' => 'save_' . $scope,
        'version' => $nextVersion,
        'scope' => $scope,
        'organization_id' => $orgId,
        'script_id' => $scriptId,
        'author' => $_SESSION['username'] ?? 'system'
    ]);
    jsonSuccess(['version_id' => $newVersionId, 'version_number' => $nextVersion], 'Nova versao salva com sucesso');
}


function handleDeleteScript($id) {
    $script = Database::fetchOne("SELECT id, is_core, organization_id, name FROM scripts WHERE id = ?", [$id]);
    if (!$script) jsonError('Script nao encontrado', 404);
    if ($script['is_core']) jsonError('Scripts core nao podem ser excluidos', 403);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $script['organization_id'] != $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    Database::execute("UPDATE scripts SET is_active = FALSE WHERE id = ?", [$id]);
    log_audit('DELETE', 'scripts', $id, ['name' => $script['name']]);
    jsonSuccess(null, 'Script excluido');
}

function handleUploadScript() {
    $userOrgId = getUserOrgId();
    if ($userOrgId === null && !isAdminGap()) jsonError('Sem permissao', 403);

    if (!isset($_FILES['script']) || $_FILES['script']['error'] !== UPLOAD_ERR_OK) {
        jsonError('Nenhum arquivo enviado', 400);
    }

    $file = $_FILES['script'];
    $name = sanitizeInput($_POST['name'] ?? pathinfo($file['name'], PATHINFO_FILENAME));
    $description = sanitizeInput($_POST['description'] ?? '');
    $isCore = isset($_POST['is_core']) && $_POST['is_core'] ? true : false;

    if ($file['size'] > 500 * 1024) jsonError('Arquivo muito grande (max 500KB)', 400);

    $content = file_get_contents($file['tmp_name']);
    $filename = sanitizeInput($file['name']);

    if (Database::fetchOne("SELECT id FROM scripts WHERE filename = ?", [$filename])) {
        jsonError('Arquivo ja existe');
    }

    Database::execute(
        "INSERT INTO scripts (name, filename, description, content, is_core, organization_id, is_active)
         VALUES (?, ?, ?, ?, ?, ?, TRUE)",
        [$name, $filename, $description, $content, $isCore, $userOrgId]
    );

    $scriptId = (int)Database::lastInsertId();
    log_audit('UPLOAD', 'scripts', $scriptId, ['name' => $name, 'filename' => $filename]);
    log_event("Script criado: $filename (id=$scriptId)", 'INFO');
    jsonSuccess(['id' => $scriptId, 'filename' => $filename], 'Script enviado');
}

// BUNDLE
function handleGenerateBundle($input) {
    $orgId = (int)($input['organization_id'] ?? 0);
    $selectedScripts = $input['scripts'] ?? [];
    $description = sanitizeInput($input['description'] ?? '');

    if (!$orgId) jsonError('Organization ID required');

    // Verificar escopo: operador_om não pode acessar dados de outra OM
    $user = getCurrentUser();
    if ($user && $user['role'] === 'operador_om' && $orgId != $user['organization_id']) {
        http_response_code(403);
        echo json_encode(['success' => false, 'error' => 'Acesso negado']);
        return;
    }

    try {
        $org = Database::fetchOne("SELECT id, acronym, domain, serial_config FROM organizations WHERE id = ?", [$orgId]);
        if (!$org) jsonError('Organizacao nao encontrada', 404);

        // Bump serial BEFORE generating bundle content so the header
        // carries the new serial, not the old one.
        $newSerial = bumpOrgSerial($orgId);
        $org['serial_config'] = $newSerial;

        // Sanitizar URLs dinâmicas baseadas na sigla da OM
        $org = sanitize_org_urls($org);

    $vars = Database::fetchAll(
        "SELECT vd.name, vd.type, COALESCE(ov.value, vd.default_value, '') AS value
         FROM variable_definitions vd
         LEFT JOIN organization_variables ov
           ON ov.variable_id = vd.id AND ov.organization_id = ?
         WHERE vd.category <> 'oculto'",
        [$orgId]
    );

    if (empty($selectedScripts)) {
        $scripts = Database::fetchAll(
            "SELECT s.id, s.name, s.filename, s.content, s.is_core,
                    COALESCE(osv.execution_order, s.execution_order) AS execution_order,
                    COALESCE(osv.is_active, TRUE) AS om_is_active
             FROM scripts s
             LEFT JOIN om_script_versions osv ON osv.organization_id = ? AND osv.script_id = s.id AND osv.is_active = TRUE
             WHERE s.is_active = TRUE AND (s.is_core = TRUE OR s.organization_id = ?)
             AND COALESCE(osv.is_active, TRUE) = TRUE
             ORDER BY COALESCE(osv.execution_order, s.execution_order) ASC, s.name",
            [$orgId, $orgId]
        );
    } else {
        $selectedScripts = array_map('intval', $selectedScripts);
        $placeholders = implode(',', array_fill(0, count($selectedScripts), '?'));
        $params = array_merge($selectedScripts, [$orgId, $orgId]);
        $scripts = Database::fetchAll(
            "SELECT s.id, s.name, s.filename, s.content, s.is_core,
                    COALESCE(osv.execution_order, s.execution_order) AS execution_order,
                    COALESCE(osv.is_active, TRUE) AS om_is_active
             FROM scripts s
             LEFT JOIN om_script_versions osv ON osv.organization_id = ? AND osv.script_id = s.id AND osv.is_active = TRUE
             WHERE s.is_active = TRUE AND (s.is_core = TRUE OR (s.id IN ($placeholders) AND s.organization_id = ?))
             AND COALESCE(osv.is_active, TRUE) = TRUE
             ORDER BY COALESCE(osv.execution_order, s.execution_order) ASC, s.name",
            $params
        );
    }

    // Todos os 23 scripts Core são incluídos no bundle.
    // Cada script de sessão (lightdm, gdm3, sddm) decide internamente se executa ou não.

    $bundle = "#!/bin/bash\n";
    $bundle .= "# ============================================\n";
    $bundle .= "# SeederLinux Lite Bundle\n";
    $bundle .= "# ============================================\n";
    $bundle .= "# Organizacao: {$org['acronym']}\n";
    $bundle .= "# Gerado em: " . date('Y-m-d H:i:s') . "\n";
    $bundle .= "# Serial: {$org['serial_config']}\n";
    $bundle .= "# Scripts: " . count($scripts) . "\n";
    $bundle .= "# ============================================\n\n";

    $bundle .= "# Verificar root\n";
    $bundle .= "if [ \"\$(id -u)\" -ne 0 ]; then\n";
    $bundle .= "    echo \"ERRO: Este script deve ser executado como root (sudo).\"\n";
    $bundle .= "    exit 1\n";
    $bundle .= "fi\n\n";

    $skipExportTypes = ['password'];
    $skipExportNames = ['INSTALL_DESKTOP'];
    // Variaveis legadas do modelo single-proxy: continuam no banco mas nao sao exportadas em bundles novos
    $deprecatedProxyVars = ['PROXY_MODE', 'PROXY_URL', 'PROXY_USER', 'PROXY_PASSWORD_B64', 'PROXY_HTTP', 'PROXY_PORTA', 'PAC_URL', 'NO_PROXY'];
    $imageVars = ['WALLPAPER_URL', 'LOGO_URL', 'WALLPAPER_LOGIN_URL', 'GREETER_URL'];
    $baseUrl = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off' ? 'https' : 'http') . '://' . ($_SERVER['HTTP_HOST'] ?? $_SERVER['SERVER_NAME'] ?? '');
    // Always use SEEDER_SERVER FQDN for URLs in the bundle
    $seederServerRow = Database::fetchOne(
        "SELECT ov.value FROM organization_variables ov
         JOIN variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name = 'SEEDER_SERVER'",
        [$orgId]
    );
    $seederServer = $seederServerRow['value'] ?? '';
    if ($seederServer) {
        $baseUrl = rtrim($seederServer, '/');
    }
    
    // Sanitizar URLs, NTP e prefixar imagens antes de exportar
    // $baseUrl vem do SEEDER_SERVER configurado pela OM; fallback apenas se vazio/invalido
    $dominioRow = Database::fetchOne(
        "SELECT ov.value FROM organization_variables ov
         JOIN variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name = 'DOMINIO'",
        [$orgId]
    );
    $dominio = strtolower(trim($dominioRow['value'] ?? ''));
    $sigla = strtolower($org['acronym'] ?? '');
    $fallbackBaseUrl = $dominio ? "https://seederlinux.$dominio" : "https://seederlinux.$sigla.intraer";
    if (empty($baseUrl) || strpos($baseUrl, 'om.local') !== false || strpos($baseUrl, 'softwarelivre') !== false) {
        $baseUrl = $fallbackBaseUrl;
    }

    foreach ($vars as &$v) {
        $name = $v['name'] ?? '';
        $val = $v['value'] ?? '';

        // URLs do servidor
        if (in_array($name, ['BASE_URL', 'SEEDER_SERVER', 'REPOSITORY_URL'], true)) {
            if (empty($val) || strpos($val, 'softwarelivre') !== false || strpos($val, 'om.local') !== false || strpos($val, ' ') !== false) {
                $v['value'] = $baseUrl;
            }
        }

        // NTP_SERVER: remover protocolo
        if ($name === 'NTP_SERVER') {
            $v['value'] = preg_replace('#^https?://#', '', $val);
        }

        // DC_IP_LIST: montar automaticamente a partir de DC_IP e DC_SECUNDARIO_IP
        if ($name === 'DC_IP_LIST') {
            $legacyValue = preg_replace('/\s+/', '', strtolower(trim((string)$val)));
            $legacyDefaults = ['10.0.0.1,10.0.0.2', '10.0.0.2,10.0.0.1'];
            $needsAutoBuild = $val === '' || in_array($legacyValue, $legacyDefaults, true);

            if ($needsAutoBuild) {
                $dcIp = '';
                $dcSecIp = '';
                foreach ($vars as $candidateVar) {
                    if (($candidateVar['name'] ?? '') === 'DC_IP') {
                        $dcIp = trim((string)($candidateVar['value'] ?? ''));
                    }
                    if (($candidateVar['name'] ?? '') === 'DC_SECUNDARIO_IP') {
                        $dcSecIp = trim((string)($candidateVar['value'] ?? ''));
                    }
                }
                $ipList = array_values(array_unique(array_filter([$dcIp, $dcSecIp], fn($ip) => $ip !== '')));
                $v['value'] = implode(',', $ipList);
            } else {
                $parts = preg_split('/[\s,]+/', trim((string)$val));
                $uniqueParts = array_values(array_unique(array_filter($parts, fn($ip) => $ip !== '')));
                $v['value'] = implode(',', $uniqueParts);
            }
        }

        // SSH_GROUPS: remover espacos extras, garantir separacao por virgula, remover caracteres invalidos
        if ($name === 'SSH_GROUPS') {
            $cleaned = preg_replace('/[^a-zA-Z0-9_,]/', '', $val);
            $parts = array_filter(array_map('trim', explode(',', $cleaned)), fn($p) => $p !== '');
            $v['value'] = implode(',', $parts);
        }

        // HOMEPAGE: remover espacos nas extremidades e normalizar espacos internos (sem forcar protocolo)
        if ($name === 'HOMEPAGE') {
            $v['value'] = trim(preg_replace('/\s+/', ' ', $val));
        }

        // Imagens: remover tripla barra e prefixar com SEEDER_SERVER se for relativa
        if (in_array($name, ['WALLPAPER_URL', 'WALLPAPER_LOGIN_URL', 'LOGO_URL', 'GREETER_URL'], true)) {
            // Remove http:/// ou https:/// (tripla barra)
            if (strpos($val, 'http:///') === 0 || strpos($val, 'https:///') === 0) {
                $val = substr($val, strpos($val, '/', 8)); // remove o prefixo
            }
            // Se for relativa (começa com /), transforma em absoluta
            if ($val !== '' && $val[0] === '/') {
                $val = rtrim($baseUrl, '/') . $val;
            }
            $v['value'] = $val;
        }
    }
    unset($v);

    $scriptMetadata = [];
    foreach ($scripts as $index => $s) {
        $scriptId = (int)($s['id'] ?? 0);
        $sourceMeta = resolveScriptSourceMetadataForOrg($orgId, $scriptId);

        $scriptMetadata[] = [
            'order' => $index + 1,
            'filename' => $s['filename'] ?? '',
            'origin' => $sourceMeta['source_type'],
            'version' => (int)($sourceMeta['version_number'] ?? 0),
        ];
    }

    $bundle .= "# === VARIAVEIS ===\n";
    $bundle .= "# ============================================\n";
    $bundle .= "# SCRIPTS INCLUÍDOS NESTE BUNDLE\n";
    $bundle .= "# ============================================\n";
    foreach ($scriptMetadata as $meta) {
        $bundle .= "# {$meta['order']}. {$meta['filename']} | Origem: {$meta['origin']} | Versão: {$meta['version']}\n";
    }
    $bundle .= "# ============================================\n\n";
    $bundle .= "export NON_INTERACTIVE=true\n";
    foreach ($vars as $v) {
        if (in_array($v['type'], $skipExportTypes, true)) continue;
        if (in_array($v['name'], $skipExportNames, true)) continue;
        if (in_array($v['name'], $deprecatedProxyVars, true)) continue;
        $varValue = $v['value'] ?? '';
        // Prefix relative paths with SEEDER_SERVER for image/branding URLs
        if (in_array($v['name'], $imageVars, true) && !empty($varValue) && strpos($varValue, 'http') !== 0) {
            $varValue = $baseUrl . '/' . ltrim($varValue, '/');
        }
        $bundle .= "export {$v['name']}='" . str_replace("'", "'\\''", $varValue) . "'\n";
    }
    $bundle .= "\n";

    $bundle .= "# === SCRIPTS ===\n\n";
    $scriptIds = [];

    // Inject the stored base64 value into the domain script for local decoding
    $adminPwdRow = Database::fetchOne(
        "SELECT ov.value FROM organization_variables ov
         JOIN variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name = 'ADMIN_PASSWORD_B64'",
        [$orgId]
    );
    $adminPwdEncoded = $adminPwdRow['value'] ?? '';

    // Inject the stored base64 value into the VNC script for local decoding
    $vncPwdRow = Database::fetchOne(
        "SELECT ov.value FROM organization_variables ov
         JOIN variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name = 'VNC_PASSWORD_B64'",
        [$orgId]
    );
    $vncPwdEncoded = $vncPwdRow['value'] ?? '';

    // Inject the stored base64 value for proxy password
    $proxyPwdRow = Database::fetchOne(
        "SELECT ov.value FROM organization_variables ov
         JOIN variable_definitions vd ON vd.id = ov.variable_id
         WHERE ov.organization_id = ? AND vd.name = 'PROXY_PASSWORD_B64'",
        [$orgId]
    );
    $proxyPwdEncoded = $proxyPwdRow['value'] ?? '';

    // Fetch named proxies for this OM (om_proxies table)
    $omProxies = Database::fetchAll(
        "SELECT name, url, username, password_enc, pac_url, no_proxy, is_default
         FROM om_proxies WHERE organization_id = ? ORDER BY is_default DESC, name ASC",
        [$orgId]
    );

    // Export proxy list in the header
    $bundle .= "export PROXY_COUNT='" . count($omProxies) . "'\n";
    $defaultProxyName = '';
    foreach ($omProxies as $p) {
        if ($p['is_default']) { $defaultProxyName = $p['name']; break; }
    }
    $bundle .= "export PROXY_DEFAULT_NAME='" . str_replace("'", "'\\''", $defaultProxyName) . "'\n";
    $proxyIdx = 1;
    foreach ($omProxies as $p) {
        $bundle .= "export PROXY_{$proxyIdx}_NAME='" . str_replace("'", "'\\''", $p['name']) . "'\n";
        $bundle .= "export PROXY_{$proxyIdx}_URL='" . str_replace("'", "'\\''", $p['url'] ?? '') . "'\n";
        $bundle .= "export PROXY_{$proxyIdx}_USER='" . str_replace("'", "'\\''", $p['username'] ?? '') . "'\n";
        $bundle .= "export PROXY_{$proxyIdx}_PASS_B64='__PROXY_{$proxyIdx}_PASS_B64__'\n";
        $bundle .= "export PROXY_{$proxyIdx}_PAC_URL='" . str_replace("'", "'\\''", $p['pac_url'] ?? '') . "'\n";
        $bundle .= "export PROXY_{$proxyIdx}_NO_PROXY='" . str_replace("'", "'\\''", $p['no_proxy'] ?? '') . "'\n";
        $proxyIdx++;
    }
    $bundle .= "\n";

    foreach ($scripts as $s) {
        $rawContent = getScriptContent((int)$s['id'], $orgId);
        $scriptContent = substituir_placeholders($rawContent, $orgId);
        $scriptContent = str_replace('__ADMIN_PASSWORD_B64__', $adminPwdEncoded, $scriptContent);
        $scriptContent = str_replace('__VNC_PASSWORD_B64__', $vncPwdEncoded, $scriptContent);
        $scriptContent = str_replace('__PROXY_PASSWORD_B64__', $proxyPwdEncoded, $scriptContent);
        // Substitute per-proxy password placeholders
        $pi = 1;
        foreach ($omProxies as $p) {
            $scriptContent = str_replace("__PROXY_{$pi}_PASS_B64__", $p['password_enc'] ?? '', $scriptContent);
            $pi++;
        }
        // Clean up any remaining __*__ placeholders that weren't resolved
        $scriptContent = preg_replace('/__[A-Z_0-9]+__/', '', $scriptContent);
        $bundle .= "# --- {$s['name']} ({$s['filename']}) ---\n";
        $bundle .= $scriptContent . "\n\n";
        $scriptIds[] = $s['id'];
    }

    $bundle .= "# === FIM DO BUNDLE ===\n";
    $bundle .= "echo 'Bundle executado com sucesso!'\n";

    $validPlaceholders = array_column(
        Database::fetchAll("SELECT placeholder FROM variable_definitions"),
        'placeholder'
    );
    if (preg_match_all('/\{\{([A-Z_]+)\}\}/', $bundle, $matches)) {
        $unresolved = [];
        foreach (array_unique($matches[1]) as $placeholder) {
            if (in_array($placeholder, $validPlaceholders, true)) {
                $unresolved[] = '{{' . $placeholder . '}}';
            }
        }
        if (!empty($unresolved)) {
            jsonError('Placeholders nao resolvidos: ' . implode(', ', $unresolved), 400);
        }
    }

    $filename = "bundle_{$org['acronym']}_" . date('Ymd_His') . ".sh";
    $userId = $_SESSION['user_id'] ?? null;

    Database::execute(
        "INSERT INTO deploy_bundles (organization_id, user_id, filename, description, content, script_ids, scripts_count, generated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)",
        [$orgId, $userId, $filename, $description, $bundle, json_encode($scriptIds), count($scripts)]
    );

    $bundleId = (int)Database::lastInsertId();

    // Desativar bundles anteriores desta organizacao
    Database::execute(
        "UPDATE deploy_bundles SET is_active = FALSE WHERE organization_id = ? AND id != ?",
        [$orgId, $bundleId]
    );

        log_audit('GENERATE', 'bundles', $bundleId, [
            'organization' => $org['acronym'],
            'organization_acronym' => $org['acronym'],
            'scripts' => count($scripts),
            'username' => $_SESSION['username'] ?? 'system',
            'full_name' => $_SESSION['full_name'] ?? null
        ]);
        log_event("Bundle gerado: {$org['acronym']} (id=$bundleId, scripts=" . count($scripts) . ")", 'INFO');

        jsonSuccess([
            'bundle_id' => $bundleId,
            'filename' => $filename,
            'download_url' => "/api/?action=bundle-by-id&id={$bundleId}",
            'scripts_count' => count($scripts)
        ], 'Bundle gerado com sucesso');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao gerar bundle: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function handleDownloadBundle($id) {
    $stationAuth = requireStationAuth();
    if ($stationAuth) {
        $bundle = Database::fetchOne("SELECT id, organization_id, filename, content FROM deploy_bundles WHERE id = ?", [$id]);
        if (!$bundle) jsonError('Bundle nao encontrado', 404);

        $stationOrgId = (int)($_REQUEST['station_org_id'] ?? 0);
        if ($stationOrgId > 0 && (int)$bundle['organization_id'] !== $stationOrgId) {
            jsonError('Sem permissao', 403);
        }
    } else {
        requireAuth();
        $bundle = Database::fetchOne("SELECT id, organization_id, filename, content FROM deploy_bundles WHERE id = ?", [$id]);
        if (!$bundle) jsonError('Bundle nao encontrado', 404);

        $userOrgId = getUserOrgId();
        if ($userOrgId !== null && !isAdminGap() && (int)$bundle['organization_id'] !== $userOrgId) {
            jsonError('Sem permissao', 403);
        }
    }

    header('Content-Type: application/octet-stream');
    header('Content-Disposition: attachment; filename="' . $bundle['filename'] . '"');
    header('Content-Length: ' . strlen($bundle['content']));
    echo $bundle['content'];
    exit;
}

// USERS
function handleGetUsers() {
    if (!isAdminGap() && !isAuditor()) jsonError('Sem permissao', 403);

    $users = Database::fetchAll(
        "SELECT u.id, u.username, u.full_name, u.email, u.role, u.is_active, u.organization_id, u.created_at,
                o.acronym as org_acronym
         FROM users u
         LEFT JOIN organizations o ON o.id = u.organization_id
         ORDER BY u.username"
    );

    jsonSuccess($users);
}

function handleCreateUser($input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $username = sanitizeInput($input['username'] ?? '');
    $password = $input['password'] ?? '';
    $confirmPassword = $input['confirm_password'] ?? '';
    $fullName = sanitizeInput($input['full_name'] ?? '');
    $email = sanitizeInput($input['email'] ?? '');
    $role = sanitizeInput($input['role'] ?? 'operador_om');
    $organizationId = $input['organization_id'] ?? null;

    if (empty($username) || empty($password)) jsonError('Username e senha obrigatorios');
    if ($password !== $confirmPassword) jsonError('Senhas nao conferem');
    if (strlen($password) < 6) jsonError('Senha deve ter no minimo 6 caracteres');

    if (Database::fetchOne("SELECT id FROM users WHERE username = ?", [$username])) {
        jsonError('Username ja existe');
    }

    $passwordHash = password_hash($password, PASSWORD_DEFAULT);

    Database::execute(
        "INSERT INTO users (username, password_hash, full_name, email, role, organization_id)
         VALUES (?, ?, ?, ?, ?, ?)",
        [$username, $passwordHash, $fullName, $email, $role, $organizationId ?: null]
    );

    $userId = (int)Database::lastInsertId();
    log_audit('CREATE', 'users', $userId, ['username' => $username, 'role' => $role]);

    jsonSuccess(['id' => $userId], 'Usuario criado');
}

function handleUpdateUser($id, $input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $username = sanitizeInput($input['username'] ?? '');
    $fullName = sanitizeInput($input['full_name'] ?? '');
    $email = sanitizeInput($input['email'] ?? '');
    $role = sanitizeInput($input['role'] ?? 'operador_om');
    $organizationId = $input['organization_id'] ?? null;
    $password = $input['password'] ?? '';
    $confirmPassword = $input['confirm_password'] ?? '';

    if (empty($username)) jsonError('Username obrigatorio');
    if ($password && $password !== $confirmPassword) jsonError('Senhas nao conferem');

    if ($password) {
        if (strlen($password) < 6) jsonError('Senha deve ter no minimo 6 caracteres');
        $passwordHash = password_hash($password, PASSWORD_DEFAULT);
        Database::execute(
            "UPDATE users SET username = ?, full_name = ?, email = ?, role = ?, organization_id = ?, password_hash = ? WHERE id = ?",
            [$username, $fullName, $email, $role, $organizationId ?: null, $passwordHash, $id]
        );
    } else {
        Database::execute(
            "UPDATE users SET username = ?, full_name = ?, email = ?, role = ?, organization_id = ? WHERE id = ?",
            [$username, $fullName, $email, $role, $organizationId ?: null, $id]
        );
    }

    log_audit('UPDATE', 'users', $id, [
        'username' => $username,
        'full_name' => $fullName,
        'password_changed' => (bool)$password,
        'author' => $_SESSION['username'] ?? 'system'
    ]);
    jsonSuccess(null, 'Usuario atualizado');
}

function handleDeleteUser($id) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $user = Database::fetchOne("SELECT username FROM users WHERE id = ?", [$id]);
    if (!$user) jsonError('Usuario nao encontrado', 404);

    Database::execute("UPDATE users SET is_active = FALSE WHERE id = ?", [$id]);
    log_audit('DELETE', 'users', $id, ['username' => $user['username']]);
    jsonSuccess(null, 'Usuario excluido');
}

function handleToggleUserStatus($id) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $user = Database::fetchOne("SELECT is_active, username FROM users WHERE id = ?", [$id]);
    if (!$user) jsonError('Usuario nao encontrado', 404);

    $newStatus = !$user['is_active'];
    Database::execute("UPDATE users SET is_active = ? WHERE id = ?", [$newStatus, $id]);
    log_audit($newStatus ? 'ACTIVATE' : 'DEACTIVATE', 'users', $id, ['username' => $user['username']]);
    jsonSuccess(null, $newStatus ? 'Usuario ativado' : 'Usuario desativado');
}

// STATIONS
function handleGetStations($orgId) {
    $userOrgId = getUserOrgId();
    $isAdmin = isAdminGap();

    $where = "1=1";
    $params = [];

    if ($userOrgId !== null && !$isAdmin) {
        $where .= " AND s.organization_id = ?";
        $params[] = $userOrgId;
    } elseif ($orgId) {
        $where .= " AND s.organization_id = ?";
        $params[] = $orgId;
    }

    try {
        // Paginação
        $page = max(1, (int)($_GET['page'] ?? 1));
        $limit = min(100, max(10, (int)($_GET['limit'] ?? 20)));
        $offset = ($page - 1) * $limit;

        // Contar total de estações
        $countResult = Database::fetchOne(
            "SELECT COUNT(*) as total FROM stations s WHERE {$where}",
            $params
        );
        $total = $countResult['total'] ?? 0;

        // Adicionar parâmetros de timestamp para status
        $twoHoursAgo = date('Y-m-d H:i:s', strtotime('-2 hours'));
        $statusParams = [$twoHoursAgo, $twoHoursAgo];

        $stations = Database::fetchAll(
            "SELECT s.id, s.hostname, s.ip_address, s.mac_address, s.os_name, s.os_version,
                    s.last_checkin, s.serial_aplicado, s.organization_id, o.acronym as org_acronym,
                    o.serial_config,
                    CASE
                        WHEN s.last_checkin >= ? THEN 'online'
                        WHEN s.last_checkin < ? AND s.last_checkin IS NOT NULL THEN 'delayed'
                        WHEN s.last_checkin IS NULL THEN 'never'
                        ELSE 'unknown'
                    END as connection_status,
                    CASE
                        WHEN s.serial_aplicado >= o.serial_config THEN 'updated'
                        ELSE 'outdated'
                    END as config_status
             FROM stations s
             JOIN organizations o ON o.id = s.organization_id
             WHERE {$where}
             ORDER BY s.last_checkin DESC NULLS LAST
             LIMIT ? OFFSET ?",
            array_merge($statusParams, $params, [$limit, $offset])
        );

        $metadata = [
            'total' => $total,
            'page' => $page,
            'limit' => $limit,
            'pages' => (int)ceil($total / $limit)
        ];

        jsonSuccess(['stations' => $stations, 'pagination' => $metadata]);
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao buscar estações: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function handleStationCheckin($input) {
    $hostname = sanitizeInput($input['hostname'] ?? '');
    $ipAddress = sanitizeInput($input['ip_address'] ?? '');
    $macAddress = sanitizeInput($input['mac_address'] ?? '');
    $osName = sanitizeInput($input['os_name'] ?? '');
    $osVersion = sanitizeInput($input['os_version'] ?? '');
    $configSerial = (int)($input['serial_applied'] ?? $input['serial_aplicado'] ?? 0);
    $orgAcronym = strtoupper(sanitizeInput($input['organization_acronym'] ?? ''));
    $stationToken = sanitizeInput($input['station_token'] ?? '');

    if (empty($hostname)) {
        jsonError('Hostname obrigatorio');
    }

    try {
        // Look up existing station: by token first, then by hostname+mac
        $existing = null;
        if (!empty($stationToken)) {
            $existing = Database::fetchOne(
                "SELECT id, organization_id FROM stations WHERE token = ?",
                [$stationToken]
            );
        }
        if (!$existing) {
            $existing = Database::fetchOne(
                "SELECT id, organization_id FROM stations WHERE hostname = ?" .
                (!empty($macAddress) ? " AND (mac_address = ? OR mac_address IS NULL OR mac_address = '')" : ""),
                !empty($macAddress) ? [$hostname, $macAddress] : [$hostname]
            );
        }

        $isNew = false;
        $newToken = null;

        if ($existing) {
            $organizationId = (int)$existing['organization_id'];
            Database::execute(
                "UPDATE stations SET ip_address = ?, mac_address = ?, os_name = ?, os_version = ?, serial_aplicado = GREATEST(serial_aplicado, ?), last_checkin = CURRENT_TIMESTAMP WHERE id = ?",
                [$ipAddress, $macAddress, $osName, $osVersion, $configSerial, $existing['id']]
            );
            $stationId = $existing['id'];
        } else {
            // New station — organization_acronym is required
            if (empty($orgAcronym)) {
                jsonError('Informe o acronimo da organizacao (--org) no primeiro check-in', 400);
            }

            $org = Database::fetchOne(
                "SELECT id FROM organizations WHERE UPPER(acronym) = ? AND is_active = TRUE",
                [$orgAcronym]
            );

            if (!$org) {
                jsonError("Organizacao nao encontrada: $orgAcronym", 404);
            }

            $organizationId = (int)$org['id'];
            $newToken = bin2hex(random_bytes(32));
            $isNew = true;

            Database::execute(
                "INSERT INTO stations (hostname, ip_address, mac_address, os_name, os_version, organization_id, serial_aplicado, last_checkin, token)
                 VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, ?)",
                [$hostname, $ipAddress, $macAddress, $osName, $osVersion, $organizationId, $configSerial, $newToken]
            );
            $stationId = Database::lastInsertId();
        }

        $orgRow = Database::fetchOne("SELECT serial_config FROM organizations WHERE id = ?", [$organizationId]);
        $latestBundle = Database::fetchOne(
            "SELECT id FROM deploy_bundles WHERE organization_id = ? ORDER BY generated_at DESC LIMIT 1",
            [$organizationId]
        );
        $orgSerial = (int)($orgRow['serial_config'] ?? 0);
        $stationRow = Database::fetchOne("SELECT serial_aplicado FROM stations WHERE id = ?", [$stationId]);
        $appliedSerial = (int)($stationRow['serial_aplicado'] ?? 0);

        $response = [
            'status' => 'ok',
            'station_id' => $stationId,
            'serial_config' => $orgSerial,
            'serial_aplicado' => $appliedSerial,
            'update_available' => ($orgSerial > $appliedSerial),
            'latest_bundle_id' => ($orgSerial > $appliedSerial) ? ($latestBundle['id'] ?? null) : null,
            'current_serial' => $appliedSerial,
            'latest_serial' => $orgSerial,
        ];

        if ($isNew && $newToken) {
            $response['station_token'] = $newToken;
        }

        jsonSuccess($response, 'Check-in registrado');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao processar check-in: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function getStationForSync($stationToken) {
    $stationToken = sanitizeInput($stationToken);
    if (empty($stationToken)) {
        jsonError('station_token obrigatorio', 400);
    }

    $station = Database::fetchOne(
        "SELECT s.id, s.organization_id, s.serial_aplicado, o.serial_config
         FROM stations s
         JOIN organizations o ON o.id = s.organization_id
         WHERE s.token = ?",
        [$stationToken]
    );

    if (!$station) {
        jsonError('Estacao nao autenticada', 401);
    }

    return $station;
}

function updateStationSerial($stationId, $serialAplicado) {
    Database::execute(
        "UPDATE stations
         SET serial_aplicado = GREATEST(serial_aplicado, ?)
         WHERE id = ?",
        [$serialAplicado, $stationId]
    );

    $station = Database::fetchOne(
        "SELECT serial_aplicado FROM stations WHERE id = ?",
        [$stationId]
    );

    return (int)($station['serial_aplicado'] ?? 0);
}

function handleStationSyncStatus($input) {
    try {
        $station = getStationForSync($input['station_token'] ?? '');
        $appliedSerial = (int)$station['serial_aplicado'];

        if (array_key_exists('serial_aplicado', $input) && $input['serial_aplicado'] !== null) {
            $appliedSerial = updateStationSerial(
                $station['id'],
                (int)$input['serial_aplicado']
            );
        }

        $currentSerial = (int)$station['serial_config'];
        jsonSuccess([
            'update_available' => $currentSerial > $appliedSerial,
            'current_serial' => $currentSerial,
            'applied_serial' => $appliedSerial,
            'manifest' => new stdClass()
        ]);
    } catch (PDOException $e) {
        jsonError('Erro ao consultar status de sincronizacao', 500);
    }
}

function handleStationSyncConfirm($input) {
    if (!array_key_exists('serial_aplicado', $input) || $input['serial_aplicado'] === null) {
        jsonError('serial_aplicado obrigatorio', 400);
    }

    try {
        $station = getStationForSync($input['station_token'] ?? '');
        $appliedSerial = updateStationSerial(
            $station['id'],
            (int)$input['serial_aplicado']
        );

        jsonSuccess([
            'serial_aplicado' => $appliedSerial
        ], 'Sincronizacao confirmada');
    } catch (PDOException $e) {
        jsonError('Erro ao confirmar sincronizacao', 500);
    }
}

// AUDIT
function handleGetAuditEvents() {
    if (!isAdminGap() && !isAuditor() && !isOperatorOm()) jsonError('Sem permissao', 403);

    try {
        // Paginação
        $page = max(1, (int)($_GET['page'] ?? 1));
        $limit = min(100, max(10, (int)($_GET['limit'] ?? 20)));
        $offset = ($page - 1) * $limit;

        // Filtros opcionais
        $orgId = isset($_GET['org_id']) ? (int)$_GET['org_id'] : null;
        $startDate = sanitizeInput($_GET['start_date'] ?? '');
        $endDate = sanitizeInput($_GET['end_date'] ?? '');
        $entityType = sanitizeInput($_GET['entity_type'] ?? '');
        $actionFilter = sanitizeInput($_GET['action_filter'] ?? '');

        $where = "1=1";
        $params = [];

        $userOrgId = getUserOrgId();

        // Admin GAP visualiza tudo. Auditores e operadores OM veem apenas eventos da propria OM.
        if (!isAdminGap()) {
            if ($orgId !== null && $orgId > 0 && $userOrgId !== null && $userOrgId !== $orgId) {
                jsonError('Sem permissao', 403);
            }
            if ($userOrgId !== null) {
                $where .= " AND a.organization_id = ?";
                $params[] = $userOrgId;
            }
        }
        if ($startDate) {
            $where .= " AND a.created_at >= ?";
            $params[] = $startDate . ' 00:00:00';
        }
        if ($endDate) {
            $where .= " AND a.created_at <= ?";
            $params[] = $endDate . ' 23:59:59';
        }
        if ($entityType) {
            $where .= " AND a.entity = ?";
            $params[] = $entityType;
        }
        if ($actionFilter) {
            $where .= " AND a.action = ?";
            $params[] = $actionFilter;
        }

        // Contar total de eventos
        $countResult = Database::fetchOne(
            "SELECT COUNT(*) as total FROM audit_events a WHERE {$where}",
            $params
        );
        $total = $countResult['total'] ?? 0;

        $events = Database::fetchAll(
            "SELECT a.id, a.action, a.entity, a.entity_id, a.details, a.ip_address, a.created_at,
                    u.username, u.full_name, o.acronym as org_acronym
             FROM audit_events a
             LEFT JOIN users u ON u.id = a.user_id
             LEFT JOIN organizations o ON o.id = a.organization_id
             WHERE {$where}
             ORDER BY a.created_at DESC
             LIMIT ? OFFSET ?",
            array_merge($params, [$limit, $offset])
        );

        foreach ($events as &$event) {
            $event['summary'] = buildAuditSummary($event['action'], $event['entity'], $event['details']);
        }
        unset($event);

        $metadata = [
            'total' => $total,
            'page' => $page,
            'limit' => $limit,
            'pages' => (int)ceil($total / $limit)
        ];

        jsonSuccess(['events' => $events, 'pagination' => $metadata]);
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao buscar eventos de auditoria: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

// UPLOADS
function handleUploadWallpaper() {
    $orgId = (int)($_POST['organization_id'] ?? $_GET['org_id'] ?? 0);
    if (!$orgId) jsonError('Organization ID required', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    if (!isset($_FILES['wallpaper']) || $_FILES['wallpaper']['error'] !== UPLOAD_ERR_OK) {
        jsonError('Nenhum arquivo enviado', 400);
    }

    $file = $_FILES['wallpaper'];
    $allowedTypes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];

    // Valida MIME real (nao confia em $file['type'] fornecido pelo cliente)
    $finfo = finfo_open(FILEINFO_MIME_TYPE);
    $realMime = $finfo ? finfo_file($finfo, $file['tmp_name']) : $file['type'];
    if ($finfo) finfo_close($finfo);

    if (!in_array($realMime, $allowedTypes, true)) {
        jsonError('Tipo de arquivo invalido. Use JPG, PNG, GIF ou WebP (MIME real: ' . $realMime . ')', 415);
    }

    if ($file['size'] > 10 * 1024 * 1024) {
        jsonError('Arquivo muito grande (max 10MB)', 400);
    }

    $ext = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
    $filename = uniqid('', true) . '.' . $ext;
    $uploadDir = __DIR__ . '/../assets/wallpapers/';

    if (!is_dir($uploadDir)) mkdir($uploadDir, 0755, true);

    if (!move_uploaded_file($file['tmp_name'], $uploadDir . $filename)) {
        jsonError('Erro ao salvar arquivo', 500);
    }

    $thumbDir = $uploadDir . 'thumbs/';
    if (!is_dir($thumbDir)) mkdir($thumbDir, 0755, true);
    generateThumbnail($uploadDir . $filename, $thumbDir . $filename, 100, 70);

    $wallpaperUrl = '/assets/wallpapers/' . $filename;

    Database::execute(
        "UPDATE organization_variables ov SET value = ?
         FROM variable_definitions vd
         WHERE ov.organization_id = ? AND ov.variable_id = vd.id AND vd.name = 'WALLPAPER_URL'",
        [$wallpaperUrl, $orgId]
    );

    log_audit('UPLOAD', 'wallpaper', null, ['organization_id' => $orgId, 'filename' => $filename]);
    jsonSuccess(['url' => $wallpaperUrl, 'filename' => $filename, 'thumbnail' => '/assets/wallpapers/thumbs/' . $filename], 'Wallpaper enviado');
}

function handleUploadLogo() {
    $orgId = (int)($_POST['organization_id'] ?? $_GET['org_id'] ?? 0);
    if (!$orgId) jsonError('Organization ID required', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    if (!isset($_FILES['logo']) || $_FILES['logo']['error'] !== UPLOAD_ERR_OK) {
        jsonError('Nenhum arquivo enviado', 400);
    }

    $file = $_FILES['logo'];
    $allowedTypes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/svg+xml'];

    // Valida MIME real (nao confia em $file['type'] fornecido pelo cliente)
    $finfo = finfo_open(FILEINFO_MIME_TYPE);
    $realMime = $finfo ? finfo_file($finfo, $file['tmp_name']) : $file['type'];
    if ($finfo) finfo_close($finfo);

    // finfo detecta SVG como "image/svg" ou "text/xml" - normaliza
    if (in_array($realMime, ['image/svg', 'text/xml', 'application/xml'], true)) {
        $realMime = 'image/svg+xml';
    }

    if (!in_array($realMime, $allowedTypes, true)) {
        jsonError('Tipo de arquivo invalido (MIME real: ' . $realMime . ')', 415);
    }

    if ($file['size'] > 10 * 1024 * 1024) {
        jsonError('Arquivo muito grande (max 10MB)', 400);
    }

    $ext = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
    $filename = uniqid('', true) . '.' . $ext;
    $uploadDir = __DIR__ . '/../assets/logos/';

    if (!is_dir($uploadDir)) mkdir($uploadDir, 0755, true);

    if (!move_uploaded_file($file['tmp_name'], $uploadDir . $filename)) {
        jsonError('Erro ao salvar arquivo', 500);
    }

    $logoUrl = '/assets/logos/' . $filename;

    Database::execute(
        "UPDATE organization_variables ov SET value = ?
         FROM variable_definitions vd
         WHERE ov.organization_id = ? AND ov.variable_id = vd.id AND vd.name = 'LOGO_URL'",
        [$logoUrl, $orgId]
    );

    log_audit('UPLOAD', 'logo', null, ['organization_id' => $orgId, 'filename' => $filename]);
    jsonSuccess(['url' => $logoUrl, 'filename' => $filename], 'Logo enviado');
}

function handleGetWallpapers($orgId) {
    if (!$orgId) jsonError('org_id required', 400);

    $uploadDir = __DIR__ . '/../assets/wallpapers/';
    $thumbDir = $uploadDir . 'thumbs/';
    $images = [];

    if (is_dir($uploadDir)) {
        foreach (scandir($uploadDir) as $file) {
            if ($file === '.' || $file === '..' || is_dir($uploadDir . $file)) continue;
            if (preg_match('/^wallpaper_org' . $orgId . '_/', $file) || preg_match('/^default\./', $file)) {
                $images[] = [
                    'filename' => $file,
                    'url' => '/assets/wallpapers/' . $file,
                    'thumbnail' => file_exists($thumbDir . $file) ? '/assets/wallpapers/thumbs/' . $file : '/assets/wallpapers/' . $file,
                    'timestamp' => filemtime($uploadDir . $file)
                ];
            }
        }
    }

    usort($images, fn($a, $b) => $b['timestamp'] - $a['timestamp']);
    jsonSuccess(['images' => $images]);
}

/**
 * Lista TODAS as imagens da pasta assets/wallpapers/ para a galeria.
 * Nao filtra por OM - mostra todas as imagens disponiveis.
 */
function handleGetGalleryImages() {
    $uploadDir = __DIR__ . '/../assets/wallpapers/';
    $thumbDir = $uploadDir . 'thumbs/';
    $images = [];
    $allowedExt = ['jpg', 'jpeg', 'png', 'gif', 'webp'];

    if (is_dir($uploadDir)) {
        foreach (scandir($uploadDir) as $file) {
            if ($file === '.' || $file === '..') continue;
            if (is_dir($uploadDir . $file)) continue;
            $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));
            if (!in_array($ext, $allowedExt)) continue;

            $images[] = [
                'filename' => $file,
                'url' => '/assets/wallpapers/' . $file,
                'thumbnail' => file_exists($thumbDir . $file) ? '/assets/wallpapers/thumbs/' . $file : '/assets/wallpapers/' . $file,
                'timestamp' => filemtime($uploadDir . $file)
            ];
        }
    }

    usort($images, fn($a, $b) => $b['timestamp'] - $a['timestamp']);
    jsonSuccess(['images' => $images]);
}

/**
 * Exclui uma imagem da pasta assets/wallpapers/.
 * Restrito ao diretorio de wallpapers - nao permite path traversal.
 */
function handleDeleteGalleryImage() {
    $filename = $_GET['file'] ?? '';
    if (!$filename) jsonError('Parametro file obrigatorio', 400);

    // Sanitize filename - apenas nome do arquivo, sem caminho
    $filename = basename($filename);
    if (!$filename || $filename === '.' || $filename === '..') {
        jsonError('Nome de arquivo invalido', 400);
    }

    // Validar extensao
    $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    $allowedExt = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
    if (!in_array($ext, $allowedExt, true)) {
        jsonError('Tipo de arquivo nao permitido', 400);
    }

    // Nao permitir excluir o default
    if (preg_match('/^default\./i', $filename)) {
        jsonError('Nao e possivel excluir a imagem padrao', 403);
    }

    $uploadDir = __DIR__ . '/../assets/wallpapers/';
    $filePath = $uploadDir . $filename;

    // Verificar que o caminho resolvido esta dentro do diretorio de wallpapers
    $realPath = realpath($filePath);
    $realDir = realpath($uploadDir);
    if ($realPath === false || $realDir === false || strpos($realPath, $realDir) !== 0) {
        jsonError('Caminho invalido', 400);
    }

    if (!file_exists($filePath)) {
        jsonError('Arquivo nao encontrado', 404);
    }

    if (!unlink($filePath)) {
        jsonError('Erro ao excluir arquivo', 500);
    }

    // Remover thumbnail se existir
    $thumbPath = $uploadDir . 'thumbs/' . $filename;
    if (file_exists($thumbPath)) {
        @unlink($thumbPath);
    }

    log_audit('DELETE', 'gallery-image', null, ['filename' => $filename]);
    jsonSuccess(null, 'Imagem excluida: ' . $filename);
}

function handleGetLogos($orgId) {
    if (!$orgId) jsonError('org_id required', 400);

    $uploadDir = __DIR__ . '/../assets/logos/';
    $images = [];

    if (is_dir($uploadDir)) {
        foreach (scandir($uploadDir) as $file) {
            if ($file === '.' || $file === '..' || is_dir($uploadDir . $file)) continue;
            if (preg_match('/^logo_org' . $orgId . '_/', $file) || preg_match('/^default\./', $file)) {
                $images[] = [
                    'filename' => $file,
                    'url' => '/assets/logos/' . $file,
                    'timestamp' => filemtime($uploadDir . $file)
                ];
            }
        }
    }

    usort($images, fn($a, $b) => $b['timestamp'] - $a['timestamp']);
    jsonSuccess(['images' => $images]);
}

/**
 * Upload unificado de qualquer asset (WALLPAPER_URL, WALLPAPER_LOGIN_URL, LOGO_URL, GREETER_URL).
 * Espera POST multipart: organization_id, var_name, file[asset]
 */
function handleUploadAsset() {
    $orgId = (int)($_POST['organization_id'] ?? 0);
    $varName = strtoupper(trim($_POST['var_name'] ?? ''));

    if (!$orgId) jsonError('Organization ID required', 400);
    if (!$varName) jsonError('var_name obrigatorio', 400);

    $allowedVars = [
        'WALLPAPER_URL' => ['dir' => 'wallpapers', 'prefix' => 'wallpaper', 'thumb' => true,  'svg' => false],
        'WALLPAPER_LOGIN_URL' => ['dir' => 'wallpapers', 'prefix' => 'wallpaper_login', 'thumb' => true, 'svg' => false],
        'LOGO_URL' => ['dir' => 'logos', 'prefix' => 'logo', 'thumb' => false, 'svg' => true],
        'GREETER_URL' => ['dir' => 'wallpapers', 'prefix' => 'greeter', 'thumb' => true, 'svg' => false],
    ];
    if (!isset($allowedVars[$varName])) jsonError('var_name nao permitido para upload de asset', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    if (!isset($_FILES['asset']) || $_FILES['asset']['error'] !== UPLOAD_ERR_OK) {
        jsonError('Nenhum arquivo enviado (esperado campo "asset")', 400);
    }

    $cfg = $allowedVars[$varName];
    $file = $_FILES['asset'];
    $allowedTypes = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];
    if ($cfg['svg']) $allowedTypes[] = 'image/svg+xml';

    // Valida MIME real via fileinfo (nao confia em $file['type'] fornecido pelo cliente)
    $finfo = finfo_open(FILEINFO_MIME_TYPE);
    $realMime = $finfo ? finfo_file($finfo, $file['tmp_name']) : $file['type'];
    if ($finfo) finfo_close($finfo);

    // finfo pode detectar SVG como "image/svg", "text/xml" ou "application/xml"
    if ($cfg['svg'] && in_array($realMime, ['image/svg', 'text/xml', 'application/xml'], true)) {
        $realMime = 'image/svg+xml';
    }

    if (!in_array($realMime, $allowedTypes, true)) {
        jsonError('Tipo de arquivo invalido (MIME real: ' . $realMime . '). Aceitos: ' . implode(', ', $allowedTypes), 415);
    }
    if ($file['size'] > 10 * 1024 * 1024) {
        jsonError('Arquivo muito grande (max 10MB)', 400);
    }

    $ext = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
    $filename = uniqid('', true) . '.' . $ext;
    $uploadDir = __DIR__ . '/../assets/' . $cfg['dir'] . '/';
    if (!is_dir($uploadDir)) mkdir($uploadDir, 0755, true);

    if (!move_uploaded_file($file['tmp_name'], $uploadDir . $filename)) {
        jsonError('Erro ao salvar arquivo', 500);
    }

    $thumbUrl = null;
    if ($cfg['thumb']) {
        $thumbDir = $uploadDir . 'thumbs/';
        if (!is_dir($thumbDir)) mkdir($thumbDir, 0755, true);
        generateThumbnail($uploadDir . $filename, $thumbDir . $filename, 100, 70);
        $thumbUrl = '/assets/' . $cfg['dir'] . '/thumbs/' . $filename;
    }

    $url = '/assets/' . $cfg['dir'] . '/' . $filename;

    Database::execute(
        "UPDATE organization_variables ov SET value = ?
         FROM variable_definitions vd
         WHERE ov.organization_id = ? AND ov.variable_id = vd.id AND vd.name = ?",
        [$url, $orgId, $varName]
    );
    log_audit('UPLOAD', 'asset', null, ['organization_id' => $orgId, 'var_name' => $varName, 'filename' => $filename]);
    jsonSuccess(['url' => $url, 'thumbnail' => $thumbUrl, 'filename' => $filename, 'var_name' => $varName], 'Asset enviado');
}

function handlePublicBundles() {
    $bundles = Database::fetchAll(
        "SELECT db.id, db.filename, db.description, db.scripts_count, db.generated_at,
                o.name as org_name, o.acronym
         FROM deploy_bundles db
         JOIN organizations o ON o.id = db.organization_id
         WHERE db.is_active = TRUE
         ORDER BY db.generated_at DESC LIMIT 20"
    );
    jsonSuccess($bundles);
}

function handleListBundles($orgId) {
    $userOrgId = getUserOrgId();
    $isAdmin = isAdminGap();

    if ($userOrgId !== null && !$isAdmin && $orgId != $userOrgId) {
        jsonError('Sem permissao', 403);
    }
    if (!$orgId) jsonError('org_id required');

    try {
        // Paginação
        $page = max(1, (int)($_GET['page'] ?? 1));
        $limit = min(100, max(10, (int)($_GET['limit'] ?? 20)));
        $offset = ($page - 1) * $limit;

        // Contar total de bundles
        $countResult = Database::fetchOne(
            "SELECT COUNT(*) as total FROM deploy_bundles WHERE organization_id = ?",
            [$orgId]
        );
        $total = $countResult['total'] ?? 0;

        $bundles = Database::fetchAll(
            "SELECT id, filename, description, scripts_count, generated_at, is_active, octet_length(content) as content_size
             FROM deploy_bundles
             WHERE organization_id = ?
             ORDER BY generated_at DESC
             LIMIT ? OFFSET ?",
            [$orgId, $limit, $offset]
        );
        
        $metadata = [
            'total' => $total,
            'page' => $page,
            'limit' => $limit,
            'pages' => (int)ceil($total / $limit)
        ];
        
        jsonSuccess(['bundles' => $bundles, 'pagination' => $metadata]);
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao listar bundles: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function handleToggleBundleActive($input) {
    $bundleId = (int)($input['bundle_id'] ?? 0);
    if (!$bundleId) jsonError('bundle_id required');

    $userOrgId = getUserOrgId();
    $isAdmin = isAdminGap();

    $bundle = Database::fetchOne("SELECT id, organization_id, is_active FROM deploy_bundles WHERE id = ?", [$bundleId]);
    if (!$bundle) jsonError('Bundle nao encontrado', 404);

    if ($userOrgId !== null && !$isAdmin && $bundle['organization_id'] != $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    // Usar boolean real em vez de string 'true'/'false'
    $currentStatus = (bool)($bundle['is_active'] ?? false);
    $newStatus = !$currentStatus;

    Database::execute(
        "UPDATE deploy_bundles SET is_active = ? WHERE id = ?",
        [$newStatus ? 'true' : 'false', $bundleId]
    );

    log_audit($newStatus ? 'ACTIVATE' : 'DEACTIVATE', 'bundles', $bundleId, []);
    jsonSuccess(null, $newStatus ? 'Bundle ativado' : 'Bundle desativado');
}

function handleDeleteBundle($id) {
    $bundle = Database::fetchOne("SELECT id, organization_id FROM deploy_bundles WHERE id = ?", [$id]);
    if (!$bundle) jsonError('Bundle nao encontrado', 404);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && !isAdminGap() && $bundle['organization_id'] != $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    Database::execute("DELETE FROM deploy_bundles WHERE id = ?", [$id]);
    log_audit('DELETE', 'bundles', $id, []);
    jsonSuccess(null, 'Bundle excluido');
}

function handleUpdateBundleDescription($input) {
    $bundleId = (int)($input['id'] ?? 0);
    $description = $input['description'] ?? '';
    if (!$bundleId) jsonError('ID do bundle requerido');

    $bundle = Database::fetchOne("SELECT id, organization_id FROM deploy_bundles WHERE id = ?", [$bundleId]);
    if (!$bundle) jsonError('Bundle nao encontrado', 404);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && !isAdminGap() && $bundle['organization_id'] != $userOrgId) {
        jsonError('Sem permissao', 403);
    }

    Database::execute("UPDATE deploy_bundles SET description = ? WHERE id = ?", [$description, $bundleId]);
    log_audit('UPDATE', 'bundles', $bundleId, ['description' => $description]);
    jsonSuccess(null, 'Descricao atualizada');
}

function handleUpdateScriptOrder($input) {
    if (!isAdminGap()) jsonError('Permissao negada', 403);

    if (!isset($input['scripts']) || !is_array($input['scripts'])) {
        jsonError('Array de scripts invalido');
    }

    Database::beginTransaction();
    try {
        foreach ($input['scripts'] as $item) {
            $id = (int)($item['id'] ?? 0);
            $order = (int)($item['order'] ?? 0);
            if (!$id) continue;
            Database::execute(
                "UPDATE scripts SET execution_order = ? WHERE id = ?",
                [$order, $id]
            );
            log_audit('UPDATE', 'scripts', $id, ['new_execution_order' => $order]);
        }
        Database::commit();
        jsonSuccess(null, 'Ordem atualizada');
    } catch (Exception $e) {
        Database::rollback();
        jsonError('Erro ao salvar ordem: ' . $e->getMessage(), 500);
    }
}

// SCRIPT VERSIONING

function getScriptContent($scriptId, $organizationId) {
    $scriptId = (int)$scriptId;
    $organizationId = (int)$organizationId;

    // 1. Se OM especificada, tenta OM override primeiro
    if ($organizationId > 0) {
        $local = Database::fetchOne(
            "SELECT content FROM om_script_versions
             WHERE organization_id = ? AND script_id = ? AND is_active = true
             ORDER BY id DESC LIMIT 1",
            [$organizationId, $scriptId]
        );
        if ($local && !empty($local['content'])) {
            return $local['content'];
        }
    }

    // 2. Tenta GAP default global
    $gap = Database::fetchOne(
        "SELECT content FROM script_versions
         WHERE script_id = ? AND version_type = 'gap_default' AND is_active = true
         ORDER BY version_number DESC LIMIT 1",
        [$scriptId]
    );
    if ($gap && !empty($gap['content'])) return $gap['content'];

    // 3. Tenta factory
    $factory = Database::fetchOne(
        "SELECT content FROM script_versions
         WHERE script_id = ? AND version_type = 'factory'
         ORDER BY version_number DESC LIMIT 1",
        [$scriptId]
    );
    if ($factory && !empty($factory['content'])) return $factory['content'];

    // 4. Fallback: scripts.content
    $script = Database::fetchOne("SELECT content FROM scripts WHERE id = ?", [$scriptId]);
    if ($script && !empty($script['content'])) return $script['content'];

    // 5. Último recurso: cria factory se não existir
    $fallbackFactory = ensureFactoryVersionForScript($scriptId);
    if ($fallbackFactory && !empty($fallbackFactory['content'])) return $fallbackFactory['content'];

    return '';
}

function handleGetScriptVersions($scriptId) {
    $script = Database::fetchOne("SELECT id, name, filename FROM scripts WHERE id = ?", [$scriptId]);
    if (!$script) jsonError('Script nao encontrado', 404);

    $versions = Database::fetchAll(
        "SELECT sv.id, sv.version_name, sv.version_number, sv.version_type, sv.changelog,
                sv.is_active, sv.created_at, sv.organization_id, sv.content,
                u.username as created_by_username
         FROM script_versions sv
         LEFT JOIN users u ON u.id = sv.created_by
         WHERE sv.script_id = ?
         ORDER BY sv.version_number DESC",
        [$scriptId]
    );

    jsonSuccess(['script' => $script, 'versions' => $versions]);
}

function handleDeleteScriptVersion($input) {
    if (!isAdminGap()) jsonError('Sem permissao: apenas admin_gap pode deletar versoes', 403);

    $versionId = (int)($input['version_id'] ?? 0);
    $scriptId = (int)($input['script_id'] ?? 0);

    if (!$versionId || !$scriptId) {
        jsonError('version_id e script_id obrigatorios', 400);
    }

    $version = Database::fetchOne(
        "SELECT id, version_type, is_active FROM script_versions WHERE id = ? AND script_id = ?",
        [$versionId, $scriptId]
    );
    if (!$version) jsonError('Versao nao encontrada', 404);

    if ($version['version_type'] === 'factory') {
        jsonError('Versoes de fabrica nao podem ser deletadas', 403);
    }

    Database::execute(
        "DELETE FROM script_versions WHERE id = ?",
        [$versionId]
    );

    log_audit('DELETE', 'script_versions', $scriptId, [
        'action' => 'delete_script_version',
        'version_id' => $versionId,
        'version_type' => $version['version_type'],
        'author' => $_SESSION['username'] ?? 'system'
    ]);

    jsonSuccess(null, 'Versao global deletada');
}

function handleSyncScript($input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $filename = sanitizeInput($input['filename'] ?? '');
    $content = $input['content'] ?? '';

    if (empty($filename) || empty($content)) jsonError('filename e content obrigatorios', 400);

    try {
        $script = Database::fetchOne("SELECT id FROM scripts WHERE filename = ?", [$filename]);
        if (!$script) jsonError('Script nao encontrado: ' . $filename, 404);

        $scriptId = (int)$script['id'];

        $maxVersion = Database::fetchOne(
            "SELECT COALESCE(MAX(version_number), 0) AS max_v FROM script_versions WHERE script_id = ?",
            [$scriptId]
        );
        $nextVersion = (int)$maxVersion['max_v'] + 1;

        $versionName = $filename . ' - Factory v' . $nextVersion;
        $userId = $_SESSION['user_id'] ?? null;

        Database::execute(
            "INSERT INTO script_versions (script_id, version_name, version_number, content, version_type, created_by)
             VALUES (?, ?, ?, ?, 'factory', ?)",
            [$scriptId, $versionName, $nextVersion, $content, $userId]
        );

        $newVersionId = (int)Database::lastInsertId();

        Database::execute(
            "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            [$newVersionId, $content, $scriptId]
        );

        log_audit('SYNC', 'scripts', $scriptId, ['filename' => $filename, 'version' => $nextVersion]);
        log_event("Script sincronizado: {$filename} v{$nextVersion} (id={$scriptId})", 'INFO');

        jsonSuccess(['version_id' => $newVersionId, 'version_number' => $nextVersion], 'Script sincronizado com sucesso');
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode([
            'success' => false,
            'error' => 'Erro ao sincronizar script: ' . $e->getMessage(),
            'file' => basename(__FILE__),
            'line' => __LINE__ - 8
        ]);
        return;
    }
}

function handleSetGapDefault($input) {
    if (!isAdminGap()) jsonError('Sem permissao', 403);

    $scriptId = (int)($input['script_id'] ?? 0);
    $versionId = (int)($input['version_id'] ?? 0);

    if (!$scriptId || !$versionId) jsonError('script_id e version_id obrigatorios', 400);

    $version = Database::fetchOne(
        "SELECT id, version_type, version_number, content FROM script_versions WHERE id = ? AND script_id = ?",
        [$versionId, $scriptId]
    );
    if (!$version) jsonError('Versao nao encontrada', 404);

    if ($version['version_type'] === 'factory') {
        jsonError('Versoes de fabrica nao podem ser ativadas como GAP default. Use reset-script-factory para reverter.', 403);
    }

    Database::execute(
        "UPDATE script_versions SET is_active = false WHERE script_id = ? AND version_type = 'gap_default'",
        [$scriptId]
    );

    Database::execute(
        "UPDATE script_versions SET is_active = true WHERE id = ?",
        [$versionId]
    );

    Database::execute(
        "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
        [$versionId, $version['content'], $scriptId]
    );

    log_audit('UPDATE', 'script_versions', $scriptId, ['action' => 'activate_gap_default', 'version' => $version['version_number'], 'scope' => 'gap_default', 'script_id' => $scriptId, 'author' => $_SESSION['username'] ?? 'system']);
    jsonSuccess(null, 'Versao default do GAP definida');
}

function handleSetOmVersion($input) {
    $scriptId = (int)($input['script_id'] ?? 0);
    $orgId = (int)($input['organization_id'] ?? 0);
    $versionId = (int)($input['version_id'] ?? 0);

    if (!$scriptId || !$orgId || !$versionId) jsonError('script_id, organization_id e version_id obrigatorios', 400);

    $userOrgId = getUserOrgId();
    if ($userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    $version = Database::fetchOne(
        "SELECT id, version_number, content FROM script_versions WHERE id = ? AND script_id = ?",
        [$versionId, $scriptId]
    );
    if (!$version) jsonError('Versao nao encontrada', 404);

    ensureOmScriptVersionSchema();

    $script = Database::fetchOne('SELECT execution_order FROM scripts WHERE id = ?', [$scriptId]);

    Database::execute(
        "UPDATE om_script_versions SET is_active = false WHERE organization_id = ? AND script_id = ?",
        [$orgId, $scriptId]
    );

    $maxV = Database::fetchOne(
        "SELECT COALESCE(MAX(version_number), 0) AS max_v FROM om_script_versions WHERE organization_id = ? AND script_id = ?",
        [$orgId, $scriptId]
    );
    $nextV = (int)$maxV['max_v'] + 1;

    Database::execute(
        "INSERT INTO om_script_versions (organization_id, script_id, version_id, content, execution_order, is_active, version_number, created_by, created_at)
         VALUES (?, ?, ?, ?, ?, true, ?, ?, CURRENT_TIMESTAMP)",
        [$orgId, $scriptId, $versionId, $version['content'], (int)($script['execution_order'] ?? 0), $nextV, $_SESSION['user_id'] ?? null]
    );

    log_audit('UPDATE', 'om_script_versions', $scriptId, ['action' => 'activate_om_specific', 'version' => $version['version_number'], 'scope' => 'om_specific', 'organization_id' => $orgId, 'script_id' => $scriptId, 'author' => $_SESSION['username'] ?? 'system']);
    jsonSuccess(null, 'Versao da OM definida');
}

function handleResetToFactory($input) {
    $scriptId = (int)($input['script_id'] ?? 0);
    $orgId = (int)($input['organization_id'] ?? 0);

    if (!$scriptId) jsonError('script_id obrigatorio', 400);

    $userOrgId = getUserOrgId();
    if ($orgId && $userOrgId !== null && $userOrgId !== $orgId && !isAdminGap()) {
        jsonError('Sem permissao', 403);
    }

    $factoryVersion = ensureFactoryVersionForScript($scriptId);
    if (!$factoryVersion) {
        jsonError('Nenhuma versao de fabrica encontrada para este script', 404);
    }

    if ($orgId) {
        Database::execute(
            "UPDATE om_script_versions
             SET is_active = false
             WHERE organization_id = ? AND script_id = ?",
            [$orgId, $scriptId]
        );
        Database::execute(
            "UPDATE script_versions SET is_active = false WHERE script_id = ? AND version_type = 'om_specific' AND organization_id = ?",
            [$scriptId, $orgId]
        );
        Database::execute(
            "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            [$factoryVersion['id'], $factoryVersion['content'], $scriptId]
        );
        log_audit('UPDATE', 'script_versions', $scriptId, ['action' => 'revert_factory', 'scope' => 'om_specific', 'organization_id' => $orgId, 'version' => $factoryVersion['version_number'], 'script_id' => $scriptId, 'author' => $_SESSION['username'] ?? 'system']);
        jsonSuccess(['is_active' => false], 'OM revertida para versao de fabrica');
    } else {
        Database::execute(
            "UPDATE script_versions SET is_active = false WHERE script_id = ? AND version_type IN ('gap_default', 'om_specific')",
            [$scriptId]
        );
        Database::execute(
            "UPDATE om_script_versions
             SET is_active = false
             WHERE script_id = ?",
            [$scriptId]
        );
        Database::execute(
            "UPDATE scripts SET current_version_id = ?, content = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            [$factoryVersion['id'], $factoryVersion['content'], $scriptId]
        );
        log_audit('UPDATE', 'script_versions', $scriptId, ['action' => 'revert_factory', 'scope' => 'gap_default', 'version' => $factoryVersion['version_number'], 'script_id' => $scriptId, 'author' => $_SESSION['username'] ?? 'system']);
        jsonSuccess(['is_active' => false], 'GAP revertido para versao de fabrica');
    }
}

function handleResetScriptOrder() {
    if (!isAdminGap()) jsonError('Permissao negada', 403);

    $defaultOrder = [
        'core_dns.sh'              => 1,
        'core_repositories.sh'     => 2,
        'core_packages.sh'         => 3,
        'core_legados.sh'          => 4,
        'core_apps.sh'             => 5,
        'core_domain.sh'           => 6,
        'core_ssh.sh'              => 7,
        'core_browser.sh'          => 8,
        'core_inventory.sh'        => 9,
        'core_printers.sh'         => 10,
        'core_vnc.sh'              => 11,
        'core_conky.sh'            => 12,
        'core_config.sh'           => 13,
        'core_branding.sh'         => 14,
        'core_logon.sh'            => 15,
        'core_password_change.sh'  => 16,
        'core_logoff.sh'           => 17,
        'core_session_lightdm.sh'  => 18,
        'core_session_gdm3.sh'     => 19,
        'core_session_sddm.sh'     => 20,
        'core_agent.sh'            => 21,
        'core_proxy.sh'            => 22,
    ];

    Database::beginTransaction();
    try {
        foreach ($defaultOrder as $filename => $order) {
            Database::execute(
                "UPDATE scripts SET execution_order = ? WHERE filename = ? AND is_core = TRUE",
                [$order, $filename]
            );
        }
        Database::commit();
        log_audit('UPDATE', 'scripts', null, ['action' => 'reset_order_to_default']);
        jsonSuccess(null, 'Ordem restaurada para o padrao');
    } catch (Exception $e) {
        Database::rollback();
        jsonError('Erro ao restaurar ordem: ' . $e->getMessage(), 500);
    }
}

// ============ SETTINGS ============

function handleGetPublicTheme() {
    try {
        $row = Database::fetchOne("SELECT value FROM settings WHERE key = 'public_theme'");
        $theme = ($row && in_array($row['value'], ['classic', 'modern', 'solar'], true)) ? $row['value'] : 'classic';
        jsonSuccess(['theme' => $theme]);
    } catch (Throwable $e) {
        jsonSuccess(['theme' => 'classic']);
    }
}

function handleSetPublicTheme($input) {
    if (!isAdminGap()) jsonError('Sem permissao: apenas admin_gap pode alterar configuracoes', 403);

    $theme = sanitizeInput($input['theme'] ?? '');
    if (!in_array($theme, ['classic', 'modern', 'solar'], true)) {
        jsonError('Valor invalido. Use: classic, modern ou solar');
    }

    Database::execute(
        "INSERT INTO settings (key, value, updated_at) VALUES ('public_theme', ?, NOW())
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
        [$theme]
    );

    log_audit('UPDATE', 'settings', null, ['setting' => 'public_theme', 'value' => $theme]);
    jsonSuccess(null, 'Tema da pagina publica atualizado');
}
