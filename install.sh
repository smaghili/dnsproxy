#!/bin/bash

# Configuration
REPO_URL="https://github.com/smaghili/dnsproxy.git"
INSTALL_DIR="/etc/dnsproxy"
SCRIPT_PATH="/usr/local/bin/dnsproxy"
PYTHON_SCRIPT_PATH="/usr/local/bin/dns_proxy.py"
SERVICE_NAME="dnsproxy"
WHITELIST_FILE="$INSTALL_DIR/whitelist.txt"
PID_FILE="/var/run/dnsproxy.pid"
LOG_FILE="/var/log/dnsproxy.log"
DNS_PORT=53

# Function to check if a package is installed
is_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q '^ii'
}

# Function to install required packages
install_packages() {
    local packages=("nginx" "python3-pip" "git")
    for package in "${packages[@]}"; do
        if ! is_installed "$package"; then
            echo "Installing $package..."
            apt-get update
            apt-get install -y "$package"
        fi
    done
    
    # Install Python packages
    pip3 install dnslib aiodns
}

# Function to clone and install the project
clone_and_install() {
    echo "Cloning the project from GitHub..."
    if [ -d "$INSTALL_DIR" ]; then
        echo "Installation directory already exists. Removing it..."
        rm -rf "$INSTALL_DIR"
    fi
    git clone "$REPO_URL" "$INSTALL_DIR"
    
    echo "Installing DNS proxy script..."
    cp "$INSTALL_DIR/dns_proxy.py" "$PYTHON_SCRIPT_PATH"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH" "$PYTHON_SCRIPT_PATH"
    
    echo "Setting up whitelist file..."
    if [ ! -f "$WHITELIST_FILE" ]; then
        touch "$WHITELIST_FILE"
    fi
}

# Function to create Nginx configuration
create_nginx_config() {
    local nginx_conf="
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
"
    echo "Creating Nginx configuration..."
    echo "$nginx_conf" > /etc/nginx/nginx.conf
    systemctl restart nginx
}

# Function to get server IP
get_server_ip() {
    hostname -I | awk '{print $1}'
}

# Function to check and stop services using port
check_and_stop_services_using_port() {
    local port=$1
    echo "Checking for services using port $port..."
    if ss -tuln | grep -q ":$port "; then
        echo "Port $port is in use. Attempting to stop related services..."
        local process_ids=$(lsof -ti:"$port")
        if [ -n "$process_ids" ]; then
            for pid in $process_ids; do
                echo "Stopping process with PID $pid"
                kill -9 "$pid"
            done
        fi
        systemctl stop systemd-resolved
    else
        echo "Port $port is not in use."
    fi
}

# Function to set Google DNS
set_google_dns() {
    echo "Setting Google DNS..."
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf
}

# Function to start the service
start_service() {
    if [ -f "$PID_FILE" ]; then
        echo "DNSProxy is already running."
        return
    fi

    check_and_stop_services_using_port $DNS_PORT
    set_google_dns

    local ip_address=$(get_server_ip)
    local cmd="python3 $PYTHON_SCRIPT_PATH --ip $ip_address --port $DNS_PORT"
    
    if [ "$1" = "--whitelist" ]; then
        if [ ! -f "$WHITELIST_FILE" ]; then
            echo "Whitelist file not found. Creating an empty one."
            touch "$WHITELIST_FILE"
        fi
        cmd+=" --whitelist $WHITELIST_FILE"
    fi

    nohup $cmd > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    echo "DNSProxy started."
}

# Function to stop the service
stop_service() {
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE")
        rm -f "$PID_FILE"
        echo "DNSProxy stopped."
    else
        echo "DNSProxy is not running."
    fi
}

# Function to show the status
show_status() {
    if [ -f "$PID_FILE" ]; then
        echo "DNSProxy is running."
    else
        echo "DNSProxy is not running."
    fi
}

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Main script logic
case "$1" in
    install)
        install_packages
        clone_and_install
        create_nginx_config
        echo "Installation completed."
        echo "You can now use 'dnsproxy' command to manage the service."
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        start_service
        ;;
    status)
        show_status
        ;;
    --whitelist)
        if [ "$2" = "start" ]; then
            start_service --whitelist
        else
            echo "Usage: $0 --whitelist start"
        fi
        ;;
    *)
        echo "Usage: $0 {install|start|stop|restart|status|--whitelist start}"
        exit 1
        ;;
esac

exit 0
