const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const app = express();
const config = JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8'));
const USERS_FILE = path.join(__dirname, 'users.json');

app.use(express.json());
app.use(express.static(__dirname));

// Простая аутентификация
const checkAuth = (req, res, next) => {
    const { password } = req.headers;
    if (password === config.panelPass) return next();
    res.status(401).json({ error: 'Unauthorized' });
};

// Чтение/запись пользователей
const readUsers = () => {
    try {
        return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8'));
    } catch {
        return [];
    }
};
const writeUsers = (users) => fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2));

// Генерация ссылки Hysteria2
const generateLink = (user) => {
    const { uuid, name, domain, port, obfsPassword } = config;
    return `hysteria2://${user.uuid}@${domain}:${port}?hiddify=1&obfs=salamander&obfs-password=${obfsPassword}&sni=${domain}&insecure=1&allow_insecure=1#${encodeURIComponent(name)}`;
};

// API: получить всех пользователей
app.get('/api/users', checkAuth, (req, res) => {
    const users = readUsers();
    res.json(users.map(u => ({ ...u, link: generateLink(u) })));
});

// API: добавить пользователя
app.post('/api/users', checkAuth, (req, res) => {
    const { name, uuid, expires, limit } = req.body;
    if (!name || !uuid) return res.status(400).json({ error: 'Name and UUID required' });
    
    const users = readUsers();
    if (users.find(u => u.uuid === uuid)) {
        return res.status(409).json({ error: 'User already exists' });
    }
    
    const newUser = {
        id: crypto.randomUUID(),
        name,
        uuid,
        expires: expires || null,
        limit: limit || null,
        createdAt: new Date().toISOString()
    };
    
    users.push(newUser);
    writeUsers(users);
    res.status(201).json({ ...newUser, link: generateLink(newUser) });
});

// API: удалить пользователя
app.delete('/api/users/:id', checkAuth, (req, res) => {
    const { id } = req.params;
    let users = readUsers();
    const len = users.length;
    users = users.filter(u => u.id !== id);
    if (users.length === len) return res.status(404).json({ error: 'Not found' });
    writeUsers(users);
    res.json({ success: true });
});

// API: конфигурация для фронтенда
app.get('/api/config', (req, res) => {
    res.json({ domain: config.domain, port: config.port });
});

app.listen(config.panelPort, '0.0.0.0', () => {
    console.log(`🔐 Panel running on port ${config.panelPort}`);
});