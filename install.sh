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
    local packages=("nginx" "python3" "python3-pip" "git")
    local to_install=()

    for package in "${packages[@]}"; do
        if ! check_installed "$package"; then
            to_install+=("$package")
        fi
    done

    if [ ${#to_install[@]} -ne 0 ]; then
        echo "Installing packages: ${to_install[@]}..."
        run_command apt-get update >/dev/null 2>&1
        run_command apt-get install -y "${to_install[@]}" >/dev/null 2>&1
    fi

    # Install Python packages
    pip3 install dnslib aiodns >/dev/null 2>&1
    echo "All required packages are installed."
}

# Function to clone or update the repository and set up the script
setup_dns_proxy() {
    if [ ! -d "$INSTALL_DIR" ]; then
        git clone "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1
    else
        (cd "$INSTALL_DIR" && git pull >/dev/null 2>&1)
    fi

    cp "$INSTALL_DIR/dns_proxy.py" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
    echo "DNSProxy repository setup completed."
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
    echo "$nginx_conf" > /etc/nginx/nginx.conf
    systemctl restart nginx >/dev/null 2>&1
    echo "Nginx configuration updated."
}

# Function to get server IP
get_server_ip() {
    hostname -I | awk '{print $1}'
}

# Function to check and stop services using port
check_and_stop_services_using_port() {
    local port=$1
    if ss -tuln | grep ":$port" &> /dev/null; then
        lsof -ti:$port | xargs -r kill -9 >/dev/null 2>&1
        systemctl stop systemd-resolved >/dev/null 2>&1
    fi
}

# Function to set Google DNS
set_google_dns() {
    local google_dns="nameserver 8.8.8.8\nnameserver 8.8.4.4"
    local current_dns=$(grep nameserver /etc/resolv.conf || true)
    if [[ -z "$current_dns" || "$current_dns" != *"8.8.8.8"* ]]; then
        echo -e "$google_dns" > /etc/resolv.conf
        echo "Google DNS has been set."
    fi
}

# Function to create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/$SERVICE_NAME.service"
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
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable $SERVICE_NAME >/dev/null 2>&1
    echo "Systemd service created."
}

# Update the dnsproxy shell script
update_dnsproxy_shell_script() {
    cat > "$DNSPROXY_SHELL_SCRIPT" << EOF
#!/bin/bash

INSTALL_DIR="/etc/dnsproxy"
SCRIPT_PATH="/usr/local/bin/dns_proxy.py"
SERVICE_NAME="dnsproxy"
WHITELIST_FILE="$INSTALL_DIR/whitelist.txt"
DNS_PORT=53

get_server_ip() {
    hostname -I | awk '{print \$1}'
}

get_current_mode() {
    if grep -q -- "--dns-allow-all" /etc/systemd/system/$SERVICE_NAME.service; then
        echo "dns-allow-all"
    elif grep -q -- "--whitelist" /etc/systemd/system/$SERVICE_NAME.service; then
        echo "whitelist"
    else
        echo "unknown"
    fi
}

switch_to_whitelist_mode() {
    local current_mode=\$(get_current_mode)
    if [ "\$current_mode" = "whitelist" ]; then
        echo "DNSProxy is already running in whitelist mode."
        return
    fi

    echo "Switching to whitelist mode..."
    systemctl stop $SERVICE_NAME.service
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    
    cat > /etc/systemd/system/$SERVICE_NAME.service << EOL
[Unit]
Description=DNSProxy Service with Whitelist
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_PATH --ip \$(get_server_ip) --port $DNS_PORT --whitelist $WHITELIST_FILE
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME.service
    echo "DNSProxy is now running in whitelist mode."
}

switch_to_dns_allow_all_mode() {
    local current_mode=\$(get_current_mode)
    if [ "\$current_mode" = "dns-allow-all" ]; then
        echo "DNSProxy is already running in dns-allow-all mode."
        return
    fi

    echo "Switching to dns-allow-all mode..."
    systemctl stop $SERVICE_NAME.service
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    
    cat > /etc/systemd/system/$SERVICE_NAME.service << EOL
[Unit]
Description=DNSProxy Service with DNS Allow All
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_PATH --ip \$(get_server_ip) --port $DNS_PORT --dns-allow-all
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME.service
    echo "DNSProxy is now running in dns-allow-all mode."
}

uninstall_dnsproxy() {
    echo "Uninstalling DNSProxy..."
    
    systemctl stop $SERVICE_NAME.service
    systemctl disable $SERVICE_NAME.service
    
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    systemctl daemon-reload
    
    rm -rf $INSTALL_DIR
    rm -f $SCRIPT_PATH
    rm -f $DNSPROXY_SHELL_SCRIPT
    rm -f $LOG_FILE
    
    echo "DNSProxy has been completely uninstalled."
    exit 0
}

case "\$1" in
    start)
        if [ "\$2" = "--whitelist" ]; then
            switch_to_whitelist_mode
        elif [ "\$2" = "--dns-allow-all" ]; then
            switch_to_dns_allow_all_mode
        else
            systemctl start $SERVICE_NAME.service
        fi
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
    uninstall)
        uninstall_dnsproxy
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status|start --whitelist|start --dns-allow-all|uninstall}"
        exit 1
        ;;
esac

exit 0
EOF
    chmod +x "$DNSPROXY_SHELL_SCRIPT"
    echo "DNSProxy shell script updated."
}

# Main installation function
install_dnsproxy() {
    install_packages
    setup_dns_proxy
    create_nginx_config
    set_google_dns
    check_and_stop_services_using_port $DNS_PORT
    create_systemd_service
    update_dnsproxy_shell_script
    systemctl start $SERVICE_NAME.service >/dev/null 2>&1
    echo "DNSProxy installation and setup completed."
    echo "Use 'dnsproxy {start|stop|restart|status|start --whitelist|start --dns-allow-all|uninstall}' to manage the service."
}

# Main script logic
if [ $# -eq 0 ]; then
    install_dnsproxy
else
    echo "Usage: $0"
    echo "This script will automatically install and set up DNSProxy."
    echo "After installation, use 'dnsproxy {start|stop|restart|status|start --whitelist|start --dns-allow-all|uninstall}' to manage the service."
    exit 1
fi

exit 0
