from flask import Flask, render_template, request, jsonify, redirect, url_for, session
import subprocess
import os
from functools import wraps

app = Flask(__name__)
app.secret_key = 'your_secret_key_here'  # Change this to a secure random key

INSTALL_DIR = "/etc/dnsproxy"
WHITELIST_FILE = f"{INSTALL_DIR}/whitelist.txt"
ALLOWED_IPS_FILE = f"{INSTALL_DIR}/allowed_ips.txt"
IP_RESTRICTION_FLAG = f"{INSTALL_DIR}/ip_restriction_enabled"

# Replace this with a secure method to store and validate credentials
ADMIN_USERNAME = "admin"
ADMIN_PASSWORD = "password"  # Change this to a strong password

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'logged_in' not in session:
            return redirect(url_for('login', next=request.url))
        return f(*args, **kwargs)
    return decorated_function

def run_command(command):
    result = subprocess.run(command, shell=True, capture_output=True, text=True)
    return result.stdout.strip()

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        if username == ADMIN_USERNAME and password == ADMIN_PASSWORD:
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            return render_template('login.html', error='Invalid credentials')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
@login_required
def index():
    return render_template('index.html')

@app.route('/api/status')
@login_required
def get_status():
    status = run_command("systemctl is-active dnsproxy")
    service_file = "/etc/systemd/system/dnsproxy.service"
    
    with open(service_file, 'r') as f:
        service_content = f.read()
    
    if "--dns-allow-all" in service_content:
        mode = "DNS Allow All"
    elif "--whitelist" in service_content:
        mode = "Whitelist"
    else:
        mode = "Unknown"
    
    ip_restriction = "ACTIVE" if os.path.exists(IP_RESTRICTION_FLAG) else "INACTIVE"
    
    return jsonify({
        "status": status, 
        "mode": mode,
        "ip_restriction": ip_restriction
    })

@app.route('/api/toggle', methods=['POST'])
@login_required
def toggle_service():
    action = request.json['action']
    mode = request.json.get('mode', '')
    if mode:
        result = run_command(f"dnsproxy {action} --{mode}")
    else:
        result = run_command(f"dnsproxy {action}")
    return jsonify({"result": result})

@app.route('/api/toggle_ip_restriction', methods=['POST'])
@login_required
def toggle_ip_restriction():
    action = request.json['action']
    if action == 'enable':
        result = run_command("dnsproxy enable ip")
    else:
        result = run_command("dnsproxy disable ip")
    return jsonify({"result": result})

@app.route('/api/whitelist')
@login_required
def get_whitelist():
    with open(WHITELIST_FILE, 'r') as f:
        domains = f.read().splitlines()
    return jsonify({"domains": domains})

@app.route('/api/whitelist', methods=['POST'])
@login_required
def update_whitelist():
    domains = request.json['domains']
    with open(WHITELIST_FILE, 'w') as f:
        f.write('\n'.join(domains))
    run_command("dnsproxy restart")
    return jsonify({"result": "Whitelist updated and service restarted"})

@app.route('/api/allowed_ips')
@login_required
def get_allowed_ips():
    with open(ALLOWED_IPS_FILE, 'r') as f:
        ips = f.read().splitlines()
    return jsonify({"ips": ips})

@app.route('/api/allowed_ips', methods=['POST'])
@login_required
def update_allowed_ips():
    ips = request.json['ips']
    with open(ALLOWED_IPS_FILE, 'w') as f:
        f.write('\n'.join(ips))
    run_command("dnsproxy restart")
    return jsonify({"result": "Allowed IPs updated and service restarted"})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
