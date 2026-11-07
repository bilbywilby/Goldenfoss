#!/usr/bin/env python3
"""
Termux Master Ultra - Dashboard & API Server
Hardened loopback HUD with mandatory token auth and safe DAG execution.
"""

import os
import sys
import re
import hmac
import atexit
import subprocess
import threading
from functools import wraps
from flask import Flask, jsonify, request, render_template_string

app = Flask(__name__)

STORAGE_DIR = os.path.expanduser(os.environ.get("MASTER_STORAGE", "~/.termux_master"))
DAGS_DIR = os.path.join(STORAGE_DIR, "dags")
LOGS_DIR = os.path.join(STORAGE_DIR, "logs")
LOCKS_DIR = os.path.join(STORAGE_DIR, "locks")

AUTH_TOKEN = os.environ.get("MASTER_AUTH_TOKEN", "").strip()
HOST = os.environ.get("MASTER_HOST", "127.0.0.1")
PORT = int(os.environ.get("MASTER_PORT", "8081"))

MAX_LOG_BYTES = 5 * 1024 * 1024

if not HOST.startswith("127.") and HOST != "localhost":
    if not AUTH_TOKEN:
        sys.exit("Refusing to bind non-loopback without MASTER_AUTH_TOKEN.")
if not AUTH_TOKEN:
    sys.exit("Refusing to start: MASTER_AUTH_TOKEN is not set.\n"
             "Generate one with: python -c \"import secrets; print(secrets.token_hex(32))\"")

for path in (STORAGE_DIR, DAGS_DIR, LOGS_DIR, LOCKS_DIR):
    os.makedirs(path, mode=0o700, exist_ok=True)

_children = set()
_children_lock = threading.Lock()

def _reap(proc):
    try:
        proc.wait()
    finally:
        with _children_lock:
            _children.discard(proc)

@atexit.register
def _terminate_children():
    with _children_lock:
        procs = list(_children)
    for proc in procs:
        if proc.poll() is None:
            proc.terminate()
    for proc in procs:
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        provided = request.headers.get("X-Master-Token", "")
        if not hmac.compare_digest(provided, AUTH_TOKEN):
            return jsonify({"status": "error", "message": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return decorated

def sanitize_dag_name(dag_name):
    filename = os.path.basename(dag_name.strip())
    if not re.match(r"^[a-zA-Z0-9_\-]+\.py$", filename):
        raise ValueError("Invalid DAG filename. Must end in .py with only alphanumerics, underscores, or hyphens.")
    return filename

def _rotate_log_if_large(log_file):
    try:
        if os.path.exists(log_file) and os.path.getsize(log_file) > MAX_LOG_BYTES:
            os.replace(log_file, log_file + ".1")
    except OSError:
        pass

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Termux Master Ultra HUD</title>
<style>
body { background:#0f172a; color:#f8fafc; font-family:monospace; padding:1rem; margin:0; }
h1 { color:#38bdf8; font-size:1.25rem; }
.card { background:#1e293b; border:1px solid #334155; padding:1rem; border-radius:0.5rem; margin-bottom:1rem; }
button { background:#0284c7; color:white; border:none; padding:0.5rem 1rem; border-radius:0.25rem; cursor:pointer; }
pre { background:#020617; padding:0.75rem; border-radius:0.25rem; overflow-x:auto; color:#4ade80; }
input { background:#020617; color:#4ade80; border:1px solid #334155; padding:0.5rem; border-radius:0.25rem; width:100%%; }
</style></head><body>
<h1>Termux Master Ultra HUD</h1>
<div class="card"><h3>Storage</h3><p>{{ storage_dir }} — {{ dag_count }} DAGs</p></div>
<div class="card"><h3>Token</h3>
<input type="password" id="token" placeholder="X-Master-Token (stored locally only)">
<p style="font-size:0.75rem;color:#64748b">Sent only as a request header; never in URLs.</p></div>
<div class="card"><h3>Available DAGs</h3><ul>
{% for dag in dags %}<li><strong>{{ dag }}</strong>
<button onclick="runDag('{{ dag }}')">Run DAG</button></li>{% else %}
<li>No DAGs found in {{ dags_dir }}</li>{% endfor %}</ul></div>
<div class="card"><h3>Output Console</h3><pre id="console">Ready...</pre></div>
<script>
const tokenInput = document.getElementById('token');
tokenInput.value = localStorage.getItem('MASTER_AUTH_TOKEN') || '';
tokenInput.addEventListener('change', () =>
    localStorage.setItem('MASTER_AUTH_TOKEN', tokenInput.value.trim()));
async function runDag(dagName) {
    const consoleEl = document.getElementById('console');
    const token = localStorage.getItem('MASTER_AUTH_TOKEN') || '';
    consoleEl.textContent = 'Triggering ' + dagName + '...';
    try {
        const res = await fetch('/api/run', { method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Master-Token': token },
            body: JSON.stringify({ dag: dagName }) });
        consoleEl.textContent = JSON.stringify(await res.json(), null, 2);
    } catch (err) {
        consoleEl.textContent = 'Error: ' + err.message;
    }
}
</script></body></html>
"""

@app.route("/")
@require_auth
def index():
    dags = sorted(f for f in os.listdir(DAGS_DIR) if f.endswith(".py")) \
           if os.path.isdir(DAGS_DIR) else []
    return render_template_string(HTML_TEMPLATE, storage_dir=STORAGE_DIR,
                                  dags_dir=DAGS_DIR, dags=dags, dag_count=len(dags))

@app.route("/api/run", methods=["POST"])
@require_auth
def api_run_dag():
    data = request.get_json(silent=True) or {}
    raw_dag = data.get("dag")
    if not raw_dag:
        return jsonify({"status": "error", "message": "Missing 'dag' parameter"}), 400
    try:
        dag_filename = sanitize_dag_name(raw_dag)
    except ValueError as err:
        return jsonify({"status": "error", "message": str(err)}), 400
    dag_path = os.path.realpath(os.path.join(DAGS_DIR, dag_filename))
    if not dag_path.startswith(os.path.realpath(DAGS_DIR) + os.sep) \
            or not os.path.isfile(dag_path):
        return jsonify({"status": "error", "message": f"DAG '{dag_filename}' not found"}), 404
    log_file = os.path.join(LOGS_DIR, f"{dag_filename}.log")
    _rotate_log_if_large(log_file)
    try:
        with open(log_file, "a") as log_out:
            proc = subprocess.Popen([sys.executable, dag_path], stdout=log_out,
                                    stderr=subprocess.STDOUT, cwd=STORAGE_DIR,
                                    close_fds=True)
        with _children_lock:
            _children.add(proc)
        threading.Thread(target=_reap, args=(proc,), daemon=True).start()
        return jsonify({"status": "success", "message": f"DAG '{dag_filename}' started",
                        "pid": proc.pid, "log_file": log_file}), 200
    except Exception as e:
        return jsonify({"status": "error", "message": f"Failed to execute DAG: {e}"}), 500

@app.route("/api/status")
@require_auth
def api_status():
    with _children_lock:
        running = [{"pid": p.pid, "argv": " ".join(p.args)} for p in _children
                   if p.poll() is None]
    return jsonify({"status": "ok", "host": HOST, "port": PORT,
                    "running_dags": running, "child_count": len(running)})

if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False)
