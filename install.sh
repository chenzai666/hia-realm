#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/realm/config.toml"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
PANEL_BIN="/usr/local/bin/realm-panel"
PANEL_SERVICE="realm-panel.service"
PANEL_SERVICE_FILE="/etc/systemd/system/${PANEL_SERVICE}"
REALM_DIR="/etc/realm"
BACKUP_DIR="/etc/realm/backups"
PANEL_DATA="/etc/realm/panel_data.json"
TMP_DIR="/tmp/realm-install"
LOG_FILE="/var/log/realm-manager.log"
NGINX_CONF="/etc/nginx/nginx.conf"
NGINX_SSL_DIR="/etc/nginx/ssl"
NGINX_CERT_DEFAULT="/etc/nginx/ssl/cert.crt"
NGINX_KEY_DEFAULT="/etc/nginx/ssl/private.key"

PANEL_PORT_DEFAULT="4794"
PANEL_USER_DEFAULT="admin"
PANEL_PASS_DEFAULT="123456"
PANEL_CERT_DEFAULT="/root/ygkkkca/cert.crt"
PANEL_KEY_DEFAULT="/root/ygkkkca/private.key"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

info() { printf "${GREEN}[信息]${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}[警告]${RESET} %s\n" "$1"; }
err() { printf "${RED}[错误]${RESET} %s\n" "$1"; }

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null || true
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        err "请以 root 用户运行此脚本。"
        exit 1
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        err "缺少依赖命令: $1"
        return 1
    }
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    [[ "$ip" =~ (^|\.)0[0-9] ]] && return 1
    local IFS='.' parts
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        (( p <= 255 )) || return 1
    done
}

validate_public_ipv4() {
    local ip="$1"
    validate_ip "$ip" || return 1
    local IFS='.' a b c d
    read -r a b c d <<< "$ip"
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
}

sanitize_name() {
    local name="$1"
    name="${name//$'\r'/ }"
    name="${name//$'\n'/ }"
    name="${name//\"/}"
    name=$(printf '%s' "$name" | sed -E 's/[[:cntrl:]]//g; s/^[[:space:]]+//; s/[[:space:]]+$//')
    printf '%s' "${name:0:60}"
}

get_local_ip() {
    local ip
    ip=$(curl -s4 --max-time 4 ifconfig.me 2>/dev/null || true)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
    hostname -I 2>/dev/null | awk '{print $1}' || echo "服务器IP"
}

is_installed() {
    [[ -x "$REALM_BIN" && -f "$SERVICE_FILE" ]]
}

ensure_dirs() {
    mkdir -p "$REALM_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
}

ensure_config_file() {
    ensure_dirs
    if [[ ! -s "$CONFIG_FILE" ]]; then
        cat > "$CONFIG_FILE" <<'EOF'
[[endpoints]]
name = "system-keepalive"
listen = "127.0.0.1:65534"
remote = "127.0.0.1:65534"
type = "tcp+udp"
EOF
    fi
}

backup_config() {
    ensure_dirs
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$BACKUP_DIR/config.toml.$(date '+%Y%m%d_%H%M%S')" 2>/dev/null || true
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v yum >/dev/null 2>&1; then echo yum
    elif command -v apk >/dev/null 2>&1; then echo apk
    else echo unknown
    fi
}

install_base_deps() {
    local pm
    pm=$(detect_pkg_manager)
    case "$pm" in
        apt)
            apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates python3 >/dev/null 2>&1
            ;;
        dnf) dnf install -y curl tar ca-certificates python3 >/dev/null 2>&1 ;;
        yum) yum install -y curl tar ca-certificates python3 >/dev/null 2>&1 ;;
        apk) apk add --no-cache curl tar ca-certificates python3 >/dev/null 2>&1 ;;
        *) ;;
    esac
}

install_nginx_dep() {
    if command -v nginx >/dev/null 2>&1; then
        return 0
    fi
    local pm
    pm=$(detect_pkg_manager)
    info "未检测到 nginx，正在自动安装。"
    case "$pm" in
        apt)
            apt-get update -y >/dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >/dev/null 2>&1
            ;;
        dnf) dnf install -y nginx >/dev/null 2>&1 ;;
        yum) yum install -y nginx >/dev/null 2>&1 ;;
        apk) apk add --no-cache nginx >/dev/null 2>&1 ;;
        *) err "无法识别包管理器，请手动安装 nginx。"; return 1 ;;
    esac
    command -v nginx >/dev/null 2>&1 || { err "nginx 安装失败。"; return 1; }
}

ensure_nginx_main_conf() {
    mkdir -p /etc/nginx "$NGINX_SSL_DIR"
    if [[ ! -f "$NGINX_CONF" ]]; then
        cat > "$NGINX_CONF" <<'EOF'
user nginx;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;
}
EOF
    fi
}

get_arch() {
    case "$(uname -m)" in
        x86_64) echo x86_64 ;;
        aarch64|arm64) echo aarch64 ;;
        armv7l|armv6l) echo armv7 ;;
        *) echo unsupported ;;
    esac
}

get_libc() {
    if ldd --version 2>&1 | grep -qi musl; then echo musl; else echo gnu; fi
}

get_realm_filename() {
    local arch libc
    arch=$(get_arch)
    libc=$(get_libc)
    case "$arch" in
        x86_64) echo "realm-x86_64-unknown-linux-${libc}.tar.gz" ;;
        aarch64) echo "realm-aarch64-unknown-linux-${libc}.tar.gz" ;;
        armv7)
            if [[ "$libc" == "musl" ]]; then
                echo "realm-armv7-unknown-linux-musleabihf.tar.gz"
            else
                echo "realm-armv7-unknown-linux-gnueabihf.tar.gz"
            fi
            ;;
        *) echo "" ;;
    esac
}

get_latest_realm_url() {
    local file
    file=$(get_realm_filename)
    [[ -z "$file" ]] && return 1
    curl -fsSL https://api.github.com/repos/zhboner/realm/releases/latest \
        | grep browser_download_url \
        | grep "$file" \
        | cut -d '"' -f 4 \
        | head -1
}

get_realm_version() {
    "$REALM_BIN" --version 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]/){print $i; exit}}' || true
}

install_realm() {
    check_root
    install_base_deps
    need_cmd curl
    need_cmd tar
    need_cmd systemctl

    local url file arch
    arch=$(get_arch)
    file=$(get_realm_filename)
    if [[ "$arch" == "unsupported" || -z "$file" ]]; then
        err "不支持的架构: $(uname -m)"
        return 1
    fi

    url=$(get_latest_realm_url || true)
    if [[ -z "$url" ]]; then
        err "获取 Realm 最新版本下载地址失败。"
        return 1
    fi

    info "正在安装/更新 Realm: ${file}"
    mkdir -p "$TMP_DIR"
    rm -f "$TMP_DIR/realm.tar.gz" "$TMP_DIR/realm"
    curl -L -o "$TMP_DIR/realm.tar.gz" "$url"
    tar -xzf "$TMP_DIR/realm.tar.gz" -C "$TMP_DIR"
    if [[ ! -f "$TMP_DIR/realm" ]]; then
        err "解压后未找到 realm 可执行文件。"
        return 1
    fi
    mv "$TMP_DIR/realm" "$REALM_BIN"
    chmod +x "$REALM_BIN"

    ensure_config_file
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Realm Proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${REALM_BIN} -c ${CONFIG_FILE}
Restart=always
LimitNOFILE=1000000
LimitNPROC=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable realm >/dev/null 2>&1 || true
    systemctl restart realm
    info "Realm 已安装/更新。当前版本: $(get_realm_version)"
    log_action "安装/更新 Realm"
}

restart_realm() {
    systemctl restart realm
    [[ -f "$PANEL_SERVICE_FILE" ]] && systemctl restart "$PANEL_SERVICE" >/dev/null 2>&1 || true
    info "Realm 已重启。"
}

uninstall_realm() {
    warn "这将卸载 Realm、面板和配置文件。"
    read -rp "确认卸载？[y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || return 0
    systemctl stop realm realm-panel >/dev/null 2>&1 || true
    systemctl disable realm realm-panel >/dev/null 2>&1 || true
    rm -f "$REALM_BIN" "$PANEL_BIN" "$SERVICE_FILE" "$PANEL_SERVICE_FILE"
    rm -rf "$REALM_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    info "Realm 已卸载。"
}

write_panel() {
    local panel_tmp
    panel_tmp="/tmp/realm-panel.$$"
    cat > "$panel_tmp" <<'PY'
#!/usr/bin/env python3
import base64
import hashlib
import http.cookies
import json
import os
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote

CONFIG_FILE = "/etc/realm/config.toml"
BACKUP_DIR = "/etc/realm/backups"
PANEL_DATA = "/etc/realm/panel_data.json"
LOG_FILE = "/var/log/realm-manager.log"
PANEL_USER = os.environ.get("PANEL_USER", "admin")
PANEL_PASS = os.environ.get("PANEL_PASS", "123456")
PANEL_PORT = int(os.environ.get("PANEL_PORT", "4794"))
PANEL_HOST = os.environ.get("PANEL_HOST", "0.0.0.0")
PANEL_CERT = os.environ.get("PANEL_CERT", "")
PANEL_KEY = os.environ.get("PANEL_KEY", "")
BG_PC = "https://images.unsplash.com/photo-1500530855697-b586d89ba3ee?auto=format&fit=crop&w=2200&q=80"
BG_MOBILE = "https://images.unsplash.com/photo-1500534314209-a25ddb2bd429?auto=format&fit=crop&w=1200&q=80"
SESSIONS = {}

def sh(cmd):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def log(msg):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("[%F %T] ") + msg + "\n")
    except OSError:
        pass

def ensure_dirs():
    os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
    os.makedirs(BACKUP_DIR, exist_ok=True)
    if not os.path.exists(CONFIG_FILE):
        write_rules([])

def valid_port(v):
    try:
        p = int(str(v))
    except ValueError:
        return False
    return 1 <= p <= 65535 and str(v) == str(p)

def valid_host_port(v):
    return bool(re.fullmatch(r"(\[[0-9a-fA-F:]+\]|[A-Za-z0-9_.:-]+):[0-9]{1,5}", v or ""))

def safe_name(v):
    v = (v or "").replace("\r", " ").replace("\n", " ").replace('"', "").strip()
    return re.sub(r"[\x00-\x1f\x7f]", "", v)[:60]

def parse_block(block, enabled=True):
    item = {"enabled": enabled, "name": "", "listen": "", "remote": "", "type": "tcp+udp"}
    for line in block:
        raw = line.strip()
        if raw.startswith("#"):
            raw = raw[1:].strip()
        m = re.match(r'(name|listen|remote|type)\s*=\s*"(.*)"', raw)
        if m:
            item[m.group(1)] = m.group(2)
    if item["listen"] == "127.0.0.1:65534" and item["remote"] == "127.0.0.1:65534":
        return None
    if item["listen"] and item["remote"]:
        item["id"] = hashlib.sha1((item["listen"] + "|" + item["remote"] + "|" + item["name"]).encode()).hexdigest()[:12]
        return item
    return None

def load_rules():
    ensure_dirs()
    rules, block, enabled = [], [], True
    with open(CONFIG_FILE, encoding="utf-8", errors="ignore") as f:
        for line in f:
            stripped = line.strip()
            marker = stripped == "[[endpoints]]" or stripped == "# [[endpoints]]"
            if marker:
                if block:
                    item = parse_block(block, enabled)
                    if item:
                        rules.append(item)
                block = [line]
                enabled = stripped == "[[endpoints]]"
            elif block:
                block.append(line)
        if block:
            item = parse_block(block, enabled)
            if item:
                rules.append(item)
    return rules

def backup_config():
    if os.path.exists(CONFIG_FILE):
        ts = time.strftime("%Y%m%d_%H%M%S")
        shutil.copy2(CONFIG_FILE, os.path.join(BACKUP_DIR, "config.toml." + ts))

def write_rules(rules):
    ensure_dirs()
    tmp = CONFIG_FILE + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        f.write('[[endpoints]]\nname = "system-keepalive"\nlisten = "127.0.0.1:65534"\nremote = "127.0.0.1:65534"\ntype = "tcp+udp"\n')
        for r in rules:
            prefix = "" if r.get("enabled", True) else "# "
            f.write("\n%s[[endpoints]]\n" % prefix)
            f.write('%sname = "%s"\n' % (prefix, safe_name(r.get("name"))))
            f.write('%slisten = "%s"\n' % (prefix, r["listen"]))
            f.write('%sremote = "%s"\n' % (prefix, r["remote"]))
            f.write('%stype = "tcp+udp"\n' % prefix)
    os.replace(tmp, CONFIG_FILE)

def restart_realm():
    sh(["systemctl", "restart", "realm"])

def schedule_restart():
    try:
        subprocess.Popen(["systemctl", "restart", "realm"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        log("restart realm failed: %s" % e)

def normalize_listen(v):
    v = str(v or "").strip()
    if valid_port(v):
        return "0.0.0.0:" + v
    return v

def test_connect(host_port):
    hp = str(host_port or "").strip()
    if hp.startswith("["):
        m = re.match(r"\[([0-9a-fA-F:]+)\]:(\d+)$", hp)
        host, port = (m.group(1), int(m.group(2))) if m else ("", 0)
    else:
        host, port_s = hp.rsplit(":", 1) if ":" in hp else ("", "0")
        port = int(port_s) if port_s.isdigit() else 0
    start = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=4):
            pass
        return {"ok": True, "elapsed_ms": int((time.monotonic() - start) * 1000)}
    except Exception as e:
        return {"ok": False, "elapsed_ms": int((time.monotonic() - start) * 1000), "error": str(e)}

def check_auth(headers):
    c = http.cookies.SimpleCookie(headers.get("Cookie", ""))
    sid = c.get("sid")
    return bool(sid and sid.value in SESSIONS)

def json_bytes(data):
    return json.dumps(data, ensure_ascii=False).encode("utf-8")

LOGIN_HTML = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Realm Login</title><style>*{margin:0;padding:0;box-sizing:border-box}body{height:100vh;width:100vw;overflow:hidden;display:flex;justify-content:center;align-items:center;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:url("__BG_PC__") no-repeat center center/cover;color:#374151}@media(max-width:768px){body{background-image:url("__BG_MOBILE__")}}.overlay{position:absolute;inset:0;background:rgba(0,0,0,.05)}.box{position:relative;z-index:2;background:rgba(255,255,255,.3);backdrop-filter:blur(25px);-webkit-backdrop-filter:blur(25px);padding:2.5rem;border-radius:24px;border:1px solid rgba(255,255,255,.4);box-shadow:0 8px 32px rgba(0,0,0,.05);width:90%;max-width:380px;text-align:center}h2{margin-bottom:2rem;font-weight:600;letter-spacing:1px}input{width:100%;padding:14px;margin-bottom:1.2rem;border:1px solid rgba(255,255,255,.5);border-radius:12px;outline:none;background:rgba(255,255,255,.5)}button{width:100%;padding:14px;background:rgba(59,130,246,.85);color:white;border:0;border-radius:12px;cursor:pointer;font-weight:600;font-size:1rem}</style></head><body><div class="overlay"></div><div class="box"><h2>Realm Panel</h2><form method="post" action="/login"><input name="username" placeholder="Username" required><input name="password" type="password" placeholder="Password" required><button>登 录</button></form></div></body></html>'''

DASH_HTML = r'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover"><title>Realm Panel</title><style>:root{--primary:#3b82f6;--danger:#f87171;--success:#34d399;--text:#374151}*{box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;height:100vh;overflow:hidden;background:url("__BG_PC__") no-repeat center center/cover;display:flex;flex-direction:column;color:var(--text)}@media(max-width:768px){body{background-image:url("__BG_MOBILE__")}}button{border:0;cursor:pointer}.navbar{background:rgba(255,255,255,.3);backdrop-filter:blur(25px);border-bottom:1px solid rgba(255,255,255,.3);padding:.8rem 2rem;display:flex;justify-content:space-between;align-items:center}.brand{font-weight:700}.container{flex:1;display:flex;flex-direction:column;max-width:1180px;margin:1.5rem auto;width:95%;overflow:hidden}.card{background:rgba(255,255,255,.3);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,.4);border-radius:18px;box-shadow:0 4px 15px rgba(0,0,0,.03)}.card-fixed{padding:1.2rem;margin-bottom:1.5rem}.card-scroll{flex:1;overflow:hidden;display:flex;flex-direction:column}.grid{display:grid;grid-template-columns:1fr 1fr 1.5fr auto auto;gap:12px}.grid input{padding:12px;border:1px solid rgba(255,255,255,.5);border-radius:12px;background:rgba(255,255,255,.55)}.btn{padding:10px 14px;border-radius:10px;color:white;font-weight:600}.btn-primary{background:var(--primary)}.btn-gray{background:rgba(255,255,255,.55);color:#4b5563}.btn-danger{background:var(--danger)}.btn-green{background:#059669}.table-wrapper{flex:1;overflow:auto;padding:0 1.5rem 1.5rem}table{width:100%;border-collapse:separate;border-spacing:0 10px}th{position:sticky;top:0;background:rgba(255,255,255,.45);backdrop-filter:blur(15px);padding:14px 12px;text-align:left;color:#6b7280;font-size:.85rem}td{background:rgba(255,255,255,.55);padding:12px;vertical-align:middle}tr td:first-child{border-radius:12px 0 0 12px}tr td:last-child{border-radius:0 12px 12px 0}.status{display:inline-flex;align-items:center;gap:7px}.dot{width:9px;height:9px;border-radius:999px;background:#9ca3af}.dot.on{background:var(--success)}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}.ops{display:flex;gap:6px;justify-content:flex-end;flex-wrap:wrap}.test{font-size:.82rem;font-weight:700;margin-left:6px}.ok{color:#059669}.bad{color:#dc2626}.modal{position:fixed;inset:0;background:rgba(0,0,0,.18);display:none;align-items:center;justify-content:center;z-index:20}.modal-box{background:rgba(255,255,255,.82);backdrop-filter:blur(25px);border-radius:20px;padding:24px;width:92%;max-width:460px}.modal-box input{width:100%;padding:12px;margin:7px 0 14px;border:1px solid rgba(0,0,0,.08);border-radius:10px;background:rgba(255,255,255,.7)}@media(max-width:768px){.grid{grid-template-columns:1fr}.navbar{padding:.8rem 1rem}thead{display:none}tbody tr{display:flex;flex-direction:column;border-radius:18px;margin-bottom:12px;padding:15px;background:rgba(255,255,255,.45)}td{display:flex;justify-content:space-between;gap:12px;background:transparent;padding:7px 0}td:before{content:attr(data-label);color:#8b95a1;font-size:.85rem}.ops{justify-content:flex-end}.nav-text{display:none}}</style></head><body><div class="navbar"><div class="brand">Realm 转发面板</div><div><button class="btn btn-gray" onclick="load()">刷新</button> <button class="btn btn-danger" onclick="logout()">退出</button></div></div><div class="container"><div class="card card-fixed"><div class="grid"><input id="n" placeholder="备注名称"><input id="l" placeholder="监听端口，如 10000"><input id="r" placeholder="目标，如 1.2.3.4:443"><button class="btn btn-primary" onclick="openAdd()">添加</button><button class="btn btn-green" onclick="backup()">导出</button></div></div><div class="card card-scroll"><div style="padding:1.2rem 1.5rem;font-weight:700">转发规则管理</div><div class="table-wrapper"><table><thead><tr><th>状态</th><th>备注</th><th>监听</th><th>目标</th><th>连通性</th><th style="text-align:right">操作</th></tr></thead><tbody id="list"></tbody></table><div id="empty" style="display:none;text-align:center;padding:50px;color:#6b7280">暂无规则</div></div></div></div><div id="modal" class="modal"><div class="modal-box"><h3 id="mt">添加规则</h3><input type="hidden" id="eid"><label>备注</label><input id="mn"><label>监听端口</label><input id="ml"><label>目标地址</label><input id="mr"><div style="margin-top:12px;display:flex;justify-content:flex-end;gap:12px"><button class="btn btn-gray" onclick="closeModal()">取消</button><button class="btn btn-primary" onclick="save()">保存</button></div></div></div><script>let rules=[];const $=id=>document.getElementById(id);function esc(v){return String(v||'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]))}async function api(u,o){const r=await fetch(u,o);if(r.status===401){location.href='/login';return}const d=await r.json().catch(()=>({}));if(!r.ok)throw new Error(d.error||r.statusText);return d}async function load(){const d=await api('/api/rules');rules=d.rules||[];render()}function render(){const t=$('list');t.innerHTML='';$('empty').style.display=rules.length?'none':'block';rules.forEach(r=>{const tr=document.createElement('tr');tr.innerHTML=`<td data-label="状态"><span class="status"><span class="dot ${r.enabled?'on':''}"></span>${r.enabled?'在线':'暂停'}</span></td><td data-label="备注"><b>${esc(r.name)}</b></td><td data-label="监听" class="mono">${esc(r.listen)}</td><td data-label="目标" class="mono">${esc(r.remote)}</td><td data-label="连通性"><button class="btn btn-gray" onclick="testRule('${r.id}',this)">测试</button><span class="test"></span></td><td data-label="操作"><div class="ops"><button class="btn btn-gray" onclick="tog('${r.id}')">${r.enabled?'暂停':'启动'}</button><button class="btn btn-primary" onclick="openEdit('${r.id}')">编辑</button><button class="btn btn-danger" onclick="delRule('${r.id}')">删除</button></div></td>`;t.appendChild(tr)})}function openAdd(){$('eid').value='';$('mt').textContent='添加规则';$('mn').value=$('n').value;$('ml').value=$('l').value;$('mr').value=$('r').value;$('modal').style.display='flex'}function openEdit(id){const r=rules.find(x=>x.id===id);$('eid').value=id;$('mt').textContent='编辑规则';$('mn').value=r.name;$('ml').value=r.listen.replace('0.0.0.0:','');$('mr').value=r.remote;$('modal').style.display='flex'}function closeModal(){$('modal').style.display='none'}async function save(){const id=$('eid').value;const body={name:$('mn').value,listen:$('ml').value,remote:$('mr').value};await api(id?'/api/rules/'+id:'/api/rules',{method:id?'PUT':'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});closeModal();$('n').value='';$('l').value='';$('r').value='';load()}async function delRule(id){if(confirm('确定删除此规则吗？')){await api('/api/rules/'+id,{method:'DELETE'});load()}}async function tog(id){await api('/api/rules/'+id+'/toggle',{method:'POST'});load()}async function testRule(id,btn){const r=rules.find(x=>x.id===id);const out=btn.parentElement.querySelector('.test');out.textContent='测试中...';out.className='test';const d=await api('/api/test',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({remote:r.remote})});if(d.ok){out.textContent='可达 '+d.elapsed_ms+'ms';out.className='test ok'}else{out.textContent='失败 '+d.elapsed_ms+'ms';out.className='test bad';alert(d.error||'连接失败')}}async function backup(){window.location.href='/api/backup'}async function logout(){await fetch('/logout',{method:'POST'});location.href='/login'}load();</script></body></html>'''

class Handler(BaseHTTPRequestHandler):
    def send_raw(self, code, body, ctype="text/html; charset=utf-8", headers=None):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def send_json(self, data, code=200):
        self.send_raw(code, json_bytes(data), "application/json; charset=utf-8")

    def body_json(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        return json.loads(self.rfile.read(n).decode("utf-8") or "{}")

    def require(self):
        if check_auth(self.headers):
            return True
        self.send_response(302)
        self.send_header("Location", "/login")
        self.end_headers()
        return False

    def do_GET(self):
        ensure_dirs()
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        if self.path == "/login":
            self.send_raw(200, LOGIN_HTML.replace("__BG_PC__", BG_PC).replace("__BG_MOBILE__", BG_MOBILE))
            return
        if not self.require():
            return
        if self.path == "/":
            self.send_raw(200, DASH_HTML.replace("__BG_PC__", BG_PC).replace("__BG_MOBILE__", BG_MOBILE))
        elif self.path == "/api/rules":
            self.send_json({"rules": load_rules(), "realm": sh(["systemctl", "is-active", "realm"]).stdout.strip()})
        elif self.path == "/api/backup":
            self.send_raw(200, json.dumps(load_rules(), ensure_ascii=False, indent=2), "application/json; charset=utf-8", {"Content-Disposition": 'attachment; filename="realm-rules.json"'})
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        ensure_dirs()
        if self.path == "/login":
            n = int(self.headers.get("Content-Length", "0") or "0")
            data = parse_qs(self.rfile.read(n).decode())
            if data.get("username", [""])[0] == PANEL_USER and data.get("password", [""])[0] == PANEL_PASS:
                sid = secrets.token_urlsafe(24)
                SESSIONS[sid] = time.time()
                self.send_response(302)
                self.send_header("Set-Cookie", "sid=%s; HttpOnly; SameSite=Lax; Path=/" % sid)
                self.send_header("Location", "/")
                self.end_headers()
            else:
                self.send_raw(401, "用户名或密码错误")
            return
        if self.path == "/logout":
            self.send_response(302)
            self.send_header("Set-Cookie", "sid=; Max-Age=0; Path=/")
            self.send_header("Location", "/login")
            self.end_headers()
            return
        if not self.require():
            return
        try:
            if self.path == "/api/rules":
                data = self.body_json()
                rule = {"enabled": True, "name": safe_name(data.get("name")), "listen": normalize_listen(data.get("listen")), "remote": str(data.get("remote", "")).strip(), "type": "tcp+udp"}
                if not rule["name"] or not valid_host_port(rule["listen"]) or not valid_host_port(rule["remote"]):
                    raise ValueError("规则格式无效")
                rules = [r for r in load_rules() if r["listen"] != rule["listen"]]
                rules.append(rule)
                backup_config(); write_rules(rules); schedule_restart()
                self.send_json({"status": "ok"})
            elif self.path == "/api/test":
                data = self.body_json()
                self.send_json(test_connect(data.get("remote")))
            else:
                parts = self.path.strip("/").split("/")
                if len(parts) == 4 and parts[:2] == ["api", "rules"] and parts[3] == "toggle":
                    rid = parts[2]
                    rules = load_rules()
                    for r in rules:
                        if r["id"] == rid:
                            r["enabled"] = not r.get("enabled", True)
                            break
                    backup_config(); write_rules(rules); schedule_restart()
                    self.send_json({"status": "ok"})
                else:
                    self.send_json({"error": "not found"}, 404)
        except Exception as e:
            self.send_json({"error": str(e)}, 400)

    def do_PUT(self):
        if not self.require():
            return
        try:
            parts = self.path.strip("/").split("/")
            if len(parts) == 3 and parts[:2] == ["api", "rules"]:
                rid = parts[2]
                data = self.body_json()
                rules = load_rules()
                found = False
                for r in rules:
                    if r["id"] == rid:
                        r.update({"name": safe_name(data.get("name")), "listen": normalize_listen(data.get("listen")), "remote": str(data.get("remote", "")).strip(), "type": "tcp+udp"})
                        found = True
                        break
                if not found:
                    raise ValueError("规则不存在")
                backup_config(); write_rules(rules); schedule_restart()
                self.send_json({"status": "ok"})
            else:
                self.send_json({"error": "not found"}, 404)
        except Exception as e:
            self.send_json({"error": str(e)}, 400)

    def do_DELETE(self):
        if not self.require():
            return
        try:
            parts = self.path.strip("/").split("/")
            if len(parts) == 3 and parts[:2] == ["api", "rules"]:
                rid = parts[2]
                rules = [r for r in load_rules() if r["id"] != rid]
                backup_config(); write_rules(rules); schedule_restart()
                self.send_json({"status": "ok"})
            else:
                self.send_json({"error": "not found"}, 404)
        except Exception as e:
            self.send_json({"error": str(e)}, 400)

    def log_message(self, fmt, *args):
        return

if __name__ == "__main__":
    ensure_dirs()
    httpd = ThreadingHTTPServer((PANEL_HOST, PANEL_PORT), Handler)
    scheme = "http"
    if PANEL_CERT and PANEL_KEY:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(PANEL_CERT, PANEL_KEY)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"
    print("realm-panel listening on %s://%s:%d" % (scheme, PANEL_HOST, PANEL_PORT), flush=True)
    httpd.serve_forever()
PY
    chmod +x "$panel_tmp"
    install -m 755 "$panel_tmp" "$PANEL_BIN"
    rm -f "$panel_tmp"
}

get_panel_env() {
    local key="$1"
    [[ -f "$PANEL_SERVICE_FILE" ]] || return 0
    sed -n -E "s|^Environment=\"${key}=([^\"]*)\"$|\\1|p" "$PANEL_SERVICE_FILE" | tail -1
}

find_acme_sh() {
    command -v acme.sh 2>/dev/null && return 0
    [[ -x "$HOME/.acme.sh/acme.sh" ]] && { echo "$HOME/.acme.sh/acme.sh"; return 0; }
    [[ -x "/root/.acme.sh/acme.sh" ]] && { echo "/root/.acme.sh/acme.sh"; return 0; }
    return 1
}

ensure_acme_sh() {
    local acme
    acme=$(find_acme_sh 2>/dev/null || true)
    [[ -n "$acme" ]] && { echo "$acme"; return 0; }
    install_base_deps
    read -rp "Let's Encrypt 账号邮箱 [可留空]: " email
    if [[ -n "$email" ]]; then
        curl -fsSL https://get.acme.sh | sh -s "email=${email}" >/dev/null
    else
        curl -fsSL https://get.acme.sh | sh >/dev/null
    fi
    find_acme_sh
}

issue_ip_cert() {
    local cert_ip="$1" cert_path="$2" key_path="$3" acme
    acme=$(ensure_acme_sh)
    "$acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    "$acme" --issue --server letsencrypt --standalone -d "$cert_ip" --certificate-profile shortlived --days 3 --force
    mkdir -p "$(dirname "$cert_path")" "$(dirname "$key_path")"
    "$acme" --install-cert -d "$cert_ip" --key-file "$key_path" --fullchain-file "$cert_path" --reloadcmd "systemctl restart ${PANEL_SERVICE}"
    "$acme" --install-cronjob >/dev/null 2>&1 || true
    chmod 600 "$key_path" 2>/dev/null || true
}

install_panel() {
    check_root
    install_base_deps
    need_cmd python3
    local port user pass host cert key existing ip scheme
    existing=0
    [[ -f "$PANEL_SERVICE_FILE" ]] && existing=1
    if (( existing )); then
        port=$(get_panel_env PANEL_PORT); user=$(get_panel_env PANEL_USER); pass=$(get_panel_env PANEL_PASS)
        host=$(get_panel_env PANEL_HOST); cert=$(get_panel_env PANEL_CERT); key=$(get_panel_env PANEL_KEY)
        port="${port:-$PANEL_PORT_DEFAULT}"; user="${user:-$PANEL_USER_DEFAULT}"; pass="${pass:-$PANEL_PASS_DEFAULT}"
        host="${host:-0.0.0.0}"; cert="${cert:-}"; key="${key:-}"
        if [[ -z "$cert" && -z "$key" && -f "$PANEL_CERT_DEFAULT" && -f "$PANEL_KEY_DEFAULT" ]]; then
            cert="$PANEL_CERT_DEFAULT"; key="$PANEL_KEY_DEFAULT"; info "检测到默认路径证书，已自动恢复 HTTPS。"
        fi
        info "检测到已安装面板，本次仅更新面板程序并保留配置。"
    else
        read -rp "面板端口 [默认 ${PANEL_PORT_DEFAULT}]: " port; port="${port:-$PANEL_PORT_DEFAULT}"
        validate_port "$port" || { err "端口无效。"; return 1; }
        read -rp "面板用户名 [默认 ${PANEL_USER_DEFAULT}]: " user; user="${user:-$PANEL_USER_DEFAULT}"
        read -rsp "面板密码 [默认 ${PANEL_PASS_DEFAULT}]: " pass; echo ""; pass="${pass:-$PANEL_PASS_DEFAULT}"
        host="0.0.0.0"; cert=""; key=""
    fi
    systemctl stop "$PANEL_SERVICE" >/dev/null 2>&1 || true
    write_panel
    cat > "$PANEL_SERVICE_FILE" <<EOF
[Unit]
Description=Realm Panel
After=network-online.target realm.service
Wants=network-online.target

[Service]
User=root
Environment="PANEL_USER=${user}"
Environment="PANEL_PASS=${pass}"
Environment="PANEL_PORT=${port}"
Environment="PANEL_HOST=${host}"
Environment="PANEL_CERT=${cert}"
Environment="PANEL_KEY=${key}"
ExecStart=${PANEL_BIN}
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$PANEL_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$PANEL_SERVICE"
    ip=$(get_local_ip)
    scheme=http; [[ -n "$cert" && -n "$key" ]] && scheme=https
    info "Realm 面板已安装/更新。"
    echo "访问地址: ${scheme}://${ip}:${port}"
    echo "用户名: ${user}"
    echo "密码: ${pass}"
}

configure_panel_tls() {
    [[ -f "$PANEL_SERVICE_FILE" ]] || { err "面板尚未安装。"; return 1; }
    local host cert key cert_ip port
    read -rp "监听 IP [默认 0.0.0.0]: " host; host="${host:-0.0.0.0}"
    read -rp "证书文件路径 [默认 ${PANEL_CERT_DEFAULT}]: " cert; cert="${cert:-$PANEL_CERT_DEFAULT}"
    read -rp "私钥文件路径 [默认 ${PANEL_KEY_DEFAULT}]: " key; key="${key:-$PANEL_KEY_DEFAULT}"
    if [[ "$cert" == "none" && "$key" == "none" ]]; then cert=""; key=""; fi
    if [[ -n "$cert" || -n "$key" ]]; then
        [[ -n "$cert" && -n "$key" ]] || { err "证书和私钥必须同时填写。"; return 1; }
        mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
        if [[ ! -f "$cert" || ! -f "$key" ]]; then
            read -rp "证书 IP [服务器公网 IPv4]: " cert_ip
            validate_public_ipv4 "$cert_ip" || { err "只能申请公网 IPv4 证书。"; return 1; }
            issue_ip_cert "$cert_ip" "$cert" "$key"
        fi
    fi
    sed -i -E "s|Environment=\"PANEL_HOST=.*\"|Environment=\"PANEL_HOST=${host}\"|" "$PANEL_SERVICE_FILE"
    sed -i -E "s|Environment=\"PANEL_CERT=.*\"|Environment=\"PANEL_CERT=${cert}\"|" "$PANEL_SERVICE_FILE"
    sed -i -E "s|Environment=\"PANEL_KEY=.*\"|Environment=\"PANEL_KEY=${key}\"|" "$PANEL_SERVICE_FILE"
    systemctl daemon-reload
    systemctl restart "$PANEL_SERVICE"
    port=$(get_panel_env PANEL_PORT); port="${port:-$PANEL_PORT_DEFAULT}"
    info "面板 TLS 配置已更新。"
    echo "访问地址: $([[ -n "$cert" && -n "$key" ]] && echo https || echo http)://$(get_local_ip):${port}"
}

update_panel_login() {
    [[ -f "$PANEL_SERVICE_FILE" ]] || { err "面板尚未安装。"; return 1; }
    local user pass
    read -rp "新的面板用户名: " user
    read -rsp "新的面板密码: " pass; echo ""
    [[ -n "$user" && -n "$pass" ]] || { err "用户名和密码不能为空。"; return 1; }
    sed -i -E "s|Environment=\"PANEL_USER=.*\"|Environment=\"PANEL_USER=${user}\"|" "$PANEL_SERVICE_FILE"
    sed -i -E "s|Environment=\"PANEL_PASS=.*\"|Environment=\"PANEL_PASS=${pass}\"|" "$PANEL_SERVICE_FILE"
    systemctl daemon-reload
    systemctl restart "$PANEL_SERVICE"
    echo "用户名: ${user}"
    echo "密码: ${pass}"
}

update_panel_port() {
    [[ -f "$PANEL_SERVICE_FILE" ]] || { err "面板尚未安装。"; return 1; }
    local port
    read -rp "新的面板端口: " port
    validate_port "$port" || { err "端口无效。"; return 1; }
    sed -i -E "s|Environment=\"PANEL_PORT=.*\"|Environment=\"PANEL_PORT=${port}\"|" "$PANEL_SERVICE_FILE"
    systemctl daemon-reload
    systemctl restart "$PANEL_SERVICE"
    info "面板端口已更新为 ${port}。"
}


configure_nginx_proxy() {
    [[ -f "$PANEL_SERVICE_FILE" ]] || { err "面板尚未安装。"; return 1; }
    install_nginx_dep || return 1
    ensure_nginx_main_conf

    local panel_port panel_cert panel_key upstream_scheme domain listen_port cert key scheme block tmp
    panel_port=$(get_panel_env PANEL_PORT); panel_port="${panel_port:-$PANEL_PORT_DEFAULT}"
    panel_cert=$(get_panel_env PANEL_CERT); panel_key=$(get_panel_env PANEL_KEY)
    upstream_scheme="http"
    [[ -n "$panel_cert" && -n "$panel_key" ]] && upstream_scheme="https"

    read -rp "反代域名（例如 panel.example.com）: " domain
    [[ -n "$domain" ]] || { err "域名不能为空。"; return 1; }
    domain="${domain//;/}"
    domain="${domain// /}"

    read -rp "Nginx 监听端口 [默认 443]: " listen_port
    listen_port="${listen_port:-443}"
    validate_port "$listen_port" || { err "Nginx 监听端口无效。"; return 1; }

    cert="$NGINX_CERT_DEFAULT"
    key="$NGINX_KEY_DEFAULT"
    mkdir -p "$NGINX_SSL_DIR"
    scheme="http"
    if [[ "$listen_port" == "443" ]]; then
        scheme="https"
        if [[ ! -f "$cert" || ! -f "$key" ]]; then
            warn "未检测到 Nginx 证书，请将证书放到：$cert"
            warn "请将私钥放到：$key"
            err "缺少 Nginx HTTPS 证书，已创建目录：$NGINX_SSL_DIR"
            return 1
        fi
    fi

    block=$(cat <<EOF
    # BEGIN REALM_PANEL_PROXY
    server {
        listen ${listen_port}$([[ "$listen_port" == "443" ]] && printf ' ssl');
        server_name ${domain};
EOF
)

    if [[ "$listen_port" == "443" ]]; then
        block+=$(cat <<EOF

        ssl_certificate ${cert};
        ssl_certificate_key ${key};
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:REALM_PANEL_SSL:10m;
EOF
)
    fi

    block+=$(cat <<EOF

        client_max_body_size 10m;

        location / {
            proxy_pass ${upstream_scheme}://127.0.0.1:${panel_port};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
EOF
)

    if [[ "$upstream_scheme" == "https" ]]; then
        block+=$(cat <<'EOF'
            proxy_ssl_server_name off;
            proxy_ssl_verify off;
EOF
)
    fi

    block+=$(cat <<'EOF'
        }
    }
    # END REALM_PANEL_PROXY
EOF
)

    tmp="${NGINX_CONF}.tmp.$$"
    python3 - "$NGINX_CONF" "$tmp" "$block" <<'PY'
import re, sys
path, tmp, block = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(path, encoding='utf-8', errors='ignore').read()
except FileNotFoundError:
    text = "events { worker_connections 1024; }\nhttp {\n}\n"
pattern = r"\n?\s*# BEGIN REALM_PANEL_PROXY\n.*?\n\s*# END REALM_PANEL_PROXY\n?"
text = re.sub(pattern, "\n", text, flags=re.S)
if re.search(r"http\s*\{", text):
    idx = text.rfind('}')
    if idx == -1:
        raise SystemExit('nginx.conf missing http closing brace')
    text = text[:idx].rstrip() + "\n\n" + block + "\n" + text[idx:]
else:
    text = text.rstrip() + "\n\nhttp {\n" + block + "\n}\n"
open(tmp, 'w', encoding='utf-8', newline='\n').write(text)
PY

    cp "$NGINX_CONF" "${NGINX_CONF}.bak.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
    mv "$tmp" "$NGINX_CONF"

    if ! nginx -t; then
        err "nginx 配置检测失败，已写入: ${NGINX_CONF}"
        return 1
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx
    else
        systemctl restart nginx
    fi
    info "Nginx 反代配置已更新。"
    echo "配置文件: ${NGINX_CONF}"
    echo "Nginx 证书: ${cert}"
    echo "Nginx 私钥: ${key}"
    echo "上游面板: ${upstream_scheme}://127.0.0.1:${panel_port}"
    echo "访问地址: ${scheme}://${domain}$([[ "$listen_port" != "80" && "$listen_port" != "443" ]] && echo ":${listen_port}")"
}

uninstall_panel() {
    systemctl stop "$PANEL_SERVICE" >/dev/null 2>&1 || true
    systemctl disable "$PANEL_SERVICE" >/dev/null 2>&1 || true
    rm -f "$PANEL_SERVICE_FILE" "$PANEL_BIN"
    systemctl daemon-reload >/dev/null 2>&1 || true
    info "Realm 面板已卸载。"
}

list_rules_cli() {
    ensure_config_file
    python3 - "$CONFIG_FILE" <<'PY'
import re, sys
path=sys.argv[1]
rules=[]; block=[]; enabled=True
def emit(b,en):
    d={}
    for line in b:
        raw=line.strip()
        if raw.startswith('#'): raw=raw[1:].strip()
        m=re.match(r'(name|listen|remote|type)\s*=\s*"(.*)"', raw)
        if m: d[m.group(1)]=m.group(2)
    if d.get('listen') != '127.0.0.1:65534' and d.get('listen'):
        rules.append((en,d))
for line in open(path,encoding='utf-8',errors='ignore'):
    s=line.strip()
    if s in ('[[endpoints]]','# [[endpoints]]'):
        if block: emit(block,enabled)
        block=[line]; enabled=s=='[[endpoints]]'
    elif block: block.append(line)
if block: emit(block,enabled)
if not rules:
    print('暂无规则')
else:
    for i,(en,r) in enumerate(rules,1):
        print(f"{i}. [{'启用' if en else '暂停'}] {r.get('name','')} | {r.get('listen','')} -> {r.get('remote','')}")
PY
}

add_rule_cli() {
    ensure_config_file
    local name port remote listen
    read -rp "规则名称: " name; name=$(sanitize_name "$name")
    read -rp "监听端口: " port; validate_port "$port" || { err "端口无效。"; return 1; }
    read -rp "目标地址 host:port: " remote
    [[ "$remote" == *:* ]] || { err "目标格式应为 host:port"; return 1; }
    listen="0.0.0.0:${port}"
    backup_config
    cat >> "$CONFIG_FILE" <<EOF

[[endpoints]]
name = "${name}"
listen = "${listen}"
remote = "${remote}"
type = "tcp+udp"
EOF
    restart_realm
    info "规则已添加。"
}

export_rules() {
    ensure_config_file
    local out
    read -rp "导出文件路径 [默认 ${BACKUP_DIR}/realm-backup.tar.gz]: " out
    out="${out:-${BACKUP_DIR}/realm-backup.tar.gz}"
    mkdir -p "$(dirname "$out")"
    tar -czf "$out" -C "$REALM_DIR" config.toml 2>/dev/null
    info "导出完成: ${out}"
}

import_rules() {
    local in
    read -rp "导入文件路径: " in
    [[ -f "$in" ]] || { err "文件不存在。"; return 1; }
    backup_config
    if [[ "$in" == *.tar.gz ]]; then
        tar -xzf "$in" -C "$REALM_DIR"
    else
        cp "$in" "$CONFIG_FILE"
    fi
    restart_realm
    info "导入完成。"
}

panel_menu() {
    while true; do
        echo ""
        echo "Realm 面板管理"
        echo "1. 安装/更新面板（保留原风格和已有配置）"
        echo "2. 卸载面板"
        echo "3. 修改面板端口"
        echo "4. 修改登录信息"
        echo "5. 配置监听 IP / HTTPS IP 证书"
        echo "6. 查看面板状态"
        echo "7. 配置 Nginx 反代面板"
        echo "0. 返回"
        read -rp "请选择 [0-7]: " opt
        case "$opt" in
            1) install_panel ;;
            2) uninstall_panel ;;
            3) update_panel_port ;;
            4) update_panel_login ;;
            5) configure_panel_tls ;;
            6) systemctl status "$PANEL_SERVICE" --no-pager || true ;;
            7) configure_nginx_proxy ;;
            0) return ;;
            *) err "无效选项。" ;;
        esac
    done
}

main_menu() {
    check_root
    while true; do
        echo ""
        echo -e "${GREEN}===== Realm TCP+UDP 转发管理 =====${RESET}"
        if is_installed; then
            echo "Realm: $(systemctl is-active realm 2>/dev/null || true)  版本: $(get_realm_version)"
        else
            echo "Realm: 未安装"
        fi
        echo "1. 安装/更新 Realm"
        echo "2. 卸载 Realm"
        echo "3. 重启 Realm"
        echo "4. 添加转发规则"
        echo "5. 查看当前规则"
        echo "6. 导出规则"
        echo "7. 导入规则"
        echo "8. Realm 面板管理"
        echo "9. 查看日志"
        echo "0. 退出"
        read -rp "请选择 [0-9]: " opt
        case "$opt" in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) restart_realm ;;
            4) add_rule_cli ;;
            5) list_rules_cli ;;
            6) export_rules ;;
            7) import_rules ;;
            8) panel_menu ;;
            9) journalctl -u realm --no-pager -n 100 || true ;;
            0) exit 0 ;;
            *) err "无效选项。" ;;
        esac
    done
}

main_menu
