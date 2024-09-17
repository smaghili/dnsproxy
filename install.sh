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
    apt-get update
    apt-get install -y nginx python3-pip git
    pip3 install dnslib dnspython cachetools
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

# Function to start the service
start_service() {
    if [ -f "$PID_FILE" ]; then
        echo "DNSProxy is already running."
        return
    fi

    check_and_stop_services_using_port $DNS_PORT
    set_dns_and_hostname

    local ip_address=$(hostname -I | awk '{print $1}')
    local cmd="python3 $PYTHON_SCRIPT_PATH --ip $ip_address --port $DNS_PORT --dns-allow-all"
    
    echo "Starting DNSProxy in allow-all mode."
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

# Main script logic
if [ $# -eq 0 ]; then
    # If no arguments are provided, perform installation and start the service
    install_packages
    clone_and_install
    create_nginx_config
    set_dns_and_hostname
    start_service
    echo "Installation and setup completed. DNSProxy is now running in allow-all mode."
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
