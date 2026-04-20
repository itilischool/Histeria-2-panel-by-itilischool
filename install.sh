#!/bin/bash
#===============================================================================
# VPN/PANEL MANAGER - Fixed Version
#===============================================================================

exec > >(tee -a /tmp/vpn-install.log) 2>&1
echo "=== Installation started at $(date) ==="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/vpn-panel"
CONFIG_DIR="${INSTALL_DIR}/configs"
DATA_DIR="${INSTALL_DIR}/data"
LOGS_DIR="${INSTALL_DIR}/logs"
WWW_DIR="${INSTALL_DIR}/www/mask"
BACKEND_DIR="${INSTALL_DIR}/backend"
FRONTEND_DIR="${INSTALL_DIR}/frontend"

PANEL_DOMAIN=""
MASK_DOMAIN=""
SSL_EMAIL=""
PANEL_PORT="8080"
ENABLE_BBR="no"
ADMIN_USER="admin"
ADMIN_PASS=""
HYSTERIA_PASS=""
NAIVE_USER="user"
NAIVE_PASS=""

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

die() {
    log_error "$1"
    exit 1
}

# ИСПРАВЛЕНО: генерация пароля без спецсимволов которые ломают URI
generate_password() {
    local length=${1:-32}
    < /dev/urandom tr -dc 'A-Za-z0-9' | head -c "$length"
}

# ИСПРАВЛЕНО: очистка ввода от лишних символов
clean_input() {
    echo "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Запустите от root"
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        log_info "ОС: $PRETTY_NAME"
    else
        die "Не удалось определить ОС"
    fi
}

collect_input() {
    echo -e "\n${GREEN}=== Настройка VPN ===${NC}\n"
    
    # ИСПРАВЛЕНО: правильная очистка ввода
    read -rp "Домен панели (panel.example.com): " PANEL_DOMAIN
    PANEL_DOMAIN=$(clean_input "$PANEL_DOMAIN" | tr '[:upper:]' '[:lower:]')
    
    read -rp "Домен маскировки (example.com): " MASK_DOMAIN
    MASK_DOMAIN=$(clean_input "$MASK_DOMAIN" | tr '[:upper:]' '[:lower:]')
    
    read -rp "Email для SSL: " SSL_EMAIL
    SSL_EMAIL=$(clean_input "$SSL_EMAIL")
    
    read -rp "Порт панели [8080]: " input_port
    if [[ -n "$input_port" ]]; then
        PANEL_PORT="$input_port"
    fi
    
    read -rp "Включить BBR? [y/N]: " bbr_input
    [[ "$bbr_input" =~ ^[Yy]$ ]] && ENABLE_BBR="yes"
    
    # Генерация паролей
    ADMIN_PASS=$(generate_password 24)
    HYSTERIA_PASS=$(generate_password 32)
    NAIVE_PASS=$(generate_password 32)
    
    echo -e "\n${GREEN}=== Учетные данные ===${NC}"
    echo "Админ: ${ADMIN_USER} / ${ADMIN_PASS}"
    echo "Hysteria: ${HYSTERIA_PASS}"
    echo "NaiveProxy: ${NAIVE_USER} / ${NAIVE_PASS}"
    echo ""
    
    read -rp "Продолжить? [Y/n]: " confirm
    
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Отменено"
        exit 0
    fi
    
    log_info "Начинаю установку..."
}

prepare_system() {
    log_info "Обновление системы..."
    apt-get update -qq
    apt-get upgrade -y -qq
    
    log_info "Установка зависимостей..."
    apt-get install -y -qq \
        curl wget git unzip socat cron jq \
        python3 python3-pip python3-venv \
        ca-certificates gnupg
    
    log_success "Система готова"
}

enable_bbr() {
    [[ "$ENABLE_BBR" != "yes" ]] && return 0
    
    log_info "Включение BBR..."
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    log_success "BBR включен"
}

install_caddy() {
    log_info "Установка Caddy..."
    
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list
    
    apt-get update -qq
    apt-get install -y -qq caddy
    
    systemctl stop caddy 2>/dev/null || true
    log_success "Caddy установлен"
}

install_hysteria() {
    log_info "Установка Hysteria 2..."
    
    local latest_ver
    latest_ver=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | \
        jq -r '.tag_name' | sed 's/^v//')
    
    local arch="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    
    curl -fsSL "https://github.com/apernet/hysteria/releases/download/v${latest_ver}/hysteria-linux-${arch}" \
        -o /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria
    
    mkdir -p "${CONFIG_DIR}"
    # ИСПРАВЛЕНО: правильные пути к SSL
    cat > "${CONFIG_DIR}/hysteria.json" << EOF
{
    "listen": ":443",
    "tls": {
        "cert": "/etc/ssl/certs/${MASK_DOMAIN}.crt",
        "key": "/etc/ssl/private/${MASK_DOMAIN}.key"
    },
    "auth": {
        "type": "password",
        "password": "${HYSTERIA_PASS}"
    },
    "masquerade": {
        "type": "proxy",
        "proxy": {
            "url": "https://${MASK_DOMAIN}",
            "rewriteHost": true
        }
    },
    "bandwidth": {
        "up": "100 mbps",
        "down": "500 mbps"
    },
    "speedTest": true
}
EOF
    
    log_success "Hysteria 2 установлен"
}

setup_mask_site() {
    log_info "Настройка сайта..."
    mkdir -p "${WWW_DIR}"
    
    cat > "${WWW_DIR}/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Welcome</title>
    <style>
        body{font-family:sans-serif;text-align:center;padding:50px;background:#f5f5f5;margin:0}
        h1{color:#333}p{color:#666}
    </style>
</head>
<body>
    <h1>Welcome</h1>
    <p>Professional hosting services</p>
</body>
</html>
EOF
    log_success "Сайт создан"
}

create_backend() {
    log_info "Создание backend..."
    mkdir -p "${BACKEND_DIR}"
    
    cat > "${BACKEND_DIR}/requirements.txt" << 'EOF'
fastapi==0.109.2
uvicorn[standard]==0.27.1
pydantic==2.5.3
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-multipart==0.0.6
sqlalchemy==2.0.25
EOF

    cat > "${BACKEND_DIR}/database.py" << 'EOF'
import sqlite3
from pathlib import Path
from contextlib import contextmanager

DB_PATH = Path("/opt/vpn-panel/data/database.db")
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

@contextmanager
def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()

def init_db():
    with get_db() as conn:
        c = conn.cursor()
        c.execute('''CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            hysteria_password TEXT NOT NULL,
            naive_password TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            is_active INTEGER DEFAULT 1
        )''')
        c.execute('''CREATE TABLE IF NOT EXISTS admins (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )''')
        c.execute('''CREATE TABLE IF NOT EXISTS logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            level TEXT NOT NULL,
            message TEXT NOT NULL,
            timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )''')
        conn.commit()
        
        c.execute('SELECT COUNT(*) FROM admins')
        if c.fetchone()[0] == 0:
            from passlib.context import CryptContext
            pwd = CryptContext(schemes=["bcrypt"])
            hashed = pwd.hash("admin123")
            c.execute('INSERT INTO admins (username, password_hash) VALUES (?, ?)',
                     ("admin", hashed))
            conn.commit()

def log_event(level, message):
    with get_db() as conn:
        conn.execute('INSERT INTO logs (level, message) VALUES (?, ?)', (level, message))
        conn.commit()
EOF

    cat > "${BACKEND_DIR}/auth.py" << 'EOF'
from datetime import datetime, timedelta
from typing import Optional
from jose import JWTError, jwt
from passlib.context import CryptContext
from fastapi import Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pathlib import Path
import secrets

SECRET_FILE = Path("/opt/vpn-panel/data/.secret")
if not SECRET_FILE.exists():
    SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
    SECRET_FILE.write_text(secrets.token_urlsafe(32))
    SECRET_FILE.chmod(0o600)

SECRET_KEY = SECRET_FILE.read_text().strip()
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 1440

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
security = HTTPBearer(auto_error=False)

def verify_password(plain, hashed):
    return pwd_context.verify(plain, hashed)

def get_password_hash(password):
    return pwd_context.hash(password)

def create_access_token(data: dict, expires_delta: Optional[timedelta] = None):
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta or timedelta(minutes=15))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def decode_token(token: str) -> Optional[dict]:
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None

async def get_current_admin(credentials: Optional[HTTPAuthorizationCredentials] = Depends(security)):
    if not credentials:
        raise HTTPException(status_code=401, detail="Auth required",
                          headers={"WWW-Authenticate": "Bearer"})
    payload = decode_token(credentials.credentials)
    if not payload or payload.get("type") != "admin":
        raise HTTPException(status_code=401, detail="Invalid auth",
                          headers={"WWW-Authenticate": "Bearer"})
    return payload

def get_admin_from_db(username: str) -> Optional[dict]:
    from database import get_db
    with get_db() as conn:
        cursor = conn.execute(
            'SELECT id, username, password_hash FROM admins WHERE username = ?',
            (username,))
        row = cursor.fetchone()
        if row:
            return {"id": row["id"], "username": row["username"], 
                   "password_hash": row["password_hash"]}
    return None
EOF

    cat > "${BACKEND_DIR}/main.py" << 'EOF'
#!/usr/bin/env python3
import logging, sys, json, secrets, string
from pathlib import Path
from datetime import datetime, timedelta
from contextlib import asynccontextmanager
from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse
from database import init_db, get_db, log_event
from auth import (get_password_hash, verify_password, create_access_token,
                  get_current_admin, get_admin_from_db, ACCESS_TOKEN_EXPIRE_MINUTES)

LOG_FILE = Path("/opt/vpn-panel/logs/panel.log")
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

logging.basicConfig(level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)])

init_db()

@asynccontextmanager
async def lifespan(app: FastAPI):
    yield

app = FastAPI(title="VPN Panel", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True,
                   allow_methods=["*"], allow_headers=["*"])

def generate_password(length=32):
    chars = string.ascii_letters + string.digits
    return ''.join(secrets.choice(chars) for _ in range(length))

def get_server_config():
    config_file = Path("/opt/vpn-panel/data/server_config.json")
    if config_file.exists():
        return json.loads(config_file.read_text())
    return {}

@app.post("/api/auth/login")
async def login(credentials: dict):
    username = credentials.get("username")
    password = credentials.get("password")
    admin = get_admin_from_db(username)
    if not admin or not verify_password(password, admin["password_hash"]):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    access_token = create_access_token(data={"sub": admin["username"], "type": "admin"},
                                       expires_delta=timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    return {"access_token": access_token, "token_type": "bearer"}

@app.get("/api/auth/me")
async def get_me(current_admin: dict = Depends(get_current_admin)):
    return {"username": current_admin["username"], "type": "admin"}

@app.post("/api/users")
async def create_user(user_in: dict, current_admin: dict = Depends(get_current_admin)):
    username = user_in.get("username")
    password = user_in.get("password") or generate_password(24)
    hysteria_pass = generate_password(32)
    naive_pass = generate_password(32)
    
    with get_db() as conn:
        try:
            cursor = conn.execute(
                '''INSERT INTO users (username, password_hash, hysteria_password, naive_password)
                   VALUES (?, ?, ?, ?)''',
                (username, get_password_hash(password), hysteria_pass, naive_pass))
            conn.commit()
            user_id = cursor.lastrowid
        except:
            raise HTTPException(status_code=400, detail="User exists")
    
    domain = get_server_config().get("mask_domain", "example.com")
    return {"id": user_id, "username": username,
            "hysteria_uri": f"hy2://{hysteria_pass}@{domain}:443?sni={domain}",
            "naive_uri": f"https://{username}:{naive_pass}@{domain}:443",
            "created_at": datetime.now().isoformat(), "is_active": True}

@app.get("/api/users")
async def list_users(current_admin: dict = Depends(get_current_admin)):
    with get_db() as conn:
        cursor = conn.execute(
            'SELECT id, username, hysteria_password, naive_password, created_at, is_active FROM users')
        rows = cursor.fetchall()
    domain = get_server_config().get("mask_domain", "example.com")
    return [{"id": r["id"], "username": r["username"],
             "hysteria_uri": f"hy2://{r['hysteria_password']}@{domain}:443?sni={domain}",
             "naive_uri": f"https://{r['username']}:{r['naive_password']}@{domain}:443",
             "created_at": r["created_at"], "is_active": bool(r["is_active"])} for r in rows]

@app.delete("/api/users/{user_id}")
async def delete_user(user_id: int, current_admin: dict = Depends(get_current_admin)):
    with get_db() as conn:
        conn.execute('DELETE FROM users WHERE id = ?', (user_id,))
        conn.commit()
    return {"status": "ok"}

@app.get("/api/config/generate/{user_id}")
async def generate_config(user_id: int, config_type: str, 
                         current_admin: dict = Depends(get_current_admin)):
    with get_db() as conn:
        cursor = conn.execute(
            'SELECT username, hysteria_password, naive_password FROM users WHERE id = ?', (user_id,))
        user = cursor.fetchone()
    if not user:
        raise HTTPException(status_code=404, detail="Not found")
    domain = get_server_config().get("mask_domain", "example.com")
    if config_type == "hysteria":
        config = f"hy2://{user['hysteria_password']}@{domain}:443?sni={domain}"
    else:
        config = f"https://{user['username']}:{user['naive_password']}@{domain}:443"
    return JSONResponse(content=config, media_type="text/plain")

@app.get("/api/system/status")
async def system_status(current_admin: dict = Depends(get_current_admin)):
    import subprocess
    def get_status(name):
        try:
            result = subprocess.run(["systemctl", "is-active", name],
                                  capture_output=True, text=True, timeout=5)
            return result.stdout.strip()
        except:
            return "unknown"
    return {"services": {"hysteria": get_status("hysteria"), "caddy": get_status("caddy"),
            "panel": get_status("panel")}}

@app.get("/")
async def serve_frontend():
    return FileResponse("/opt/vpn-panel/frontend/index.html")

@app.get("/login")
async def serve_login():
    return FileResponse("/opt/vpn-panel/frontend/login.html")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8080)
EOF

    cd "${BACKEND_DIR}"
    python3 -m venv venv
    source venv/bin/activate
    pip install -q -r requirements.txt
    log_success "Backend создан"
}

create_frontend() {
    log_info "Создание frontend..."
    mkdir -p "${FRONTEND_DIR}"
    
    cat > "${FRONTEND_DIR}/style.css" << 'EOF'
:root{--primary:#2563eb;--bg:#f8fafc;--card:#fff;--text:#1e293b;--border:#e2e8f0}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--text)}
.container{max-width:1200px;margin:0 auto;padding:1rem}
.header{background:var(--card);border-bottom:1px solid var(--border);padding:1rem 0;margin-bottom:1rem}
.header-content{display:flex;justify-content:space-between;align-items:center}
.logo{font-size:1.25rem;font-weight:700;color:var(--primary)}
.btn{padding:0.5rem 1rem;background:var(--primary);color:#fff;border:none;border-radius:6px;cursor:pointer;text-decoration:none;display:inline-block}
.btn:hover{opacity:0.9}.btn-sm{padding:0.375rem 0.75rem;font-size:0.875rem}
.btn-danger{background:#ef4444}.btn-outline{background:transparent;border:1px solid var(--border);color:var(--text)}
.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:1.25rem;margin-bottom:1rem}
.card-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem}
.card-title{font-weight:600}.form-group{margin-bottom:1rem}
.form-group label{display:block;margin-bottom:0.375rem;font-weight:500}
.form-control{width:100%;padding:0.5rem;border:1px solid var(--border);border-radius:6px}
.table{width:100%;border-collapse:collapse}.table th,.table td{padding:0.75rem;text-align:left;border-bottom:1px solid var(--border)}
.table th{font-weight:600;font-size:0.875rem;color:#64748b}
.alert{padding:0.75rem;border-radius:6px;margin-bottom:1rem}
.alert-success{background:#dcfce7;color:#166534}.alert-error{background:#fee2e2;color:#991b1b}
.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);align-items:center;justify-content:center;z-index:1000}
.modal.active{display:flex}.modal-content{background:var(--card);border-radius:8px;padding:1.5rem;max-width:500px;width:90%}
.modal-header{display:flex;justify-content:space-between;margin-bottom:1rem}
.modal-close{background:none;border:none;font-size:1.5rem;cursor:pointer}
.config-box{background:#f1f5f9;padding:0.75rem;border-radius:6px;font-family:monospace;font-size:0.875rem;word-break:break-all;margin:0.5rem 0}
.flex{display:flex;gap:0.5rem;align-items:center}.hidden{display:none}
.status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:0.375rem}
.status-dot.online{background:#22c55e}.status-dot.offline{background:#ef4444}
EOF

    cat > "${FRONTEND_DIR}/login.html" << 'EOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Login</title>
<link rel="stylesheet" href="/static/style.css">
<style>body{display:flex;align-items:center;justify-content:center;min-height:100vh}</style>
</head><body>
<div class="card" style="max-width:400px;width:100%">
<h1 class="card-title" style="text-align:center;margin-bottom:1.5rem">🔐 VPN Panel</h1>
<form id="loginForm"><div class="form-group"><label>Логин</label>
<input type="text" id="username" class="form-control" required></div>
<div class="form-group"><label>Пароль</label>
<input type="password" id="password" class="form-control" required></div>
<div id="error" class="alert alert-error hidden"></div>
<button type="submit" class="btn" style="width:100%">Войти</button></form></div>
<script>
document.getElementById('loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();const error=document.getElementById('error');
    try{const res=await fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({username:document.getElementById('username').value,password:document.getElementById('password').value})});
    const data=await res.json();if(!res.ok)throw new Error(data.detail);
    localStorage.setItem('token',data.access_token);window.location.href='/';}
    catch(err){error.textContent=err.message;error.classList.remove('hidden');}});
</script></body></html>
EOF

    cat > "${FRONTEND_DIR}/index.html" << 'EOF'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>VPN Panel</title>
<link rel="stylesheet" href="/static/style.css"></head><body>
<header class="header"><div class="container header-content">
<div class="logo">🚀 VPN Panel</div><div class="flex">
<span id="username"></span><button class="btn btn-outline btn-sm" onclick="logout()">Выйти</button>
</div></div></header><main class="container">
<div id="alert" class="alert hidden"></div>
<div class="card"><div class="card-header"><span class="card-title">📊 Статус</span>
<button class="btn btn-outline btn-sm" onclick="refreshStatus()">Обновить</button></div>
<div class="flex" style="gap:1.5rem"><div><span class="status-dot" id="status-hysteria"></span>Hysteria: <span id="text-hysteria">...</span></div>
<div><span class="status-dot" id="status-caddy"></span>Caddy: <span id="text-caddy">...</span></div></div></div>
<div class="card"><div class="card-header"><span class="card-title">👥 Пользователи</span>
<button class="btn btn-sm" onclick="openModal('userModal')">+ Добавить</button></div>
<table class="table"><thead><tr><th>ID</th><th>Имя</th><th>Hysteria</th><th>Naive</th><th>Действия</th></tr></thead>
<tbody id="usersTable"></tbody></table></div></main>
<div id="userModal" class="modal"><div class="modal-content">
<div class="modal-header"><h3>Новый пользователь</h3>
<button class="modal-close" onclick="closeModal('userModal')">&times;</button></div>
<form id="userForm"><div class="form-group"><label>Имя</label>
<input type="text" id="newUsername" class="form-control" required></div>
<div class="form-group"><label>Пароль (опционально)</label>
<input type="text" id="newPassword" class="form-control"></div>
<button type="submit" class="btn">Создать</button></form></div></div>
<div id="configModal" class="modal"><div class="modal-content">
<div class="modal-header"><h3>Конфигурация</h3>
<button class="modal-close" onclick="closeModal('configModal')">&times;</button></div>
<div id="configHysteria" class="config-box"></div><div id="configNaive" class="config-box"></div>
<div class="flex" style="margin-top:1rem"><button class="btn btn-sm btn-outline" onclick="copyConfig('hysteria')">Копировать Hysteria</button>
<button class="btn btn-sm btn-outline" onclick="copyConfig('naive')">Копировать Naive</button></div></div></div>
<script>
const token=localStorage.getItem('token');if(!token)window.location.href='/login';
const headers={'Authorization':`Bearer ${token}`};let currentUserId=null;
(async ()=>{try{const res=await fetch('/api/auth/me',{headers});if(!res.ok)throw new Error();
const data=await res.json();document.getElementById('username').textContent=data.username;
loadUsers();refreshStatus();}catch{localStorage.removeItem('token');window.location.href='/login';}})();
function logout(){localStorage.removeItem('token');window.location.href='/login';}
function showAlert(msg,type='success'){const alert=document.getElementById('alert');
alert.className=`alert alert-${type}`;alert.textContent=msg;alert.classList.remove('hidden');
setTimeout(()=>alert.classList.add('hidden'),3000);}
async function loadUsers(){try{const res=await fetch('/api/users',{headers});const users=await res.json();
document.getElementById('usersTable').innerHTML=users.map(u=>`<tr><td>${u.id}</td><td>${u.username}</td>
<td><small>${u.hysteria_uri.substring(0,30)}...</small></td><td><small>${u.naive_uri.substring(0,30)}...</small></td>
<td><button class="btn btn-sm btn-outline" onclick="showConfig(${u.id})">🔑</button>
<button class="btn btn-sm btn-danger" onclick="deleteUser(${u.id})">🗑️</button></td></tr>`).join('');}
catch(err){showAlert(err.message,'error');}}
document.getElementById('userForm').addEventListener('submit',async(e)=>{e.preventDefault();
try{const res=await fetch('/api/users',{method:'POST',headers:{...headers,'Content-Type':'application/json'},
body:JSON.stringify({username:document.getElementById('newUsername').value,password:document.getElementById('newPassword').value||undefined})});
if(!res.ok)throw new Error('Ошибка');closeModal('userModal');e.target.reset();showAlert('Создан');loadUsers();}
catch(err){showAlert(err.message,'error');}});
async function deleteUser(id){if(!confirm('Удалить?'))return;
try{await fetch(`/api/users/${id}`,{method:'DELETE',headers});showAlert('Удален');loadUsers();}
catch(err){showAlert(err.message,'error');}}
async function showConfig(id){currentUserId=id;
try{const[h,n]=await Promise.all([fetch(`/api/config/generate/${id}?config_type=hysteria`,{headers}),
fetch(`/api/config/generate/${id}?config_type=naive`,{headers})]);
document.getElementById('configHysteria').textContent=await h.text();
document.getElementById('configNaive').textContent=await n.text();openModal('configModal');}
catch(err){showAlert(err.message,'error');}}
function copyConfig(type){const text=document.getElementById(`config${type==='hysteria'?'Hysteria':'Naive'}`).textContent;
navigator.clipboard.writeText(text).then(()=>showAlert('Скопировано'));}
async function refreshStatus(){try{const res=await fetch('/api/system/status',{headers});const data=await res.json();
['hysteria','caddy'].forEach(svc=>{const status=data.services[svc];
document.getElementById(`status-${svc}`).className=`status-dot ${status==='active'?'online':'offline'}`;
document.getElementById(`text-${svc}`).textContent=status;});}catch{}}
function openModal(id){document.getElementById(id).classList.add('active');}
function closeModal(id){document.getElementById(id).classList.remove('active');}
window.onclick=(e)=>{if(e.target.classList.contains('modal'))e.target.classList.remove('active');};
</script></body></html>
EOF

    log_success "Frontend создан"
}

create_systemd_services() {
    log_info "Настройка systemd..."
    
    cat > /etc/systemd/system/hysteria.service << 'EOF'
[Unit]
Description=Hysteria 2 Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /opt/vpn-panel/configs/hysteria.json
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/panel.service << EOF
[Unit]
Description=VPN Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/vpn-panel/backend
ExecStart=/opt/vpn-panel/backend/venv/bin/uvicorn main:app --host 127.0.0.1 --port ${PANEL_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable hysteria panel 2>/dev/null || true
    log_success "Systemd настроен"
}

# ИСПРАВЛЕНО: правильная настройка Caddy с SSL
configure_caddy() {
    log_info "Настройка Caddy..."
    
    cat > /etc/caddy/Caddyfile << EOF
${PANEL_DOMAIN} {
    tls ${SSL_EMAIL}
    reverse_proxy 127.0.0.1:${PANEL_PORT}
}

${MASK_DOMAIN} {
    tls ${SSL_EMAIL}
    handle {
        forward_proxy {
            basic_auth ${NAIVE_USER} ${NAIVE_PASS}
            hide_ip
            hide_via
        }
    }
    root * ${WWW_DIR}
    file_server
}
EOF

    # Копируем SSL сертификаты для Hysteria
    mkdir -p /etc/ssl/certs /etc/ssl/private
    
    # Запускаем Caddy для получения SSL
    systemctl enable --now caddy
    sleep 5
    
    # Ждем пока Caddy получит сертификаты
    log_info "Ожидание выпуска SSL сертификатов..."
    sleep 10
    
    # Копируем сертификаты из Caddy
    if [[ -f /etc/caddy/certs/${MASK_DOMAIN}/fullchain.pem ]]; then
        cp /etc/caddy/certs/${MASK_DOMAIN}/fullchain.pem /etc/ssl/certs/${MASK_DOMAIN}.crt
        cp /etc/caddy/certs/${MASK_DOMAIN}/key.pem /etc/ssl/private/${MASK_DOMAIN}.key
        chmod 600 /etc/ssl/private/${MASK_DOMAIN}.key
    fi
    
    log_success "Caddy настроен"
}

save_config() {
    log_info "Сохранение конфигурации..."
    mkdir -p "${DATA_DIR}"
    
    cat > "${DATA_DIR}/server_config.json" << EOF
{
    "panel_domain": "${PANEL_DOMAIN}",
    "mask_domain": "${MASK_DOMAIN}",
    "panel_port": ${PANEL_PORT},
    "admin_user": "${ADMIN_USER}",
    "hysteria_password": "${HYSTERIA_PASS}",
    "naive_user": "${NAIVE_USER}",
    "naive_password": "${NAIVE_PASS}"
}
EOF
    chmod 600 "${DATA_DIR}/server_config.json"
    
    python3 << PYEOF
import sys
sys.path.insert(0, '${BACKEND_DIR}')
from auth import get_password_hash
from database import get_db

with get_db() as conn:
    conn.execute(
        "UPDATE admins SET password_hash = ? WHERE username = ?",
        (get_password_hash('${ADMIN_PASS}'), '${ADMIN_USER}')
    )
    conn.commit()
PYEOF
    
    log_success "Конфигурация сохранена"
}

# ИСПРАВЛЕНО: правильный вывод без \n
print_final() {
    clear
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ✅ УСТАНОВКА ЗАВЕРШЕНА${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BLUE}Панель:${NC}"
    printf "  URL: https://%s\n" "${PANEL_DOMAIN}"
    printf "  Логин: %s\n" "${ADMIN_USER}"
    printf "  Пароль: %s\n" "${ADMIN_PASS}"
    echo ""
    
    echo -e "${BLUE}Hysteria2:${NC}"
    printf "  hy2://%s@%s:443?sni=%s\n" "${HYSTERIA_PASS}" "${MASK_DOMAIN}" "${MASK_DOMAIN}"
    echo ""
    
    echo -e "${BLUE}NaiveProxy:${NC}"
    printf "  https://%s:%s@%s:443\n" "${NAIVE_USER}" "${NAIVE_PASS}" "${MASK_DOMAIN}"
    echo ""
    
    echo -e "${YELLOW}СОХРАНИТЕ ЭТИ ДАННЫЕ!${NC}"
    echo ""
    echo "Лог: /tmp/vpn-install.log"
    echo ""
    echo "Проверка сервисов:"
    echo "  systemctl status caddy"
    echo "  systemctl status panel"
    echo "  systemctl status hysteria"
}

main() {
    echo -e "${GREEN}🚀 VPN Panel Installer${NC}"
    echo ""
    
    check_root
    check_os
    collect_input
    
    prepare_system
    enable_bbr
    install_caddy
    install_hysteria
    setup_mask_site
    create_backend
    create_frontend
    create_systemd_services
    configure_caddy
    save_config
    
    log_info "Запуск сервисов..."
    systemctl restart caddy
    systemctl start panel
    systemctl start hysteria
    
    print_final
}

main "$@"
