from fastapi import FastAPI, Depends, HTTPException, Form
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
import sqlite3
import jwt
import bcrypt
import yaml
import subprocess
from datetime import datetime, timedelta

app = FastAPI(title="Hysteria 2 Panel")
SECRET_KEY = "change-this-in-production-2026"
ALGORITHM = "HS256"
DB_PATH = "/opt/hysteria-panel/users.db"

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db()
    conn.execute("""CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        created_at TEXT
    )""")
    conn.commit()
    conn.close()

init_db()

# Пароль админа заменяется при установке
ADMIN_HASH = bcrypt.hashpw(b'__ADMIN_PASS_PLACEHOLDER__', bcrypt.gensalt()).decode()

class UserCreate(BaseModel):
    username: str
    password: str

def create_jwt(data: dict):
    to_encode = data.copy()
    to_encode.update({"exp": datetime.utcnow() + timedelta(hours=24)})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def verify_token(token: str):
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except:
        raise HTTPException(status_code=401, detail="Invalid token")

def get_config():
    with open("/etc/hysteria/config.yaml") as f:
        return yaml.safe_load(f)

def save_config(config):
    with open("/etc/hysteria/config.yaml", "w") as f:
        yaml.dump(config, f, default_flow_style=False)
    subprocess.run(["systemctl", "restart", "hysteria"], check=True)

@app.get("/", response_class=HTMLResponse)
async def root():
    with open("/opt/hysteria-panel/static/index.html", encoding="utf-8") as f:
        return f.read()

@app.post("/api/login")
async def login(username: str = Form(...), password: str = Form(...)):
    if username != "admin" or not bcrypt.checkpw(password.encode(), ADMIN_HASH.encode()):
        raise HTTPException(401, "Неверный логин или пароль")
    return {"access_token": create_jwt({"sub": "admin"}), "token_type": "bearer"}

@app.get("/api/users")
async def list_users(token: dict = Depends(verify_token)):
    conn = get_db()
    users = conn.execute("SELECT username, created_at FROM users").fetchall()
    conn.close()
    return {"users": [dict(u) for u in users]}

@app.post("/api/users")
async def create_user(user: UserCreate, token: dict = Depends(verify_token)):
    conn = get_db()
    try:
        conn.execute("INSERT INTO users (username, password, created_at) VALUES (?, ?, ?)",
                     (user.username, user.password, datetime.utcnow().isoformat()))
        conn.commit()
    except sqlite3.IntegrityError:
        raise HTTPException(400, "Пользователь уже существует")
    finally:
        conn.close()

    config = get_config()
    config.setdefault("auth", {}).setdefault("userpass", {})[user.username] = user.password
    save_config(config)
    return {"status": "ok"}

@app.delete("/api/users/{username}")
async def delete_user(username: str, token: dict = Depends(verify_token)):
    conn = get_db()
    conn.execute("DELETE FROM users WHERE username=?", (username,))
    conn.commit()
    conn.close()

    config = get_config()
    config.get("auth", {}).get("userpass", {}).pop(username, None)
    save_config(config)
    return {"status": "ok"}

@app.get("/api/config/{username}")
async def get_client_config(username: str, token: dict = Depends(verify_token)):
    config = get_config()
    pw = config.get("auth", {}).get("userpass", {}).get(username)
    if not pw:
        raise HTTPException(404, "Пользователь не найден")
    port = str(config["listen"]).split(":")[-1]
    domain = config["acme"]["domains"][0]
    return {
        "uri": f"hysteria2://{username}:{pw}@{domain}:{port}/",
        "yaml": f"server: {domain}:{port}\nauth: {username}:{pw}\ntls:\n  sni: {domain}\n  insecure: false"
    }
