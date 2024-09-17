#!/bin/bash

# Configuration
REPO_URL="https://github.com/smaghili/dnsproxy.git"
INSTALL_DIR="/etc/dnsproxy"
SCRIPT_PATH="/usr/local/bin/dns_proxy.py"
SERVICE_NAME="dnsproxy"
WHITELIST_FILE="$INSTALL_DIR/whitelist.txt"
PID_FILE="/var/run/dnsproxy.pid"
LOG_FILE="/var/log/dnsproxy.log"
DNS_PORT=53

# Function to run commands
run_command() {
    if [ "$2" = "capture_output" ]; then
        sudo "$1" 2>&1
    else
        sudo "$1"
    fi
}

# Function to check if a package is installed
is_installed() {
    dpkg -l "$1" | grep -q '^ii'
}

# Function to install required packages
install_packages() {
    local packages=("nginx" "python3-pip" "git")
    for package in "${packages[@]}"; do
        if ! is_installed "$package"; then
            echo "Installing $package..."
            run_command "apt-get update"
            run_command "apt-get install -y $package"
        fi
    done
    
    # Install Python packages
    run_command "pip3 install dnslib aiodns"
}

# Function to clone and install the project
clone_and_install() {
    echo "Cloning the project from GitHub..."
    if [ -d "$INSTALL_DIR" ]; then
        echo "Installation directory already exists. Removing it..."
        run_command "rm -rf $INSTALL_DIR"
    fi
    run_command "git clone $REPO_URL $INSTALL_DIR"
    
    echo "Installing DNS proxy script..."
    run_command "cp $INSTALL_DIR/dns_proxy.py $SCRIPT_PATH"
    run_command "chmod +x $SCRIPT_PATH"
    
    echo "Setting up whitelist file..."
    if [ ! -f "$WHITELIST_FILE" ]; then
        run_command "touch $WHITELIST_FILE"
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
    echo "$nginx_conf" | sudo tee /etc/nginx/nginx.conf > /dev/null
    run_command "systemctl restart nginx"
}

# Function to get server IP
get_server_ip() {
    local ip_address=$(run_command "hostname -I | awk '{print \$1}'" capture_output)
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
    if run_command "ss -tuln | grep :$port" capture_output > /dev/null; then
        echo "Port $port is in use. Attempting to stop related services..."
        local process_ids=$(run_command "lsof -ti:$port" capture_output)
        if [ -n "$process_ids" ]; then
            for pid in $process_ids; do
                echo "Stopping process with PID $pid"
                run_command "kill -9 $pid"
            done
        fi
        run_command "systemctl stop systemd-resolved"
    else
        echo "Port $port is not in use."
    fi
}

# Function to set Google DNS
set_google_dns() {
    echo "Setting Google DNS..."
    local google_dns="nameserver 8.8.8.8\nnameserver 8.8.4.4"
    local current_dns=$(run_command "grep nameserver /etc/resolv.conf" capture_output)
    if [ -z "$current_dns" ] || ! echo "$current_dns" | grep -q "8.8.8.8"; then
        echo "Updating DNS settings..."
        echo -e "$google_dns" | sudo tee /etc/resolv.conf > /dev/null
    else
        echo "Google DNS is already set."
    fi
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
    local cmd="python3 $SCRIPT_PATH --ip $ip_address --port $DNS_PORT"
    
    if [ "$1" = "--whitelist" ]; then
        if [ ! -f "$WHITELIST_FILE" ]; then
            echo "Whitelist file not found. Creating an empty one."
            sudo touch "$WHITELIST_FILE"
        fi
        cmd+=" --whitelist $WHITELIST_FILE"
    fi

    sudo nohup $cmd > "$LOG_FILE" 2>&1 &
    echo $! | sudo tee "$PID_FILE" > /dev/null
    echo "DNSProxy started."
}

# Function to stop the service
stop_service() {
    if [ -f "$PID_FILE" ]; then
        sudo kill $(cat "$PID_FILE")
        sudo rm -f "$PID_FILE"
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
case "$1" in
    install)
        install_packages
        clone_and_install
        create_nginx_config
        echo "Installation completed."
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
