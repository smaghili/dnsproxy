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

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Function to install required packages
install_packages() {
    local packages_to_install=()
    for package in nginx python3-pip git; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            packages_to_install+=("$package")
        fi
    done

    if [ ${#packages_to_install[@]} -ne 0 ]; then
        echo "Installing packages: ${packages_to_install[*]}"
        apt-get update
        apt-get install -y "${packages_to_install[@]}"
    else
        echo "All required system packages are already installed."
    fi

    # Install Python packages only if not already installed
    if ! python3 -c "import dnslib, dns, cachetools" 2>/dev/null; then
        echo "Installing required Python packages..."
        pip3 install --no-warn-script-location dnslib dnspython cachetools
    else
        echo "All required Python packages are already installed."
    fi
}

# Function to clone and install the project
clone_and_install() {
    if [ -d "$INSTALL_DIR" ]; then
        echo "Updating existing installation..."
        cd "$INSTALL_DIR"
        git pull
    else
        echo "Cloning the project..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    cp "$INSTALL_DIR/dns_proxy.py" "$PYTHON_SCRIPT_PATH"
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH" "$PYTHON_SCRIPT_PATH"
    [ ! -f "$WHITELIST_FILE" ] && touch "$WHITELIST_FILE"
}

# Function to create optimized Nginx configuration
create_nginx_config() {
    cat > /etc/nginx/nginx.conf <<EOL
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_buffers 16 8k;
    gzip_http_version 1.1;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        return 301 https://\$host\$request_uri;
    }
}

stream {
    upstream backend {
        server 127.0.0.1:8443;
    }

    server {
        listen 443;
        proxy_pass backend;
        ssl_preread on;
        proxy_buffer_size 16k;
        proxy_socket_keepalive on;
        tcp_nodelay on;
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

# Function to check and stop services using port
check_and_stop_services_using_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        echo "Port $port is in use. Stopping related services..."
        systemctl stop systemd-resolved
        kill $(lsof -t -i:$port) 2>/dev/null
    fi
}

# Function to start the service
start_service() {
    if [ -f "$PID_FILE" ]; then
        if ps -p $(cat "$PID_FILE") > /dev/null 2>&1; then
            echo "DNSProxy is already running."
            return
        else
            echo "Stale PID file found. Removing it."
            rm -f "$PID_FILE"
        fi
    fi

    check_and_stop_services_using_port $DNS_PORT
    set_dns_and_hostname

    local ip_address=$(hostname -I | awk '{print $1}')
    local cmd="python3 $PYTHON_SCRIPT_PATH --ip $ip_address --port $DNS_PORT --dns-allow-all"
    
    echo "Starting DNSProxy in allow-all mode."
    nohup $cmd > "$LOG_FILE" 2>&1 &
    local pid=$!
    echo $pid > "$PID_FILE"
    
    sleep 2
    if ps -p $pid > /dev/null 2>&1; then
        echo "DNSProxy started successfully with PID $pid."
        if ! lsof -i :53 | grep -q LISTEN; then
            echo "Warning: DNSProxy is running but not listening on port 53."
            echo "Check $LOG_FILE for errors."
            tail -n 20 "$LOG_FILE"
        fi
    else
        echo "Failed to start DNSProxy. Check $LOG_FILE for errors."
        tail -n 20 "$LOG_FILE"
    fi
}

# Function to stop the service
stop_service() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p $pid > /dev/null 2>&1; then
            echo "Stopping DNSProxy..."
            kill $pid
            sleep 2
            if ps -p $pid > /dev/null 2>&1; then
                echo "DNSProxy did not stop gracefully. Forcing stop."
                kill -9 $pid
            fi
        else
            echo "DNSProxy is not running, but PID file exists. Cleaning up."
        fi
        rm -f "$PID_FILE"
        echo "DNSProxy stopped."
    else
        echo "DNSProxy is not running."
    fi
}

# Function to show the status
show_status() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p $pid > /dev/null 2>&1; then
            echo "DNSProxy is running with PID $pid."
            if lsof -i :53 | grep -q LISTEN; then
                echo "DNSProxy is listening on port 53."
            else
                echo "Warning: DNSProxy is running but not listening on port 53."
            fi
        else
            echo "DNSProxy is not running, but a stale PID file exists."
        fi
    else
        echo "DNSProxy is not running."
    fi
}

# Main script logic
if [ $# -eq 0 ]; then
    install_packages
    clone_and_install
    create_nginx_config
    set_dns_and_hostname
    stop_service  # Ensure any existing instance is stopped
    start_service
    show_status
else
    case "$1" in
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
            echo "Usage: $0 {start|stop|restart|status|--whitelist start}"
            exit 1
            ;;
    esac
fi

exit 0
