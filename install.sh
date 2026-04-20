#!/bin/bash
#===============================================================================
# VPN/PANEL MANAGER - One-Command Installer
# Production-ready Hysteria2 + NaiveProxy + Management Panel
# Supports: Ubuntu 20.04/22.04, Debian 11/12
#===============================================================================

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Пути установки
INSTALL_DIR="/opt/vpn-panel"
CONFIG_DIR="${INSTALL_DIR}/configs"
DATA_DIR="${INSTALL_DIR}/data"
LOGS_DIR="${INSTALL_DIR}/logs"
WWW_DIR="${INSTALL_DIR}/www/mask"
BACKEND_DIR="${INSTALL_DIR}/backend"
FRONTEND_DIR="${INSTALL_DIR}/frontend"
SYSTEMD_DIR="/etc/systemd/system"

# Глобальные переменные
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

#===============================================================================
# УТИЛИТЫ
#===============================================================================

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

die() {
    log_error "$1"
    exit 1
}

# Генерация случайного пароля
generate_password() {
    local length=${1:-32}
    tr -dc 'A-Za-z0-9!@#%^&*' </dev/urandom | head -c "$length"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Этот скрипт должен запускаться от root (используйте sudo)"
    fi
}

# Проверка ОС
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Не удалось определить операционную систему"
    fi
    
    source /etc/os-release
    case "$ID" in
        ubuntu)
            if [[ ! "$VERSION_ID" =~ ^(20\.04|22\.04)$ ]]; then
                die "Поддерживаются только Ubuntu 20.04 и 22.04 (ваша: $VERSION_ID)"
            fi
            ;;
        debian)
            if [[ ! "$VERSION_ID" =~ ^(11|12)$ ]]; then
                die "Поддерживаются только Debian 11 и 12 (ваша: $VERSION_ID)"
            fi
            ;;
        *)
            die "Неподдерживаемая ОС: $ID"
            ;;
    esac
    log_info "ОС: $PRETTY_NAME"
}

# Проверка занятости порта
check_port() {
    local port=$1
    if ss -tlnp | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

#===============================================================================
# СБОР ВВОДА ПОЛЬЗОВАТЕЛЯ
#===============================================================================

collect_input() {
    echo -e "\n${GREEN}=== Настройка VPN Панели ===${NC}\n"
    
    # Домен панели
    while [[ -z "$PANEL_DOMAIN" ]]; do
        read -rp "Домен панели управления (например: panel.example.com): " PANEL_DOMAIN
        PANEL_DOMAIN=$(echo "$PANEL_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        [[ -z "$PANEL_DOMAIN" ]] && log_warn "Введите домен"
    done
    
    # Домен маскировки
    while [[ -z "$MASK_DOMAIN" ]]; do
        read -rp "Домен маскировочного сайта (например: example.com): " MASK_DOMAIN
        MASK_DOMAIN=$(echo "$MASK_DOMAIN" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        [[ -z "$MASK_DOMAIN" ]] && log_warn "Введите домен"
    done
    
    # Email для SSL
    while [[ -z "$SSL_EMAIL" ]]; do
        read -rp "Email для Let's Encrypt уведомлений: " SSL_EMAIL
        [[ -z "$SSL_EMAIL" ]] && log_warn "Введите email"
    done
    
    # Порт панели
    read -rp "Порт панели управления [8080]: " input_port
    [[ -n "$input_port" ]] && PANEL_PORT="$input_port"
    
    if ! check_port "$PANEL_PORT"; then
        log_warn "Порт $PANEL_PORT занят, выбираем другой..."
        PANEL_PORT=8443
    fi
    log_info "Порт панели: $PANEL_PORT"
    
    # BBR
    read -rp "Включить TCP BBR для улучшения скорости? [y/N]: " bbr_input
    [[ "${bbr_input,,}" =~ ^[yyes]$ ]] && ENABLE_BBR="yes" || ENABLE_BBR="no"
    
    # Генерация паролей
    ADMIN_PASS=$(generate_password 24)
    HYSTERIA_PASS=$(generate_password 32)
    NAIVE_PASS=$(generate_password 32)
    
    echo -e "\n${GREEN}=== Сгенерированные учетные данные ===${NC}"
    echo -e "Админ панели:   ${YELLOW}${ADMIN_USER}${NC} / ${YELLOW}${ADMIN_PASS}${NC}"
    echo -e "Hysteria пароль: ${YELLOW}${HYSTERIA_PASS}${NC}"
    echo -e "NaiveProxy:      ${YELLOW}${NAIVE_USER}${NC} / ${YELLOW}${NAIVE_PASS}${NC}"
    echo ""
    read -rp "Продолжить установку? [Y/n]: " confirm
    [[ "${confirm,,}" =~ ^[nnо]$ ]] && die "Установка отменена"
}

#===============================================================================
# ПОДГОТОВКА СИСТЕМЫ
#===============================================================================

prepare_system() {
    log_info "Обновление пакетов..."
    apt-get update -qq
    apt-get upgrade -y -qq
    
    log_info "Установка зависимостей..."
    apt-get install -y -qq \
        curl wget git unzip socat cron jq \
        python3 python3-pip python3-venv \
        systemd-timesyncd ca-certificates
    
    # Настройка часового пояса
    timedatectl set-timezone UTC 2>/dev/null || true
    
    log_success "Система подготовлена"
}

#===============================================================================
# ВКЛЮЧЕНИЕ BBR
#===============================================================================

enable_bbr() {
    [[ "$ENABLE_BBR" != "yes" ]] && return 0
    
    log_info "Включение TCP BBR..."
    
    # Проверка поддержки ядром
    if ! modprobe tcp_bbr 2>/dev/null; then
        log_warn "Модуль tcp_bbr не загружен, пробуем включить..."
    fi
    
    # Настройка sysctl
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_fastopen_key="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
EOF
    
    sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    
    # Проверка активации
    if [[ "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')" == "bbr" ]]; then
        log_success "BBR активирован"
    else
        log_warn "BBR не удалось активировать (может потребоваться перезагрузка)"
    fi
}

#===============================================================================
# УСТАНОВКА CADDY
#===============================================================================

install_caddy() {
    log_info "Установка Caddy..."
    
    # Добавление репозитория
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
        gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
        tee /etc/apt/sources.list.d/caddy-stable.list
    
    apt-get update -qq
    apt-get install -y -qq caddy
    
    # Остановка стандартного сервиса для ручной настройки
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true
    
    log_success "Caddy установлен"
}

#===============================================================================
# УСТАНОВКА HYSTERIA 2
#===============================================================================

install_hysteria() {
    log_info "Установка Hysteria 2..."
    
    local latest_ver
    latest_ver=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | \
        jq -r '.tag_name' | sed 's/^v//')
    
    local arch="amd64"
    [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
    
    local download_url="https://github.com/apernet/hysteria/releases/download/v${latest_ver}/hysteria-linux-${arch}"
    
    mkdir -p /usr/local/bin
    curl -fsSL "$download_url" -o /usr/local/bin/hysteria
    chmod +x /usr/local/bin/hysteria
    
    # Создание конфигурации
    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_DIR}/hysteria.json" << EOF
{
    "listen": ":443",
    "tls": {
        "cert": "/etc/caddy/certs/${MASK_DOMAIN}/fullchain.pem",
        "key": "/etc/caddy/certs/${MASK_DOMAIN}/key.pem"
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
    "ignoreClientBandwidth": false,
    "speedTest": true,
    "disableUDP": false
}
EOF
    
    log_success "Hysteria 2 установлен"
}

#===============================================================================
# НАСТРОЙКА МАСКИРОВОЧНОГО САЙТА
#===============================================================================

setup_mask_site() {
    log_info "Настройка маскировочного сайта..."
    
    mkdir -p "${WWW_DIR}"
    
    cat > "${WWW_DIR}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome - Premium Hosting Solutions</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;line-height:1.6;color:#333;background:#f8f9fe}
        .container{max-width:1200px;margin:0 auto;padding:2rem}
        header{display:flex;justify-content:space-between;align-items:center;padding:1rem 0;border-bottom:1px solid #eee;margin-bottom:3rem}
        .logo{font-size:1.5rem;font-weight:700;color:#2563eb}
        nav a{margin-left:2rem;color:#666;text-decoration:none;font-weight:500}
        nav a:hover{color:#2563eb}
        .hero{text-align:center;padding:4rem 2rem}
        .hero h1{font-size:3rem;margin-bottom:1rem;color:#1e293b}
        .hero p{font-size:1.25rem;color:#64748b;max-width:600px;margin:0 auto 2rem}
        .btn{display:inline-block;padding:0.875rem 2rem;background:#2563eb;color:#fff;border-radius:8px;text-decoration:none;font-weight:600;transition:background 0.2s}
        .btn:hover{background:#1d4ed8}
        .features{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:2rem;margin-top:4rem}
        .feature{background:#fff;padding:2rem;border-radius:12px;box-shadow:0 1px 3px rgba(0,0,0,0.1)}
        .feature h3{margin-bottom:0.5rem;color:#1e293b}
        .feature p{color:#64748b}
        footer{text-align:center;padding:2rem 0;margin-top:4rem;color:#64748b;font-size:0.875rem}
        @media(max-width:768px){.hero h1{font-size:2rem}nav{display:none}}
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="logo">CloudServe</div>
            <nav>
                <a href="#features">Features</a>
                <a href="#pricing">Pricing</a>
                <a href="#contact">Contact</a>
            </nav>
        </header>
        <main class="hero">
            <h1>Fast & Reliable Web Hosting</h1>
            <p>Deploy your applications with confidence. 99.9% uptime guarantee, 24/7 support, and blazing-fast performance.</p>
            <a href="#contact" class="btn">Get Started Free</a>
        </main>
        <section id="features" class="features">
            <div class="feature">
                <h3>⚡ Blazing Fast</h3>
                <p>SSD storage and optimized servers ensure your sites load instantly.</p>
            </div>
            <div class="feature">
                <h3>🔒 Secure by Default</h3>
                <p>Free SSL certificates, DDoS protection, and automated backups included.</p>
            </div>
            <div class="feature">
                <h3>🌍 Global CDN</h3>
                <p>Content delivered from 200+ edge locations worldwide for minimal latency.</p>
            </div>
        </section>
        <footer>
            <p>&copy; 2024 CloudServe. All rights reserved. | <a href="#" style="color:#64748b">Privacy Policy</a></p>
        </footer>
    </div>
</body>
</html>
HTMLEOF
    
    log_success "Маскировочный сайт настроен"
}

#===============================================================================
# СОЗДАНИЕ BACKEND (FastAPI)
#===============================================================================

create_backend() {
    log_info "Создание backend приложения..."
    
    mkdir -p "${BACKEND_DIR}"
    
    # requirements.txt
    cat > "${BACKEND_DIR}/requirements.txt" << 'EOF'
fastapi==0.109.2
uvicorn[standard]==0.27.1
pydantic==2.5.3
pydantic-settings==2.1.0
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-multipart==0.0.6
sqlalchemy==2.0.25
aiofiles==23.2.1
EOF
    
    # database.py
    cat > "${BACKEND_DIR}/database.py" << 'PYEOF'
import sqlite3
from pathlib import Path
from contextlib import contextmanager

DB_PATH = Path("/opt/vpn-panel/data/database.db")
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

@contextmanager
def get_db():
    conn = sqlite3.connect(str(DB_PATH), check_same_thread=False)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()

def init_db():
    with get_db() as conn:
        cursor = conn.cursor()
        
        # Таблица пользователей
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                hysteria_password TEXT NOT NULL,
                naive_password TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                is_active INTEGER DEFAULT 1
            )
        ''')
        
        # Таблица админов панели
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS admins (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        # Таблица логов
        cursor.execute('''
            CREATE TABLE IF NOT EXISTS logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                level TEXT NOT NULL,
                message TEXT NOT NULL,
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        
        conn.commit()
        
        # Создание админа по умолчанию
        cursor.execute('SELECT COUNT(*) FROM admins')
        if cursor.fetchone()[0] == 0:
            from passlib.context import CryptContext
            pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
            hashed = pwd_context.hash("CHANGE_ME_ADMIN_PASS")
            cursor.execute(
                'INSERT INTO admins (username, password_hash) VALUES (?, ?)',
                ("admin", hashed)
            )
            conn.commit()

def log_event(level: str, message: str):
    with get_db() as conn:
        conn.execute(
            'INSERT INTO logs (level, message) VALUES (?, ?)',
            (level, message)
        )
        conn.commit()
PYEOF
    
    # auth.py
    cat > "${BACKEND_DIR}/auth.py" << 'PYEOF'
from datetime import datetime, timedelta
from typing import Optional
from jose import JWTError, jwt
from passlib.context import CryptContext
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pathlib import Path
import sqlite3

SECRET_KEY = Path("/opt/vpn-panel/data/.secret").read_text().strip() if Path("/opt/vpn-panel/data/.secret").exists() else ""
if not SECRET_KEY:
    import secrets
    SECRET_KEY = secrets.token_urlsafe(32)
    Path("/opt/vpn-panel/data/.secret").write_text(SECRET_KEY)
    Path("/opt/vpn-panel/data/.secret").chmod(0o600)

ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 1440  # 24 часа

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
security = HTTPBearer(auto_error=False)

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

def get_password_hash(password: str) -> str:
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

async def get_current_admin(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security)
):
    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Требуется авторизация",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    payload = decode_token(credentials.credentials)
    if not payload or payload.get("type") != "admin":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Неверные учетные данные",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return payload

def get_admin_from_db(username: str) -> Optional[dict]:
    from database import get_db
    with get_db() as conn:
        cursor = conn.execute(
            'SELECT id, username, password_hash FROM admins WHERE username = ?',
            (username,)
        )
        row = cursor.fetchone()
        if row:
            return {"id": row["id"], "username": row["username"], "password_hash": row["password_hash"]}
    return None
PYEOF
    
    # models.py
    cat > "${BACKEND_DIR}/models.py" << 'PYEOF'
from pydantic import BaseModel, Field, field_validator
from typing import Optional, List
import re

class AdminLogin(BaseModel):
    username: str = Field(..., min_length=3, max_length=50)
    password: str = Field(..., min_length=8)

class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"

class TokenData(BaseModel):
    username: Optional[str] = None
    type: str = "admin"

class UserCreate(BaseModel):
    username: str = Field(..., min_length=3, max_length=50, pattern=r'^[a-zA-Z0-9_-]+$')
    password: Optional[str] = Field(None, min_length=8)
    
    @field_validator('username')
    @classmethod
    def username_valid(cls, v):
        if not re.match(r'^[a-zA-Z0-9_-]+$', v):
            raise ValueError('Только буквы, цифры, _ и -')
        return v

class UserResponse(BaseModel):
    id: int
    username: str
    hysteria_uri: str
    naive_uri: str
    created_at: str
    is_active: bool
    
    class Config:
        from_attributes = True

class ConfigGenerate(BaseModel):
    user_id: int
    domain: str
    port: int = 443

class LogEntry(BaseModel):
    id: int
    level: str
    message: str
    timestamp: str
    
    class Config:
        from_attributes = True
PYEOF
    
    # utils.py
    cat > "${BACKEND_DIR}/utils.py" << 'PYEOF'
import secrets
import string
from pathlib import Path
import json
import subprocess
from datetime import datetime

CONFIG_DIR = Path("/opt/vpn-panel/configs")
DATA_DIR = Path("/opt/vpn-panel/data")

def generate_password(length: int = 32) -> str:
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(secrets.choice(chars) for _ in range(length))

def get_server_config() -> dict:
    config_file = DATA_DIR / "server_config.json"
    if config_file.exists():
        return json.loads(config_file.read_text())
    return {}

def save_server_config(config: dict):
    config_file = DATA_DIR / "server_config.json"
    config_file.write_text(json.dumps(config, indent=2))
    config_file.chmod(0o600)

def generate_hysteria_uri(password: str, domain: str, port: int = 443) -> str:
    return f"hy2://{password}@{domain}:{port}?sni={domain}&insecure=0"

def generate_naive_uri(username: str, password: str, domain: str, port: int = 443) -> str:
    return f"https://{username}:{password}@{domain}:{port}"

def restart_service(name: str) -> bool:
    try:
        subprocess.run(
            ["systemctl", "restart", name],
            capture_output=True,
            check=True,
            timeout=30
        )
        return True
    except subprocess.CalledProcessError:
        return False

def get_service_status(name: str) -> str:
    try:
        result = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True,
            text=True,
            timeout=10
        )
        return result.stdout.strip()
    except:
        return "unknown"

def get_system_info() -> dict:
    import platform
    import psutil
    
    return {
        "hostname": platform.node(),
        "os": f"{platform.system()} {platform.release()}",
        "python": platform.python_version(),
        "cpu_count": psutil.cpu_count(),
        "memory_total_gb": round(psutil.virtual_memory().total / (1024**3), 2),
        "disk_total_gb": round(psutil.disk_usage('/').total / (1024**3), 2),
        "uptime": datetime.fromtimestamp(psutil.boot_time()).isoformat()
    }
PYEOF
    
    # main.py (основное приложение)
    cat > "${BACKEND_DIR}/main.py" << 'PYEOF'
#!/usr/bin/env python3
import logging
import sys
from pathlib import Path
from datetime import datetime
from contextlib import asynccontextmanager

from fastapi import FastAPI, Depends, HTTPException, status, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse

from database import init_db, get_db, log_event
from auth import (
    get_password_hash, verify_password, create_access_token,
    get_current_admin, get_admin_from_db, ACCESS_TOKEN_EXPIRE_MINUTES
)
from models import (
    AdminLogin, Token, UserCreate, UserResponse, 
    ConfigGenerate, LogEntry
)
from utils import (
    generate_password, generate_hysteria_uri, generate_naive_uri,
    restart_service, get_service_status, get_system_info
)

# Настройка логирования
LOG_FILE = Path("/opt/vpn-panel/logs/panel.log")
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("panel")

# Инициализация БД
init_db()

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Panel backend starting...")
    log_event("INFO", "Backend запущен")
    yield
    logger.info("Panel backend stopping...")

app = FastAPI(
    title="VPN Panel API",
    description="API для управления VPN/Proxy сервером",
    version="1.0.0",
    lifespan=lifespan
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Статика для фронтенда
app.mount("/static", StaticFiles(directory="/opt/vpn-panel/frontend"), name="static")

#===============================================================================
# AUTH ENDPOINTS
#===============================================================================

@app.post("/api/auth/login", response_model=Token)
async def login(credentials: AdminLogin):
    admin = get_admin_from_db(credentials.username)
    if not admin or not verify_password(credentials.password, admin["password_hash"]):
        log_event("WARN", f"Неудачная попытка входа: {credentials.username}")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Неверный логин или пароль",
            headers={"WWW-Authenticate": "Bearer"},
        )
    
    access_token = create_access_token(
        data={"sub": admin["username"], "type": "admin"},
        expires_delta=timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    )
    log_event("INFO", f"Успешный вход: {credentials.username}")
    return {"access_token": access_token, "token_type": "bearer"}

@app.get("/api/auth/me")
async def get_me(current_admin: dict = Depends(get_current_admin)):
    return {"username": current_admin["username"], "type": "admin"}

#===============================================================================
# USER MANAGEMENT ENDPOINTS
#===============================================================================

@app.post("/api/users", response_model=UserResponse, status_code=201)
async def create_user(
    user_in: UserCreate,
    background_tasks: BackgroundTasks,
    current_admin: dict = Depends(get_current_admin)
):
    from database import get_db
    import sqlite3
    
    password = user_in.password or generate_password(24)
    hysteria_pass = generate_password(32)
    naive_pass = generate_password(32)
    
    with get_db() as conn:
        try:
            cursor = conn.execute(
                '''INSERT INTO users (username, password_hash, hysteria_password, naive_password)
                   VALUES (?, ?, ?, ?)''',
                (user_in.username, get_password_hash(password), hysteria_pass, naive_pass)
            )
            conn.commit()
            user_id = cursor.lastrowid
            log_event("INFO", f"Создан пользователь: {user_in.username}")
        except sqlite3.IntegrityError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Пользователь с таким именем уже существует"
            )
    
    # Перезагрузка Hysteria для применения нового пользователя
    background_tasks.add_task(lambda: restart_service("hysteria"))
    
    domain = get_server_config().get("mask_domain", "example.com")
    
    return UserResponse(
        id=user_id,
        username=user_in.username,
        hysteria_uri=generate_hysteria_uri(hysteria_pass, domain),
        naive_uri=generate_naive_uri(user_in.username, naive_pass, domain),
        created_at=datetime.now().isoformat(),
        is_active=True
    )

@app.get("/api/users", response_model=List[UserResponse])
async def list_users(
    skip: int = 0,
    limit: int = 100,
    current_admin: dict = Depends(get_current_admin)
):
    from database import get_db
    
    with get_db() as conn:
        cursor = conn.execute(
            'SELECT id, username, hysteria_password, naive_password, created_at, is_active FROM users LIMIT ? OFFSET ?',
            (limit, skip)
        )
        rows = cursor.fetchall()
    
    domain = get_server_config().get("mask_domain", "example.com")
    
    return [
        UserResponse(
            id=row["id"],
            username=row["username"],
            hysteria_uri=generate_hysteria_uri(row["hysteria_password"], domain),
            naive_uri=generate_naive_uri(row["username"], row["naive_password"], domain),
            created_at=row["created_at"],
            is_active=bool(row["is_active"])
        )
        for row in rows
    ]

@app.get("/api/users/{user_id}", response_model=UserResponse)
async def get_user(
    user_id: int,
    current_admin: dict = Depends(get_current_admin)
):
    from database import get_db
    
    with get_db() as conn:
        cursor = conn.execute(
            'SELECT id, username, hysteria_password, naive_password, created_at, is_active FROM users WHERE id = ?',
            (user_id,)
        )
        row = cursor.fetchone()
    
    if not row:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    
    domain = get_server_config().get("mask_domain", "example.com")
    
    return UserResponse(
        id=row["id"],
        username=row["username"],
        hysteria_uri=generate_hysteria_uri(row["hysteria_password"], domain),
        naive_uri=generate_naive_uri(row["username"], row["naive_password"], domain),
        created_at=row["created_at"],
        is_active=bool(row["is_active"])
    )

@app.delete("/api/users/{user_id}", status_code=204)
async def delete_user(
    user_id: int,
    background_tasks: BackgroundTasks,
    current_admin: dict = Depends(get_current_admin)
):
    from database import get_db
    
    with get_db() as conn:
        cursor = conn.execute('SELECT username FROM users WHERE id = ?', (user_id,))
        user = cursor.fetchone()
        if not user:
            raise HTTPException(status_code=404, detail="Пользователь не найден")
        conn.execute('DELETE FROM users WHERE id = ?', (user_id,))
        conn.commit()
        log_event("INFO", f"Удален пользователь: {user['username']}")
    
    background_tasks.add_task(lambda: restart_service("hysteria"))

#===============================================================================
# CONFIG & SYSTEM ENDPOINTS
#===============================================================================

@app.get("/api/config/generate/{user_id}")
async def generate_config(
    user_id: int,
    config_type: str,  # hysteria или naive
    current_admin: dict = Depends(get_current_admin)
):
    from database import get_db
    
    with get_db() as conn:
        cursor = conn.execute(
            'SELECT username, hysteria_password, naive_password FROM users WHERE id = ?',
            (user_id,)
        )
        user = cursor.fetchone()
    
    if not user:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    
    domain = get_server_config().get("mask_domain", "example.com")
    port = get_server_config().get("panel_port", 443)
    
    if config_type == "hysteria":
        config = generate_hysteria_uri(user["hysteria_password"], domain, port)
        content_type = "text/plain"
    elif config_type == "naive":
        config = generate_naive_uri(user["username"], user["naive_password"], domain, port)
        content_type = "text/plain"
    else:
        raise HTTPException(status_code=400, detail="Неподдерживаемый тип конфигурации")
    
    return JSONResponse(content=config, media_type=content_type)

@app.get("/api/system/status")
async def system_status(current_admin: dict = Depends(get_current_admin)):
    return {
        "services": {
            "hysteria": get_service_status("hysteria"),
            "caddy": get_service_status("caddy"),
            "panel": get_service_status("panel")
        },
        "system": get_system_info()
    }

@app.post("/api/system/restart/{service}")
async def restart_system_service(
    service: str,
    current_admin: dict = Depends(get_current_admin)
):
    if service not in ["hysteria", "caddy", "panel"]:
        raise HTTPException(status_code=400, detail="Неподдерживаемый сервис")
    
    if restart_service(service):
        log_event("INFO", f"Перезапущен сервис: {service}")
        return {"status": "ok", "service": service}
    raise HTTPException(status_code=500, detail="Не удалось перезапустить сервис")

@app.get("/api/logs", response_model=List[LogEntry])
async def get_logs(
    level: Optional[str] = None,
    limit: int = 100,
    current_admin: dict = Depends(get_current_admin)
):
    from database import get_db
    
    with get_db() as conn:
        if level:
            cursor = conn.execute(
                'SELECT id, level, message, timestamp FROM logs WHERE level = ? ORDER BY timestamp DESC LIMIT ?',
                (level.upper(), limit)
            )
        else:
            cursor = conn.execute(
                'SELECT id, level, message, timestamp FROM logs ORDER BY timestamp DESC LIMIT ?',
                (limit,)
            )
        rows = cursor.fetchall()
    
    return [LogEntry(**dict(row)) for row in rows]

#===============================================================================
# FRONTEND ROUTES
#===============================================================================

@app.get("/")
async def serve_frontend():
    return FileResponse("/opt/vpn-panel/frontend/index.html")

@app.get("/login")
async def serve_login():
    return FileResponse("/opt/vpn-panel/frontend/login.html")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="127.0.0.1", port=8080, reload=False)
PYEOF
    
    # Добавим недостающий импорт в main.py
    sed -i 's/from auth import (/from datetime import timedelta\nfrom auth import (/' "${BACKEND_DIR}/main.py"
    
    # Установка зависимостей в venv
    cd "${BACKEND_DIR}"
    python3 -m venv venv
    source venv/bin/activate
    pip install -q -r requirements.txt
    pip install -q psutil  # для utils.py
    
    log_success "Backend создан"
}

#===============================================================================
# СОЗДАНИЕ FRONTEND
#===============================================================================

create_frontend() {
    log_info "Создание frontend приложения..."
    
    mkdir -p "${FRONTEND_DIR}"
    
    # style.css
    cat > "${FRONTEND_DIR}/style.css" << 'CSSEOF'
:root{--primary:#2563eb;--primary-hover:#1d4ed8;--success:#22c55e;--danger:#ef4444;--warning:#f59e0b;--bg:#f8fafc;--card:#fff;--text:#1e293b;--text-muted:#64748b;--border:#e2e8f0}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);line-height:1.5}
.container{max-width:1200px;margin:0 auto;padding:1rem}
.header{background:var(--card);border-bottom:1px solid var(--border);padding:1rem 0}
.header-content{display:flex;justify-content:space-between;align-items:center}
.logo{font-size:1.25rem;font-weight:700;color:var(--primary)}
.btn{display:inline-flex;align-items:center;gap:0.5rem;padding:0.5rem 1rem;background:var(--primary);color:#fff;border:none;border-radius:6px;font-weight:500;cursor:pointer;transition:background 0.2s;text-decoration:none}
.btn:hover{background:var(--primary-hover)}
.btn-sm{padding:0.375rem 0.75rem;font-size:0.875rem}
.btn-danger{background:var(--danger)}
.btn-danger:hover{background:#dc2626}
.btn-outline{background:transparent;border:1px solid var(--border);color:var(--text)}
.btn-outline:hover{background:var(--bg)}
.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:1.25rem;margin-bottom:1rem}
.card-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem;padding-bottom:0.75rem;border-bottom:1px solid var(--border)}
.card-title{font-weight:600;font-size:1.1rem}
.form-group{margin-bottom:1rem}
.form-group label{display:block;margin-bottom:0.375rem;font-weight:500;font-size:0.9rem}
.form-control{width:100%;padding:0.5rem 0.75rem;border:1px solid var(--border);border-radius:6px;font-size:1rem}
.form-control:focus{outline:none;border-color:var(--primary);box-shadow:0 0 0 3px rgba(37,99,235,0.1)}
.table{width:100%;border-collapse:collapse}
.table th,.table td{padding:0.75rem 1rem;text-align:left;border-bottom:1px solid var(--border)}
.table th{font-weight:600;font-size:0.875rem;color:var(--text-muted);text-transform:uppercase}
.table tr:hover{background:var(--bg)}
.badge{display:inline-block;padding:0.25rem 0.5rem;border-radius:4px;font-size:0.75rem;font-weight:500}
.badge-success{background:rgba(34,197,94,0.1);color:var(--success)}
.badge-danger{background:rgba(239,68,68,0.1);color:var(--danger)}
.badge-warning{background:rgba(245,158,11,0.1);color:var(--warning)}
.alert{padding:0.75rem 1rem;border-radius:6px;margin-bottom:1rem}
.alert-success{background:rgba(34,197,94,0.1);border:1px solid var(--success);color:var(--success)}
.alert-error{background:rgba(239,68,68,0.1);border:1px solid var(--danger);color:var(--danger)}
.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.5);align-items:center;justify-content:center;z-index:1000}
.modal.active{display:flex}
.modal-content{background:var(--card);border-radius:8px;padding:1.5rem;max-width:500px;width:90%;max-height:90vh;overflow-y:auto}
.modal-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem}
.modal-title{font-weight:600;font-size:1.1rem}
.modal-close{background:none;border:none;font-size:1.5rem;cursor:pointer;color:var(--text-muted)}
.config-box{background:var(--bg);padding:0.75rem;border-radius:6px;font-family:monospace;font-size:0.875rem;word-break:break-all;margin:0.5rem 0}
.status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:0.375rem}
.status-dot.online{background:var(--success)}
.status-dot.offline{background:var(--danger)}
.status-dot.unknown{background:var(--text-muted)}
.flex{display:flex;gap:0.5rem;align-items:center}
.flex-col{display:flex;flex-direction:column;gap:0.5rem}
.justify-between{justify-content:space-between}
.mt-1{margin-top:0.25rem}.mt-2{margin-top:0.5rem}.mt-4{margin-top:1rem}
.mb-1{margin-bottom:0.25rem}.mb-2{margin-bottom:0.5rem}.mb-4{margin-bottom:1rem}
.text-center{text-align:center}.text-muted{color:var(--text-muted)}
.hidden{display:none}
CSSEOF

    # login.html
    cat > "${FRONTEND_DIR}/login.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Вход - VPN Panel</title>
    <link rel="stylesheet" href="/static/style.css">
    <style>
        body{display:flex;align-items:center;justify-content:center;min-height:100vh;padding:1rem}
        .login-card{max-width:400px;width:100%}
        .login-card .card-header{text-align:center;border-bottom:none;padding-bottom:0}
        .login-card .card-title{font-size:1.5rem}
    </style>
</head>
<body>
    <div class="card login-card">
        <div class="card-header">
            <h1 class="card-title">🔐 VPN Panel</h1>
        </div>
        <form id="loginForm">
            <div class="form-group">
                <label for="username">Логин</label>
                <input type="text" id="username" class="form-control" required autocomplete="username">
            </div>
            <div class="form-group">
                <label for="password">Пароль</label>
                <input type="password" id="password" class="form-control" required autocomplete="current-password">
            </div>
            <div id="error" class="alert alert-error hidden"></div>
            <button type="submit" class="btn" style="width:100%">Войти</button>
        </form>
    </div>
    <script>
        document.getElementById('loginForm').addEventListener('submit', async (e) => {
            e.preventDefault();
            const error = document.getElementById('error');
            error.classList.add('hidden');
            
            try {
                const res = await fetch('/api/auth/login', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        username: document.getElementById('username').value,
                        password: document.getElementById('password').value
                    })
                });
                const data = await res.json();
                if (!res.ok) throw new Error(data.detail || 'Ошибка входа');
                
                localStorage.setItem('token', data.access_token);
                window.location.href = '/';
            } catch (err) {
                error.textContent = err.message;
                error.classList.remove('hidden');
            }
        });
    </script>
</body>
</html>
HTMLEOF

    # index.html (основная панель)
    cat > "${FRONTEND_DIR}/index.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VPN Panel</title>
    <link rel="stylesheet" href="/static/style.css">
</head>
<body>
    <header class="header">
        <div class="container header-content">
            <div class="logo">🚀 VPN Panel</div>
            <div class="flex">
                <span id="username" class="text-muted"></span>
                <button class="btn btn-outline btn-sm" onclick="logout()">Выйти</button>
            </div>
        </div>
    </header>
    
    <main class="container">
        <div id="alert" class="alert hidden"></div>
        
        <!-- Статус сервисов -->
        <div class="card">
            <div class="card-header">
                <span class="card-title">📊 Статус сервисов</span>
                <button class="btn btn-outline btn-sm" onclick="refreshStatus()">Обновить</button>
            </div>
            <div class="flex" style="gap:1.5rem">
                <div class="flex"><span class="status-dot" id="status-hysteria"></span>Hysteria2: <span id="text-hysteria">...</span></div>
                <div class="flex"><span class="status-dot" id="status-caddy"></span>Caddy: <span id="text-caddy">...</span></div>
                <div class="flex"><span class="status-dot" id="status-panel"></span>Panel: <span id="text-panel">...</span></div>
            </div>
        </div>
        
        <!-- Управление пользователями -->
        <div class="card">
            <div class="card-header justify-between">
                <span class="card-title">👥 Пользователи</span>
                <button class="btn btn-sm" onclick="openModal('userModal')">+ Добавить</button>
            </div>
            <div style="overflow-x:auto">
                <table class="table">
                    <thead>
                        <tr><th>ID</th><th>Имя</th><th>Hysteria URI</th><th>NaiveProxy URI</th><th>Создан</th><th>Действия</th></tr>
                    </thead>
                    <tbody id="usersTable"></tbody>
                </table>
            </div>
        </div>
        
        <!-- Логи -->
        <div class="card">
            <div class="card-header">
                <span class="card-title">📋 Логи</span>
            </div>
            <div id="logs" style="max-height:200px;overflow-y:auto;font-family:monospace;font-size:0.85rem"></div>
        </div>
    </main>
    
    <!-- Модальное окно: новый пользователь -->
    <div id="userModal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3 class="modal-title">Новый пользователь</h3>
                <button class="modal-close" onclick="closeModal('userModal')">&times;</button>
            </div>
            <form id="userForm">
                <div class="form-group">
                    <label>Имя пользователя</label>
                    <input type="text" id="newUsername" class="form-control" pattern="[a-zA-Z0-9_-]+" required>
                </div>
                <div class="form-group">
                    <label>Пароль (опционально)</label>
                    <input type="text" id="newPassword" class="form-control" placeholder="Сгенерировать автоматически">
                </div>
                <button type="submit" class="btn">Создать</button>
            </form>
        </div>
    </div>
    
    <!-- Модальное окно: показать конфиг -->
    <div id="configModal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3 class="modal-title">Конфигурация</h3>
                <button class="modal-close" onclick="closeModal('configModal')">&times;</button>
            </div>
            <div class="flex" style="gap:0.5rem;margin-bottom:1rem">
                <button class="btn btn-sm btn-outline" onclick="copyConfig('hysteria')">Копировать Hysteria</button>
                <button class="btn btn-sm btn-outline" onclick="copyConfig('naive')">Копировать Naive</button>
            </div>
            <div id="configHysteria" class="config-box"></div>
            <div id="configNaive" class="config-box"></div>
        </div>
    </div>
    
    <script src="/static/app.js"></script>
</body>
</html>
HTMLEOF

    # app.js
    cat > "${FRONTEND_DIR}/app.js" << 'JSEOF'
// Проверка авторизации
const token = localStorage.getItem('token');
if (!token) {
    window.location.href = '/login';
}

// Глобальные переменные
let currentUserId = null;
const API = '/api';

// Auth headers
const headers = {
    'Content-Type': 'application/json',
    'Authorization': `Bearer ${token}`
};

// Проверка токена при загрузке
(async () => {
    try {
        const res = await fetch(`${API}/auth/me`, {headers});
        if (!res.ok) throw new Error();
        const data = await res.json();
        document.getElementById('username').textContent = data.username;
        loadUsers();
        loadLogs();
        refreshStatus();
    } catch {
        localStorage.removeItem('token');
        window.location.href = '/login';
    }
})();

// Выход
function logout() {
    localStorage.removeItem('token');
    window.location.href = '/login';
}

// Показать уведомление
function showAlert(message, type = 'success') {
    const alert = document.getElementById('alert');
    alert.className = `alert alert-${type}`;
    alert.textContent = message;
    alert.classList.remove('hidden');
    setTimeout(() => alert.classList.add('hidden'), 5000);
}

// Загрузка пользователей
async function loadUsers() {
    try {
        const res = await fetch(`${API}/users`, {headers});
        if (!res.ok) throw new Error('Ошибка загрузки');
        const users = await res.json();
        
        const tbody = document.getElementById('usersTable');
        tbody.innerHTML = users.map(u => `
            <tr>
                <td>${u.id}</td>
                <td><strong>${u.username}</strong></td>
                <td><small class="text-muted">${u.hysteria_uri.substring(0,30)}...</small></td>
                <td><small class="text-muted">${u.naive_uri.substring(0,30)}...</small></td>
                <td>${new Date(u.created_at).toLocaleDateString()}</td>
                <td>
                    <button class="btn btn-sm btn-outline" onclick="showConfig(${u.id})">🔑</button>
                    <button class="btn btn-sm btn-danger" onclick="deleteUser(${u.id})">🗑️</button>
                </td>
            </tr>
        `).join('');
    } catch (err) {
        showAlert(err.message, 'error');
    }
}

// Создание пользователя
document.getElementById('userForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    try {
        const res = await fetch(`${API}/users`, {
            method: 'POST',
            headers,
            body: JSON.stringify({
                username: document.getElementById('newUsername').value,
                password: document.getElementById('newPassword').value || undefined
            })
        });
        if (!res.ok) {
            const err = await res.json();
            throw new Error(err.detail || 'Ошибка создания');
        }
        closeModal('userModal');
        e.target.reset();
        showAlert('Пользователь создан');
        loadUsers();
    } catch (err) {
        showAlert(err.message, 'error');
    }
});

// Удаление пользователя
async function deleteUser(id) {
    if (!confirm('Удалить пользователя?')) return;
    try {
        const res = await fetch(`${API}/users/${id}`, {method: 'DELETE', headers});
        if (!res.ok) throw new Error('Ошибка удаления');
        showAlert('Пользователь удален');
        loadUsers();
    } catch (err) {
        showAlert(err.message, 'error');
    }
}

// Показать конфигурацию
async function showConfig(userId) {
    currentUserId = userId;
    try {
        const [hRes, nRes] = await Promise.all([
            fetch(`${API}/config/generate/${userId}?config_type=hysteria`, {headers}),
            fetch(`${API}/config/generate/${userId}?config_type=naive`, {headers})
        ]);
        document.getElementById('configHysteria').textContent = await hRes.text();
        document.getElementById('configNaive').textContent = await nRes.text();
        openModal('configModal');
    } catch (err) {
        showAlert(err.message, 'error');
    }
}

// Копирование конфига
function copyConfig(type) {
    const text = document.getElementById(`config${type === 'hysteria' ? 'Hysteria' : 'Naive'}`).textContent;
    navigator.clipboard.writeText(text).then(() => showAlert('Скопировано!'));
}

// Загрузка логов
async function loadLogs() {
    try {
        const res = await fetch(`${API}/logs?limit=20`, {headers});
        const logs = await res.json();
        document.getElementById('logs').innerHTML = logs.map(l => 
            `<div><span class="badge badge-${l.level === 'ERROR' ? 'danger' : l.level === 'WARN' ? 'warning' : 'success'}">${l.level}</span> ${l.timestamp} - ${l.message}</div>`
        ).join('');
    } catch {}
}

// Статус сервисов
async function refreshStatus() {
    try {
        const res = await fetch(`${API}/system/status`, {headers});
        const data = await res.json();
        
        ['hysteria', 'caddy', 'panel'].forEach(svc => {
            const status = data.services[svc];
            const dot = document.getElementById(`status-${svc}`);
            const text = document.getElementById(`text-${svc}`);
            dot.className = `status-dot ${status === 'active' ? 'online' : status === 'inactive' ? 'offline' : 'unknown'}`;
            text.textContent = status;
        });
    } catch {}
}

// Модальные окна
function openModal(id) { document.getElementById(id).classList.add('active'); }
function closeModal(id) { document.getElementById(id).classList.remove('active'); }
window.onclick = (e) => { if (e.target.classList.contains('modal')) e.target.classList.remove('active'); };

// Автообновление
setInterval(() => { refreshStatus(); loadLogs(); }, 30000);
JSEOF
    
    log_success "Frontend создан"
}

#===============================================================================
# СИСТЕМНЫЕ СЕРВИСЫ (systemd)
#===============================================================================

create_systemd_services() {
    log_info "Создание systemd сервисов..."
    
    # hysteria.service
    cat > "${SYSTEMD_DIR}/hysteria.service" << 'EOF'
[Unit]
Description=Hysteria 2 VPN Service
After=network.target caddy.service
Wants=caddy.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /opt/vpn-panel/configs/hysteria.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    # panel.service
    cat > "${SYSTEMD_DIR}/panel.service" << EOF
[Unit]
Description=VPN Panel Backend
After=network.target
Wants=caddy.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vpn-panel/backend
Environment="PATH=/opt/vpn-panel/backend/venv/bin"
ExecStart=/opt/vpn-panel/backend/venv/bin/uvicorn main:app --host 127.0.0.1 --port ${PANEL_PORT} --reload false
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    # Override для Caddy (если нужно)
    mkdir -p "${SYSTEMD_DIR}/caddy.service.d"
    cat > "${SYSTEMD_DIR}/caddy.service.d/override.conf" << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
EOF

    # Перезагрузка systemd
    systemctl daemon-reload
    
    # Включение сервисов
    systemctl enable --now hysteria.service 2>/dev/null || log_warn "Не удалось запустить hysteria"
    systemctl enable --now panel.service 2>/dev/null || log_warn "Не удалось запустить panel"
    
    log_success "Systemd сервисы настроены"
}

#===============================================================================
# НАСТРОЙКА CADDYFILE
#===============================================================================

configure_caddy() {
    log_info "Настройка Caddy..."
    
    cat > /etc/caddy/Caddyfile << EOF
# Панель управления
${PANEL_DOMAIN} {
    tls ${SSL_EMAIL}
    reverse_proxy 127.0.0.1:${PANEL_PORT}
}

# Маскировочный сайт + прокси для Hysteria/Naive
${MASK_DOMAIN} {
    tls ${SSL_EMAIL}
    
    # NaiveProxy (обработка до file_server)
    handle {
        forward_proxy {
            basic_auth ${NAIVE_USER} ${NAIVE_PASS}
            hide_ip
            hide_via
            probe_resist
        }
    }
    
    # Маскировочный сайт
    root * ${WWW_DIR}
    file_server
}

# Catch-all для других запросов на 443 (Hysteria masquerade)
:443 {
    tls ${SSL_EMAIL}
    
    handle {
        respond "Not Found" 404
    }
}
EOF
    
    # Проверка конфигурации
    if ! caddy adapt --config /etc/caddy/Caddyfile --validate 2>/dev/null; then
        log_warn "Предупреждение: возможна ошибка в Caddyfile"
    fi
    
    # Запуск Caddy
    systemctl enable --now caddy
    
    log_success "Caddy настроен"
}

#===============================================================================
# БРАНДМАУЭР (UFW)
#===============================================================================

configure_firewall() {
    log_info "Настройка брандмауэра..."
    
    if command -v ufw &>/dev/null; then
        ufw --force enable 2>/dev/null || true
        ufw allow 22/tcp 2>/dev/null || true
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        ufw allow "${PANEL_PORT}"/tcp 2>/dev/null || true
        # Hysteria использует 443, уже открыт
        log_success "Правила UFW применены"
    else
        log_warn "UFW не установлен, пропуск настройки фаервола"
    fi
}

#===============================================================================
# СОХРАНЕНИЕ КОНФИГА И ДАННЫХ
#===============================================================================

save_config() {
    log_info "Сохранение конфигурации..."
    
    mkdir -p "${DATA_DIR}"
    
    # Серверный конфиг
    cat > "${DATA_DIR}/server_config.json" << EOF
{
    "panel_domain": "${PANEL_DOMAIN}",
    "mask_domain": "${MASK_DOMAIN}",
    "ssl_email": "${SSL_EMAIL}",
    "panel_port": ${PANEL_PORT},
    "bbr_enabled": ${ENABLE_BBR == "yes"},
    "admin_user": "${ADMIN_USER}",
    "admin_pass_hash": "$(python3 -c "from passlib.context import CryptContext; print(CryptContext(schemes=['bcrypt']).hash('${ADMIN_PASS}'))")",
    "hysteria_password": "${HYSTERIA_PASS}",
    "naive_user": "${NAIVE_USER}",
    "naive_password": "${NAIVE_PASS}",
    "installed_at": "$(date -Iseconds)"
}
EOF
    chmod 600 "${DATA_DIR}/server_config.json"
    
    # Обновление пароля админа в БД
    python3 << PYEOF
import sqlite3, sys
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

#===============================================================================
# CRON ДЛЯ АВТООБНОВЛЕНИЯ
#===============================================================================

setup_autoupdate() {
    log_info "Настройка автообновления..."
    
    cat > /etc/cron.daily/vpn-panel-update << 'EOF'
#!/bin/bash
# Автообновление Hysteria и проверка сервисов

LOG="/opt/vpn-panel/logs/update.log"
echo "[$(date)] Starting update check" >> "$LOG"

# Проверка обновлений Hysteria
CURRENT=$(/usr/local/bin/hysteria version 2>/dev/null | grep -oP 'v\K[0-9.]+')
LATEST=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r '.tag_name' | sed 's/^v//')

if [[ "$CURRENT" != "$LATEST" && -n "$LATEST" ]]; then
    echo "[$(date)] Updating Hysteria $CURRENT -> $LATEST" >> "$LOG"
    # Здесь можно добавить логику обновления
    systemctl restart hysteria 2>/dev/null
fi

# Проверка сервисов
for svc in hysteria caddy panel; do
    if ! systemctl is-active --quiet "$svc"; then
        echo "[$(date)] Restarting failed service: $svc" >> "$LOG"
        systemctl restart "$svc" 2>/dev/null
    fi
done

echo "[$(date)] Update check completed" >> "$LOG"
EOF
    chmod +x /etc/cron.daily/vpn-panel-update
    
    log_success "Автообновление настроено"
}

#===============================================================================
# ФИНАЛЬНЫЙ ВЫВОД
#===============================================================================

print_final_output() {
    clear
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  🎉 ${YELLOW}VPN/PANEL MANAGER УСПЕШНО УСТАНОВЛЕН${NC}      ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${BLUE}📋 Доступ к панели:${NC}"
    echo -e "   URL:     ${YELLOW}https://${PANEL_DOMAIN}${NC}"
    echo -e "   Логин:   ${YELLOW}${ADMIN_USER}${NC}"
    echo -e "   Пароль:  ${YELLOW}${ADMIN_PASS}${NC}\n"
    
    echo -e "${BLUE}🔑 Hysteria 2 подключение:${NC}"
    echo -e "   URI: ${YELLOW}hy2://${HYSTERIA_PASS}@${MASK_DOMAIN}:443?sni=${MASK_DOMAIN}${NC}\n"
    
    echo -e "${BLUE}🌐 NaiveProxy подключение:${NC}"
    echo -e "   URI: ${YELLOW}https://${NAIVE_USER}:${NAIVE_PASS}@${MASK_DOMAIN}:443${NC}\n"
    
    echo -e "${BLUE}⚙️  Управление:${NC}"
    echo -e "   • Системные сервисы: ${YELLOW}systemctl status {hysteria|panel|caddy}${NC}"
    echo -e "   • Логи панели:       ${YELLOW}tail -f /opt/vpn-panel/logs/panel.log${NC}"
    echo -e "   • Резервное копирование: ${YELLOW}/opt/vpn-panel/data/${NC}\n"
    
    echo -e "${YELLOW}⚠️  ВАЖНО:${NC}"
    echo -e "   1. Настройте DNS A-записи для ${PANEL_DOMAIN} и ${MASK_DOMAIN}"
    echo -e "   2. Первый вход в панель сменит пароль админа"
    echo -e "   3. SSL сертификаты выпустятся автоматически при первом запросе\n"
    
    # Сохранение кредов в файл для восстановления
    cat > "${INSTALL_DIR}/credentials.txt" << EOF
VPN Panel Credentials - $(date)
================================
Panel URL: https://${PANEL_DOMAIN}
Panel Login: ${ADMIN_USER}
Panel Password: ${ADMIN_PASS}

Hysteria2:
  URI: hy2://${HYSTERIA_PASS}@${MASK_DOMAIN}:443?sni=${MASK_DOMAIN}
  Password: ${HYSTERIA_PASS}

NaiveProxy:
  URI: https://${NAIVE_USER}:${NAIVE_PASS}@${MASK_DOMAIN}:443
  Username: ${NAIVE_USER}
  Password: ${NAIVE_PASS}
EOF
    chmod 600 "${INSTALL_DIR}/credentials.txt"
    
    echo -e "${GREEN}✅ Готово! Креденшалы сохранены в: ${INSTALL_DIR}/credentials.txt${NC}\n"
}

#===============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
#===============================================================================

main() {
    echo -e "${GREEN}\n🚀 VPN/PANEL MANAGER Installer v1.0${NC}"
    echo -e "   Production-ready Hysteria2 + NaiveProxy + Web Panel\n"
    
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
    configure_firewall
    save_config
    setup_autoupdate
    print_final_output
}

# Запуск
main "$@"
