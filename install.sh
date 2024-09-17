#!/bin/bash

# Configuration
REPO_URL="https://github.com/smaghili/dnsproxy.git"
INSTALL_DIR="/etc/dnsproxy"
SCRIPT_PATH="/usr/local/bin/dnsproxy"
PYTHON_SCRIPT_PATH="/usr/local/bin/dns_proxy.py"
WHITELIST_FILE="$INSTALL_DIR/whitelist.txt"
PID_FILE="/var/run/dnsproxy.pid"
LOG_FILE="/var/log/dnsproxy.log"
DNS_PORT=53

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Function to install required packages
install_packages() {
    apt-get update
    apt-get install -y nginx python3-pip git
    pip3 install dnslib aiodns
}

# Function to clone and install the project
clone_and_install() {
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
    fi
    git clone "$REPO_URL" "$INSTALL_DIR"
    cp "$INSTALL_DIR/dns_proxy.py" "$PYTHON_SCRIPT_PATH"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH" "$PYTHON_SCRIPT_PATH"
    touch "$WHITELIST_FILE"
}

# Function to create Nginx configuration
create_nginx_config() {
    cat > /etc/nginx/nginx.conf <<EOL
worker_processes auto;
worker_rlimit_nofile 65535;
load_module /usr/lib/nginx/modules/ngx_stream_module.so;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        return 301 https://\$host\$request_uri;
    }
}

stream {
    server {
        resolver 1.1.1.1 ipv6=off;
        listen 443;
        ssl_preread on;
        proxy_pass \$ssl_preread_server_name:443;
        proxy_buffer_size 16k;
        proxy_socket_keepalive on;
    }
}
EOL
    systemctl restart nginx
}

# Function to set Google DNS and fix hostname resolution
set_dns_and_hostname() {
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf
    hostname_ip=$(hostname -I | awk '{print $1}')
    hostname_name=$(hostname)
    if ! grep -q "$hostname_name" /etc/hosts; then
        echo "$hostname_ip $hostname_name" >> /etc/hosts
    fi
}

# Function to start the service
start_service() {
    if [ -f "$PID_FILE" ]; then
        echo "DNSProxy is already running."
        return
    fi

    local ip_address=$(hostname -I | awk '{print $1}')
    nohup python3 "$PYTHON_SCRIPT_PATH" --ip "$ip_address" --port "$DNS_PORT" --whitelist "$WHITELIST_FILE" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "DNSProxy started."
}

# Main installation process
echo "Starting DNSProxy installation..."
install_packages
clone_and_install
create_nginx_config
set_dns_and_hostname
start_service

echo "Installation and setup completed."
echo "DNSProxy is now running with whitelist mode."
echo "To manage the service, use the following commands:"
echo "  - Stop DNSProxy: dnsproxy stop"
echo "  - Start DNSProxy: dnsproxy start"
echo "  - Restart DNSProxy: dnsproxy restart"
echo "  - Check DNSProxy status: dnsproxy status"
echo "To modify the whitelist, edit the file: $WHITELIST_FILE"

exit 0
