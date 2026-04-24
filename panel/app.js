const API = '/api';
let password = localStorage.getItem('h2_panel_pass') || '';

// Проверка авторизации
async function checkAuth() {
    if (!password) return false;
    try {
        const res = await fetch(`${API}/config`, { headers: { password } });
        return res.ok;
    } catch { return false; }
}

// Вход
async function login() {
    password = document.getElementById('panel-pass').value;
    if (await checkAuth()) {
        localStorage.setItem('h2_panel_pass', password);
        document.getElementById('auth-section').style.display = 'none';
        document.getElementById('user-section').style.display = 'flex';
        document.getElementById('app').style.display = 'block';
        loadUsers();
    } else {
        alert('❌ Неверный пароль');
        password = '';
    }
}

// Выход
function logout() {
    localStorage.removeItem('h2_panel_pass');
    password = '';
    location.reload();
}

// Загрузка пользователей
async function loadUsers() {
    const tbody = document.getElementById('users-body');
    tbody.innerHTML = '<tr><td colspan="6">Загрузка...</td></tr>';
    
    try {
        const res = await fetch(`${API}/users`, { headers: { password } });
        if (!res.ok) throw new Error();
        const users = await res.json();
        
        if (users.length === 0) {
            tbody.innerHTML = '<tr><td colspan="6">Нет пользователей</td></tr>';
            return;
        }
        
        tbody.innerHTML = users.map(u => `
            <tr>
                <td><strong>${escapeHtml(u.name)}</strong></td>
                <td><code>${u.uuid}</code></td>
                <td>${u.expires ? new Date(u.expires).toLocaleDateString() : '∞'}</td>
                <td>${u.limit ? u.limit + ' GB' : '-'}</td>
                <td class="link-cell">
                    <code title="${u.link}">${u.link}</code>
                    <button class="small" onclick="copyLink('${escapeJs(u.link)}')">📋</button>
                </td>
                <td class="actions">
                    <button class="small danger" onclick="deleteUser('${u.id}')">❌</button>
                </td>
            </tr>
        `).join('');
    } catch {
        tbody.innerHTML = '<tr><td colspan="6">❌ Ошибка загрузки</td></tr>';
    }
}

// Добавление пользователя
document.getElementById('add-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const data = {
        name: document.getElementById('name').value,
        uuid: document.getElementById('uuid').value,
        expires: document.getElementById('expires').value || null,
        limit: document.getElementById('limit').value || null
    };
    
    const res = await fetch(`${API}/users`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', password },
        body: JSON.stringify(data)
    });
    
    if (res.ok) {
        e.target.reset();
        loadUsers();
    } else {
        const err = await res.json().catch(() => ({}));
        alert('❌ ' + (err.error || 'Ошибка'));
    }
});

// Удаление пользователя
async function deleteUser(id) {
    if (!confirm('Удалить пользователя?')) return;
    const res = await fetch(`${API}/users/${id}`, {
        method: 'DELETE',
        headers: { password }
    });
    if (res.ok) loadUsers();
    else alert('❌ Ошибка удаления');
}

// Копирование ссылки
function copyLink(text) {
    navigator.clipboard.writeText(text).then(() => {
        const btn = event.target;
        const orig = btn.textContent;
        btn.textContent = '✅';
        setTimeout(() => btn.textContent = orig, 1000);
    });
}

// Утилиты
function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}
function escapeJs(str) {
    return str.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\n/g, '\\n');
}

// Инициализация
(async () => {
    if (await checkAuth()) {
        document.getElementById('auth-section').style.display = 'none';
        document.getElementById('user-section').style.display = 'flex';
        document.getElementById('app').style.display = 'block';
        loadUsers();
    }
})();