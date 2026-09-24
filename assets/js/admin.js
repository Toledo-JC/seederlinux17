/**
 * SeederLinux Lite - Admin JavaScript
 * API, Utils and Toast are defined in app.js and loaded before this file.
 */

let currentUser = null;
let currentOrgId = null;
let organizations = [];
let allVariables = [];
let activeCategory = 'identidade';
let uploadedImages = { wallpapers: [], logos: [] };
let scriptTab = 'Core';
let mirrorOrgRepositoryState = null;

const categoryLabels = {
    'dominio': 'Dominio', 'rede': 'Rede', 'proxy': 'Proxy', 'inventario': 'Inventario',
    'navegador': 'Navegador', 'seguranca': 'Seguranca', 'branding': 'Identidade',
    'assets': 'Identidade Visual & Assets', 'monitoramento': 'Monitoramento (Conky)',
    'ambiente': 'Ambiente Grafico',
    'generic': 'Geral', 'custom': 'Custom', 'arquivos': 'Arquivos',
    'acesso_remoto': 'Acesso Remoto', 'impressoras': 'Impressoras',
    'certificados': 'Certificados', 'repositorios': 'Repositorios',
    'aplicacoes': 'Aplicacoes', 'avancado': 'Avancado', 'agente': 'Agente'
};

const categoryOrder = [
    'dominio', 'rede', 'proxy', 'repositorios', 'ambiente', 'navegador',
    'branding', 'assets', 'monitoramento',
    'arquivos', 'impressoras', 'inventario', 'aplicacoes',
    'acesso_remoto', 'certificados', 'seguranca', 'avancado', 'agente', 'generic', 'custom'
];

// ============ SUPER CATEGORIES (7 screens) ============
// Groups the 18 original categories into 7 screens by affinity.
// Variables are NOT removed or renamed — only regrouped visually.
const superCategoryOrder = [
    'identidade', 'rede_proxy', 'dominio_ad', 'repositorios',
    'seguranca_agente', 'aplicacoes_nav', 'estacoes_perifericos'
];

const superCategoryLabels = {
    'identidade': 'Identidade e Personalização',
    'rede_proxy': 'Rede e Proxy',
    'dominio_ad': 'Domínio e Autenticação AD',
    'repositorios': 'Repositórios e Distribuições',
    'seguranca_agente': 'Segurança, Certificados e Agente',
    'aplicacoes_nav': 'Aplicações e Navegadores',
    'estacoes_perifericos': 'Estações, Periféricos e Monitoramento'
};

// Map original category -> super category
const categoryToSuper = {
    'branding': 'identidade',
    'assets': 'identidade',
    'ambiente': 'identidade',
    'rede': 'rede_proxy',
    'proxy': 'rede_proxy',
    'dominio': 'dominio_ad',
    'repositorios': 'repositorios',
    'seguranca': 'seguranca_agente',
    'certificados': 'seguranca_agente',
    'avancado': 'seguranca_agente',
    'agente': 'seguranca_agente',
    'aplicacoes': 'aplicacoes_nav',
    'navegador': 'aplicacoes_nav',
    'impressoras': 'estacoes_perifericos',
    'arquivos': 'estacoes_perifericos',
    'inventario': 'estacoes_perifericos',
    'acesso_remoto': 'estacoes_perifericos',
    'monitoramento': 'estacoes_perifericos',
    'generic': 'estacoes_perifericos',
    'custom': 'estacoes_perifericos'
};

// Within each super category, define sub-section headers by variable name.
// Variables not listed in any section are collected into a "Outras Variáveis" block.
const superCategorySections = {
    'identidade': [
        { title: 'Identidade da OM', vars: ['DISPLAY_NAME', 'OM_ACRONYM', 'OM_NAME', 'THEME'] },
        { title: 'Identidade Visual', vars: ['LOGO_URL', 'WALLPAPER_URL', 'WALLPAPER_LOGIN_URL', 'GREETER_URL'] },
        { title: 'Ambiente Gráfico', vars: ['DISPLAY_MANAGER', 'INSTALL_DESKTOP', 'DESKTOP_ENV'] }
    ],
    'rede_proxy': [
        { title: 'Rede', vars: ['BASE_URL', 'SEEDER_SERVER', 'PRINT_SERVER', 'DNS_PRIMARIO', 'DNS_SECUNDARIO', 'DNS_INTERNET', 'NTP_SERVER'] },
        { title: 'APT (repositórios de pacotes)', vars: ['APT_POLICY', 'MIRROR_LOCAL_SEEDER_PATH', 'MIRROR_LOCAL_OM_URL'] },
        { title: 'CLI (wget/curl/git)', vars: ['CLI_POLICY'] },
        { title: 'Browsers (Firefox/Chrome/Chromium)', vars: ['BROWSER_POLICY'] },
        { title: 'Detalhes do proxy (compartilhado)', vars: ['PROXY_URL', 'PROXY_USER', 'PROXY_PASSWORD_B64', 'PAC_URL', 'NO_PROXY'] },
        { title: 'Proxy (legado)', vars: ['PROXY_MODE', 'PROXY_HTTP', 'PROXY_PORTA'] }
    ],
    'dominio_ad': [
        { title: 'Domínio', vars: ['DOMINIO', 'DOMINIO_NETBIOS', 'OU_PADRAO'] },
        { title: 'Controladores', vars: ['DC_IP', 'DC_SECUNDARIO_IP', 'DC_IP_LIST'] },
        { title: 'Autenticação', vars: ['ADMIN_USERNAME', 'ADMIN_PASSWORD_B64', 'GRUPO_ADMIN', 'AUTH_METHOD'] },
        { title: 'Cache Offline', vars: ['OFFLINE_AUTH_ENABLED', 'OFFLINE_AUTH_DAYS'] }
    ],
    'repositorios': [
        { title: 'Configurações Globais', vars: ['REPOSITORY_MODE', 'REPOSITORY_NODE'] },
        { title: 'URLs por Distribuição', vars: ['REPOSITORY_DEBIAN_ENABLED', 'REPOSITORY_DEBIAN_URL', 'REPOSITORY_UBUNTU_ENABLED', 'REPOSITORY_UBUNTU_URL', 'REPOSITORY_MINT_ENABLED', 'REPOSITORY_MINT_URL', 'REPOSITORY_ZORIN_ENABLED', 'REPOSITORY_ZORIN_URL'] },
        { title: 'Fallback Global', vars: ['REPOSITORY_FALLBACK', 'REPOSITORY_URL'] }
    ],
    'seguranca_agente': [
        { title: 'Certificados', vars: ['CERTIFICATE_AUTO_INSTALL', 'CERTIFICATE_BUNDLE'] },
        { title: 'Agente', vars: ['AGENT_NO_CHECK_CERT', 'INSTALL_AGENT', 'NON_INTERACTIVE'] },
        { title: 'Grupos Sudo', vars: ['GRUPO_ADMIN_AD', 'GRUPO_ADMIN_LINUX', 'GRUPO_DASTI'] },
        { title: 'Exceções', vars: ['JAVA_EXCEPTIONS', 'SSH_GROUPS'] }
    ],
    'aplicacoes_nav': [
        { title: 'Navegadores', vars: ['HOMEPAGE', 'INSTALL_CHROME', 'INSTALL_CHROMIUM', 'INSTALL_FIREFOX52'] },
        { title: 'Ferramentas', vars: ['INSTALL_ONLYOFFICE', 'REMOVER_LIBREOFFICE'] },
        { title: 'Java e Utilitários', vars: ['INSTALL_JAVA8', 'INSTALL_PASSWORD_CHANGER'] }
    ],
    'estacoes_perifericos': [
        { title: 'Impressoras', vars: ['DEFAULT_PRINTER', 'PRINTERS'] },
        { title: 'Arquivos', vars: ['SERVIDOR_ARQUIVOS', 'MOUNT_BASE', 'COMPARTILHAMENTOS'] },
        { title: 'Inventário', vars: ['INVENTORY_ENABLED', 'GLPI_SERVER', 'OCS_SERVER', 'OCS_TAG'] },
        { title: 'Acesso Remoto', vars: ['REMOTE_METHOD', 'SSH_PORT', 'VNC_ENABLED', 'VNC_PASSWORD_B64'] },
        { title: 'Monitoramento', vars: ['CONKY_PROFILE', 'CONKY_CONFIG'] }
    ]
};

// Variables that should appear in a different super category than their original category maps to.
const variableSuperOverride = {
    'NO_PROXY': 'rede_proxy',
    'PAC_URL': 'rede_proxy',
    'PROXY_MODE': 'rede_proxy',
    'PROXY_HTTP': 'rede_proxy',
    'PROXY_PORTA': 'rede_proxy',
    'PROXY_URL': 'rede_proxy',
    'PROXY_USER': 'rede_proxy',
    'PROXY_PASSWORD_B64': 'rede_proxy',
    'APT_POLICY': 'rede_proxy',
    'CLI_POLICY': 'rede_proxy',
    'BROWSER_POLICY': 'rede_proxy',
    'MIRROR_LOCAL_SEEDER_PATH': 'rede_proxy',
    'MIRROR_LOCAL_OM_URL': 'rede_proxy',
    'NTP_SERVER': 'rede_proxy',
    'HOMEPAGE': 'aplicacoes_nav',
    'CERTIFICATE_BUNDLE': 'seguranca_agente',
    'SSH_GROUPS': 'seguranca_agente',
    'JAVA_EXCEPTIONS': 'seguranca_agente',
    'VNC_PASSWORD_B64': 'estacoes_perifericos',
    'DESKTOP_ENV': 'identidade'
};

// Campos dependentes: chave = var pai, valor = lista de vars que aparecem apenas se pai=true
const dependentFields = {
    'VNC_ENABLED': ['VNC_PASSWORD_B64'],
    'INSTALL_DESKTOP': ['DESKTOP_ENV'],
    'INVENTORY_ENABLED': ['OCS_SERVER', 'OCS_TAG', 'GLPI_SERVER'],
    'OFFLINE_AUTH_ENABLED': ['OFFLINE_AUTH_DAYS']
};

// Grupo visual: 3 vars renderizadas juntas em um bloco unico
const groupedVariables = {
    'GRUPO_ADMIN_AD': {block: 'sudo_groups', label: 'Grupo AD (Dominio)', order: 1},
    'GRUPO_ADMIN_LINUX': {block: 'sudo_groups', label: 'Grupo Local', order: 2},
    'GRUPO_DASTI': {block: 'sudo_groups', label: 'Grupo DASTI', order: 3}
};
const groupLabels = {
    'sudo_groups': 'Grupos com privilegio sudo'
};

const variableOptions = {
    'PROXY_MODE': ['NONE', 'MANUAL', 'PAC'],
    'APT_POLICY': ['DIRECT', 'PROXY_NO_AUTH', 'PROXY_WITH_AUTH', 'MIRROR_LOCAL_SEEDER', 'MIRROR_LOCAL_OM', 'MIRROR_OFFICIAL'],
    'CLI_POLICY': ['DIRECT', 'PROXY_NO_AUTH', 'PROXY_WITH_AUTH', 'PAC'],
    'BROWSER_POLICY': ['DIRECT', 'PROXY_NO_AUTH', 'PROXY_WITH_AUTH', 'PAC', 'SYSTEM'],
    'REPOSITORY_MODE': ['PUBLIC', 'MIRROR', 'HYBRID', 'CUSTOM'],
    'REMOTE_METHOD': ['ssh', 'xrdp', 'anydesk', 'rustdesk'],
    'PROXY_PORTA': ['80', '8080', '3128', '8888'],
    'DESKTOP_ENV': ['', 'cinnamon', 'mate', 'gnome', 'xfce', 'kde', 'lxde'],
    'DISPLAY_MANAGER': ['', 'lightdm', 'gdm3', 'sddm'],
    'AUTH_METHOD': ['sssd', 'winbind', 'both'],
    'THEME': ['DEFAULT', 'Adwaita', 'Adwaita-dark', 'Arc', 'Arc-Dark', 'Breeze', 'Breeze-Dark', 'Mint-Y', 'Mint-Y-Dark', 'Numix', 'Pop', 'Yaru', 'Yaru-Dark'],
    'CONKY_PROFILE': ['default', 'minimal', 'full', 'custom'],
    'OFFLINE_AUTH_ENABLED': 'boolean',
    'INVENTORY_ENABLED': 'boolean',
    'CERTIFICATE_AUTO_INSTALL': 'boolean',
    'INSTALL_ONLYOFFICE': 'boolean',
    'INSTALL_CHROME': 'boolean',
    'INSTALL_CHROMIUM': 'boolean',
    'INSTALL_JAVA8': 'boolean',
    'INSTALL_FIREFOX52': 'boolean',
    'INSTALL_DESKTOP': 'boolean',
    'VNC_ENABLED': 'boolean',
    'REMOVER_LIBREOFFICE': 'boolean',
    'INSTALL_AGENT': 'boolean',
    'AGENT_NO_CHECK_CERT': 'boolean'
};

const conkyPositions = ['top_left', 'top_right', 'top_middle', 'middle_left', 'middle_right', 'bottom_left', 'bottom_right', 'bottom_middle'];

const roleLabels = {
    'admin_gap': 'Admin GAP',
    'operador_om': 'Operador OM',
    'auditor': 'Auditor'
};

// ============ THEME TOGGLE ============

function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    const iconDark = document.getElementById('theme-icon-dark');
    const iconLight = document.getElementById('theme-icon-light');
    if (iconDark && iconLight) {
        if (theme === 'light') {
            iconDark.classList.add('hidden');
            iconLight.classList.remove('hidden');
        } else {
            iconDark.classList.remove('hidden');
            iconLight.classList.add('hidden');
        }
    }
}

function toggleTheme() {
    const current = document.documentElement.getAttribute('data-theme') || 'dark';
    const next = current === 'dark' ? 'light' : 'dark';
    localStorage.setItem('seederlinux-theme', next);
    applyTheme(next);
}
window.toggleTheme = toggleTheme;

(function initTheme() {
    const saved = localStorage.getItem('seederlinux-theme') || 'dark';
    applyTheme(saved);
})();

// ============ INITIALIZATION ============

document.addEventListener('DOMContentLoaded', async () => {
    const savedTheme = localStorage.getItem('seederlinux-theme') || 'dark';
    applyTheme(savedTheme);

    document.querySelectorAll('.modal').forEach(m => m.classList.add('hidden'));
    setupEventListeners();

    try {
        const session = await API.get('session');
        if (!session.success) { location.href = '/login.html'; return; }
        currentUser = session.data;
        csrfToken = session.data?.csrf_token || '';
        applyRolePermissions();
        await loadDashboard();
        await loadOrganizations();

// ============ SCRIPT REORDER (DRAG AND DROP) ============

let dragSrcEl = null;

async function showReorderModal() {
    try {
        const res = await API.get('scripts');
        if (!res.success) { Toast.error('Erro ao carregar scripts'); return; }

        const core = res.data.filter(s => s.is_core).sort((a, b) => (a.execution_order || 0) - (b.execution_order || 0));
        const list = document.getElementById('reorder-script-list');
        if (!list) return;
        list.innerHTML = '';

        core.forEach(script => {
            const item = document.createElement('div');
            item.className = 'reorder-item';
            item.draggable = true;
            item.dataset.id = script.id;
            item.dataset.order = script.execution_order;
            item.innerHTML = `
                <span class="drag-handle">&#9776;</span>
                <span class="order-number">${script.execution_order || '?'}</span>
                <span class="script-name">${Utils.escapeHtml(script.name)}</span>
                <span class="text-slate-500 text-xs font-mono">${Utils.escapeHtml(script.filename || '')}</span>
                <span class="script-badge core">Core</span>
            `;
            item.addEventListener('dragstart', handleDragStart);
            item.addEventListener('dragover', handleDragOver);
            item.addEventListener('drop', handleDrop);
            item.addEventListener('dragend', handleDragEnd);
            list.appendChild(item);
        });

        openModal('modal-reorder-scripts');
    } catch (e) {
        Toast.error('Erro ao abrir reordenacao: ' + e.message);
    }
}
window.showReorderModal = showReorderModal;

function handleDragStart(e) {
    dragSrcEl = this;
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', this.dataset.id);
    this.classList.add('dragging');
}

function handleDragOver(e) {
    if (e.preventDefault) e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
    return false;
}

function handleDrop(e) {
    if (e.stopPropagation) e.stopPropagation();
    if (dragSrcEl && dragSrcEl !== this) {
        const parent = this.parentNode;
        const children = [...parent.children];
        const from = children.indexOf(dragSrcEl);
        const to = children.indexOf(this);
        if (from < to) {
            parent.insertBefore(dragSrcEl, this.nextSibling);
        } else {
            parent.insertBefore(dragSrcEl, this);
        }
        updateOrderNumbers();
    }
    return false;
}

function handleDragEnd() {
    this.classList.remove('dragging');
}

function updateOrderNumbers() {
    document.querySelectorAll('#reorder-script-list .reorder-item').forEach((item, i) => {
        const num = item.querySelector('.order-number');
        if (num) num.textContent = i + 1;
    });
}

async function saveScriptOrder() {
    const items = document.querySelectorAll('#reorder-script-list .reorder-item');
    const scripts = Array.from(items).map((item, index) => ({
        id: parseInt(item.dataset.id),
        order: index + 1
    }));

    try {
        const res = await API.post('update-script-order', { scripts });
        if (res.success) {
            Toast.success('Ordem salva com sucesso!');
            closeModal('modal-reorder-scripts');
            if (document.getElementById('scripts-list')) loadAllScripts();
        } else {
            Toast.error(res.error || 'Falha ao salvar ordem');
        }
    } catch (e) {
        Toast.error('Erro ao salvar: ' + e.message);
    }
}
window.saveScriptOrder = saveScriptOrder;

async function resetScriptOrder() {
    if (!confirm('Isso restaurara a ordem padrao dos scripts. Continuar?')) return;
    try {
        const res = await API.post('reset-script-order', {});
        if (res.success) {
            Toast.success('Ordem restaurada para o padrao!');
            showReorderModal();
        } else {
            Toast.error(res.error || 'Falha ao restaurar ordem');
        }
    } catch (e) {
        Toast.error('Erro ao restaurar: ' + e.message);
    }
}
window.resetScriptOrder = resetScriptOrder;

    } catch (e) {
        console.error('Init error:', e);
        location.href = '/login.html';
    }
});

function applyRolePermissions() {
    const role = currentUser?.role;
    document.getElementById('user-name').textContent = currentUser?.username || 'Usuario';
    document.getElementById('user-initial').textContent = (currentUser?.username || 'U').charAt(0).toUpperCase();
    document.getElementById('user-role').textContent = roleLabels[role] || role;

    ['nav-scripts-core', 'nav-users', 'btn-new-org', 'btn-new-user', 'btn-reorder-scripts'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.classList.toggle('hidden', role !== 'admin_gap');
    });
    const mirrorNav = document.getElementById('nav-mirror');
    if (mirrorNav) mirrorNav.classList.toggle('hidden', role !== 'admin_gap');

    ['nav-audit'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.classList.toggle('hidden', role !== 'admin_gap' && role !== 'auditor' && role !== 'operador_om');
    });

    const canExportAudit = role === 'admin_gap';
    const csvBtn = document.getElementById('audit-export-csv');
    const jsonBtn = document.getElementById('audit-export-json');
    if (csvBtn) csvBtn.classList.toggle('hidden', !canExportAudit);
    if (jsonBtn) jsonBtn.classList.toggle('hidden', !canExportAudit);

    const publicThemeSettings = document.getElementById('public-theme-settings');
    if (publicThemeSettings) publicThemeSettings.classList.toggle('hidden', !['admin_gap', 'admin'].includes(role));
}

// ============ VIEW MANAGEMENT ============

function showView(viewName) {
    ['view-dashboard', 'view-organizations', 'view-mirror', 'view-om-detail', 'view-scripts-core', 'view-users', 'view-stations', 'view-audit'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.classList.add('hidden');
    });

    document.querySelectorAll('.nav-item').forEach(btn => btn.classList.remove('active'));

    const view = document.getElementById(`view-${viewName}`);
    if (view) view.classList.remove('hidden');

    const titles = {
        dashboard: ['Dashboard', 'Visao geral do sistema'],
        organizations: ['Organizacoes', 'Dashboard de Organizacoes Militares'],
        mirror: ['Mirror', 'Repositorios APT locais para as OMs'],
        'scripts-core': ['Scripts Core', 'Scripts do sistema'],
        users: ['Usuarios', 'Gerenciamento de usuarios'],
        stations: ['Estacoes', 'Maquinas registradas'],
        audit: ['Auditoria', 'Log de eventos']
    };

    if (titles[viewName]) {
        document.getElementById('page-title').textContent = titles[viewName][0];
        document.getElementById('page-subtitle').textContent = titles[viewName][1];
    }

    const navBtn = document.querySelector(`.nav-item[data-view="${viewName}"]`);
    if (navBtn) navBtn.classList.add('active');

    switch (viewName) {
        case 'dashboard': loadDashboard(); break;
        case 'organizations': loadOrganizationsDashboard(); break;
        case 'mirror': loadMirror(); break;
        case 'users': loadUsers(); break;
        case 'scripts-core': loadAllScripts(); break;
        case 'stations': loadStations(); break;
        case 'audit': loadAuditEvents(); break;
    }
}
window.showView = showView;

// ============ MIRROR ADMINISTRATION ============

const mirrorArchitectures = ['amd64', 'i386', 'arm64'];
const mirrorComponents = ['main', 'contrib', 'non-free', 'restricted', 'universe'];
let mirrorCatalogTab = 'active';
let mirrorCatalog = [];
let mirrorCatalogForm = { type: null, id: null, distroId: null };
let mirrorBasePath = '';

function mirrorIsActive(value) {
    return value === true || value === 't' || value === '1' || value === 1;
}

function renderMirrorOptions() {
    const architectureEl = document.getElementById('mirror-architectures');
    const componentEl = document.getElementById('mirror-components');
    if (architectureEl && !architectureEl.children.length) {
        architectureEl.innerHTML = mirrorArchitectures.map((name, index) => `
            <label class="mirror-chip"><input type="checkbox" data-mirror-architecture value="${name}" ${index === 0 ? 'checked' : ''}><span>${name}</span></label>
        `).join('');
    }
    if (componentEl && !componentEl.children.length) {
        componentEl.innerHTML = mirrorComponents.map((name, index) => `
            <label class="mirror-chip"><input type="checkbox" data-mirror-component value="${name}" ${index === 0 ? 'checked' : ''}><span>${name}</span></label>
        `).join('');
    }
}

function renderMirrorDistros(distros) {
    const container = document.getElementById('mirror-distros-list');
    if (!container) return;
    mirrorCatalog = distros;
    const showActive = mirrorCatalogTab === 'active';
    const visibleDistros = distros.filter(distro => {
        const distroActive = mirrorIsActive(distro.active);
        const hasMatchingVersion = (distro.versions || []).some(version => mirrorIsActive(version.active) === showActive);
        return distroActive === showActive || (!showActive && hasMatchingVersion);
    });
    if (!visibleDistros.length) {
        container.innerHTML = `<p class="text-slate-400">Nenhuma distro ${showActive ? 'ativa' : 'inativa'} no catálogo.</p>`;
        return;
    }
    container.innerHTML = visibleDistros.map(distro => `
        <div class="mirror-distro-block">
            <div class="mirror-distro-heading">
                <label class="mirror-check-label"><input type="checkbox" data-mirror-distro value="${distro.id}" ${mirrorIsActive(distro.active) ? 'checked' : ''}><strong>${Utils.escapeHtml(distro.name)}</strong></label>
                ${distro.base_distro ? `<span class="mirror-base-relation">Base: ${Utils.escapeHtml(distro.base_distro.name)}</span>` : ''}
            </div>
            <div class="mirror-catalog-actions"><button type="button" class="btn btn-secondary btn-sm" onclick="editMirrorDistro(${distro.id})">Editar distro</button><button type="button" class="btn btn-secondary btn-sm" onclick="toggleMirrorDistro(${distro.id})">${mirrorIsActive(distro.active) ? 'Desativar' : 'Ativar'}</button><button type="button" class="btn btn-primary btn-sm" onclick="addMirrorVersion(${distro.id})">Adicionar versão</button></div>
            <div class="mirror-version-list">
                ${(distro.versions || []).filter(version => mirrorIsActive(version.active) === showActive).map(version => `<div class="mirror-version"><label class="mirror-version-label"><input type="checkbox" data-mirror-version data-distro-id="${distro.id}" value="${version.id}" ${mirrorIsActive(version.active) ? 'checked' : ''}><span>${Utils.escapeHtml(version.version)}</span><span class="badge ${version.status === 'current' ? 'badge-success' : version.status === 'future' ? 'badge-info' : 'badge-secondary'}">${Utils.escapeHtml(version.status)}</span></label><span class="mirror-version-actions"><button type="button" onclick="editMirrorVersion(${version.id})" title="Editar versão">Editar</button><button type="button" onclick="toggleMirrorVersion(${version.id})" title="Ativar ou desativar versão">${mirrorIsActive(version.active) ? 'Desativar' : 'Ativar'}</button><button type="button" class="mirror-delete-action" onclick="deleteMirrorVersion(${version.id})" title="Remover versão">Remover</button></span></div>`).join('')}
            </div>
        </div>
    `).join('');
}

function renderMirrorJobs(jobs) {
    const body = document.getElementById('mirror-jobs-tbody');
    if (!body) return;
    body.innerHTML = jobs?.length ? jobs.map(job => `<tr><td>${Utils.escapeHtml(job.job_type)}</td><td><span class="badge ${job.status === 'success' ? 'badge-success' : job.status === 'error' ? 'badge-danger' : 'badge-secondary'}">${Utils.escapeHtml(job.status)}</span></td><td>${Utils.formatDate(job.started_at)}</td><td>${Utils.escapeHtml(job.details || '-')}</td></tr>`).join('') : '<tr><td colspan="4" class="text-center text-slate-400">Nenhum job registrado.</td></tr>';
}

function openMirrorCatalogForm(type, item = {}, distroId = null) {
    mirrorCatalogForm = { type, id: item.id || null, distroId: distroId || item.distro_id || null };
    const isDistro = type === 'distro';
    document.getElementById('mirror-catalog-modal-title').textContent = isDistro ? (item.id ? 'Editar distro' : 'Adicionar distro') : (item.id ? 'Editar versão' : 'Adicionar versão');
    document.getElementById('mirror-distro-fields').classList.toggle('hidden', !isDistro);
    document.getElementById('mirror-version-fields').classList.toggle('hidden', isDistro);
    if (isDistro) {
        document.getElementById('mirror-catalog-name').value = item.name || '';
        document.getElementById('mirror-catalog-codename').value = item.codename || '';
        const baseSelect = document.getElementById('mirror-catalog-base');
        baseSelect.innerHTML = '<option value="">Nenhuma</option>' + mirrorCatalog.filter(distro => Number(distro.id) !== Number(item.id)).map(distro => `<option value="${distro.id}">${Utils.escapeHtml(distro.name)}</option>`).join('');
        baseSelect.value = item.base_distro?.id || '';
    } else {
        document.getElementById('mirror-catalog-version').value = item.version || '';
        document.getElementById('mirror-catalog-status').value = item.status || 'current';
    }
    openModal('modal-mirror-catalog');
}

async function addMirrorDistro() {
    openMirrorCatalogForm('distro');
}

async function editMirrorDistro(id) {
    const distro = mirrorCatalog.find(item => Number(item.id) === Number(id));
    if (distro) openMirrorCatalogForm('distro', distro);
}

async function toggleMirrorDistro(id) {
    if (!confirm('Alternar o estado desta distro? Suas versões ficarão ocultas quando a distro estiver inativa.')) return;
    const distro = mirrorCatalog.find(item => Number(item.id) === Number(id));
    try { const res = await API.post('mirror-toggle-distro', { distro_id: id, active: !mirrorIsActive(distro?.active) }); if (!res.success) throw new Error(res.error); Toast.success(res.message || 'Estado da distro atualizado.'); await loadMirror(); } catch (error) { Toast.error(error.message || 'Não foi possível alterar a distro.'); }
}

async function addMirrorVersion(distroId) {
    openMirrorCatalogForm('version', {}, distroId);
}

function findMirrorVersion(id) { return mirrorCatalog.flatMap(distro => distro.versions || []).find(version => Number(version.id) === Number(id)); }

async function editMirrorVersion(id) {
    const versionData = findMirrorVersion(id);
    if (versionData) openMirrorCatalogForm('version', versionData);
}

async function saveMirrorCatalogForm() {
    const isDistro = mirrorCatalogForm.type === 'distro';
    const data = isDistro ? {
        name: document.getElementById('mirror-catalog-name').value.trim(),
        codename: document.getElementById('mirror-catalog-codename').value.trim(),
        base_distro_id: document.getElementById('mirror-catalog-base').value || null
    } : {
        version: document.getElementById('mirror-catalog-version').value.trim(),
        status: document.getElementById('mirror-catalog-status').value
    };
    const action = isDistro ? (mirrorCatalogForm.id ? 'mirror-update-distro' : 'mirror-add-distro') : (mirrorCatalogForm.id ? 'mirror-update-version' : 'mirror-add-version');
    if (isDistro && mirrorCatalogForm.id) data.distro_id = mirrorCatalogForm.id;
    if (!isDistro && mirrorCatalogForm.id) data.version_id = mirrorCatalogForm.id;
    if (!isDistro && !mirrorCatalogForm.id) data.distro_id = mirrorCatalogForm.distroId;
    try {
        const res = await API.post(action, data);
        if (!res.success) throw new Error(res.error || 'Falha ao salvar item');
        closeModal('modal-mirror-catalog');
        Toast.success('Catálogo atualizado.');
        await loadMirror();
    } catch (error) { Toast.error(error.message || 'Não foi possível salvar o item.'); }
}

async function toggleMirrorVersion(id) {
    if (!confirm('Alternar o estado desta versão?')) return;
    const version = findMirrorVersion(id);
    try { const res = await API.post('mirror-toggle-version', { version_id: id, active: !mirrorIsActive(version?.active) }); if (!res.success) throw new Error(res.error); Toast.success(res.message || 'Estado da versão atualizado.'); await loadMirror(); } catch (error) { Toast.error(error.message || 'Não foi possível alterar a versão.'); }
}

async function deleteMirrorVersion(id) {
    if (!confirm('Remover esta versão do catálogo?')) return;
    try { const res = await API.post('mirror-delete-version', { version_id: id }); if (!res.success) throw new Error(res.error); Toast.success('Versão removida.'); await loadMirror(); } catch (error) { Toast.error(error.message || 'Não foi possível remover a versão.'); }
}
window.editMirrorDistro = editMirrorDistro;
window.toggleMirrorDistro = toggleMirrorDistro;
window.addMirrorVersion = addMirrorVersion;
window.editMirrorVersion = editMirrorVersion;
window.toggleMirrorVersion = toggleMirrorVersion;
window.deleteMirrorVersion = deleteMirrorVersion;

function renderMirrorOrganizations(settings) {
    const body = document.getElementById('mirror-orgs-tbody');
    if (!body) return;
    body.innerHTML = settings.length ? settings.map(org => `
        <tr>
            <td><strong>${Utils.escapeHtml(org.acronym)}</strong><span class="mirror-org-name">${Utils.escapeHtml(org.name)}</span><span class="mirror-org-repository">Modo: ${Utils.escapeHtml(org.repository_mode || '-')}</span><span class="mirror-org-repository">Debian: ${Utils.escapeHtml(org.repository_debian_url || '-')}</span></td>
            <td><label class="toggle-switch"><input type="checkbox" data-mirror-org-enabled="${org.id}" onchange="saveMirrorOrgSetting(${org.id})" ${org.use_local_mirror === true || org.use_local_mirror === 't' ? 'checked' : ''}><span class="toggle-slider"></span></label></td>
            <td><input class="form-input mirror-priority" type="number" min="0" max="10000" value="${org.mirror_priority !== null && org.mirror_priority !== undefined ? Number(org.mirror_priority) : 100}" data-mirror-org-priority="${org.id}"></td>
            <td class="text-right"><button type="button" class="btn btn-secondary btn-sm" onclick="saveMirrorOrgSetting(${org.id})">Salvar</button></td>
        </tr>
    `).join('') : '<tr><td colspan="4" class="text-center text-slate-400">Nenhuma OM ativa.</td></tr>';
}

async function loadMirror() {
    if (currentUser?.role !== 'admin_gap') return;
    renderMirrorOptions();
    try {
        const res = await API.get('mirror-status');
        if (!res.success) throw new Error(res.error || 'Falha ao carregar o Mirror');
        const data = res.data || {};
        mirrorBasePath = data.mirror_base_path || '';
        document.getElementById('mirror-enabled').checked = Boolean(data.enabled);
        document.getElementById('mirror-tool').value = data.tool || 'aptly';
        document.getElementById('mirror-url-base').value = data.mirror_url_base || '';
        document.getElementById('mirror-base-path-display').textContent = mirrorBasePath || '-';
        document.getElementById('mirror-verify-gpg').checked = Boolean(data.verify_gpg);
        document.getElementById('mirror-interval').value = data.sync_interval_hours || 24;
        document.getElementById('mirror-auto-cleanup').checked = Boolean(data.auto_cleanup_enabled);
        document.getElementById('mirror-retention').value = data.retention_snapshots ?? 2;
        document.getElementById('mirror-quarantine').value = data.quarantine_days ?? 7;
        const pathLocked = Boolean(data.path_locked);
        const pathLock = document.getElementById('mirror-path-lock');
        const pathButton = document.getElementById('btn-edit-mirror-path');
        const pathHelp = document.getElementById('mirror-path-help');
        if (pathLock) {
            pathLock.textContent = pathLocked ? 'Bloqueado' : 'Configuração inicial';
            pathLock.className = `badge ${pathLocked ? 'badge-warning' : 'badge-info'}`;
        }
        if (pathButton) pathButton.classList.toggle('hidden', pathLocked);
        if (pathHelp) pathHelp.textContent = pathLocked
            ? 'Bloqueado após ativação ou criação de jobs; compartilhado pelo mirror e pelo Apache.'
            : 'Pode ser definido apenas antes de ativar o mirror ou criar jobs.';
        document.getElementById('mirror-free-space').textContent = Number(data.disk_free_gb || 0).toFixed(2);
        document.getElementById('mirror-total-space').textContent = Number(data.disk_total_gb || 0).toFixed(2);
        document.getElementById('mirror-org-usage').textContent = `${data.organization_usage || 0} OM(s) ativas`;
        const lastJob = document.getElementById('mirror-last-job');
        if (lastJob) {
            lastJob.textContent = data.last_job_status ? `Último job: ${data.last_job_status}` : 'Sem sincronização';
            lastJob.className = `badge ${data.last_job_status === 'success' ? 'badge-success' : data.last_job_status === 'error' ? 'badge-danger' : 'badge-secondary'}`;
        }
        renderMirrorDistros(data.available_distros || []);
        renderMirrorOrganizations(data.organization_settings || []);
        renderMirrorJobs(data.jobs || []);
        updateMirrorCapacity();
    } catch (error) {
        Toast.error(error.message || 'Não foi possível carregar o Mirror.');
    }
}

async function syncMirrorNow() {
    if (!confirm('Enfileirar uma sincronização do Mirror agora? A execução real ainda não está habilitada.')) return;
    const button = document.getElementById('btn-mirror-sync-now');
    if (button) button.disabled = true;
    try {
        const res = await API.post('mirror-sync-now', {});
        if (!res.success) throw new Error(res.error || 'Falha ao enfileirar sincronização');
        Toast.success(`Job #${res.data.job_id} criado com status ${res.data.status}.`);
        await loadMirror();
    } catch (error) {
        Toast.error(error.message || 'Não foi possível enfileirar a sincronização.');
    } finally {
        if (button) button.disabled = false;
    }
}

function updateMirrorCapacity() {
    const free = Number(document.getElementById('mirror-free-space')?.textContent);
    const estimated = Number(document.getElementById('mirror-estimated-space')?.textContent);
    const alert = document.getElementById('mirror-capacity-alert');
    const state = document.getElementById('mirror-capacity-state');
    if (!alert || !state || !Number.isFinite(free) || !Number.isFinite(estimated) || estimated <= 0) return;
    const insufficient = estimated > free;
    alert.textContent = insufficient ? 'Espaço livre insuficiente para esta seleção.' : 'Espaço livre suficiente para esta seleção.';
    alert.classList.toggle('hidden', false);
    alert.classList.toggle('is-danger', insufficient);
    alert.classList.toggle('is-success', !insufficient);
    state.textContent = insufficient ? 'Atenção' : 'Viável';
    state.className = `badge ${insufficient ? 'badge-danger' : 'badge-success'}`;
}

async function saveMirrorConfig() {
    const button = document.getElementById('btn-save-mirror-config');
    button.disabled = true;
    try {
        const res = await API.post('mirror-save-config', {
            enabled: document.getElementById('mirror-enabled').checked,
            tool: document.getElementById('mirror-tool').value,
            mirror_base_path: mirrorBasePath,
            mirror_url_base: document.getElementById('mirror-url-base').value.trim(),
            verify_gpg: document.getElementById('mirror-verify-gpg').checked,
            sync_interval_hours: Number(document.getElementById('mirror-interval').value),
            auto_cleanup_enabled: document.getElementById('mirror-auto-cleanup').checked,
            retention_snapshots: Number(document.getElementById('mirror-retention').value),
            quarantine_days: Number(document.getElementById('mirror-quarantine').value)
        });
        if (!res.success) throw new Error(res.error || 'Falha ao salvar configuração');
        Toast.success('Configuração global do Mirror salva.');
        await loadMirror();
    } catch (error) {
        Toast.error(error.message || 'Não foi possível salvar a configuração.');
    } finally {
        button.disabled = false;
    }
}

function openMirrorPathModal() {
    const button = document.getElementById('btn-edit-mirror-path');
    if (button?.classList.contains('hidden')) return;
    document.getElementById('mirror-path-input').value = mirrorBasePath;
    openModal('modal-mirror-path');
}

function applyMirrorPath() {
    const value = document.getElementById('mirror-path-input').value.trim();
    if (!value) {
        Toast.error('Informe um caminho absoluto para o mirror.');
        return;
    }
    mirrorBasePath = value;
    document.getElementById('mirror-base-path-display').textContent = value;
    closeModal('modal-mirror-path');
    Toast.info('Caminho alterado localmente. Salve a configuração para persistir.');
}

async function saveMirrorOrgSetting(organizationId) {
    const enabled = document.querySelector(`[data-mirror-org-enabled="${organizationId}"]`);
    const priority = document.querySelector(`[data-mirror-org-priority="${organizationId}"]`);
    try {
        const res = await API.post('mirror-save-org-settings', {
            organization_id: organizationId,
            use_local_mirror: enabled?.checked || false,
            mirror_priority: Number(priority?.value || 100)
        });
        if (!res.success) throw new Error(res.error || 'Falha ao salvar preferência');
        Toast.success('Preferência da OM salva.');
        await loadMirror();
        if (currentOrgId && Number(currentOrgId) === Number(organizationId)) {
            await loadVariables(organizationId);
        }
    } catch (error) {
        Toast.error(error.message || 'Não foi possível salvar a preferência.');
    }
}
window.saveMirrorOrgSetting = saveMirrorOrgSetting;

async function estimateMirror() {
    const button = document.getElementById('btn-estimate-mirror');
    const payload = {
        distros: [...document.querySelectorAll('[data-mirror-distro]:checked')].map(input => input.value),
        versions: [...document.querySelectorAll('[data-mirror-version]:checked')].map(input => input.value),
        architectures: [...document.querySelectorAll('[data-mirror-architecture]:checked')].map(input => input.value),
        components: [...document.querySelectorAll('[data-mirror-component]:checked')].map(input => input.value)
    };
    if (button) button.disabled = true;
    const msgEl = document.getElementById('mirror-estimate-message');
    if (msgEl) msgEl.textContent = 'Calculando estimativa a partir dos indices upstream...';
    try {
        const res = await API.post('mirror-estimate', payload);
        if (!res.success) throw new Error(res.error || 'Falha ao calcular estimativa');
        const data = res.data || {};
        const estimatedGb = data.estimated_gb;
        document.getElementById('mirror-estimated-space').textContent = estimatedGb == null ? '-' : Number(estimatedGb).toFixed(2);
        document.getElementById('mirror-estimate-message').textContent = data.message || 'Estimativa atualizada.';

        const errorsEl = document.getElementById('mirror-estimate-errors');
        if (errorsEl) {
            const errors = data.errors || [];
            if (errors.length > 0) {
                errorsEl.innerHTML = errors.slice(0, 10).map(e =>
                    `<div class="text-sm text-amber-400 mt-1">${Utils.escapeHtml(e.distro)} ${Utils.escapeHtml(e.version)} / ${Utils.escapeHtml(e.arch)} / ${Utils.escapeHtml(e.component)}: ${Utils.escapeHtml(e.error)}</div>`
                ).join('') + (errors.length > 10 ? `<div class="text-sm text-slate-500 mt-1">... e mais ${errors.length - 10} erro(s)</div>` : '');
                errorsEl.classList.remove('hidden');
            } else {
                errorsEl.innerHTML = '';
                errorsEl.classList.add('hidden');
            }
        }

        updateMirrorCapacity();
    } catch (error) {
        Toast.error(error.message || 'Não foi possível calcular a estimativa.');
    } finally {
        if (button) button.disabled = false;
    }
}

// ============ OM VIEW SWITCHER ============

function switchOMView(panel) {
    const dashPanel = document.getElementById('om-view-dashboard');
    const configPanel = document.getElementById('om-view-config');
    const btnDash = document.getElementById('btn-om-dashboard');
    const btnConfig = document.getElementById('btn-om-config');

    if (panel === 'dashboard') {
        dashPanel.classList.remove('hidden');
        configPanel.classList.add('hidden');
        btnDash.classList.replace('btn-secondary', 'btn-primary');
        btnConfig.classList.replace('btn-primary', 'btn-secondary');
    } else {
        dashPanel.classList.add('hidden');
        configPanel.classList.remove('hidden');
        btnConfig.classList.replace('btn-secondary', 'btn-primary');
        btnDash.classList.replace('btn-primary', 'btn-secondary');
    }
}
window.switchOMView = switchOMView;

// ============ GLOBAL DASHBOARD ============

async function loadDashboard() {
    const res = await API.get('dashboard');
    if (!res.success) return;

    const stats = res.data;
    document.getElementById('dash-orgs').textContent = stats.organizations || 0;
    document.getElementById('dash-scripts').textContent = stats.scripts || 0;
    document.getElementById('dash-vars').textContent = stats.variables || 0;
    document.getElementById('dash-bundles').textContent = stats.bundles_this_month || 0;
    document.getElementById('dash-stations-online').textContent = stats.stations_online || 0;
    document.getElementById('dash-stations-outdated').textContent = stats.stations_outdated || 0;

    if (['admin_gap', 'admin'].includes(currentUser?.role)) await loadPublicTheme();

    const stationsEl = document.getElementById('recent-stations');
    if (stationsEl) {
        if (stats.recent_stations?.length) {
            stationsEl.innerHTML = `
                <table class="w-full text-sm">
                    <thead><tr class="bg-slate-900">
                        <th class="px-3 py-2 text-left text-slate-400">Hostname</th>
                        <th class="px-3 py-2 text-left text-slate-400">IP</th>
                        <th class="px-3 py-2 text-left text-slate-400">Check-in</th>
                        <th class="px-3 py-2 text-left text-slate-400">OM</th>
                        <th class="px-3 py-2 text-left text-slate-400">Status</th>
                    </tr></thead>
                    <tbody>
                        ${stats.recent_stations.map(s => `
                            <tr class="border-b border-slate-700">
                                <td class="px-3 py-2">${Utils.escapeHtml(s.hostname)}</td>
                                <td class="px-3 py-2">${Utils.escapeHtml(s.ip_address || '-')}</td>
                                <td class="px-3 py-2">${Utils.formatDate(s.last_checkin)}</td>
                                <td class="px-3 py-2">${Utils.escapeHtml(s.org_acronym || '-')}</td>
                                <td class="px-3 py-2"><span class="badge ${s.status === 'Atualizado' ? 'badge-success' : 'badge-warning'}">${s.status}</span></td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>`;
        } else {
            stationsEl.innerHTML = '<p class="text-slate-400 text-center py-4">Nenhuma estacao registrada</p>';
        }
    }

    const orgsEl = document.getElementById('recent-orgs');
    if (orgsEl && stats.recent_orgs?.length) {
        orgsEl.innerHTML = stats.recent_orgs.map(o => `
            <div class="p-3 bg-slate-800 rounded-lg border border-slate-700 flex items-center justify-between mb-2">
                <div class="flex items-center gap-2">
                    <span class="font-semibold text-blue-400">${Utils.escapeHtml(o.acronym)}</span>
                    <span class="text-slate-300">${Utils.escapeHtml(o.name)}</span>
                </div>
                <button onclick="selectOrganization(${o.id})" class="text-sm text-blue-400 hover:text-blue-300">Ver</button>
            </div>
        `).join('');
    }
}

async function loadPublicTheme() {
    const select = document.getElementById('public-theme-select');
    const status = document.getElementById('public-theme-status');
    if (!select) return;

    try {
        const res = await API.get('public-theme');
        if (!res.success) throw new Error(res.error || 'Falha ao carregar o tema');
        const publishedTheme = res.data?.theme || 'classic';
        select.value = publishedTheme;
        if (status) status.textContent = ({ classic: 'Clássico publicado', modern: 'Moderno publicado', solar: 'Solar publicado' })[publishedTheme] || 'Clássico publicado';
    } catch (error) {
        if (status) status.textContent = 'Indisponível';
        Toast.error('Não foi possível carregar o tema público.');
    }
}

async function savePublicTheme() {
    const select = document.getElementById('public-theme-select');
    const status = document.getElementById('public-theme-status');
    const button = document.getElementById('btn-save-public-theme');
    if (!select || !['admin_gap', 'admin'].includes(currentUser?.role)) return;

    button.disabled = true;
    try {
        const res = await API.post('set-public-theme', { theme: select.value });
        if (!res.success) throw new Error(res.error || 'Falha ao salvar o tema');
        if (status) status.textContent = ({ classic: 'Clássico publicado', modern: 'Moderno publicado', solar: 'Solar publicado' })[select.value] || 'Clássico publicado';
        Toast.success('Tema da página pública atualizado.');
    } catch (error) {
        Toast.error(error.message || 'Não foi possível salvar o tema público.');
        await loadPublicTheme();
    } finally {
        button.disabled = false;
    }
}
window.savePublicTheme = savePublicTheme;

// ============ ORGANIZATIONS DASHBOARD ============

async function loadOrganizationsDashboard() {
    const [orgsRes, dashRes] = await Promise.all([
        API.get('organizations'),
        API.get('dashboard')
    ]);

    if (!orgsRes.success) return;
    const orgs = orgsRes.data || [];

    const dash = dashRes.success ? dashRes.data : {};

    document.getElementById('orgs-dash-total').textContent = orgs.length;
    document.getElementById('orgs-dash-stations').textContent = dash.stations_total || orgs.reduce((a, o) => a + (o.station_count || 0), 0);
    document.getElementById('orgs-dash-online').textContent = dash.stations_online || 0;
    document.getElementById('orgs-dash-bundles').textContent = dash.bundles_this_month || 0;

    const searchWrapper = document.getElementById('orgs-search-wrapper');
    if (searchWrapper) searchWrapper.style.display = orgs.length > 3 ? 'block' : 'none';

    const grid = document.getElementById('orgs-cards-grid');
    if (!grid) return;

    if (orgs.length === 0) {
        grid.innerHTML = '<p class="text-slate-400 text-center py-8">Nenhuma organizacao cadastrada.</p>';
        return;
    }

    grid.innerHTML = orgs.map(org => {
        const sigla = Utils.escapeHtml(org.acronym || '');
        const nome = Utils.escapeHtml(org.name || '');
        const dominio = Utils.escapeHtml(org.domain || '');
        const scripts = org.script_count || 0;
        const stations = org.station_count || 0;
        const bundles = org.bundle_count || 0;
        const conformity = org.conformity != null ? org.conformity : 0;
        const confClass = conformity >= 80 ? 'green' : conformity >= 50 ? 'amber' : 'red';
        const allUpdated = org.all_updated != null ? org.all_updated : (conformity >= 100);

        const logoHtml = org.logo_url
            ? `<div class="org-logo"><img class="org-logo-img" src="${Utils.escapeHtml(org.logo_url)}" alt="${sigla}" onerror="if(this.style)this.style.display='none';if(this.nextElementSibling&&this.nextElementSibling.style)this.nextElementSibling.style.display='flex'"></div><div class="org-logo-placeholder" style="display:none">${sigla.substring(0, 3).toUpperCase()}</div>`
            : `<div class="org-logo-placeholder">${sigla.substring(0, 3).toUpperCase()}</div>`;

        const statusHtml = allUpdated
            ? '<span class="badge badge-success">✓ Todas atualizadas</span>'
            : `<span class="badge badge-warning">${conformity}% conformes</span>`;

        return `
            <div class="card p-4 cursor-pointer hover:border-blue-500 transition-all" onclick="selectOrganization(${org.id})">
                <div class="flex items-center gap-3 mb-3">
                    ${logoHtml}
                    <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2">
                            <span class="font-semibold text-white truncate">${nome}</span>
                            <span class="badge badge-secondary">${sigla}</span>
                        </div>
                        <div class="text-xs text-slate-400 truncate">${dominio}</div>
                    </div>
                </div>
                <div class="flex gap-4 text-xs text-slate-400 mb-2">
                    <span>${scripts} scripts</span>
                    <span>${stations} estacoes</span>
                    <span>${bundles} bundles</span>
                </div>
                <div class="conformity-bar">
                    <div class="conformity-bar-fill ${confClass}" style="width: ${conformity}%"></div>
                </div>
                <div class="mt-2">${statusHtml}</div>
            </div>
        `;
    }).join('');

    const searchInput = document.getElementById('orgs-search');
    if (searchInput && !searchInput.dataset.bound) {
        searchInput.dataset.bound = '1';
        searchInput.addEventListener('input', () => {
            const q = searchInput.value.toLowerCase();
            grid.querySelectorAll('.card').forEach((card, i) => {
                const o = orgs[i];
                const text = `${o.name} ${o.acronym} ${o.domain}`.toLowerCase();
                card.style.display = text.includes(q) ? '' : 'none';
            });
        });
    }
}

// ============ PER-OM DASHBOARD ============

async function loadOMDashboard(orgId) {
    const res = await API.get('dashboard', { org_id: orgId });
    if (!res.success) return;

    const s = res.data;
    document.getElementById('om-stat-scripts').textContent = s.scripts || 0;
    document.getElementById('om-stat-vars').textContent = s.variables || 0;
    document.getElementById('om-stat-bundles').textContent = s.bundles_this_month || 0;
    document.getElementById('om-stat-online').textContent = s.stations_online || 0;
    document.getElementById('om-stat-outdated').textContent = s.stations_outdated || 0;

    // Recent stations for this OM
    const el = document.getElementById('om-recent-stations');
    if (el) {
        if (s.recent_stations?.length) {
            el.innerHTML = `
                <table class="w-full text-sm">
                    <thead><tr class="bg-slate-900">
                        <th class="px-3 py-2 text-left text-slate-400">Hostname</th>
                        <th class="px-3 py-2 text-left text-slate-400">IP</th>
                        <th class="px-3 py-2 text-left text-slate-400">Check-in</th>
                        <th class="px-3 py-2 text-left text-slate-400">Status</th>
                    </tr></thead>
                    <tbody>
                        ${s.recent_stations.map(st => `
                            <tr class="border-b border-slate-700">
                                <td class="px-3 py-2">${Utils.escapeHtml(st.hostname)}</td>
                                <td class="px-3 py-2 font-mono text-xs">${Utils.escapeHtml(st.ip_address || '-')}</td>
                                <td class="px-3 py-2">${Utils.formatDate(st.last_checkin)}</td>
                                <td class="px-3 py-2"><span class="badge ${st.status === 'Atualizado' ? 'badge-success' : 'badge-warning'}">${st.status}</span></td>
                            </tr>
                        `).join('')}
                    </tbody>
                </table>`;
        } else {
            el.innerHTML = '<p class="text-slate-400 text-center py-4">Nenhuma estacao registrada ainda.<br><span class="text-xs">Use: <code>sudo seeder-agent --org ' + Utils.escapeHtml(organizations.find(o=>o.id===orgId)?.acronym||'SIGLA') + '</code></span></p>';
        }
    }

    // Scripts overview
    const scriptsEl = document.getElementById('om-scripts-overview');
    if (scriptsEl) {
        const scripts = s.org_scripts || [];
        const core = scripts.filter(sc => sc.is_core);
        const custom = scripts.filter(sc => !sc.is_core);
        scriptsEl.innerHTML = `
            <div class="space-y-1">
                ${core.map(sc => `
                    <div class="flex items-center justify-between py-2 border-b border-slate-700">
                        <div class="flex items-center gap-2">
                            <span class="px-1.5 py-0.5 text-xs bg-blue-500/20 text-blue-400 rounded">Core</span>
                            <span class="text-sm text-white">${Utils.escapeHtml(sc.name)}</span>
                        </div>
                        <button onclick="viewScript(${sc.id})" class="text-xs text-blue-400 hover:text-blue-300">Ver</button>
                    </div>
                `).join('')}
                ${custom.map(sc => `
                    <div class="flex items-center justify-between py-2 border-b border-slate-700">
                        <div class="flex items-center gap-2">
                            <span class="px-1.5 py-0.5 text-xs bg-emerald-500/20 text-emerald-400 rounded">Custom</span>
                            <span class="text-sm text-white">${Utils.escapeHtml(sc.name)}</span>
                        </div>
                        <button onclick="viewScript(${sc.id})" class="text-xs text-blue-400 hover:text-blue-300">Ver</button>
                    </div>
                `).join('')}
                ${!scripts.length ? '<p class="text-slate-400 text-sm text-center py-4">Nenhum script</p>' : ''}
            </div>`;
    }
}

// ============ ORGANIZATIONS ============

async function loadOrganizations() {
    const res = await API.get('organizations');
    if (!res.success) return;

    organizations = res.data;
    const el = document.getElementById('om-list');
    if (!el) return;

    if (!organizations.length) {
        el.innerHTML = '<p class="text-slate-500 text-sm text-center py-4">Nenhuma organizacao</p>';
        return;
    }

    el.innerHTML = organizations.map(o => `
        <button class="nav-item w-full flex items-center gap-3 px-3 py-2 rounded-lg text-slate-300 hover:bg-slate-700 text-left"
                data-org-id="${o.id}" onclick="selectOrganization(${o.id})">
            <div class="w-10 h-10 rounded-lg bg-gradient-to-br from-blue-500 to-emerald-500 flex items-center justify-center text-white font-bold text-sm flex-shrink-0">
                ${o.logo_url
                    ? `<img src="${Utils.escapeHtml(o.logo_url)}" class="w-full h-full object-cover rounded" onerror="if(this.parentElement)this.parentElement.textContent='${o.acronym.substring(0, 3)}'">`
                    : o.acronym.substring(0, 3)}
            </div>
            <div class="min-w-0">
                <span class="block font-medium truncate">${Utils.escapeHtml(o.acronym)}</span>
                <span class="block text-xs text-slate-500 truncate">${Utils.escapeHtml(o.name)}</span>
            </div>
        </button>
    `).join('');

    const select = document.getElementById('user-organization');
    if (select) {
        select.innerHTML = '<option value="">Nenhuma</option>' + organizations.map(o =>
            `<option value="${o.id}">${Utils.escapeHtml(o.acronym)}</option>`
        ).join('');
    }
}

async function selectOrganization(orgId) {
    currentOrgId = orgId;
    const org = organizations.find(o => o.id === orgId);
    if (!org) return;

    // Update nav
    document.querySelectorAll('.nav-item[data-org-id]').forEach(btn => {
        btn.classList.toggle('active', parseInt(btn.dataset.orgId) === orgId);
    });

    // Hide all main views, show OM detail
    ['view-dashboard', 'view-scripts-core', 'view-users', 'view-stations', 'view-audit'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.classList.add('hidden');
    });
    document.getElementById('view-om-detail').classList.remove('hidden');

    // Update header
    document.getElementById('page-title').textContent = org.acronym;
    document.getElementById('page-subtitle').textContent = org.name;

    // Update OM header elements
    document.getElementById('om-display-name').textContent = org.name;
    document.getElementById('om-display-acronym').textContent = org.acronym;
    document.getElementById('om-display-domain').textContent = org.domain || 'Sem dominio';

    // Edit modal prefill
    document.getElementById('edit-org-name').value = org.name;
    document.getElementById('edit-org-acronym').value = org.acronym;
    document.getElementById('edit-org-domain').value = org.domain || '';
    document.getElementById('edit-org-description').value = org.description || '';

    // Badge
    const badge = document.getElementById('om-badge');
    badge.innerHTML = org.logo_url
        ? `<img src="${Utils.escapeHtml(org.logo_url)}" class="w-full h-full object-cover rounded-xl" onerror="if(this.parentElement)this.parentElement.textContent='${org.acronym.substring(0, 3)}'">`
        : org.acronym.substring(0, 3);

    // Show overview panel by default
    switchOMView('dashboard');
    await loadOMDashboard(orgId);

    // Pre-carregar variaveis e scripts para que as abas ja tenham dados
    loadVariables(orgId);
    loadOrgScripts(orgId);
    loadBundles(orgId);
}
window.selectOrganization = selectOrganization;

function normalizeText(value) {
    return String(value || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
}

function matchesVariableSearch(variable, searchText) {
    if (!searchText) return true;
    const haystack = [variable.name, variable.description, variable.placeholder].join(' ');
    return normalizeText(haystack).includes(searchText);
}

const variableHelpText = {
    NTP_SERVER: 'Apenas IP ou hostname, sem http://. Ex: pool.ntp.org',
    HOMEPAGE: 'Inclua http:// ou https://. Ex: http://www.intraer',
    PRINTERS: 'Nomes separados por vírgula. Ex: printer1,printer2',
    COMPARTILHAMENTOS: 'Nomes separados por vírgula. Ex: publico,usuarios,setores',
    SSH_GROUPS: 'Grupos separados por vírgula. Ex: linux-admins,_DASTI'
};

function getVariableTooltip(variable) {
    const variableName = String(variable?.name || '').toUpperCase();
    return variableHelpText[variableName] || variable?.description || '';
}

function getFieldLabelMarkup(variable, labelText) {
    const tooltip = getVariableTooltip(variable);
    const label = Utils.escapeHtml(labelText || variable.name || '');
    if (!tooltip) return label;
    return `
        <span class="var-label-with-tooltip">
            <span class="var-label-text">${label}</span>
            <span class="var-help-icon" tabindex="0" aria-label="${Utils.escapeHtml(tooltip)}">?</span>
            <span class="var-tooltip">${Utils.escapeHtml(tooltip)}</span>
        </span>
    `;
}

function updateVariableSearchCount() {
    const countEl = document.getElementById('var-results-count');
    if (!countEl) return;
    const searchInput = document.getElementById('var-search');
    const searchValue = searchInput ? searchInput.value.trim() : '';
    const total = document.querySelectorAll('.var-row').length;
    const visible = Array.from(document.querySelectorAll('.var-row')).filter(row => row.style.display !== 'none').length;
    const displayed = searchValue ? Math.max(visible, 0) : Math.max(total, 0);
    countEl.textContent = `Mostrando ${displayed} de ${Math.max(total, 0)} variáveis`;
}

// ============ VARIABLES ============

async function loadVariables(orgId) {
    if (!orgId) orgId = currentOrgId;

    const res = await API.get('variables', { id: orgId });
    if (!res.success) {
        Toast.error(res.error || 'Erro ao carregar variaveis');
        return;
    }

    allVariables = res.data.variables || [];
    mirrorOrgRepositoryState = null;
    if (currentUser?.role === 'admin_gap') {
        try {
            const mirrorRes = await API.get('mirror-status');
            if (mirrorRes.success) {
                mirrorOrgRepositoryState = (mirrorRes.data.organization_settings || [])
                    .find(org => Number(org.id) === Number(orgId)) || null;
            }
        } catch (error) {
            mirrorOrgRepositoryState = null;
        }
    }
    activeCategory = 'identidade';
    renderVariables(allVariables);

    try {
        const [wRes, lRes] = await Promise.all([
            API.get('wallpapers', { org_id: orgId }),
            API.get('logos', { org_id: orgId })
        ]);
        uploadedImages.wallpapers = wRes.success ? wRes.data.images : [];
        uploadedImages.logos = lRes.success ? lRes.data.images : [];
    } catch (e) {}
}

function renderVariables(vars) {
    const el = document.getElementById('vars-list');
    if (!el) return;

    if (!vars.length) {
        el.innerHTML = '<p class="text-slate-400 text-center py-8">Nenhuma variavel</p>';
        return;
    }

    const varByName = {};
    vars.forEach(v => { varByName[v.name] = v; });

    const hiddenNames = new Set();
    Object.entries(dependentFields).forEach(([parent, children]) => {
        const p = varByName[parent];
        if (p) {
            const val = p.current_value;
            const active = val === 'true' || val === '1' || val === true;
            if (!active) children.forEach(c => hiddenNames.add(c));
        }
    });

    const superBuckets = {};
    superCategoryOrder.forEach(sc => { superBuckets[sc] = []; });

    vars.forEach(v => {
        if (hiddenNames.has(v.name)) return;
        const sc = variableSuperOverride[v.name] || categoryToSuper[v.category || 'generic'] || 'estacoes_perifericos';
        superBuckets[sc].push(v);
    });

    const activeSuperCats = superCategoryOrder.filter(sc => superBuckets[sc].length > 0);

    if (!activeCategory || !superBuckets[activeCategory] || superBuckets[activeCategory].length === 0) {
        activeCategory = activeSuperCats[0] || 'identidade';
    }

    let html = '<div class="category-tabs">';
    activeSuperCats.forEach(sc => {
        html += `<button class="cat-tab ${activeCategory === sc ? 'active' : ''}" onclick="filterByCategory('${Utils.escapeHtml(sc)}')">${superCategoryLabels[sc] || sc}</button>`;
    });
    html += '</div>';

    const searchInput = document.getElementById('var-search');
    const searchTerm = normalizeText(searchInput?.value || '');
    let bucket = superBuckets[activeCategory] || [];

    if (searchTerm) {
        bucket = bucket.filter(v => matchesVariableSearch(v, searchTerm));
    }

    if (!bucket.length) {
        html += '<p class="text-slate-400 text-center py-8">Nenhuma variavel nesta categoria</p>';
        el.innerHTML = html;
        updateVariableSearchCount();
        return;
    }

    if (activeCategory === 'repositorios') {
        html += renderRepositoryManagement(bucket, searchTerm);
        html += '</div>';
        el.innerHTML = html;
        updateVariableSearchCount();
        return;
    }

    const sections = superCategorySections[activeCategory] || [];
    const sectionVarNames = new Set();
    sections.forEach(s => s.vars.forEach(n => sectionVarNames.add(n)));

    const leftover = bucket.filter(v => !sectionVarNames.has(v.name));

    html += '<div class="var-grid">';

    sections.forEach(section => {
        const sectionVars = bucket.filter(v => section.vars.includes(v.name));
        if (!sectionVars.length) return;

        const sectionHidden = searchTerm && !sectionVars.some(v => matchesVariableSearch(v, searchTerm));
        html += `<div class="var-section-header" ${sectionHidden ? 'style="display:none;"' : ''}><h4 class="var-section-title">${Utils.escapeHtml(section.title)}</h4></div>`;

        html += renderVarsWithGroups(sectionVars, searchTerm);
    });

    if (leftover.length) {
        html += `<div class="var-section-header" ${searchTerm && !leftover.some(v => matchesVariableSearch(v, searchTerm)) ? 'style="display:none;"' : ''}><h4 class="var-section-title">Outras Variáveis</h4></div>`;
        html += renderVarsWithGroups(leftover, searchTerm);
    }

    html += '</div>';
    el.innerHTML = html;
    updateVariableSearchCount();
}

// ===== Layout especial: Repositorios por distribuicao =====
const repoDistros = [
    { name: 'Debian',   cls: 'debian',   logo: '/assets/images/distros/debian.svg',   enabledVar: 'REPOSITORY_DEBIAN_ENABLED', urlVar: 'REPOSITORY_DEBIAN_URL', placeholder: 'http://mirror.intraer/debian' },
    { name: 'Ubuntu',   cls: 'ubuntu',   logo: '/assets/images/distros/ubuntu.svg',   enabledVar: 'REPOSITORY_UBUNTU_ENABLED', urlVar: 'REPOSITORY_UBUNTU_URL', placeholder: 'http://mirror.intraer/ubuntu' },
    { name: 'Linux Mint', cls: 'mint',   logo: '/assets/images/distros/linuxmint.svg', enabledVar: 'REPOSITORY_MINT_ENABLED', urlVar: 'REPOSITORY_MINT_URL', placeholder: 'http://mirror.intraer/mint' },
    { name: 'Zorin OS', cls: 'zorin',    logo: '/assets/images/distros/zorin.svg',    enabledVar: 'REPOSITORY_ZORIN_ENABLED', urlVar: 'REPOSITORY_ZORIN_URL', placeholder: 'http://mirror.intraer/zorin' },
    { name: 'Padrao',   cls: 'default', logo: '/assets/images/distros/default.svg', enabledVar: null, urlVar: null, placeholder: '' }
];

function isRepositoryManagedByGap() {
    return mirrorOrgRepositoryState?.use_local_mirror === true
        || mirrorOrgRepositoryState?.use_local_mirror === 't';
}

function normalizeBooleanValue(value) {
    return value === true || value === 1 || value === '1' || String(value).toLowerCase() === 'true';
}

function renderRepositoryManagement(vars, searchTerm = '') {
    const varMap = {};
    vars.forEach(v => { varMap[v.name] = v; });
    const modeVar = varMap.REPOSITORY_MODE;
    const fallbackVar = varMap.REPOSITORY_FALLBACK;
    const mode = String(modeVar?.current_value || 'PUBLIC').toUpperCase();
    const managed = isRepositoryManagedByGap();
    const modeDescriptions = {
        PUBLIC: 'Usa os repositórios oficiais da internet.',
        MIRROR: managed ? 'URLs derivadas do mirror do GAP e gerenciadas automaticamente.' : 'Permite informar URLs locais manualmente.',
        HYBRID: 'Usa URLs locais quando disponíveis e fallback para a internet.',
        CUSTOM: 'Permite configurar cada distribuição manualmente.'
    };
    let html = `<div class="repository-management col-span-2">`;
    if (managed) {
        html += `<div class="repository-gap-banner"><strong>Repositório gerenciado pelo GAP</strong><span>Esta OM está usando o mirror do GAP. As URLs abaixo são derivadas automaticamente.</span></div>`;
    }
    if (modeVar) {
        const modeInput = renderTypedInput(modeVar).replace('<select ', '<select onchange="updateRepositoryModeView(this.value)" ');
        html += `<div class="repository-mode-panel"><div><label class="form-label" title="PUBLIC usa fontes oficiais; MIRROR usa o mirror local; HYBRID combina mirror e fallback; CUSTOM permite URLs próprias.">Modo do repositório</label><p class="repository-mode-help">${modeDescriptions[mode] || 'Escolha como esta OM obterá os pacotes.'}</p></div><div class="repository-mode-control">${modeInput}<span class="repository-mode-hint">PUBLIC: oficiais | MIRROR: local | HYBRID: local + fallback | CUSTOM: manual</span></div></div>`;
    }
    if (mode === 'PUBLIC') {
        if (fallbackVar) html += renderRepositoryInformativeField(fallbackVar, 'Fallback configurado');
        html += '<div class="repository-public-note">Esta OM está configurada para usar os repositórios oficiais. URLs específicas ficam ocultas.</div></div>';
        return html;
    }
    if (managed) {
        html += '<div class="repository-managed-note">O GAP controla estas URLs para manter todas as OMs alinhadas ao mirror local.</div>';
    }
    html += '<div class="repository-card-grid">';
    repoDistros.forEach(distro => {
        const enVar = varMap[distro.enabledVar];
        const urlVar = varMap[distro.urlVar];
        if (!enVar && !urlVar) return;
        const enabled = normalizeBooleanValue(enVar?.current_value);
        const readonly = managed && ['MIRROR', 'HYBRID'].includes(mode);
        html += `<div class="repo-card ${distro.cls} ${readonly ? 'repository-managed-card' : ''}">
            <div class="repo-card-header"><img src="${distro.logo}" alt="${distro.name}" onerror="if(this.parentElement)this.style.display='none'"><h4>${distro.name}</h4></div>`;
        if (enVar && !readonly) {
            html += `<div class="flex items-center justify-between mb-2"><span class="text-xs text-slate-400">Habilitar repositório</span><label class="toggle-switch"><input type="checkbox" data-var-id="${enVar.id}" data-repository-boolean="1" ${enabled ? 'checked' : ''} onchange="toggleRepoUrl(this, '${distro.urlVar}')"><span class="toggle-slider"></span></label></div>`;
        }
        if (urlVar) {
            const urlValue = Utils.escapeHtml(urlVar.current_value || '');
            html += `<div class="repo-url-wrap"><label class="text-xs text-slate-400">URL ${distro.name}</label><input type="url" data-var-id="${urlVar.id}" data-repository-url="1" class="var-input" value="${urlValue}" placeholder="${distro.placeholder}" ${readonly ? 'readonly' : ''}><p class="text-slate-500 text-xs mt-1 font-mono">${urlVar.name}${readonly ? ' · gerenciada pelo GAP' : ''}</p></div>`;
        }
        html += '</div>';
    });
    html += '</div>';
    if (fallbackVar && mode === 'HYBRID') {
        html += renderRepositoryField(fallbackVar, false, 'Fallback para a internet');
    } else if (fallbackVar && mode === 'MIRROR' && managed) {
        html += renderRepositoryInformativeField(fallbackVar, 'Fallback preservado');
    } else if (fallbackVar) {
        html += renderRepositoryField(fallbackVar, false, 'Fallback global');
    }
    return html + '</div>';
}

function updateRepositoryModeView(value) {
    const modeVar = allVariables.find(variable => variable.name === 'REPOSITORY_MODE');
    if (!modeVar) return;
    modeVar.current_value = String(value || 'PUBLIC').toUpperCase();
    renderVariables(allVariables);
}

function renderRepositoryInformativeField(variable, label) {
    return `<div class="repository-informative-field"><label class="form-label">${label}</label><code>${Utils.escapeHtml(variable.current_value || '-')}</code><span class="mirror-help">Informativo neste modo.</span></div>`;
}

function renderRepositoryField(variable, readonly, label) {
    return `<div class="repository-fallback-field"><label class="form-label">${label}</label><input type="url" data-var-id="${variable.id}" class="var-input" value="${Utils.escapeHtml(variable.current_value || '')}" placeholder="http://deb.debian.org/debian" ${readonly ? 'readonly' : ''}><p class="text-slate-500 text-xs mt-1 font-mono">${variable.name}</p></div>`;
}

function renderRepositoryCards(vars, searchTerm = '') {
    const varMap = {};
    vars.forEach(v => { varMap[v.name] = v; });

    let html = '<div class="col-span-2 grid gap-4" style="grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));">';

    repoDistros.forEach(d => {
        if (d.enabledVar === null) return;
        const enVar = varMap[d.enabledVar];
        const urlVar = varMap[d.urlVar];
        if (!enVar && !urlVar) return;

        const matches = !searchTerm || [enVar, urlVar].some(v => v && matchesVariableSearch(v, searchTerm));
        const rowStyle = matches ? '' : 'style="display:none;"';
        const enabled = enVar && (enVar.current_value === 'true' || enVar.current_value === '1' || enVar.current_value === true);

        html += `<div class="repo-card ${d.cls}" ${rowStyle}>
            <div class="repo-card-header">
                <img src="${d.logo}" alt="${d.name}" onerror="if(this.parentElement)this.style.display='none'">
                <h4>${d.name}</h4>
            </div>`;

        if (enVar) {
            html += `<div class="flex items-center justify-between mb-2">
                <span class="text-xs text-slate-400">Habilitar repositório</span>
                <label class="toggle-switch">
                    <input type="checkbox" data-var="${enVar.name}" ${enabled ? 'checked' : ''} onchange="toggleRepoUrl(this, '${d.urlVar}')">
                    <span class="toggle-slider"></span>
                </label>
            </div>`;
        }

        if (urlVar) {
            const urlStyle = enabled ? '' : 'style="display:none;"';
            html += `<div class="repo-url-wrap" ${urlStyle}>
                <input type="text" class="var-input" data-var="${urlVar.name}" value="${Utils.escapeHtml(urlVar.current_value || '')}" placeholder="${d.placeholder}">
                <p class="text-slate-500 text-xs mt-1 font-mono">${urlVar.name}</p>
            </div>`;
        }

        html += `</div>`;
    });

    html += '</div>';
    return html;
}

function toggleRepoUrl(checkbox, urlVarName) {
    const wrap = checkbox.closest('.repo-card').querySelector('.repo-url-wrap');
    if (wrap) wrap.style.display = checkbox.checked ? '' : 'none';
}

// Renderiza vars agrupando as que pertencem ao mesmo bloco visual (ex: sudo_groups)
function renderVarsWithGroups(vars, searchTerm = '') {
    let html = '';
    const grouped = {};
    const rest = [];
    vars.forEach(v => {
        const g = groupedVariables[v.name];
        if (g) {
            grouped[g.block] = grouped[g.block] || [];
            grouped[g.block].push(v);
        } else {
            rest.push(v);
        }
    });

    Object.entries(grouped).forEach(([blockKey, blockVars]) => {
        blockVars.sort((a, b) => groupedVariables[a.name].order - groupedVariables[b.name].order);
        html += `<div class="col-span-2 mb-2 p-4 bg-slate-800/40 border border-slate-700 rounded-lg">
            <div class="text-sm font-semibold text-slate-200 mb-3">${groupLabels[blockKey] || blockKey}</div>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-3">`;
        blockVars.forEach(v => {
            const label = groupedVariables[v.name].label;
            const itemHidden = !!searchTerm && !matchesVariableSearch(v, searchTerm);
            html += `<div class="var-row-wrapper" ${itemHidden ? 'style="display:none;"' : ''}>
                <label class="block text-xs font-medium text-slate-400 mb-1">${getFieldLabelMarkup(v, label)}</label>
                ${renderTypedInput(v)}
                <p class="text-slate-500 text-xs mt-1 font-mono">${Utils.escapeHtml(v.name)}</p>
            </div>`;
        });
        html += `</div></div>`;
    });
    rest.forEach(v => html += renderVarRow(v, searchTerm));
    return html;
}

function renderVarRow(v, searchTerm = '') {
    if ((v.category || '') === 'assets' || v.type === 'image') {
        return renderAssetCard(v);
    }

    const input = renderTypedInput(v);
    const hiddenStyle = !!searchTerm && !matchesVariableSearch(v, searchTerm) ? 'style="display:none;"' : '';
    return `
        <div class="var-row" ${hiddenStyle}>
            <label class="block text-sm font-medium text-slate-300 mb-1">
                ${getFieldLabelMarkup(v, v.name)}${v.is_required ? '<span class="text-red-400">*</span>' : ''}
            </label>
            ${input}
            ${v.description ? `<p class="text-slate-500 text-xs mt-1">${Utils.escapeHtml(v.description)}</p>` : ''}
        </div>`;
}

// Rótulos amigaveis para os assets
const assetLabels = {
    'LOGO_URL': { title: 'Logo da OM', hint: 'Ícone/marca exibido no login e menus' },
    'WALLPAPER_URL': { title: 'Wallpaper (Desktop)', hint: 'Papel de parede da área de trabalho' },
    'WALLPAPER_LOGIN_URL': { title: 'Wallpaper (Login)', hint: 'Papel de parede da tela de login (greeter)' },
    'GREETER_URL': { title: 'Greeter (Boas-vindas)', hint: 'Tela de boas-vindas customizada' }
};

function renderAssetCard(v) {
    const val = v.current_value || '';
    const meta = assetLabels[v.name] || { title: v.name, hint: v.description || '' };
    const preview = val
        ? `<img src="${Utils.escapeHtml(val)}" class="asset-card-preview" alt="Preview" onerror="this.classList.add('asset-card-preview-broken')">`
        : `<div class="asset-card-preview-empty">Nenhuma imagem definida</div>`;
    const acceptTypes = v.name === 'LOGO_URL'
        ? 'image/jpeg,image/png,image/gif,image/webp,image/svg+xml'
        : 'image/jpeg,image/png,image/gif,image/webp';

    return `
        <div class="asset-card" data-var-name="${Utils.escapeHtml(v.name)}">
            <div class="asset-card-header">
                <div>
                    <div class="asset-card-title">${Utils.escapeHtml(meta.title)}</div>
                    <div class="asset-card-hint">${Utils.escapeHtml(meta.hint)}</div>
                </div>
                <span class="asset-card-varname">${Utils.escapeHtml(v.name)}</span>
            </div>
            <div class="asset-card-preview-wrap" id="asset-preview-${v.id}">
                ${preview}
            </div>
            <input type="url" data-var-id="${v.id}" value="${Utils.escapeHtml(val)}" class="var-input asset-card-url" placeholder="URL da imagem (ou faça upload)" oninput="updateAssetCardPreview(${v.id}, this.value)">
            <div class="asset-card-actions">
                <label class="asset-btn asset-btn-primary">
                    <input type="file" class="hidden" accept="${acceptTypes}" onchange="uploadAsset('${Utils.escapeHtml(v.name)}', ${v.id}, this)">
                    <i class="fas fa-upload"></i> Selecionar arquivo
                </label>
                ${v.name !== 'LOGO_URL' ? `
                <button type="button" class="asset-btn asset-btn-secondary" onclick="openImageGallery('${Utils.escapeHtml(v.name)}', ${v.id})">
                    <i class="fas fa-search"></i> Buscar no Servidor
                </button>` : ''}
                <button type="button" class="asset-btn asset-btn-secondary" onclick="clearAsset(${v.id})" ${val ? '' : 'disabled'}>
                    <i class="fas fa-trash"></i> Remover
                </button>
            </div>
        </div>`;
}

// Preview live enquanto o usuario digita/cola a URL
function updateAssetCardPreview(varId, url) {
    const wrap = document.getElementById(`asset-preview-${varId}`);
    if (!wrap) return;
    const trimmed = (url || '').trim();
    if (trimmed) {
        wrap.innerHTML = `<img src="${Utils.escapeHtml(trimmed)}" class="asset-card-preview" alt="Preview" onerror="this.classList.add('asset-card-preview-broken')">`;
    } else {
        wrap.innerHTML = `<div class="asset-card-preview-empty">Nenhuma imagem definida</div>`;
    }
    // Ativa/desativa botao Remover
    const card = wrap.closest('.asset-card');
    if (card) {
        const removeBtn = card.querySelector('.asset-btn-secondary');
        if (removeBtn) removeBtn.disabled = !trimmed;
    }
}
window.updateAssetCardPreview = updateAssetCardPreview;

// Limpar URL (sem apagar o arquivo do servidor)
function clearAsset(varId) {
    const urlInput = document.querySelector(`input[data-var-id="${varId}"].asset-card-url`);
    if (!urlInput) return;
    urlInput.value = '';
    updateAssetCardPreview(varId, '');
    Toast.info && Toast.info('URL removida. Clique em Salvar para persistir.');
}
window.clearAsset = clearAsset;

// Upload via endpoint unificado /api/?action=upload-asset
async function uploadAsset(varName, varId, inputEl) {
    if (!inputEl.files || !inputEl.files[0]) return;
    if (!currentOrgId) { Toast.error('Selecione uma OM antes'); return; }
    const file = inputEl.files[0];

    const fd = new FormData();
    fd.append('organization_id', currentOrgId);
    fd.append('var_name', varName);
    fd.append('asset', file);

    try {
        const res = await fetch('/api/?action=upload-asset', { method: 'POST', body: fd, credentials: 'include' });
        const data = await res.json();
        if (!data.success) {
            Toast.error(data.error || 'Falha no upload');
            return;
        }
        const url = data.data.url;
        // Atualiza o input e a preview
        const urlInput = document.querySelector(`input[data-var-id="${varId}"].asset-card-url`);
        if (urlInput) urlInput.value = url;
        updateAssetCardPreview(varId, url);
        // Atualiza allVariables in-memory
        const v = allVariables.find(x => String(x.id) === String(varId));
        if (v) v.current_value = url;
        Toast.success('Imagem enviada e salva com sucesso');
    } catch (e) {
        Toast.error('Erro de rede no upload');
    } finally {
        inputEl.value = '';
    }
}
window.uploadAsset = uploadAsset;

function renderTypedInput(v) {
    const val = v.current_value || '';
    const varId = v.id;
    const opts = variableOptions[v.name];

    if (opts === 'boolean' || v.type === 'boolean') {
        const checked = val === 'true' || val === '1' || val === true;
        const hasDeps = dependentFields[v.name] ? 'data-parent-toggle="1"' : '';
        return `
            <label class="toggle-switch">
                <input type="checkbox" data-var-id="${varId}" ${hasDeps} ${checked ? 'checked' : ''}>
                <span class="toggle-slider"></span>
            </label>
            <span class="ml-2 text-sm text-slate-300">${checked ? 'Ativo' : 'Inativo'}</span>`;
    }

    if (Array.isArray(opts)) {
        return `<select data-var-id="${varId}" class="var-select">
            ${opts.map(o => `<option value="${o}" ${val === o ? 'selected' : ''}>${o === '' ? '(auto-detectar)' : o}</option>`).join('')}
        </select>`;
    }

    if (v.type === 'tags') {
        const items = String(val).split(',').map(s => s.trim()).filter(Boolean);
        const chips = items.map((t, i) =>
            `<span class="tag-chip" data-idx="${i}">${Utils.escapeHtml(t)}<button type="button" class="tag-remove" onclick="removeTag(${varId}, ${i})" title="Remover">&times;</button></span>`
        ).join('');
        return `
            <div class="tags-wrapper" data-var-id="${varId}" data-type="tags">
                <div class="tags-list" id="tags-list-${varId}">${chips || '<span class="text-slate-500 text-xs">Nenhum item</span>'}</div>
                <input type="text" class="tag-input" placeholder="Digite e pressione Enter" onkeydown="handleTagInput(event, ${varId})">
                <input type="hidden" data-var-id="${varId}" data-type="tags-hidden" value="${Utils.escapeHtml(items.join(','))}">
            </div>`;
    }

    if (v.type === 'image' || (v.name.endsWith('_URL') && ['WALLPAPER_URL','WALLPAPER_LOGIN_URL','LOGO_URL','GREETER_URL'].includes(v.name))) {
        const preview = val
            ? `<img src="${Utils.escapeHtml(val)}" class="asset-preview" onerror="if(this.style)this.style.display='none'" alt="Preview">`
            : `<div class="asset-preview-empty">Sem imagem</div>`;
        return `
            <div class="asset-field">
                ${preview}
                <input type="url" data-var-id="${varId}" value="${Utils.escapeHtml(val)}" class="var-input" placeholder="URL da imagem" oninput="updateAssetPreview(this)">
            </div>`;
    }

    if (v.type === 'json_conky' || v.name === 'CONKY_CONFIG') {
        return renderConkyPanel(v, varId, val);
    }

    if (v.type === 'array') {
        let ph = 'Separe multiplos valores por virgula';
        let note = '';
        if (v.name === 'JAVA_EXCEPTIONS') ph = 'Uma URL por linha';
        if (v.name === 'SSH_GROUPS') {
            ph = 'Grupos separados por vírgula. Ex: linux-admins,_DASTI';
            note = '<span class="text-xs text-slate-400 mt-1 block">Grupos separados por vírgula. Ex: linux-admins,_DASTI</span>';
        }
        return `<textarea data-var-id="${varId}" rows="2" class="var-textarea" placeholder="${ph}">${Utils.escapeHtml(val)}</textarea>${note}`;
    }

    if (v.type === 'url' || v.name.includes('URL')) {
        let ph = '';
        let note = '';
        
        if (v.name === 'BASE_URL') {
            ph = ' placeholder="https://seederlinux.SUA-OM.intraer"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else if (v.name === 'SEEDER_SERVER') {
            ph = ' placeholder="https://seederlinux.SUA-OM.intraer"';
            note = '<div class="var-hint" style="font-size:0.8em;color:var(--text-muted);margin-top:4px">Inclua o protocolo (http:// ou https://). Configure este FQDN no DNS ou adicione ao /etc/hosts das estacoes.</div>';
        } else if (v.name === 'HOMEPAGE') {
            ph = ' placeholder="https://portal.SUA-OM.intraer"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else if (v.name === 'REPOSITORY_URL') {
            ph = ' placeholder="http://mirror.SUA-OM.intraer/debian"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else if (v.name === 'WALLPAPER_URL') {
            ph = ' placeholder="https://seederlinux.SUA-OM.intraer/assets/wallpaper.jpg"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else if (v.name === 'LOGO_URL') {
            ph = ' placeholder="https://seederlinux.SUA-OM.intraer/assets/logo.png"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else if (v.name === 'GREETER_URL') {
            ph = ' placeholder="https://seederlinux.SUA-OM.intraer/assets/greeter.png"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else if (v.name === 'WALLPAPER_LOGIN_URL') {
            ph = ' placeholder="https://seederlinux.SUA-OM.intraer/assets/login-bg.jpg"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else if (v.name === 'CERTIFICATE_BUNDLE') {
            ph = ' placeholder="https://seederlinux.SUA-OM.intraer/certs/bundle.tar.gz"';
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        } else {
            note = '<span class="text-xs text-slate-400 mt-1 block">Inclua o protocolo (http:// ou https://)</span>';
        }
        
        return `<input type="url" data-var-id="${varId}" value="${Utils.escapeHtml(val)}" class="var-input"${ph}>${note}`;
    }

    if (v.type === 'ip' || v.name.includes('IP') || v.name.includes('DNS') || v.name === 'NTP_SERVER') {
        return `<input type="text" data-var-id="${varId}" value="${Utils.escapeHtml(val)}" class="var-input font-mono" placeholder="IP ou hostname (ex: 10.108.64.51)" pattern="^([a-zA-Z0-9.-]+)$" title="Apenas IP ou hostname. Nao use URLs (http://).">`;
    }

    if (v.type === 'password') {
        const isB64Pwd = v.name === 'ADMIN_PASSWORD_B64' || v.name === 'VNC_PASSWORD_B64';
        const alertBadge = isB64Pwd
            ? '<div class="var-security-alert" style="color:var(--error);font-size:0.8em;margin-top:4px">ATENCAO: Armazenada em base64. O bundle decodifica durante a execucao.</div>'
            : '';
        const hint = isB64Pwd
            ? ' placeholder="Digite a senha (sera codificada automaticamente)"'
            : '';
        return `<input type="password" data-var-id="${varId}" data-b64-encode="${isB64Pwd ? '1' : '0'}" value="${Utils.escapeHtml(val)}" class="var-input"${hint}>${alertBadge}`;
    }

    return `<input type="text" data-var-id="${varId}" value="${Utils.escapeHtml(val)}" class="var-input">`;
}

// ============ CONKY EXPANDED PANEL ============
function renderConkyPanel(v, varId, val) {
    let cfg;
    try { cfg = JSON.parse(val || '{}'); } catch (e) { cfg = {}; }
    cfg = Object.assign({
        position: 'top_right', transparent: true, color_text: '#FFFFFF', color_bg: '#000000',
        font_size: 10, font_size_hostname: 14, gap_x: 10, gap_y: 40,
        show_cpu: true, show_ram: true, show_disk: true, disk_partition: '/',
        show_network: true, network_interface: 'eth0', show_top_processes: true,
        show_datetime: true, show_hostname: true, update_interval: 1.0
    }, cfg);

    const posOpts = conkyPositions.map(p => `<option value="${p}" ${cfg.position===p?'selected':''}>${p}</option>`).join('');

    return `
    <div class="conky-panel" data-var-id="${varId}" data-type="json_conky">
        <input type="hidden" data-var-id="${varId}" data-type="conky-hidden" id="conky-hidden-${varId}" value='${JSON.stringify(cfg).replace(/'/g,"&apos;")}'>
        <div class="conky-section conky-section-hostname">
            <div class="conky-section-title">Hostname (destaque)</div>
            <div class="conky-grid">
                <label class="conky-inline"><input type="checkbox" ${cfg.show_hostname?'checked':''} onchange="updateConkyField(${varId},'show_hostname',this.checked)">Mostrar Hostname</label>
                <label>Tamanho da fonte (hostname)<input type="number" min="8" max="32" class="var-input" value="${cfg.font_size_hostname}" onchange="updateConkyField(${varId},'font_size_hostname',parseInt(this.value))"></label>
            </div>
        </div>
        <div class="conky-section">
            <div class="conky-section-title">Aparencia</div>
            <div class="conky-grid">
                <label>Posicao<select class="var-select" onchange="updateConkyField(${varId},'position',this.value)">${posOpts}</select></label>
                <label class="conky-inline">Transparente<input type="checkbox" ${cfg.transparent?'checked':''} onchange="updateConkyField(${varId},'transparent',this.checked)"></label>
                <label>Cor do texto<input type="color" class="conky-color" value="${cfg.color_text}" onchange="updateConkyField(${varId},'color_text',this.value)"></label>
                <label>Cor de fundo<input type="color" class="conky-color" value="${cfg.color_bg}" onchange="updateConkyField(${varId},'color_bg',this.value)"></label>
                <label>Tamanho da fonte<input type="number" min="6" max="24" class="var-input" value="${cfg.font_size}" onchange="updateConkyField(${varId},'font_size',parseInt(this.value))"></label>
                <label>Margem X (gap_x)<input type="number" min="0" max="500" class="var-input" value="${cfg.gap_x}" onchange="updateConkyField(${varId},'gap_x',parseInt(this.value))"></label>
                <label>Margem Y (gap_y)<input type="number" min="0" max="500" class="var-input" value="${cfg.gap_y}" onchange="updateConkyField(${varId},'gap_y',parseInt(this.value))"></label>
                <label>Intervalo atualizacao (s)<input type="number" min="0.1" step="0.1" class="var-input" value="${cfg.update_interval}" onchange="updateConkyField(${varId},'update_interval',parseFloat(this.value))"></label>
            </div>
        </div>
        <div class="conky-section">
            <div class="conky-section-title">Informacoes exibidas</div>
            <div class="conky-grid">
                <label class="conky-inline"><input type="checkbox" ${cfg.show_cpu?'checked':''} onchange="updateConkyField(${varId},'show_cpu',this.checked)">Mostrar CPU</label>
                <label class="conky-inline"><input type="checkbox" ${cfg.show_ram?'checked':''} onchange="updateConkyField(${varId},'show_ram',this.checked)">Mostrar RAM/Swap</label>
                <label class="conky-inline"><input type="checkbox" ${cfg.show_disk?'checked':''} onchange="updateConkyField(${varId},'show_disk',this.checked)">Mostrar Disco</label>
                <label>Particao do disco<input type="text" class="var-input font-mono" value="${Utils.escapeHtml(cfg.disk_partition)}" onchange="updateConkyField(${varId},'disk_partition',this.value)"></label>
                <label class="conky-inline"><input type="checkbox" ${cfg.show_network?'checked':''} onchange="updateConkyField(${varId},'show_network',this.checked)">Mostrar Rede</label>
                <label>Interface de rede<input type="text" class="var-input font-mono" value="${Utils.escapeHtml(cfg.network_interface)}" onchange="updateConkyField(${varId},'network_interface',this.value)"></label>
                <label class="conky-inline"><input type="checkbox" ${cfg.show_top_processes?'checked':''} onchange="updateConkyField(${varId},'show_top_processes',this.checked)">Top 3 processos</label>
                <label class="conky-inline"><input type="checkbox" ${cfg.show_datetime?'checked':''} onchange="updateConkyField(${varId},'show_datetime',this.checked)">Data/Hora</label>
            </div>
        </div>
    </div>`;
}

// ============ TAG/CHIP INPUT HANDLERS ============
function handleTagInput(e, varId) {
    if (e.key !== 'Enter' && e.key !== ',') return;
    e.preventDefault();
    const val = e.target.value.trim().replace(/,/g, '');
    if (!val) return;
    const hidden = document.querySelector(`input[data-var-id="${varId}"][data-type="tags-hidden"]`);
    const items = hidden.value ? hidden.value.split(',').map(s => s.trim()).filter(Boolean) : [];
    if (items.includes(val)) { e.target.value = ''; return; }
    items.push(val);
    hidden.value = items.join(',');
    e.target.value = '';
    refreshTagsList(varId, items);
}
window.handleTagInput = handleTagInput;

function removeTag(varId, idx) {
    const hidden = document.querySelector(`input[data-var-id="${varId}"][data-type="tags-hidden"]`);
    const items = hidden.value.split(',').map(s => s.trim()).filter(Boolean);
    items.splice(idx, 1);
    hidden.value = items.join(',');
    refreshTagsList(varId, items);
}
window.removeTag = removeTag;

function refreshTagsList(varId, items) {
    const listEl = document.getElementById(`tags-list-${varId}`);
    if (!listEl) return;
    listEl.innerHTML = items.length
        ? items.map((t, i) => `<span class="tag-chip" data-idx="${i}">${Utils.escapeHtml(t)}<button type="button" class="tag-remove" onclick="removeTag(${varId}, ${i})">&times;</button></span>`).join('')
        : '<span class="text-slate-500 text-xs">Nenhum item</span>';
}

// ============ IMAGE PREVIEW ============
function updateAssetPreview(inputEl) {
    const wrapper = inputEl.closest('.asset-field');
    if (!wrapper) return;
    const url = inputEl.value.trim();
    const oldImg = wrapper.querySelector('.asset-preview, .asset-preview-empty');
    if (oldImg) oldImg.remove();
    let previewEl;
    if (url) {
        previewEl = document.createElement('img');
        previewEl.src = url;
        previewEl.className = 'asset-preview';
        previewEl.alt = 'Preview';
        previewEl.onerror = () => { previewEl.style.display = 'none'; };
    } else {
        previewEl = document.createElement('div');
        previewEl.className = 'asset-preview-empty';
        previewEl.textContent = 'Sem imagem';
    }
    wrapper.insertBefore(previewEl, inputEl);
}
window.updateAssetPreview = updateAssetPreview;

// ============ CONKY FIELD UPDATE ============
function updateConkyField(varId, field, value) {
    const hidden = document.getElementById(`conky-hidden-${varId}`);
    if (!hidden) return;
    let cfg;
    try { cfg = JSON.parse(hidden.value.replace(/&apos;/g, "'")); } catch (e) { cfg = {}; }
    cfg[field] = value;
    hidden.value = JSON.stringify(cfg);
}
window.updateConkyField = updateConkyField;

function filterByCategory(c) {
    activeCategory = c;
    renderVariables(allVariables);
}
window.filterByCategory = filterByCategory;

async function saveVariables() {
    if (!currentOrgId) { Toast.error('Selecione uma organizacao antes de salvar'); return; }

    const updates = {};
    // Coleta apenas UM input por variable_id (prefere o "hidden" com dados serializados)
    const collected = {};
    document.querySelectorAll('[data-var-id]').forEach(el => {
        const varId = el.dataset.varId;
        const dtype = el.dataset.type;
        let value;
        if (el.type === 'checkbox' && !dtype) {
            value = el.checked ? 'true' : 'false';
        } else if (dtype === 'tags-hidden' || dtype === 'conky-hidden') {
            value = el.value;
        } else if (el.tagName === 'INPUT' && el.type === 'file') {
            return; // ignora file inputs
        } else if (dtype === 'tags' || dtype === 'json_conky') {
            return; // wrapper — ja tratado pelo hidden
        } else {
            value = el.value;
        }
        // Prefere valores de hidden (mais confiaveis para tags/conky)
        if (!(varId in collected) || dtype === 'tags-hidden' || dtype === 'conky-hidden') {
            collected[varId] = value;
        }
    });

    // Encode password fields marked as b64 before sending to API
    document.querySelectorAll('[data-b64-encode="1"][data-var-id]').forEach(el => {
        const varId = el.dataset.varId;
        const raw = el.value.trim();
        if (raw !== '' && varId in collected) {
            collected[varId] = btoa(unescape(encodeURIComponent(raw)));
        }
    });

    // Normalize URL fields: ensure they start with http:// or https://
    // Skip image/asset path variables that use relative paths (e.g. /assets/wallpapers/...)
    const imagePathVars = ['WALLPAPER_URL', 'WALLPAPER_LOGIN_URL', 'GREETER_URL', 'LOGO_URL'];
    const urlVarNames = allVariables
        .filter(v => (v.type === 'url' || v.name.includes('URL') || v.name.includes('SERVER') || v.name === 'HOMEPAGE') && !imagePathVars.includes(v.name))
        .map(v => String(v.id));
    for (const varId of Object.keys(collected)) {
        if (urlVarNames.includes(varId)) {
            let val = (collected[varId] || '').trim();
            if (val && !/^https?:\/\//.test(val)) {
                val = 'http://' + val;
                collected[varId] = val;
            }
        }
    }

    Object.assign(updates, collected);

    try {
        const res = await API.post('variables-update', { organization_id: currentOrgId, variables: updates });
        if (res.success) {
            Toast.success('Variaveis salvas com sucesso');
            loadVariables(currentOrgId);
        } else {
            Toast.error(res.error || 'Erro ao salvar');
        }
    } catch (error) {
        Toast.error('Nao foi possivel salvar as variaveis');
    }
}
window.saveVariables = saveVariables;

// Re-render vars quando toggle "pai" muda (para esconder/mostrar dependentes)
document.addEventListener('change', (e) => {
    if (e.target && e.target.matches('input[type="checkbox"][data-parent-toggle="1"]')) {
        // Atualiza current_value em allVariables e re-renderiza
        const varId = e.target.dataset.varId;
        const v = allVariables.find(x => String(x.id) === String(varId));
        if (v) {
            v.current_value = e.target.checked ? 'true' : 'false';
            renderVariables(allVariables);
        }
    }
});

async function addVariable(e) {
    e.preventDefault();

    const name = document.getElementById('new-var-name').value.trim();
    const type = document.getElementById('new-var-type').value;
    const value = document.getElementById('new-var-value').value;
    const description = document.getElementById('new-var-description').value;
    const category = document.getElementById('new-var-category').value;
    const required = document.getElementById('new-var-required').checked;

    if (!name) { Toast.error('Nome da variavel obrigatorio'); return; }

    const res = await API.post('variable-add', { organization_id: currentOrgId, name, value, type, description, category, required });
    if (res.success) {
        Toast.success('Variavel adicionada com sucesso');
        closeModal('modal-add-variable');
        document.getElementById('add-variable-form')?.reset();
        loadVariables(currentOrgId);
    } else {
        Toast.error(res.error || 'Erro ao adicionar variavel');
    }
}
window.addVariable = addVariable;



// ============ TABS ============

function switchTab(tabName) {
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.tab === tabName);
    });
    document.querySelectorAll('.tab-content').forEach(c => c.classList.add('hidden'));
    document.getElementById(`tab-${tabName}`)?.classList.remove('hidden');

    if (tabName === 'scripts') loadOrgScripts(currentOrgId);
    if (tabName === 'variables') loadVariables(currentOrgId);
    if (tabName === 'proxies') loadOmProxies(currentOrgId);
}
window.switchTab = switchTab;

// ============ SCRIPTS ============

function getScriptVersionLabel(versionType) {
    const labels = {
        factory: 'Fábrica',
        gap_default: 'GAP Default',
        om_specific: 'OM Específica'
    };
    return labels[versionType] || 'Fábrica';
}

async function getScriptVersionState(scriptId) {
    try {
        const res = await API.get('script-versions', { id: scriptId });
        if (!res.success || !Array.isArray(res.data?.versions)) {
            return { label: 'Fábrica', type: 'factory', versions: [] };
        }

        const versions = (res.data.versions || []).sort((a, b) => (Number(b.version_number) || 0) - (Number(a.version_number) || 0));
        const activeGap = versions.find(v => v.version_type === 'gap_default' && v.is_active);
        const activeOm = versions.find(v => v.version_type === 'om_specific' && v.is_active);

        if (activeOm) {
            return { label: 'OM Específica', type: 'om_specific', versions };
        }
        if (activeGap) {
            return { label: 'GAP Default', type: 'gap_default', versions };
        }
        return { label: 'Fábrica', type: 'factory', versions };
    } catch (error) {
        return { label: 'Fábrica', type: 'factory', versions: [] };
    }
}

async function loadAllScripts() {
    const res = await API.get('scripts');
    if (!res.success) return;

    const scripts = res.data || [];
    const core = scripts.filter(s => s.is_core);
    const custom = scripts.filter(s => !s.is_core);

    const coreWithState = await Promise.all(core.map(async (s) => ({
        ...s,
        versionState: await getScriptVersionState(s.id)
    })));

    const el = document.getElementById('scripts-list');
    if (!el) return;

    el.innerHTML = `
        <div class="mb-6">
            <h4 class="text-sm font-semibold text-slate-400 uppercase mb-3">Scripts Core (${core.length})</h4>
            <div class="table-wrapper">
                <table>
                    <thead>
                        <tr>
                            <th>Nome</th>
                            <th>Descricao</th>
                            <th>Ordem</th>
                            <th>Versao</th>
                            <th class="text-right">Acoes</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${coreWithState.map((s) => `
                            <tr>
                                <td><div class="font-medium text-white">${Utils.escapeHtml(s.filename || s.name)}</div></td>
                                <td>${Utils.escapeHtml(s.description || 'Sem descricao')}</td>
                                <td>${Number(s.execution_order || 0)}</td>
                                <td><span class="badge badge-${s.versionState.type === 'factory' ? 'info' : s.versionState.type === 'gap_default' ? 'warning' : 'success'}">${Utils.escapeHtml(s.versionState.label)}</span></td>
                                <td class="text-right">
                                    <div class="flex justify-end gap-2">
                                        <button class="btn btn-secondary btn-sm" onclick="editScript(${s.id}, 'gap_default')">Editar</button>
                                        <button class="btn btn-secondary btn-sm" onclick="openScriptHistory(${s.id}, '${Utils.escapeHtml(s.filename || s.name)}')">Histórico</button>
                                        <button class="btn btn-danger btn-sm" onclick="resetScriptToFactory(${s.id})">Reverter para Fábrica</button>
                                    </div>
                                </td>
                            </tr>
                        `).join('') || '<tr><td colspan="5" class="text-slate-500 text-center py-4">Nenhum script core</td></tr>'}
                    </tbody>
                </table>
            </div>
        </div>
        <div>
            <div class="flex justify-between mb-3">
                <h4 class="text-sm font-semibold text-slate-400 uppercase">Scripts Custom (${custom.length})</h4>
                <button onclick="openModal('modal-new-script')" class="text-sm text-blue-400 hover:text-blue-300">+ Novo</button>
            </div>
            <div class="space-y-2">
                ${custom.map(s => `
                    <div class="p-4 bg-slate-900 rounded-lg border border-slate-700 flex justify-between items-center">
                        <div>
                            <span class="font-medium text-white">${Utils.escapeHtml(s.name)}</span>
                            <span class="text-slate-500 text-sm ml-2">${Utils.escapeHtml(s.filename)}</span>
                        </div>
                        <div class="flex gap-2">
                            <button onclick="viewScript(${s.id})" class="text-blue-400 hover:text-blue-300 text-sm">Visualizar</button>
                            <button onclick="editScript(${s.id})" class="text-amber-400 hover:text-amber-300 text-sm">Editar</button>
                            <button onclick="deleteScript(${s.id})" class="text-red-400 hover:text-red-300 text-sm">Excluir</button>
                        </div>
                    </div>
                `).join('') || '<p class="text-slate-500 text-sm">Nenhum</p>'}
            </div>
        </div>`;
}

async function openScriptHistory(scriptId, scriptName) {
    try {
        const res = await API.get('script-versions', { id: scriptId });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao carregar histórico');
            return;
        }

        const versions = res.data.versions || [];
        const listEl = document.getElementById('script-history-list');
        const contentEl = document.getElementById('script-history-content');
        if (!listEl || !contentEl) return;

        document.getElementById('script-history-title').textContent = `Histórico: ${scriptName}`;
        if (!versions.length) {
            listEl.innerHTML = '<p class="text-slate-500 text-sm">Nenhuma versão registrada.</p>';
            contentEl.value = '';
            openModal('modal-script-history');
            return;
        }

        const ordered = [...versions].sort((a, b) => Number(b.version_number) - Number(a.version_number));
        const canDelete = currentUser && currentUser.role === 'admin_gap';
        listEl.innerHTML = ordered.map(v => {
            const isActive = Boolean(v.is_active);
            const activeBadge = isActive ? ' <span class="badge badge-success">Ativa</span>' : '';
            return `
            <div class="p-3 bg-slate-900 rounded border border-slate-700">
                <div class="flex items-center justify-between gap-3 mb-2">
                    <div>
                        <div class="font-medium text-white">v${Number(v.version_number || 0)} • ${Utils.escapeHtml(v.version_name || 'Versão')}</div>
                        <div class="text-xs text-slate-400">${Utils.escapeHtml(v.created_at || '')} • ${Utils.escapeHtml(v.created_by_username || 'Sistema')}</div>
                    </div>
                    <div class="flex gap-1">
                        <span class="badge badge-${v.version_type === 'factory' ? 'info' : v.version_type === 'gap_default' ? 'warning' : 'success'}">${Utils.escapeHtml(getScriptVersionLabel(v.version_type))}</span>
                        ${activeBadge}
                    </div>
                </div>
                <div class="text-xs text-slate-400 mb-2">${Utils.escapeHtml(v.changelog || 'Sem changelog')}</div>
                <div class="flex gap-2">
                    <button class="btn btn-secondary btn-sm" onclick="previewScriptVersion(${scriptId}, ${v.id})">Visualizar</button>
                    ${(v.version_type === 'factory' || isActive) ? '' : `<button class="btn btn-primary btn-sm" onclick="activateScriptVersion(${scriptId}, ${v.id}, '${v.version_type}')">Ativar esta versão</button>`}
                    ${(canDelete && v.version_type !== 'factory') ? `<button class="btn btn-danger btn-sm" onclick="deleteScriptVersion(${scriptId}, ${v.id})">Deletar</button>` : ''}
                </div>
            </div>
            `;
        }).join('');

        const latest = ordered[0];
        if (latest) {
            contentEl.value = latest.content || '';
        }
        openModal('modal-script-history');
    } catch (error) {
        Toast.error('Erro ao abrir histórico do script');
    }
}
window.openScriptHistory = openScriptHistory;

async function previewScriptVersion(scriptId, versionId) {
    try {
        const res = await API.get('script-versions', { id: scriptId });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao carregar versão');
            return;
        }
        const version = (res.data.versions || []).find(v => Number(v.id) === Number(versionId));
        if (!version) {
            Toast.error('Versão não encontrada');
            return;
        }
        document.getElementById('script-history-content').value = version.content || '';
    } catch (error) {
        Toast.error('Erro ao visualizar versão');
    }
}
window.previewScriptVersion = previewScriptVersion;

async function activateScriptVersion(scriptId, versionId, versionType) {
    try {
        const payload = { script_id: Number(scriptId), version_id: Number(versionId) };
        if (versionType === 'om_specific') {
            payload.organization_id = currentOrgId;
            const res = await API.post('set-om-version', payload);
            if (!res.success) { Toast.error(res.error || 'Erro ao ativar versão da OM'); return; }
            Toast.success('Versão da OM ativada');
        } else {
            const res = await API.post('set-gap-default', payload);
            if (!res.success) { Toast.error(res.error || 'Erro ao ativar versão GAP'); return; }
            Toast.success('Versão GAP ativada');
        }
        closeModal('modal-script-history');
        loadAllScripts();
    } catch (error) {
        Toast.error('Erro ao ativar versão');
    }
}
window.activateScriptVersion = activateScriptVersion;

async function deleteScriptVersion(scriptId, versionId) {
    if (!confirm('Tem certeza que deseja deletar esta versão? Esta ação não pode ser desfeita.')) return;
    try {
        const res = await API.post('delete-script-version', {
            script_id: Number(scriptId),
            version_id: Number(versionId)
        });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao deletar versão');
            return;
        }
        Toast.success(res.message || 'Versão deletada');
        openScriptHistory(scriptId, document.getElementById('script-history-title').textContent.replace('Histórico: ', ''));
    } catch (error) {
        Toast.error('Erro ao deletar versão');
    }
}
window.deleteScriptVersion = deleteScriptVersion;

async function resetScriptToFactory(scriptId) {
    if (!confirm('Deseja reverter este script para a versão de fábrica?')) return;

    try {
        const res = await API.post('reset-script-factory', { script_id: Number(scriptId) });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao reverter para fábrica');
            return;
        }

        Toast.success('Script revertido para a versão de fábrica');
        loadAllScripts();
    } catch (error) {
        Toast.error('Erro ao reverter para fábrica');
    }
}
window.resetScriptToFactory = resetScriptToFactory;

function getOrgScriptBadgeMeta(script) {
    const badgeClassBySource = {
        factory: 'badge-secondary',
        gap_default: 'badge-warning',
        global: 'badge-warning',
        local: 'badge-success'
    };
    const badgeLabelBySource = {
        factory: 'Fábrica',
        gap_default: 'GAP Default',
        global: 'GAP Default',
        local: 'Local'
    };

    const sourceType = script?.source_type || 'factory';
    return {
        className: badgeClassBySource[sourceType] || 'badge-secondary',
        label: badgeLabelBySource[sourceType] || 'Fábrica'
    };
}

async function loadOrgScripts(orgId) {
    if (!orgId) orgId = currentOrgId;
    const res = await API.get('get-org-scripts', { organization_id: orgId });
    if (!res.success) {
        Toast.error(res.error || 'Erro ao carregar scripts da OM');
        return;
    }

    const scripts = res.data || [];
    const core = scripts.filter(s => s.is_core);
    const custom = scripts.filter(s => !s.is_core);
    const currentList = scriptTab === 'Core' ? core : custom;

    const el = document.getElementById('org-scripts-list');
    if (!el) return;

    const sectionTitle = scriptTab === 'Core' ? `Scripts Core (${currentList.length})` : `Scripts Custom (${currentList.length})`;

    el.innerHTML = `
        <div class="mb-6">
            <h4 class="text-sm font-semibold text-slate-400 uppercase mb-3">${sectionTitle}</h4>
            <div class="table-wrapper">
                <table>
                    <thead>
                        <tr>
                            <th>Nome</th>
                            <th>Descricao</th>
                            <th>Ordem</th>
                            <th>Versao Local</th>
                            <th>Status</th>
                            <th class="text-right">Acoes</th>
                        </tr>
                    </thead>
                    <tbody>
                        ${currentList.map((s) => {
                            const badgeMeta = getOrgScriptBadgeMeta(s);
                            const statusLabel = s.is_active ? 'Ativo' : 'Inativo';
                            const versionLabel = s.has_local_override ? `Local${s.version ? ` v${s.version}` : ''}` : badgeMeta.label;
                            return `
                                <tr>
                                    <td><div class="font-medium text-white">${Utils.escapeHtml(s.filename || s.name || 'Script')}</div></td>
                                    <td>${Utils.escapeHtml(s.description || 'Sem descricao')}</td>
                                    <td>${Number(s.execution_order || 0)}</td>
                                    <td><span class="badge ${badgeMeta.className}">${Utils.escapeHtml(versionLabel)}</span></td>
                                    <td>
                                        <button class="btn ${s.is_active ? 'btn-success btn-sm' : 'btn-secondary btn-sm'}" onclick="toggleLocalScript(${s.id}, ${s.is_active ? 'false' : 'true'})">
                                            ${statusLabel}
                                        </button>
                                    </td>
                                    <td class="text-right">
                                        <div class="flex justify-end gap-2">
                                            <button class="btn btn-secondary btn-sm" onclick="openOmScriptEditor(${s.id})">Editar</button>
                                            <button class="btn btn-secondary btn-sm" onclick="openLocalScriptHistory(${s.id})">Histórico</button>
                                            <button class="btn btn-danger btn-sm" onclick="restoreLocalScriptDefault(${s.id})">Usar Default do Servidor</button>
                                        </div>
                                    </td>
                                </tr>
                            `;
                        }).join('') || '<tr><td colspan="6" class="text-slate-500 text-center py-4">Nenhum script</td></tr>'}
                    </tbody>
                </table>
            </div>
            <div class="mt-4 flex justify-end">
                <button class="btn btn-secondary btn-sm" onclick="showOrgReorderModal()">Reordenar Scripts</button>
            </div>
        </div>
    `;
}

async function openOmScriptEditor(scriptId) {
    if (!currentOrgId) {
        Toast.error('Selecione uma OM antes de editar scripts locais');
        return;
    }

    const [scriptMeta, orgScripts] = await Promise.all([
        API.get('script', { id: scriptId }),
        API.get('get-org-scripts', { organization_id: currentOrgId })
    ]);
    if (!scriptMeta.success) {
        Toast.error(scriptMeta.error || 'Erro ao carregar script');
        return;
    }

    const scriptData = scriptMeta.data || {};
    const localScript = orgScripts.success
        ? (orgScripts.data || []).find(script => Number(script.id) === Number(scriptId))
        : null;
    const resolvedName = localScript?.name || scriptData.name || '';
    const resolvedDescription = localScript?.description || scriptData.description || '';
    const resolvedFilename = localScript?.filename || scriptData.filename || '';

    document.getElementById('edit-script-id').value = scriptData.id;
    document.getElementById('edit-script-filename').value = resolvedFilename;
    document.getElementById('edit-script-name').value = resolvedName;
    document.getElementById('edit-script-description').value = resolvedDescription;
    document.getElementById('edit-script-content').value = localScript?.content || scriptData.content || '';
    document.getElementById('edit-script-changelog').value = '';
    document.getElementById('edit-script-scope-preview').textContent = 'Escopo: OM Específica';
    document.getElementById('edit-script-scope').value = 'om_specific';
    document.getElementById('edit-script-name-group').style.display = 'none';
    document.getElementById('edit-script-description-group').style.display = 'none';
    document.getElementById('edit-script-changelog-group').style.display = 'block';
    document.getElementById('edit-script-submit-btn').textContent = 'Salvar';
    document.getElementById('edit-script-modal-title').textContent = `Editar Script OM: ${resolvedFilename || 'Script'}`;
    document.getElementById('edit-script-form').onsubmit = saveOmScriptVersion;
    openModal('modal-edit-script');
}
window.openOmScriptEditor = openOmScriptEditor;

async function saveOmScriptVersion(event) {
    event.preventDefault();

    if (!currentOrgId) {
        Toast.error('Selecione uma OM antes de salvar o script');
        return;
    }

    const scriptId = Number(document.getElementById('edit-script-id').value);
    const content = document.getElementById('edit-script-content').value;
    const changelog = document.getElementById('edit-script-changelog').value.trim();

    if (!scriptId || !content.trim()) {
        Toast.error('Conteudo do script obrigatorio');
        return;
    }

    let executionOrder = 0;
    try {
        const orgScriptsRes = await API.get('get-org-scripts', { organization_id: Number(currentOrgId) });
        if (orgScriptsRes.success) {
            const existing = (orgScriptsRes.data || []).find(s => Number(s.id) === scriptId);
            if (existing) executionOrder = Number(existing.execution_order || 0);
        }
    } catch (e) {}

    const res = await API.post('save-script-om-version', {
        script_id: scriptId,
        organization_id: Number(currentOrgId),
        content,
        execution_order: executionOrder,
        is_active: true,
        changelog
    });

    if (!res.success) {
        Toast.error(res.error || 'Erro ao salvar override local');
        return;
    }

    Toast.success(res.message || 'Override local salvo com sucesso');
    closeModal('modal-edit-script');
    loadOrgScripts(currentOrgId);
}
window.saveOmScriptVersion = saveOmScriptVersion;

let localHistoryContent = {};
let localHistoryScriptId = null;
let localHistoryOrgId = null;

async function openLocalScriptHistory(scriptId) {
    localHistoryScriptId = Number(scriptId);
    localHistoryOrgId = Number(currentOrgId);

    try {
        const res = await API.get('om-script-versions', {
            script_id: localHistoryScriptId,
            organization_id: localHistoryOrgId
        });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao carregar histórico da OM');
            return;
        }

        const script = res.data?.script || {};
        const versions = res.data?.versions || [];
        const listEl = document.getElementById('script-history-list');
        const contentEl = document.getElementById('script-history-content');
        if (!listEl || !contentEl) return;

        const scriptName = script?.name || script?.filename || 'Script';
        document.getElementById('script-history-title').textContent = `Histórico Local: ${scriptName}`;

        if (!versions.length) {
            listEl.innerHTML = '<p class="text-slate-500 text-sm">Nenhuma versão local registrada para este script.</p>';
            contentEl.value = '';
            openModal('modal-script-history');
            return;
        }

        localHistoryContent = {};
        versions.forEach(v => {
            localHistoryContent[v.id] = v.content || '';
        });

        const canDelete = currentUser && currentUser.role === 'admin_gap';

        listEl.innerHTML = versions.map(v => {
            const isActive = Boolean(v.is_active);
            const statusBadge = isActive
                ? '<span class="badge badge-success">Ativa</span>'
                : '<span class="badge badge-secondary">Inativa</span>';
            const reactivateBtn = isActive
                ? ''
                : `<button class="btn btn-primary btn-sm" onclick="reactivateLocalVersion(${v.id})">Reativar</button>`;
            const deleteBtn = canDelete
                ? `<button class="btn btn-danger btn-sm" onclick="deleteLocalVersion(${v.id})">Deletar</button>`
                : '';
            return `
                <div class="p-3 bg-slate-900 rounded border border-slate-700">
                    <div class="flex items-center justify-between gap-3 mb-2">
                        <div>
                            <div class="font-medium text-white">v${Number(v.version_number || 0)}</div>
                            <div class="text-xs text-slate-400">${Utils.escapeHtml(v.created_at || '')} • ${Utils.escapeHtml(v.created_by_username || 'Sistema')}</div>
                        </div>
                        ${statusBadge}
                    </div>
                    <div class="flex gap-2 mt-2">
                        <button class="btn btn-secondary btn-sm" onclick="previewLocalVersion(${v.id})">Visualizar</button>
                        ${reactivateBtn}
                        ${deleteBtn}
                    </div>
                </div>
            `;
        }).join('');

        const activeVersion = versions.find(v => Boolean(v.is_active)) || versions[0];
        contentEl.value = activeVersion?.content || '';
        openModal('modal-script-history');
    } catch (error) {
        Toast.error('Erro ao abrir histórico do script local');
    }
}
window.openLocalScriptHistory = openLocalScriptHistory;

window.previewLocalVersion = function(versionId) {
    const contentEl = document.getElementById('script-history-content');
    if (!contentEl) return;
    contentEl.value = localHistoryContent[versionId] || '';
};

async function reactivateLocalVersion(versionId) {
    try {
        const res = await API.post('reactivate-om-version', {
            version_id: Number(versionId),
            organization_id: localHistoryOrgId,
            script_id: localHistoryScriptId
        });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao reativar versão');
            return;
        }
        Toast.success(res.message || 'Versão reativada');
        openLocalScriptHistory(localHistoryScriptId);
    } catch (error) {
        Toast.error('Erro ao reativar versão');
    }
}
window.reactivateLocalVersion = reactivateLocalVersion;

async function deleteLocalVersion(versionId) {
    if (!confirm('Tem certeza que deseja deletar esta versão? Esta ação não pode ser desfeita.')) return;
    try {
        const res = await API.post('delete-om-version', {
            version_id: Number(versionId),
            organization_id: localHistoryOrgId,
            script_id: localHistoryScriptId
        });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao deletar versão');
            return;
        }
        Toast.success(res.message || 'Versão deletada');
        openLocalScriptHistory(localHistoryScriptId);
    } catch (error) {
        Toast.error('Erro ao deletar versão');
    }
}
window.deleteLocalVersion = deleteLocalVersion;

async function toggleLocalScript(scriptId, nextState) {
    const res = await API.get('get-org-scripts', { organization_id: currentOrgId });
    if (!res.success) {
        Toast.error(res.error || 'Erro ao carregar status do script');
        return;
    }

    const script = (res.data || []).find(item => Number(item.id) === Number(scriptId));
    if (!script) {
        Toast.error('Script não encontrado na OM');
        return;
    }

    const payload = {
        script_id: Number(scriptId),
        organization_id: Number(currentOrgId),
        content: script.content || '',
        execution_order: Number(script.execution_order || 0),
        is_active: Boolean(nextState),
        changelog: `Ativacao local: ${nextState ? 'ativo' : 'inativo'}`
    };

    const saveRes = await API.post('save-script-om-version', payload);
    if (!saveRes.success) {
        Toast.error(saveRes.error || 'Erro ao alternar script local');
        return;
    }

    Toast.success(nextState ? 'Script ativado localmente' : 'Script desativado localmente');
    loadOrgScripts(currentOrgId);
}
window.toggleLocalScript = toggleLocalScript;

async function showOrgReorderModal() {
    if (!currentOrgId) {
        Toast.error('Selecione uma OM antes de reordenar os scripts');
        return;
    }

    try {
        const res = await API.get('get-org-scripts', { organization_id: currentOrgId });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao carregar scripts da OM');
            return;
        }

        const list = document.getElementById('reorder-script-list');
        if (!list) return;

        const scripts = [...(res.data || [])].sort((a, b) => (Number(a.execution_order || 0) - Number(b.execution_order || 0)) || (a.name || '').localeCompare(b.name || ''));
        list.innerHTML = scripts.map((script, index) => `
            <div class="reorder-item" data-id="${script.id}" data-order="${Number(script.execution_order || index + 1)}">
                <span class="drag-handle">&#9776;</span>
                <span class="order-number">${Number(script.execution_order || index + 1)}</span>
                <span class="script-name">${Utils.escapeHtml(script.name || script.filename || 'Script')}</span>
                <span class="text-slate-500 text-xs font-mono">${Utils.escapeHtml(script.filename || '')}</span>
                <span class="script-badge ${script.source_type === 'local' ? 'core' : (script.source_type === 'gap_default' || script.source_type === 'global') ? 'warning' : 'secondary'}">${Utils.escapeHtml(getOrgScriptBadgeMeta(script).label)}</span>
            </div>
        `).join('');

        list.querySelectorAll('.reorder-item').forEach((item) => {
            item.addEventListener('dragstart', handleDragStart);
            item.addEventListener('dragover', handleDragOver);
            item.addEventListener('drop', handleDrop);
            item.addEventListener('dragend', handleDragEnd);
        });

        openModal('modal-reorder-scripts');
    } catch (error) {
        Toast.error('Erro ao abrir reordenacao local');
    }
}
window.showOrgReorderModal = showOrgReorderModal;

async function saveOrgScriptOrder() {
    const items = document.querySelectorAll('#reorder-script-list .reorder-item');
    const scripts = Array.from(items).map((item, index) => ({
        id: parseInt(item.dataset.id, 10),
        order: index + 1
    }));

    try {
        const currentRes = await API.get('get-org-scripts', { organization_id: currentOrgId });
        if (!currentRes.success) {
            Toast.error(currentRes.error || 'Erro ao carregar scripts da OM');
            return;
        }

        const results = await Promise.all(scripts.map(async (script) => {
            const target = (currentRes.data || []).find(item => Number(item.id) === Number(script.id));
            if (!target) return false;
            return API.post('save-script-om-version', {
                script_id: Number(script.id),
                organization_id: Number(currentOrgId),
                content: target.content || '',
                execution_order: Number(script.order),
                is_active: Boolean(target.is_active),
                changelog: 'Reordenacao local'
            });
        }));

        const failed = results.some(result => !result || !result.success);
        if (failed) {
            Toast.error('Falha ao salvar ordem local');
            return;
        }

        Toast.success('Ordem local salva com sucesso');
        closeModal('modal-reorder-scripts');
        loadOrgScripts(currentOrgId);
    } catch (error) {
        Toast.error('Erro ao salvar ordem local');
    }
}
window.saveOrgScriptOrder = saveOrgScriptOrder;

async function resetOrgScriptOrder() {
    if (!confirm('Deseja restaurar a ordem padrao da OM para os scripts?')) return;

    try {
        const res = await API.get('get-org-scripts', { organization_id: currentOrgId });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao carregar scripts da OM');
            return;
        }

        const scripts = res.data || [];
        const results = await Promise.all(scripts.map(async (script) => {
            if (!script.id) return false;
            return API.post('save-script-om-version', {
                script_id: Number(script.id),
                organization_id: Number(currentOrgId),
                content: script.content || '',
                execution_order: Number(script.execution_order || 0),
                is_active: Boolean(script.is_active),
                changelog: 'Reset local da ordem'
            });
        }));

        const failed = results.some(result => !result || !result.success);
        if (failed) {
            Toast.error('Falha ao restaurar ordem local');
            return;
        }

        Toast.success('Ordem local restaurada');
        showOrgReorderModal();
    } catch (error) {
        Toast.error('Erro ao restaurar ordem local');
    }
}
window.resetOrgScriptOrder = resetOrgScriptOrder;

async function moveOrgScriptOrder(scriptId, delta) {
    const res = await API.get('get-org-scripts', { organization_id: currentOrgId });
    if (!res.success) return;

    const scripts = [...(res.data || [])].sort((a, b) => Number(a.execution_order || 0) - Number(b.execution_order || 0));
    const index = scripts.findIndex(item => Number(item.id) === Number(scriptId));
    if (index < 0) return;

    const nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= scripts.length) return;

    const current = scripts[index];
    const target = scripts[nextIndex];
    const currentOrder = Number(current.execution_order || 0);
    const targetOrder = Number(target.execution_order || 0);

    const currentUpdate = await API.post('save-script-om-version', {
        script_id: Number(current.id),
        organization_id: Number(currentOrgId),
        content: current.content || '',
        execution_order: targetOrder,
        is_active: Boolean(current.is_active),
        changelog: 'Reordenacao local'
    });
    const targetUpdate = await API.post('save-script-om-version', {
        script_id: Number(target.id),
        organization_id: Number(currentOrgId),
        content: target.content || '',
        execution_order: currentOrder,
        is_active: Boolean(target.is_active),
        changelog: 'Reordenacao local'
    });

    if (!currentUpdate.success || !targetUpdate.success) {
        Toast.error('Erro ao reordenar scripts locais');
        return;
    }

    Toast.success('Ordem local atualizada');
    loadOrgScripts(currentOrgId);
}
window.moveOrgScriptOrder = moveOrgScriptOrder;

async function restoreLocalScriptDefault(scriptId) {
    if (!confirm('Deseja restaurar o default do servidor para este script da OM?')) return;

    const res = await API.post('reset-script-om-default', {
        script_id: Number(scriptId),
        organization_id: Number(currentOrgId)
    });

    if (!res.success) {
        Toast.error(res.error || 'Erro ao restaurar default do servidor');
        return;
    }

    Toast.success(res.message || 'Default do servidor restaurado');
    loadOrgScripts(currentOrgId);
}
window.restoreLocalScriptDefault = restoreLocalScriptDefault;

function switchScriptTab(type) {
    scriptTab = type;
    document.querySelectorAll('.script-tab-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.scriptTab === type);
        btn.classList.toggle('btn-primary', btn.dataset.scriptTab === type);
        btn.classList.toggle('btn-secondary', btn.dataset.scriptTab !== type);
    });
    loadOrgScripts(currentOrgId);
}
window.switchScriptTab = switchScriptTab;

async function viewScript(id) {
    const res = await API.get('script', { id });
    if (!res.success) { Toast.error(res.error || 'Erro ao carregar script'); return; }

    document.getElementById('script-view-name').textContent = res.data.name;
    document.getElementById('script-view-filename').textContent = res.data.filename;
    document.getElementById('script-view-content').value = res.data.content || '';
    document.getElementById('script-view-core').textContent = res.data.is_core ? 'Sim' : 'Nao';

    document.getElementById('script-edit-btn').classList.toggle('hidden', res.data.is_core);
    document.getElementById('script-delete-btn').classList.toggle('hidden', res.data.is_core);

    if (!res.data.is_core) {
        document.getElementById('script-edit-btn').onclick = () => editScript(id);
        document.getElementById('script-delete-btn').onclick = () => deleteScript(id);
    }

    openModal('modal-view-script');
}
window.viewScript = viewScript;

async function editScript(id, scopeOverride = null) {
    const res = await API.get('script', { id });
    if (!res.success) { Toast.error(res.error); return; }

    const isCore = Boolean(res.data.is_core);
    const contextScope = scopeOverride || (currentUser && currentUser.role === 'admin_gap' ? 'gap_default' : 'om_specific');
    const scopeLabel = contextScope === 'gap_default' ? 'GAP Default' : 'OM Específica';

    document.getElementById('edit-script-id').value = res.data.id;
    document.getElementById('edit-script-filename').value = res.data.filename || '';
    document.getElementById('edit-script-name').value = res.data.name || '';
    document.getElementById('edit-script-description').value = res.data.description || '';
    document.getElementById('edit-script-content').value = res.data.content || '';
    document.getElementById('edit-script-changelog').value = '';
    document.getElementById('edit-script-scope').value = isCore ? contextScope : 'gap_default';
    document.getElementById('edit-script-scope-preview').textContent = `Escopo: ${scopeLabel}`;
    window.__scriptEditScope = contextScope;

    const nameGroup = document.getElementById('edit-script-name-group');
    const descGroup = document.getElementById('edit-script-description-group');
    const changelogGroup = document.getElementById('edit-script-changelog-group');
    const submitBtn = document.getElementById('edit-script-submit-btn');

    if (isCore) {
        document.getElementById('edit-script-modal-title').textContent = `Editar Script: ${res.data.filename || 'Core'}`;
        nameGroup.style.display = 'none';
        descGroup.style.display = 'none';
        changelogGroup.style.display = 'block';
        submitBtn.textContent = 'Salvar como nova versão';
        document.getElementById('edit-script-form').onsubmit = saveScriptVersion;
    } else {
        document.getElementById('edit-script-modal-title').textContent = 'Editar Script';
        nameGroup.style.display = 'block';
        descGroup.style.display = 'block';
        changelogGroup.style.display = 'none';
        submitBtn.textContent = 'Salvar';
        document.getElementById('edit-script-form').onsubmit = updateScript;
    }

    closeModal('modal-view-script');
    openModal('modal-edit-script');
}
window.editScript = editScript;

async function saveScriptVersion(event) {
    event.preventDefault();
    const scriptId = Number(document.getElementById('edit-script-id').value);
    const content = document.getElementById('edit-script-content').value;
    const changelog = document.getElementById('edit-script-changelog').value.trim();

    if (!scriptId || !content.trim()) {
        Toast.error('Conteudo do script e obrigatorio');
        return;
    }

    try {
        const res = await API.post('save-script-gap-version', {
            script_id: scriptId,
            content,
            changelog
        });
        if (!res.success) {
            Toast.error(res.error || 'Erro ao salvar versao GAP');
            return;
        }

        Toast.success('Versao GAP salva com sucesso');
        closeModal('modal-edit-script');
        loadAllScripts();
    } catch (error) {
        Toast.error('Erro ao salvar versao GAP');
    }
}
window.saveScriptVersion = saveScriptVersion;

async function deleteScript(id) {
    if (!confirm('Tem certeza que deseja excluir? Esta acao nao pode ser desfeita.')) return;
    const res = await API.delete('script', id);
    if (res.success) {
        Toast.success('Script excluido');
        closeModal('modal-view-script');
        loadAllScripts();
    } else {
        Toast.error(res.error || 'Erro ao excluir');
    }
}
window.deleteScript = deleteScript;

async function createScript(e) {
    e.preventDefault();
    const name = document.getElementById('new-script-name').value.trim();
    const filename = document.getElementById('new-script-filename').value.trim();
    const description = document.getElementById('new-script-description').value;
    const content = document.getElementById('new-script-content').value;

    if (!name || !filename) { Toast.error('Nome e arquivo obrigatorios'); return; }

    const res = await API.post('script', { name, filename, description, content, is_core: false });
    if (res.success) {
        Toast.success('Script criado com sucesso');
        closeModal('modal-new-script');
        document.getElementById('new-script-form')?.reset();
        loadAllScripts();
        if (currentOrgId) loadOrgScripts(currentOrgId);
    } else {
        Toast.error(res.error || 'Erro ao criar script');
    }
}
window.createScript = createScript;

async function updateScript(e) {
    e.preventDefault();
    const id = document.getElementById('edit-script-id').value;
    const name = document.getElementById('edit-script-name').value.trim();
    const description = document.getElementById('edit-script-description').value;
    const content = document.getElementById('edit-script-content').value;

    if (!name) { Toast.error('Nome obrigatorio'); return; }

    const res = await API.put('script', id, { name, description, content });
    if (res.success) {
        Toast.success('Script atualizado com sucesso');
        closeModal('modal-edit-script');
        loadAllScripts();
        if (currentOrgId) loadOrgScripts(currentOrgId);
    } else {
        Toast.error(res.error || 'Erro ao atualizar script');
    }
}
window.updateScript = updateScript;

// ============ BUNDLE ============

async function generateBundle() {
    if (!currentOrgId) { Toast.error('Selecione uma organizacao'); return; }

    const selected = [...document.querySelectorAll('.script-checkbox:checked')].map(el => parseInt(el.value));

    // Solicitar descricao opcional do bundle
    const description = prompt('Descricao do bundle (opcional):', '');
    // Se o usuario cancelar (prompt retorna null), aborta a geracao
    if (description === null) return;

    const forceNotify = document.getElementById('force-notify')?.checked ?? false;

    Toast.info('Gerando bundle...');

    try {
        const res = await API.post('generate-bundle', {
            organization_id: currentOrgId,
            scripts: selected,
            description: description.trim(),
            force_notify: forceNotify
        });
        if (res.success) {
            Toast.success('Bundle gerado com sucesso');
            loadBundles(currentOrgId);
        } else {
            Toast.error(res.error || 'Erro ao gerar bundle');
        }
    } catch (error) {
        Toast.error('Nao foi possivel gerar o bundle');
    }
}
window.generateBundle = generateBundle;

// ============ BUNDLES GALLERY ============

async function loadBundles(orgId) {
    if (!orgId) return;
    const el = document.getElementById('bundles-tbody');
    if (!el) return;

    el.innerHTML = '<tr><td colspan="6" class="px-4 py-8"><div class="skeleton-table-row"><span class="skeleton-block short"></span><span class="skeleton-block"></span><span class="skeleton-block"></span><span class="skeleton-block"></span><span class="skeleton-block short"></span></div></td></tr>';

    const res = await API.get('bundles', { org_id: orgId });
    if (!res.success) { el.innerHTML = '<tr><td colspan="6" class="px-4 py-8 text-center text-rose-400">Erro ao carregar</td></tr>'; return; }

    const bundleList = Array.isArray(res.data) ? res.data : (res.data && Array.isArray(res.data.bundles) ? res.data.bundles : []);

    if (!bundleList || bundleList.length === 0) {
        el.innerHTML = '<tr><td colspan="6" class="px-4 py-8 text-center text-slate-400">Nenhum bundle gerado ainda</td></tr>';
        return;
    }

    el.innerHTML = bundleList.map(b => {
        const date = new Date(b.generated_at);
        const dateStr = date.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric' }) +
            ' ' + date.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
        const sizeKb = b.content_size ? Math.round(b.content_size / 1024) : '-';
        const activeBadge = b.is_active
            ? '<span class="badge badge-success">Ativo</span>'
            : '<span class="badge badge-secondary">Inativo</span>';
        const descText = b.description
            ? `<span title="${Utils.escapeHtml(b.description)}">${Utils.escapeHtml(b.description.length > 40 ? b.description.substring(0, 40) + '...' : b.description)}</span>`
            : '<span class="text-slate-500 italic">—</span>';
        return `
            <tr class="border-b border-slate-700/50" data-testid="bundle-row-${b.id}">
                <td class="px-4 py-3 text-sm text-slate-300">${dateStr}</td>
                <td class="px-4 py-3 text-sm text-slate-300">${descText}</td>
                <td class="px-4 py-3 text-sm text-slate-400">${b.scripts_count || 0}</td>
                <td class="px-4 py-3 text-sm text-slate-400">${sizeKb} KB</td>
                <td class="px-4 py-3">${activeBadge}</td>
                <td class="px-4 py-3 text-right">
                    <button data-testid="bundle-download-${b.id}" onclick="downloadBundle(${b.id})" class="text-blue-400 hover:text-blue-300 text-sm mr-2">Download</button>
                    <button data-testid="bundle-toggle-${b.id}" onclick="toggleBundleActive(${b.id})" class="text-amber-400 hover:text-amber-300 text-sm">${b.is_active ? 'Desativar' : 'Ativar'}</button>
                    <button data-testid="bundle-edit-${b.id}" onclick="editBundleDesc(${b.id})" class="text-blue-400 hover:text-blue-300 text-sm ml-2">Editar</button>
<button data-testid="bundle-delete-${b.id}" onclick="deleteBundle(${b.id})" class="text-red-400 hover:text-red-300 text-sm ml-2">Excluir</button>
                </td>
            </tr>`;
    }).join('');
}
window.loadBundles = loadBundles;

function downloadBundle(bundleId) {
    window.location.href = `/api/?action=bundle-by-id&id=${bundleId}`;
}
window.downloadBundle = downloadBundle;

async function toggleBundleActive(bundleId) {
    const res = await API.post('bundle-toggle', { bundle_id: bundleId });
    if (res.success) {
        Toast.success(res.message || 'Status alterado');
        if (currentOrgId) loadBundles(currentOrgId);
    } else {
        Toast.error(res.error || 'Erro');
    }
}
window.toggleBundleActive = toggleBundleActive;

// ============ USERS ============

async function loadUsers() {
    const res = await API.get('users');
    if (!res.success) return;

    const el = document.getElementById('users-tbody');
    if (!el) return;

    el.innerHTML = res.data.length ? res.data.map(u => `
        <tr>
            <td class="px-4 py-3">${Utils.escapeHtml(u.username)}</td>
            <td class="px-4 py-3">${Utils.escapeHtml(u.full_name || '-')}</td>
            <td class="px-4 py-3">${Utils.escapeHtml(u.email || '-')}</td>
            <td class="px-4 py-3"><span class="badge badge-info">${roleLabels[u.role] || u.role}</span></td>
            <td class="px-4 py-3">${Utils.escapeHtml(u.org_acronym || '-')}</td>
            <td class="px-4 py-3"><span class="badge ${u.is_active ? 'badge-success' : 'badge-secondary'}">${u.is_active ? 'Ativo' : 'Inativo'}</span></td>
            <td class="px-4 py-3 text-right">
                <button onclick="editUser(${u.id})" class="text-blue-400 hover:text-blue-300 text-sm mr-2">Editar</button>
                <button onclick="toggleUserStatus(${u.id})" class="text-amber-400 hover:text-amber-300 text-sm mr-2">${u.is_active ? 'Desativar' : 'Ativar'}</button>
                <button onclick="deleteUser(${u.id})" class="text-red-400 hover:text-red-300 text-sm">Excluir</button>
            </td>
        </tr>
    `).join('') : '<tr><td colspan="7" class="px-4 py-8 text-center text-slate-400">Nenhum usuario</td></tr>';
}

async function saveUser(e) {
    e.preventDefault();
    const password = document.getElementById('user-password').value;
    const confirmPassword = document.getElementById('user-confirm-password').value;

    if (password && password !== confirmPassword) { Toast.error('Senhas nao conferem'); return; }

    const id = document.getElementById('user-edit-id').value;
    const data = {
        username: document.getElementById('user-username').value,
        full_name: document.getElementById('user-full-name').value,
        email: document.getElementById('user-email').value,
        role: document.getElementById('user-role').value,
        organization_id: document.getElementById('user-organization').value || null,
        password, confirm_password: confirmPassword
    };

    const res = id ? await API.put('user', id, data) : await API.post('users', data);
    if (res.success) {
        Toast.success(id ? 'Usuario atualizado' : 'Usuario criado');
        closeModal('modal-user');
        loadUsers();
    } else {
        Toast.error(res.error || 'Erro ao salvar');
    }
}
window.saveUser = saveUser;

function editUser(id) {
    API.get('users').then(res => {
        if (!res.success) return;
        const user = res.data.find(u => u.id === id);
        if (!user) return;
        document.getElementById('user-edit-id').value = user.id;
        document.getElementById('user-username').value = user.username;
        document.getElementById('user-full-name').value = user.full_name || '';
        document.getElementById('user-email').value = user.email || '';
        document.getElementById('user-role').value = user.role;
        document.getElementById('user-organization').value = user.organization_id || '';
        document.getElementById('user-password').value = '';
        document.getElementById('user-confirm-password').value = '';
        document.getElementById('modal-user-title').textContent = 'Editar Usuario';
        openModal('modal-user');
    });
}
window.editUser = editUser;

async function deleteUser(id) {
    if (!confirm('Tem certeza que deseja excluir? Esta acao nao pode ser desfeita.')) return;
    const res = await API.delete('user', id);
    if (res.success) { Toast.success('Usuario excluido'); loadUsers(); }
    else Toast.error(res.error || 'Erro ao excluir');
}
window.deleteUser = deleteUser;

async function toggleUserStatus(id) {
    const res = await API.post('user', {}, { id });
    if (res.success) { Toast.success(res.message || 'Status alterado'); loadUsers(); }
    else Toast.error(res.error || 'Erro');
}
window.toggleUserStatus = toggleUserStatus;

// ============ STATIONS ============

async function loadStations() {
    const res = await API.get('stations', { org_id: currentOrgId || 0 });
    if (!res.success) return;

    const el = document.getElementById('stations-tbody');
    if (!el) return;

    el.innerHTML = res.data.length ? res.data.map(s => {
        const connBadge = { online: 'badge-success', delayed: 'badge-warning', never: 'badge-secondary' }[s.connection_status] || 'badge-secondary';
        const connLabel = { online: 'Online', delayed: 'Atrasada', never: 'Nunca' }[s.connection_status] || '-';
        return `
            <tr>
                <td class="px-4 py-3">${Utils.escapeHtml(s.hostname)}</td>
                <td class="px-4 py-3 font-mono text-sm">${Utils.escapeHtml(s.ip_address || '-')}</td>
                <td class="px-4 py-3 font-mono text-sm">${Utils.escapeHtml(s.mac_address || '-')}</td>
                <td class="px-4 py-3">${Utils.escapeHtml(s.os_name || '-')} ${Utils.escapeHtml(s.os_version || '')}</td>
                <td class="px-4 py-3">${Utils.formatDate(s.last_checkin)}</td>
                <td class="px-4 py-3"><span class="badge ${connBadge}">${connLabel}</span></td>
                <td class="px-4 py-3">${Utils.escapeHtml(s.org_acronym || '-')}</td>
            </tr>`;
    }).join('') : '<tr><td colspan="7" class="px-4 py-8 text-center text-slate-400">Nenhuma estacao</td></tr>';
}

// ============ AUDIT ============

let auditCurrentPage = 1;
let auditCurrentTab = 'all';
let auditSeverityFilter = 'all';
let auditRows = [];

function getAuditSeverity(event) {
    const action = String(event?.action || '').toUpperCase();
    if (action.includes('FAILED') || action.includes('DELETE') || action.includes('RESET') || action.includes('DEACTIVATE')) return 'critical';
    if (action.includes('CREATE') || action.includes('UPDATE') || action.includes('UPLOAD') || action.includes('GENERATE') || action.includes('SYNC') || action.includes('ACTIVATE')) return 'important';
    return 'informative';
}

function getAuditSeverityLabel(level) {
    const map = {
        critical: 'Crítico',
        important: 'Importante',
        informative: 'Informativo'
    };
    return map[level] || 'Informativo';
}

function getAuditSeverityClass(level) {
    const map = {
        critical: 'badge-danger',
        important: 'badge-warning',
        informative: 'badge-info'
    };
    return map[level] || 'badge-info';
}

function getAuditCategory(event) {
    const entity = String(event?.entity || '').toLowerCase();
    const action = String(event?.action || '').toUpperCase();

    if (['login', 'logout', 'login_failed'].includes(action.toLowerCase()) || entity === 'users' && (action.includes('LOGIN') || action.includes('LOGOUT'))) return 'auth';
    if (entity === 'organizations') return 'organizations';
    if (entity === 'users') return 'users';
    if (['scripts', 'script_versions', 'om_script_versions'].includes(entity)) return 'scripts';
    if (entity === 'bundles' || action.includes('GENERATE') || action.includes('BUNDLE')) return 'bundles';
    if (['wallpaper', 'logo', 'gallery-image', 'asset'].includes(entity)) return 'assets';
    if (['variables', 'variable_definitions', 'config', 'settings'].includes(entity)) return 'settings';
    if (action.includes('LOGIN') || action.includes('LOGOUT')) return 'auth';
    return 'all';
}

function summarizeAuditDetails(event) {
    const details = event?.details;
    if (!details) return '-';

    if (typeof details === 'string') {
        try {
            const parsed = JSON.parse(details);
            if (parsed && typeof parsed === 'object') return JSON.stringify(parsed).slice(0, 140);
        } catch (e) {
            return details.slice(0, 140);
        }
        return details.slice(0, 140);
    }

    if (typeof details === 'object') {
        const compact = JSON.stringify(details).slice(0, 140);
        return compact === '{}' ? '-' : compact;
    }

    return String(details).slice(0, 140);
}

function applyAuditFilters(rows) {
    const selectedTab = auditCurrentTab;
    const severity = auditSeverityFilter;

    return rows.filter((event) => {
        const categoryMatches = selectedTab === 'all' || getAuditCategory(event) === selectedTab;
        const severityMatches = severity === 'all' || getAuditSeverity(event) === severity;
        return categoryMatches && severityMatches;
    });
}

async function loadAuditEvents() {
    const params = { page: auditCurrentPage, limit: 20 };
    const startDate = document.getElementById('audit-start-date')?.value;
    const endDate = document.getElementById('audit-end-date')?.value;
    if (startDate) params.start_date = startDate;
    if (endDate) params.end_date = endDate;

    try {
        const res = await API.get('audit', params);
        if (!res.success) {
            Toast.error(res.error || 'Erro ao carregar auditoria');
            return;
        }

        const payload = res.data && typeof res.data === 'object' ? res.data : {};
        const events = Array.isArray(payload.events) ? payload.events : Array.isArray(res.data) ? res.data : [];
        const pagination = payload.pagination || { total: 0, page: 1, pages: 1 };
        auditRows = events;

        const filtered = applyAuditFilters(auditRows);
        const el = document.getElementById('audit-tbody');
        if (!el) return;

        if (!filtered.length) {
            el.innerHTML = '<tr><td colspan="7" class="px-4 py-8 text-center text-slate-400">Nenhum evento registrado</td></tr>';
        } else {
            el.innerHTML = filtered.map(event => {
                const level = getAuditSeverity(event);
                return `
                    <tr>
                        <td class="px-4 py-3">${Utils.formatDate(event.created_at)}</td>
                        <td class="px-4 py-3"><span class="badge ${getAuditSeverityClass(level)}">${Utils.escapeHtml(getAuditSeverityLabel(level))}</span></td>
                        <td class="px-4 py-3">${Utils.escapeHtml(event.full_name || event.username || '-')}</td>
                        <td class="px-4 py-3">${Utils.escapeHtml(event.org_acronym || '-')}</td>
                        <td class="px-4 py-3"><span class="badge badge-info">${Utils.escapeHtml(event.action || '-')}</span></td>
                        <td class="px-4 py-3">${Utils.escapeHtml(event.entity || '-')}</td>
                        <td class="px-4 py-3 text-slate-400 text-sm">${Utils.escapeHtml(event.summary || summarizeAuditDetails(event))}</td>
                    </tr>
                `;
            }).join('');
        }

        const infoEl = document.getElementById('audit-info');
        if (infoEl) infoEl.textContent = `${pagination.total} evento(s)`;

        const pageInfoEl = document.getElementById('audit-page-info');
        if (pageInfoEl) pageInfoEl.textContent = `Pagina ${pagination.page} de ${pagination.pages}`;

        const prevBtn = document.getElementById('audit-prev');
        const nextBtn = document.getElementById('audit-next');
        if (prevBtn) prevBtn.disabled = pagination.page <= 1;
        if (nextBtn) nextBtn.disabled = pagination.page >= pagination.pages;
    } catch (error) {
        console.error('Erro ao carregar auditoria:', error);
        Toast.error(error?.message || 'Erro de rede ao carregar auditoria');
        const el = document.getElementById('audit-tbody');
        if (el) el.innerHTML = '<tr><td colspan="7" class="px-4 py-8 text-center text-slate-400">Erro ao carregar eventos</td></tr>';
    }
}
window.loadAuditEvents = loadAuditEvents;

function auditChangePage(delta) {
    const next = auditCurrentPage + delta;
    if (next < 1) return;
    auditCurrentPage = next;
    loadAuditEvents();
}
window.auditChangePage = auditChangePage;

function exportAuditCsv() {
    const rows = applyAuditFilters(auditRows);
    if (!rows.length) {
        Toast.warning('Nenhum evento para exportar.');
        return;
    }

    const header = ['Data/Hora', 'Severidade', 'Usuario', 'OM', 'Acao', 'Entidade', 'Descricao'];
    const csvRows = [header.join(',')].concat(rows.map(event => {
        const values = [
            event.created_at || '',
            getAuditSeverityLabel(getAuditSeverity(event)),
            event.full_name || event.username || '',
            event.org_acronym || '',
            event.action || '',
            event.entity || '',
            summarizeAuditDetails(event).replace(/\r?\n/g, ' ')
        ];
        return values.map(v => `"${String(v).replace(/"/g, '""')}"`).join(',');
    }));

    const blob = new Blob([csvRows.join('\n')], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'audit_events.csv';
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
}
window.exportAuditCsv = exportAuditCsv;

function exportAuditJson() {
    const rows = applyAuditFilters(auditRows);
    if (!rows.length) {
        Toast.warning('Nenhum evento para exportar.');
        return;
    }

    const blob = new Blob([JSON.stringify(rows, null, 2)], { type: 'application/json;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = 'audit_events.json';
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
}
window.exportAuditJson = exportAuditJson;

// ============ ORG CRUD ============

async function createOrganization(e) {
    e.preventDefault();
    const res = await API.post('organizations', {
        name: document.getElementById('new-org-name').value,
        acronym: document.getElementById('new-org-acronym').value.toUpperCase(),
        domain: document.getElementById('new-org-domain').value,
        description: document.getElementById('new-org-description').value,
        dc_ip: document.getElementById('new-org-dc-ip')?.value,
        dns_primario: document.getElementById('new-org-dns-primario')?.value,
        dns_secundario: document.getElementById('new-org-dns-secundario')?.value
    });
    if (res.success) {
        Toast.success('Organizacao criada');
        closeModal('modal-new-org');
        loadDashboard();
        await loadOrganizations();
        if (res.data?.id) selectOrganization(res.data.id);
    } else {
        Toast.error(res.error || 'Erro ao criar');
    }
}
window.createOrganization = createOrganization;

async function updateOrganization(e) {
    e.preventDefault();
    if (!currentOrgId) return;
    const res = await API.put('organization', currentOrgId, {
        name: document.getElementById('edit-org-name').value,
        domain: document.getElementById('edit-org-domain').value,
        description: document.getElementById('edit-org-description').value
    });
    if (res.success) {
        Toast.success('Organizacao atualizada');
        closeModal('modal-edit-org');
        loadDashboard();
        await loadOrganizations();
        selectOrganization(currentOrgId);
    } else {
        Toast.error(res.error || 'Erro ao atualizar');
    }
}
window.updateOrganization = updateOrganization;

async function deleteOrganization(id) {
    if (!confirm('Tem certeza que deseja excluir? Esta acao nao pode ser desfeita.')) return;
    const res = await API.delete('organization', id);
    if (res.success) {
        Toast.success('Organizacao excluida');
        showView('dashboard');
        loadDashboard();
        loadOrganizations();
    } else {
        Toast.error(res.error || 'Erro ao excluir');
    }
}
window.deleteOrganization = deleteOrganization;

// ============ MODALS ============

function openModal(id) {
    const modal = document.getElementById(id);
    if (modal) modal.classList.remove('hidden');
}
window.openModal = openModal;

function closeModal(id) {
    const modal = document.getElementById(id);
    if (modal) modal.classList.add('hidden');
}
window.closeModal = closeModal;

// ============ BUNDLE ACTIONS ============

async function editBundleDesc(bundleId) {
    const newDesc = prompt('Nova descrição do bundle:');
    if (newDesc === null) return;
    const res = await API.put('bundle', bundleId, { id: bundleId, description: newDesc });
    if (res.success) {
        Toast.success('Descrição atualizada');
        if (currentOrgId) loadBundles(currentOrgId);
    } else {
        Toast.error(res.error || 'Erro');
    }
}
window.editBundleDesc = editBundleDesc;

async function deleteBundle(bundleId) {
    if (!confirm('Tem certeza que deseja excluir este bundle?')) return;
    const res = await API.delete('bundle', bundleId);
    if (res.success) {
        Toast.success('Bundle excluído');
        if (currentOrgId) loadBundles(currentOrgId);
    } else {
        Toast.error(res.error || 'Erro');
    }
}
window.deleteBundle = deleteBundle;

// ============ EVENT LISTENERS ============

function setupEventListeners() {
    document.getElementById('btn-logout')?.addEventListener('click', async () => {
        await API.post('logout');
        location.href = '/login.html';
    });

    document.getElementById('btn-new-org')?.addEventListener('click', () => {
        document.getElementById('new-org-form')?.reset();
        openModal('modal-new-org');
    });

    document.getElementById('btn-save-public-theme')?.addEventListener('click', savePublicTheme);
    document.getElementById('btn-save-mirror-config')?.addEventListener('click', saveMirrorConfig);
    document.getElementById('btn-edit-mirror-path')?.addEventListener('click', openMirrorPathModal);
    document.getElementById('btn-confirm-mirror-path')?.addEventListener('click', applyMirrorPath);
    document.getElementById('btn-estimate-mirror')?.addEventListener('click', estimateMirror);
    document.getElementById('btn-mirror-sync-now')?.addEventListener('click', syncMirrorNow);
    document.getElementById('btn-add-mirror-distro')?.addEventListener('click', addMirrorDistro);
    document.getElementById('btn-save-mirror-catalog')?.addEventListener('click', saveMirrorCatalogForm);
    document.querySelectorAll('[data-mirror-catalog-tab]').forEach(tab => {
        tab.addEventListener('click', () => {
            mirrorCatalogTab = tab.dataset.mirrorCatalogTab || 'active';
            document.querySelectorAll('[data-mirror-catalog-tab]').forEach(item => {
                const selected = item === tab;
                item.classList.toggle('btn-primary', selected);
                item.classList.toggle('btn-secondary', !selected);
            });
            renderMirrorDistros(mirrorCatalog);
        });
    });
    document.getElementById('btn-save-vars')?.addEventListener('click', saveVariables);
    document.getElementById('btn-generate-bundle')?.addEventListener('click', generateBundle);

    document.getElementById('btn-new-user')?.addEventListener('click', () => {
        document.getElementById('user-form')?.reset();
        document.getElementById('user-edit-id').value = '';
        document.getElementById('modal-user-title').textContent = 'Novo Usuario';
        openModal('modal-user');
    });

    document.querySelectorAll('.audit-tab').forEach((tab) => {
        tab.addEventListener('click', () => {
            document.querySelectorAll('.audit-tab').forEach((item) => {
                const isActive = item === tab;
                item.classList.toggle('btn-primary', isActive);
                item.classList.toggle('btn-secondary', !isActive);
            });
            auditCurrentTab = tab.dataset.auditTab || 'all';
            auditCurrentPage = 1;
            loadAuditEvents();
        });
    });

    const severitySelect = document.getElementById('audit-severity-filter');
    severitySelect?.addEventListener('change', (event) => {
        auditSeverityFilter = event.target.value || 'all';
        auditCurrentPage = 1;
        loadAuditEvents();
    });

    document.getElementById('var-search')?.addEventListener('input', Utils.debounce(() => {
        renderVariables(allVariables);
    }, 300));

    document.querySelectorAll('.modal-backdrop').forEach(el => {
        el.addEventListener('click', (e) => {
            if (e.target === el) el.closest('.modal')?.classList.add('hidden');
        });
    });

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') document.querySelectorAll('.modal:not(.hidden)').forEach(m => m.classList.add('hidden'));
    });
}

// ============================================================
// GALERIA DE IMAGENS - Buscar no Servidor
// ============================================================

let galleryTargetVarName = null;
let galleryTargetVarId = null;

async function openImageGallery(varName, varId) {
    galleryTargetVarName = varName;
    galleryTargetVarId = varId;

    const fieldLabels = {
        'WALLPAPER_URL': 'Wallpaper Desktop',
        'WALLPAPER_LOGIN_URL': 'Wallpaper Login',
        'GREETER_URL': 'Greeter (Boas-vindas)'
    };

    const titleEl = document.getElementById('gallery-modal-title');
    if (titleEl) titleEl.textContent = 'Selecionar imagem - ' + (fieldLabels[varName] || varName);

    const gridEl = document.getElementById('gallery-grid');
    if (gridEl) gridEl.innerHTML = '<div class="skeleton-gallery-grid"><span class="skeleton-block"></span><span class="skeleton-block"></span><span class="skeleton-block"></span><span class="skeleton-block"></span></div>';

    openModal('modal-image-gallery');

    await loadGalleryImages();
}

async function loadGalleryImages() {
    const gridEl = document.getElementById('gallery-grid');
    if (!gridEl) return;

    gridEl.innerHTML = '<div class="skeleton-gallery-grid"><span class="skeleton-block"></span><span class="skeleton-block"></span><span class="skeleton-block"></span><span class="skeleton-block"></span></div>';

    try {
        const res = await API.get('gallery-images');
        if (!res.success || !res.data.images || !res.data.images.length) {
            gridEl.innerHTML = '<p class="text-slate-400 text-center py-8">Nenhuma imagem encontrada em assets/wallpapers/</p>';
            return;
        }

        gridEl.innerHTML = res.data.images.map(img => `
            <div class="gallery-item" onclick="selectGalleryImage('${Utils.escapeHtml(img.filename)}')">
                <div class="gallery-item-img">
                    <img src="${Utils.escapeHtml(img.thumbnail || img.url)}" alt="${Utils.escapeHtml(img.filename)}" loading="lazy">
                </div>
                <span class="gallery-item-name">${Utils.escapeHtml(img.filename)}</span>
                <button class="gallery-item-delete" onclick="event.stopPropagation(); deleteGalleryImage('${Utils.escapeHtml(img.filename)}')" title="Excluir imagem">
                    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path><line x1="10" y1="11" x2="10" y2="17"></line><line x1="14" y1="11" x2="14" y2="17"></line></svg>
                </button>
            </div>
        `).join('');
    } catch (err) {
        gridEl.innerHTML = '<p class="text-red-400 text-center py-8">Erro ao carregar imagens: ' + Utils.escapeHtml(err.message || 'erro') + '</p>';
    }
}

function selectGalleryImage(filename) {
    if (!galleryTargetVarName || !galleryTargetVarId) return;

    const relativeUrl = `/assets/wallpapers/${filename}`;

    const inputEl = document.querySelector(`input[data-var-id="${galleryTargetVarId}"].asset-card-url`);
    if (inputEl) {
        inputEl.value = relativeUrl;
        inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    }

    updateAssetCardPreview(galleryTargetVarId, relativeUrl);

    const v = allVariables.find(x => String(x.id) === String(galleryTargetVarId));
    if (v) v.current_value = relativeUrl;

    closeModal('modal-image-gallery');
    Toast.success('Imagem selecionada: ' + filename);
}
async function deleteGalleryImage(filename) {
    if (!confirm(`Tem certeza que deseja excluir a imagem '${filename}'? Esta ação é irreversível.`)) return;
    try {
        const res = await API.request('gallery-image', 'DELETE', null, { file: filename });
        if (res.success) {
            Toast.success('Imagem excluída: ' + filename);
            await loadGalleryImages();
        } else {
            Toast.error(res.error || 'Erro ao excluir imagem');
        }
    } catch (err) {
        Toast.error(err.message || 'Erro ao excluir imagem');
    }
}

window.openImageGallery = openImageGallery;
window.loadGalleryImages = loadGalleryImages;
window.selectGalleryImage = selectGalleryImage;
window.deleteGalleryImage = deleteGalleryImage;

// ============ OM PROXIES ============

async function loadOmProxies(orgId) {
    if (!orgId) orgId = currentOrgId;
    try {
        const res = await API.get('om-proxies', { organization_id: orgId });
        if (!res.success) { Toast.error(res.error || 'Erro ao carregar proxies'); return; }
        const proxies = res.data || [];
        const el = document.getElementById('om-proxies-list');
        if (!el) return;
        if (!proxies.length) {
            el.innerHTML = '<p class="text-slate-500 text-sm py-4">Nenhum proxy cadastrado para esta OM.</p>';
            return;
        }
        el.innerHTML = proxies.map(p => `
            <div class="p-4 bg-slate-900 rounded-lg border border-slate-700 flex justify-between items-center">
                <div>
                    <span class="font-medium text-white">${Utils.escapeHtml(p.name)}</span>
                    ${p.is_default ? '<span class="badge badge-success ml-2">Padrão</span>' : ''}
                    <span class="text-slate-500 text-sm ml-2">${Utils.escapeHtml(p.url || '')}</span>
                    ${p.username ? '<span class="text-slate-600 text-xs ml-2">user: ' + Utils.escapeHtml(p.username) + '</span>' : ''}
                    ${p.pac_url ? '<span class="text-slate-600 text-xs ml-2">PAC: ' + Utils.escapeHtml(p.pac_url) + '</span>' : ''}
                </div>
                <div class="flex gap-2">
                    <button class="btn btn-secondary btn-sm" onclick="editOmProxy(${p.id})">Editar</button>
                    <button class="btn btn-danger btn-sm" onclick="deleteOmProxy(${p.id})">Excluir</button>
                </div>
            </div>
        `).join('');
    } catch (e) {
        Toast.error('Erro ao carregar proxies: ' + e.message);
    }
}
window.loadOmProxies = loadOmProxies;

function openOmProxyModal(proxyId = null) {
    const modal = document.getElementById('modal-om-proxy');
    const form = document.getElementById('om-proxy-form');
    if (form) form.reset();
    document.getElementById('om-proxy-id').value = proxyId || '';
    document.getElementById('om-proxy-title').textContent = proxyId ? 'Editar Proxy' : 'Novo Proxy';
    if (modal) modal.classList.remove('hidden');
}
window.openOmProxyModal = openOmProxyModal;

async function saveOmProxy() {
    const id = document.getElementById('om-proxy-id').value;
    const name = document.getElementById('om-proxy-name').value.trim();
    const url = document.getElementById('om-proxy-url').value.trim();
    const username = document.getElementById('om-proxy-username').value.trim();
    const password = document.getElementById('om-proxy-password').value;
    const pacUrl = document.getElementById('om-proxy-pac-url').value.trim();
    const noProxy = document.getElementById('om-proxy-no-proxy').value.trim();
    const isDefault = document.getElementById('om-proxy-default').checked;

    if (!name) { Toast.error('Nome do proxy é obrigatório'); return; }

    const payload = { organization_id: currentOrgId, name, url, username, pac_url: pacUrl, no_proxy: noProxy, is_default: isDefault };
    if (password) payload.password = password;

    try {
        const res = id
            ? await API.request('om-proxy', 'PUT', payload, { id })
            : await API.post('om-proxies', payload);
        if (res.success) {
            Toast.success(id ? 'Proxy atualizado' : 'Proxy criado');
            document.getElementById('modal-om-proxy')?.classList.add('hidden');
            loadOmProxies(currentOrgId);
        } else {
            Toast.error(res.error || 'Erro ao salvar proxy');
        }
    } catch (e) {
        Toast.error('Erro: ' + e.message);
    }
}
window.saveOmProxy = saveOmProxy;

async function editOmProxy(id) {
    try {
        const res = await API.get('om-proxies', { organization_id: currentOrgId });
        if (!res.success) return;
        const proxy = (res.data || []).find(p => p.id === id);
        if (!proxy) { Toast.error('Proxy não encontrado'); return; }
        document.getElementById('om-proxy-id').value = proxy.id;
        document.getElementById('om-proxy-name').value = proxy.name || '';
        document.getElementById('om-proxy-url').value = proxy.url || '';
        document.getElementById('om-proxy-username').value = proxy.username || '';
        document.getElementById('om-proxy-password').value = '';
        document.getElementById('om-proxy-pac-url').value = proxy.pac_url || '';
        document.getElementById('om-proxy-no-proxy').value = proxy.no_proxy || '';
        document.getElementById('om-proxy-default').checked = !!proxy.is_default;
        document.getElementById('om-proxy-title').textContent = 'Editar Proxy';
        document.getElementById('modal-om-proxy')?.classList.remove('hidden');
    } catch (e) {
        Toast.error('Erro ao carregar proxy: ' + e.message);
    }
}
window.editOmProxy = editOmProxy;

async function deleteOmProxy(id) {
    if (!confirm('Tem certeza que deseja excluir este proxy?')) return;
    try {
        const res = await API.request('om-proxy', 'DELETE', null, { id });
        if (res.success) {
            Toast.success('Proxy excluído');
            loadOmProxies(currentOrgId);
        } else {
            Toast.error(res.error || 'Erro ao excluir proxy');
        }
    } catch (e) {
        Toast.error('Erro: ' + e.message);
    }
}
window.deleteOmProxy = deleteOmProxy;

