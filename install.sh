#!/bin/bash

# Configuration
REPO_URL="https://github.com/smaghili/dnsproxy.git"
INSTALL_DIR="/etc/dnsproxy"
SCRIPT_PATH="/usr/local/bin/dns_proxy.py"
DNSPROXY_SHELL_SCRIPT="/usr/local/bin/dnsproxy"
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

# Function to clone or update the repository and set up the script
setup_dns_proxy() {
    echo "Cloning or updating DNSProxy repository..."
    if [ ! -d "$INSTALL_DIR" ]; then
        run_command git clone "$REPO_URL" "$INSTALL_DIR"
    else
        run_command bash -c "cd $INSTALL_DIR && git pull"
    fi

    echo "Copying dns_proxy.py to $SCRIPT_PATH..."
    run_command cp "$INSTALL_DIR/dns_proxy.py" "$SCRIPT_PATH"
    run_command chmod +x "$SCRIPT_PATH"

    # Create dnsproxy shell script
    echo "Creating dnsproxy shell script..."
    cat > "$DNSPROXY_SHELL_SCRIPT" << EOF
#!/bin/bash

case "\$1" in
    start)
        systemctl start $SERVICE_NAME.service
        ;;
    stop)
        systemctl stop $SERVICE_NAME.service
        ;;
    restart)
        systemctl restart $SERVICE_NAME.service
        ;;
    status)
        systemctl status $SERVICE_NAME.service
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOF
    run_command chmod +x "$DNSPROXY_SHELL_SCRIPT"
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
    local service_file="/etc/systemd/system/$SERVICE_NAME.service"
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
    run_command systemctl enable $SERVICE_NAME
}

# Main installation function
install_dnsproxy() {
    install_packages
    setup_dns_proxy
    create_nginx_config
    set_google_dns
    check_and_stop_services_using_port $DNS_PORT
    create_systemd_service
    systemctl start $SERVICE_NAME.service
    echo "Installation and setup completed."
    echo "Use 'dnsproxy {start|stop|restart|status}' to manage the service."
}

# Main script logic
if [ $# -eq 0 ]; then
    install_dnsproxy
else
    echo "Usage: $0"
    echo "This script will automatically install and set up DNSProxy."
    echo "After installation, use 'dnsproxy {start|stop|restart|status}' to manage the service."
    exit 1
fi

exit 0
