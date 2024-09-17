#!/bin/bash

# Configuration
REPO_URL="https://github.com/smaghili/dnsproxy.git"
INSTALL_DIR="/etc/dnsproxy"
SCRIPT_PATH="/usr/local/bin/dns_proxy.py"  # نام فایل پایتون صحیح
SERVICE_NAME="dnsproxy"
WHITELIST_FILE="$INSTALL_DIR/whitelist.txt"
LOG_FILE="/var/log/dnsproxy.log"
DNS_PORT=53

# Function to run commands
run_command() {
    "$@"
}

# Function to check if a package is installed
check_installed() {
    dpkg -l "$1" &> /dev/null
}

# Function to install required packages
install_packages() {
    echo "Checking if Nginx, Python3, pip3, and git are installed..."
    local packages=("nginx" "python3" "python3-pip" "git")
    local to_install=()

    for package in "${packages[@]}"; do
        if ! check_installed "$package"; then
            to_install+=("$package")
        fi
    done

    if [ ${#to_install[@]} -ne 0 ]; then
        echo "Installing packages: ${to_install[@]}..."
        run_command apt-get update
        run_command apt-get install -y "${to_install[@]}"
    else
        echo "All required packages are already installed."
    fi

    echo "Installing Python packages dnslib and aiodns..."
    run_command pip3 install dnslib aiodns
}

# Function to clone the repository and set up the script
setup_dns_proxy() {
    echo "Cloning DNSProxy repository..."
    if [ ! -d "$INSTALL_DIR" ]; then
        run_command git clone "$REPO_URL" "$INSTALL_DIR"
    else
        echo "Install directory already exists. Pulling latest changes..."
        run_command bash -c "cd $INSTALL_DIR && git pull"
    fi

    echo "Copying dns_proxy.py to $SCRIPT_PATH..."
    run_command cp "$INSTALL_DIR/dns_proxy.py" "$SCRIPT_PATH"
    run_command chmod +x "$SCRIPT_PATH"
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
    run_command systemctl restart nginx
}

# Function to get server IP
get_server_ip() {
    local ip_address
    ip_address=$(hostname -I | awk '{print $1}')
    if [ -z "$ip_address" ]; then
        echo "Could not determine the server's IP address." >&2
        exit 1
    fi
    echo "$ip_address"
}

# Function to check and stop services using port
check_and_stop_services_using_port() {
    local port=$1
    echo "Checking for services using port $port..."
    if ss -tuln | grep ":$port" &> /dev/null; then
        echo "Port $port is in use. Attempting to stop related services..."
        local process_ids
        process_ids=$(lsof -ti:$port)
        if [ -n "$process_ids" ]; then
            for pid in $process_ids; do
                echo "Stopping process with PID $pid"
                run_command kill -9 "$pid"
            done
        fi
        run_command systemctl stop systemd-resolved
    else
        echo "Port $port is not in use."
    fi
}

# Function to set Google DNS
set_google_dns() {
    echo "Setting Google DNS..."
    local google_dns="nameserver 8.8.8.8\nnameserver 8.8.4.4"
    local current_dns
    current_dns=$(grep nameserver /etc/resolv.conf || true)
    if [[ -z "$current_dns" || "$current_dns" != *"8.8.8.8"* ]]; then
        echo -e "$google_dns" > /etc/resolv.conf
        echo "Google DNS has been set."
    else
        echo "Google DNS is already set."
    fi
}

# Function to create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/dnsproxy.service"
    echo "Creating systemd service for DNSProxy..."
    local service_content="
[Unit]
Description=DNSProxy Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_PATH --ip $(get_server_ip) --port $DNS_PORT --dns-allow-all
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
"
    echo "$service_content" > "$service_file"
    run_command systemctl daemon-reload
    run_command systemctl enable dnsproxy
}

# Function to create systemd service with whitelist
create_systemd_service_with_whitelist() {
    local service_file="/etc/systemd/system/dnsproxy.service"
    echo "Creating systemd service for DNSProxy with whitelist..."
    local service_content="
[Unit]
Description=DNSProxy Service with Whitelist
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_PATH --ip $(get_server_ip) --port $DNS_PORT --whitelist $WHITELIST_FILE
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
"
    echo "$service_content" > "$service_file"
    run_command systemctl daemon-reload
    run_command systemctl enable dnsproxy
}

# Function to start the service
start_service() {
    echo "Starting DNSProxy service..."
    run_command systemctl start dnsproxy
    sleep 2
    if systemctl is-active --quiet dnsproxy; then
        echo "DNSProxy service started successfully."
    else
        echo "Failed to start DNSProxy service. Check the logs for details." >&2
        exit 1
    fi
}

# Function to stop the service
stop_service() {
    echo "Stopping DNSProxy service..."
    run_command systemctl stop dnsproxy
    if [ $? -eq 0 ]; then
        echo "DNSProxy service stopped successfully."
    else
        echo "Failed to stop DNSProxy service." >&2
    fi
}

# Function to show the status
show_status() {
    if systemctl is-active --quiet dnsproxy; then
        echo "DNSProxy is running."
    else
        echo "DNSProxy is not running."
    fi
}

# Function to handle whitelist start
whitelist_start() {
    if [ ! -f "$WHITELIST_FILE" ]; then
        echo "Whitelist file not found. Creating an empty one."
        run_command touch "$WHITELIST_FILE"
    fi
    echo "Starting DNSProxy service with whitelist..."
    run_command systemctl stop dnsproxy
    create_systemd_service_with_whitelist
    start_service
}

# Function to display usage
usage() {
    echo "Usage: $0 {install|start|stop|restart|status|--whitelist start}"
    exit 1
}

# Main script logic

# Function to perform default install and start
default_install_and_start() {
    echo "No arguments provided. Running default install and start service."
    install_packages
    setup_dns_proxy
    create_nginx_config
    set_google_dns
    check_and_stop_services_using_port $DNS_PORT
    create_systemd_service
    start_service
}

# Check if no arguments are provided
if [ $# -eq 0 ]; then
    default_install_and_start
    exit 0
fi

# Main command processing
case "$1" in
    install)
        install_packages
        setup_dns_proxy
        create_nginx_config
        set_google_dns
        check_and_stop_services_using_port $DNS_PORT
        create_systemd_service
        start_service
        echo "Installation and setup completed."
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
            whitelist_start
        else
            echo "Usage: $0 --whitelist start"
            exit 1
        fi
        ;;
    *)
        usage
        ;;
esac

exit 0
