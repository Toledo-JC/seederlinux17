<?php
function jsonSuccess($data, $message = '') {
    jsonResponse(['success' => true, 'data' => $data, 'message' => $message], 200);
}

function jsonError($message, $code = 400) {
    jsonResponse(['success' => false, 'error' => $message], $code);
}

function jsonResponse($data, $code = 200) {
    http_response_code($code);
    echo json_encode($data);
    exit;
}

function sanitizeInput($str) {
    return trim($str ?? '');
}

function getCsrfToken() {
    if (empty($_SESSION['csrf_token'])) {
        $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf_token'];
}

function requireCsrfToken($input = []) {
    $headers = function_exists('getallheaders') ? getallheaders() : [];
    $headerToken = '';
    foreach ($headers as $name => $value) {
        if (strtolower($name) === 'x-csrf-token') {
            $headerToken = $value;
            break;
        }
    }
    $token = $headerToken ?: ($input['csrf_token'] ?? '');
    if (!is_string($token) || !hash_equals(getCsrfToken(), $token)) {
        jsonError('Token CSRF ausente ou invalido', 400);
    }
}

function requireAuth() {
    // 1. Verificar token Bearer
    $headers = function_exists('getallheaders') ? getallheaders() : [];
    $authHeader = '';
    foreach ($headers as $name => $value) {
        if (strtolower($name) === 'authorization') {
            $authHeader = $value;
            break;
        }
    }

    if (preg_match('/Bearer\s+(.+)/', $authHeader, $matches)) {
        $token = trim($matches[1]);
        $tokens = Database::fetchAll(
            "SELECT ut.user_id, ut.token_hash, u.role, u.organization_id, u.username, u.full_name
             FROM user_tokens ut
             JOIN users u ON u.id = ut.user_id
             WHERE ut.expires_at > NOW()"
        );

        foreach ($tokens as $t) {
            if (password_verify($token, $t['token_hash'])) {
                $_SESSION['user_id'] = $t['user_id'];
                $_SESSION['username'] = $t['username'];
                $_SESSION['role'] = $t['role'];
                $_SESSION['organization_id'] = $t['organization_id'];
                $_SESSION['full_name'] = $t['full_name'];
                return;
            }
        }
    }

    // 2. Fallback: sessão PHP
    if (!empty($_SESSION['user_id'])) {
        return;
    }

    jsonError('Autenticacao necessaria', 401);
}

function requireStationAuth() {
    $headers = function_exists('getallheaders') ? getallheaders() : [];
    $authHeader = '';
    foreach ($headers as $name => $value) {
        if (strtolower($name) === 'authorization') {
            $authHeader = $value;
            break;
        }
    }

    if (preg_match('/Bearer\s+(.+)/', $authHeader, $matches)) {
        $token = trim($matches[1]);
        $station = Database::fetchOne(
            "SELECT id, organization_id, hostname FROM stations WHERE token = ? LIMIT 1",
            [$token]
        );
        if ($station) {
            $_REQUEST['station_id'] = $station['id'];
            $_REQUEST['station_org_id'] = $station['organization_id'];
            return true;
        }
    }

    return false;
}

function bumpOrgSerial($orgId) {
    Database::execute(
        "UPDATE organizations SET serial_config = serial_config + 1 WHERE id = ?",
        [$orgId]
    );
    return true;
}

function isAdminGap() {
    $role = $_SESSION['role'] ?? null;
    return in_array($role, ['admin_gap', 'admin'], true);
}

function isAuditor() {
    return isset($_SESSION['role']) && $_SESSION['role'] === 'auditor';
}

function isOperatorOm() {
    return isset($_SESSION['role']) && $_SESSION['role'] === 'operador_om';
}

function getUserOrgId() {
    if (isAdminGap()) {
        return null;
    }

    $orgId = $_SESSION['organization_id'] ?? null;
    if ($orgId === null || $orgId === '' || (int)$orgId <= 0) {
        return null;
    }

    return (int)$orgId;
}

function isLoggedIn() {
    return isset($_SESSION['user_id']);
}

function getCurrentUser() {
    if (!isLoggedIn()) return null;
    return [
        'id' => $_SESSION['user_id'],
        'username' => $_SESSION['username'],
        'role' => $_SESSION['role'],
        'organization_id' => $_SESSION['organization_id'] ?? null
    ];
}

function log_event($msg, $level = 'INFO') {
    error_log("[$level] " . date('Y-m-d H:i:s') . " - $msg");
}

function buildAuditSummary($action, $entity, $details = null) {
    if (is_string($details)) {
        $decoded = json_decode($details, true);
        $details = is_array($decoded) ? $decoded : [];
    }
    $details = is_array($details) ? $details : [];

    $action = strtoupper((string)$action);
    $entity = strtolower((string)$entity);
    $targetUser = $details['full_name'] ?? $details['username'] ?? $details['author'] ?? 'sistema';
    $script = $details['script_name'] ?? $details['filename'] ?? 'script';
    $version = $details['new_version'] ?? $details['version_number'] ?? $details['version'] ?? null;
    $organization = $details['organization_acronym'] ?? $details['organization'] ?? null;

    if ($action === 'LOGIN') return "Login do usuário {$targetUser}";
    if ($action === 'LOGOUT') return "Logout do usuário {$targetUser}";
    if ($action === 'LOGIN_FAILED') return "Falha de login do usuário {$targetUser}";

    if ($entity === 'users') {
        if (!empty($details['password_changed'])) return "Alteração de senha do usuário {$targetUser}";
        if ($action === 'CREATE') return "Criação do usuário {$targetUser}";
        if ($action === 'UPDATE') return "Edição do usuário {$targetUser}";
        if ($action === 'DELETE') return "Exclusão do usuário {$targetUser}";
        if ($action === 'ACTIVATE') return "Ativação do usuário {$targetUser}";
        if ($action === 'DEACTIVATE') return "Desativação do usuário {$targetUser}";
    }

    if (in_array($entity, ['script_versions', 'om_script_versions'], true)) {
        $versionText = $version !== null ? " v{$version}" : '';
        if ($action === 'UPDATE') return "Nova versão do script {$script}{$versionText}";
        if ($action === 'DELETE') return "Exclusão da versão do script {$script}{$versionText}";
    }

    if ($entity === 'scripts') {
        if ($action === 'SYNC') return "Sincronização do script {$script}" . ($version !== null ? " v{$version}" : '');
        if ($action === 'UPDATE') return "Edição do script {$script}";
        if ($action === 'CREATE') return "Criação do script {$script}";
        if ($action === 'DELETE') return "Exclusão do script {$script}";
    }

    if ($entity === 'bundles' && $action === 'GENERATE') {
        $orgText = $organization ? " para OM {$organization}" : '';
        $scriptCount = isset($details['scripts']) ? " com {$details['scripts']} scripts" : '';
        return "Geração de bundle{$orgText}{$scriptCount}";
    }

    if ($entity === 'variables' && $action === 'UPDATE') {
        $orgText = $organization ? " da OM {$organization}" : '';
        $changed = $details['changed_variables'] ?? [];
        $variableText = is_array($changed) && $changed ? ': ' . implode(', ', $changed) : '';
        return "Alteração de variáveis{$orgText}{$variableText}";
    }

    $labels = [
        'CREATE' => 'Criação', 'UPDATE' => 'Alteração', 'DELETE' => 'Exclusão',
        'UPLOAD' => 'Upload', 'GENERATE' => 'Geração', 'ACTIVATE' => 'Ativação',
        'DEACTIVATE' => 'Desativação', 'RESET' => 'Redefinição', 'SYNC' => 'Sincronização'
    ];
    return ($labels[$action] ?? ucfirst(strtolower($action))) . " em {$entity}";
}

function log_audit($action, $entity, $entityId = null, $details = null, $organizationId = null) {
    $userId = $_SESSION['user_id'] ?? null;
    $orgId = $organizationId ?? ($_SESSION['organization_id'] ?? null);
    $ip = $_SERVER['REMOTE_ADDR'] ?? null;

    try {
        $normalizedEntityId = $entityId !== null && $entityId !== '' ? (int)$entityId : null;
        $payload = $details !== null ? json_encode($details) : null;
        if ($payload === false) {
            $payload = null;
            error_log('log_audit: falha ao serializar detalhes para action=' . $action . ' entity=' . $entity);
        }

        Database::execute(
            "INSERT INTO audit_events (user_id, organization_id, action, entity, entity_id, details, ip_address, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, NOW())",
            [$userId, $orgId, $action, $entity, $normalizedEntityId, $payload, $ip]
        );
    } catch (Throwable $e) {
        error_log('log_audit failed: ' . $e->getMessage() . ' | action=' . $action . ' | entity=' . $entity);
    }
}

/**
 * Substitui placeholders {{VARIAVEL}} pelos valores reais das variáveis da organização
 */
function substituir_placeholders($content, $orgId) {
    // Fetch all variable definitions with org-specific value if set, otherwise use default_value
    $vars = Database::fetchAll(
        "SELECT vd.name, COALESCE(ov.value, vd.default_value, '') AS value
         FROM variable_definitions vd
         LEFT JOIN organization_variables ov
           ON ov.variable_id = vd.id AND ov.organization_id = ?",
        [$orgId]
    );

    foreach ($vars as $v) {
        $placeholder = '{{' . $v['name'] . '}}';
        $content = str_replace($placeholder, $v['value'] ?? '', $content);
    }

    return $content;
}

/**
 * Gera valores dinâmicos para uma nova organização
 */
function generateDefaultVariables($orgId, $name, $acronym, $domain, $dcIp = null, $dnsPrimario = null, $dnsSecundario = null, $proxyHttp = null, $proxyPorta = null) {
    // Valores padrão usando caminhos LOCAIS
    $defaultValues = [
        'DOMINIO' => $domain,
        'DOMINIO_NETBIOS' => strtoupper($acronym),
        'OM_ACRONYM' => strtoupper($acronym),
        'OM_NAME' => $name,
        'DISPLAY_NAME' => $name,
        'BASE_URL' => $domain ? "https://seederlinux.{$domain}" : '',
        'WALLPAPER_URL' => '/assets/wallpapers/default.jpg',
        'LOGO_URL' => '/assets/logos/default.png',
        'HOMEPAGE' => $domain ? "www.{$domain}" : '',
        'OCS_SERVER' => $domain ? "http://ocs.{$domain}/ocsinventory" : '',
        'OCS_TAG' => strtoupper($acronym) . '-ESTACOES',
        'PROXY_URL' => $domain ? "http://proxy.{$domain}:8080" : '',
        'NO_PROXY' => $domain ? "localhost,127.0.0.1,{$domain}" : '',
        'OU_PADRAO' => $domain ? 'OU=Estacoes,' . implode(',', array_map(fn($p) => "DC=$p", explode('.', $domain))) : '',
        'REPOSITORY_URL' => $domain ? "https://seederlinux.{$domain}" : '',
        'SEEDER_SERVER' => $domain ? "https://seederlinux.{$domain}" : '',
    ];

    if ($dcIp) $defaultValues['DC_IP'] = $dcIp;
    if ($dnsPrimario) $defaultValues['DNS_PRIMARIO'] = $dnsPrimario;
    if ($dnsSecundario) $defaultValues['DNS_SECUNDARIO'] = $dnsSecundario;
    if ($proxyHttp) $defaultValues['PROXY_HTTP'] = $proxyHttp;
    if ($proxyPorta) $defaultValues['PROXY_PORTA'] = $proxyPorta;

    // Atualiza as variáveis da organização
    foreach ($defaultValues as $varName => $varValue) {
        Database::execute(
            "UPDATE organization_variables ov SET value = ?
             FROM variable_definitions vd
             WHERE ov.organization_id = ? AND ov.variable_id = vd.id AND vd.name = ?",
            [$varValue, $orgId, $varName]
        );
    }
}

/**
 * Gera thumbnail de imagem
 */
function generateThumbnail($srcPath, $dstPath, $width = 100, $height = 70) {
    try {
        $info = getimagesize($srcPath);
        if (!$info) return false;

        $type = $info[2];
        $src = match($type) {
            IMAGETYPE_JPEG => imagecreatefromjpeg($srcPath),
            IMAGETYPE_PNG => imagecreatefrompng($srcPath),
            IMAGETYPE_GIF => imagecreatefromgif($srcPath),
            IMAGETYPE_WEBP => imagecreatefromwebp($srcPath),
            default => false
        };

        if (!$src) return false;

        $thumb = imagecreatetruecolor($width, $height);
        imagecopyresampled($thumb, $src, 0, 0, 0, 0, $width, $height, imagesx($src), imagesy($src));

        match($type) {
            IMAGETYPE_JPEG => imagejpeg($thumb, $dstPath, 85),
            IMAGETYPE_PNG => imagepng($thumb, $dstPath, 8),
            IMAGETYPE_GIF => imagegif($thumb, $dstPath),
            IMAGETYPE_WEBP => imagewebp($thumb, $dstPath, 85),
            default => false
        };

        imagedestroy($src);
        imagedestroy($thumb);
        return true;
    } catch (Exception $e) {
        return false;
    }
}
