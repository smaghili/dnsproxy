#!/bin/bash

# Configuration
REPO_URL="https://github.com/smaghili/dnsproxy.git"
INSTALL_DIR="/etc/dnsproxy"
SCRIPT_PATH="/usr/local/bin/dns_proxy.py"
DNSPROXY_SHELL_SCRIPT="/usr/local/bin/dnsproxy"
SERVICE_NAME="dnsproxy"
WHITELIST_FILE="$INSTALL_DIR/whitelist.txt"
ALLOWED_IPS_FILE="$INSTALL_DIR/allowed_ips.txt"
LOG_FILE="/var/log/dnsproxy.log"
DNS_PORT=53
IP_RESTRICTION_FLAG="$INSTALL_DIR/ip_restriction_enabled"

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
        run_command sudo apt-get update
        run_command sudo apt-get install -y "${to_install[@]}"
    fi

    # Install Python packages including Flask
    run_command sudo pip3 install dnslib aiodns flask
    echo "All required packages are installed."
}

# Function to clone or update the repository and set up the script
setup_dns_proxy() {
    if [ ! -d "$INSTALL_DIR" ]; then
        run_command sudo git clone "$REPO_URL" "$INSTALL_DIR"
    else
        (cd "$INSTALL_DIR" && run_command sudo git pull)
    fi

    run_command sudo cp "$INSTALL_DIR/dns_proxy.py" "$SCRIPT_PATH"
    run_command sudo chmod +x "$SCRIPT_PATH"
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
    echo "$nginx_conf" | run_command sudo tee /etc/nginx/nginx.conf > /dev/null
    run_command sudo systemctl restart nginx
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
        run_command sudo lsof -ti:$port | xargs -r sudo kill -9
        run_command sudo systemctl stop systemd-resolved
    fi
}

# Function to set Google DNS
set_google_dns() {
    local google_dns="nameserver 8.8.8.8\nnameserver 8.8.4.4"
    local current_dns=$(grep nameserver /etc/resolv.conf || true)
    if [[ -z "$current_dns" || "$current_dns" != *"8.8.8.8"* ]]; then
        echo -e "$google_dns" | run_command sudo tee /etc/resolv.conf > /dev/null
        echo "Google DNS has been set."
    fi
}

# Function to switch modes and apply IP restriction
switch_to_mode() {
    local mode=$1
    echo "Switching to $mode mode..."
    sudo systemctl stop $SERVICE_NAME.service
    sudo rm -f /etc/systemd/system/$SERVICE_NAME.service

    # Check the IP restriction flag
    local use_allowed_ips="false"
    if [ -f "$IP_RESTRICTION_FLAG" ]; then
        use_allowed_ips="true"
    fi

    local allowed_ips_arg=""
    if [ "$use_allowed_ips" = "true" ]; then
        allowed_ips_arg="--allowed-ips $ALLOWED_IPS_FILE"
    fi

    local whitelist_arg=""
    if [ "$mode" = "whitelist" ]; then
        whitelist_arg="--whitelist $WHITELIST_FILE"
    else
        whitelist_arg="--dns-allow-all"
    fi

    cat << EOL | sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null
[Unit]
Description=DNSProxy Service with $mode
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_PATH --ip $(get_server_ip) --port $DNS_PORT $whitelist_arg $allowed_ips_arg
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable $SERVICE_NAME
    sudo systemctl start $SERVICE_NAME.service
    echo "DNSProxy is now running in $mode mode."
    if [ "$use_allowed_ips" = "true" ]; then
        echo "IP restriction is enabled."
    else
        echo "IP restriction is disabled."
    fi
}

# Function to get current mode
get_current_mode() {
    if grep -q "dns-allow-all" /etc/systemd/system/$SERVICE_NAME.service; then
        echo "dns-allow-all"
    else
        echo "whitelist"
    fi
}

# Function to enable IP restriction
enable_ip_restriction() {
    echo "Enabling IP restriction..."
    touch "$IP_RESTRICTION_FLAG"
    local current_mode=$(get_current_mode)
    switch_to_mode "$current_mode"
}

# Function to disable IP restriction
disable_ip_restriction() {
    echo "Disabling IP restriction..."
    rm -f "$IP_RESTRICTION_FLAG"
    local current_mode=$(get_current_mode)
    switch_to_mode "$current_mode"
}

# Function to check IP restriction status
ip_restriction_status() {
    if sudo systemctl show -p ExecStart --value $SERVICE_NAME.service | grep -q -- "--allowed-ips"; then
        echo "IP restriction is currently enabled."
    else
        echo "IP restriction is currently disabled."
    fi
}

# Function to uninstall DNSProxy
uninstall_dnsproxy() {
    echo "Uninstalling DNSProxy..."

    sudo systemctl stop $SERVICE_NAME.service
    sudo systemctl disable $SERVICE_NAME.service

    sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
    sudo systemctl daemon-reload

    sudo rm -rf $INSTALL_DIR
    sudo rm -f $SCRIPT_PATH
    sudo rm -f $DNSPROXY_SHELL_SCRIPT
    sudo rm -f $LOG_FILE
    sudo rm -f $IP_RESTRICTION_FLAG

    echo "DNSProxy has been completely uninstalled."
    exit 0
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
    echo "$service_content" | run_command sudo tee "$service_file" > /dev/null
    run_command sudo systemctl daemon-reload
    run_command sudo systemctl enable $SERVICE_NAME
    echo "Systemd service created."
}

# Function to create the web panel systemd service
create_web_panel_service() {
    local web_service_file="/etc/systemd/system/dnsproxy-web-panel.service"
    echo "Creating systemd service for DNS Proxy Web Panel..."
    local web_service_content="
[Unit]
Description=DNS Proxy Web Panel
After=network.target

[Service]
ExecStart=/usr/bin/python3 /etc/dnsproxy/web_panel.py
Restart=always
User=root
Environment=FLASK_APP=/etc/dnsproxy/web_panel.py

[Install]
WantedBy=multi-user.target
"
    echo "$web_service_content" | run_command sudo tee "$web_service_file" > /dev/null
    run_command sudo systemctl daemon-reload
    run_command sudo systemctl enable dnsproxy-web-panel
    run_command sudo systemctl start dnsproxy-web-panel.service
    echo "Systemd service for DNS Proxy Web Panel created and started."
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
    run_command sudo systemctl start $SERVICE_NAME
    create_web_panel_service  # Added this line to create the web panel service
    echo "DNSProxy installation and setup completed."
    echo "Use 'dnsproxy {start|stop|restart|status|start --whitelist|start --dns-allow-all|enable ip|disable ip|status ip|uninstall}' to manage the service."
}

# Update the dnsproxy shell script
update_dnsproxy_shell_script() {
    cat << EOF | run_command sudo tee "$DNSPROXY_SHELL_SCRIPT" > /dev/null
#!/bin/bash

INSTALL_DIR="$INSTALL_DIR"
SCRIPT_PATH="$SCRIPT_PATH"
SERVICE_NAME="$SERVICE_NAME"
WHITELIST_FILE="$WHITELIST_FILE"
ALLOWED_IPS_FILE="$ALLOWED_IPS_FILE"
DNS_PORT=$DNS_PORT
IP_RESTRICTION_FLAG="$IP_REstriction_flag"

$(declare -f get_server_ip)
$(declare -f switch_to_mode)
$(declare -f get_current_mode)
$(declare -f enable_ip_restriction)
$(declare -f disable_ip_restriction)
$(declare -f ip_restriction_status)
$(declare -f uninstall_dnsproxy)

case "\$1" in
    start)
        if [ "\$2" = "--whitelist" ]; then
            switch_to_mode "whitelist"
        elif [ "\$2" = "--dns-allow-all" ]; then
            switch_to_mode "dns-allow-all"
        else
            sudo systemctl start $SERVICE_NAME.service
        fi
        ;;
    stop)
        sudo systemctl stop $SERVICE_NAME.service
        ;;
    restart)
        sudo systemctl restart $SERVICE_NAME.service
        ;;
    status)
        if [ "\$2" = "ip" ]; then
            ip_restriction_status
        else
            sudo systemctl status $SERVICE_NAME.service
        fi
        ;;
    enable)
        if [ "\$2" = "ip" ]; then
            enable_ip_restriction
        else
            echo "Usage: \$0 enable ip"
        fi
        ;;
    disable)
        if [ "\$2" = "ip" ]; then
            disable_ip_restriction
        else
            echo "Usage: \$0 disable ip"
        fi
        ;;
    uninstall)
        uninstall_dnsproxy
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status|start --whitelist|start --dns-allow-all|enable ip|disable ip|status ip|uninstall}"
        exit 1
        ;;
esac

exit 0
EOF
    run_command sudo chmod +x "$DNSPROXY_SHELL_SCRIPT"
    echo "DNSProxy shell script updated."
}

# Main script logic
if [ $# -eq 0 ]; then
    install_dnsproxy
else
    echo "Usage: $0"
    echo "This script will automatically install and set up DNSProxy."
    echo "After installation, use 'dnsproxy {start|stop|restart|status|start --whitelist|start --dns-allow-all|enable ip|disable ip|status ip|uninstall}' to manage the service."
    exit 1
fi

exit 0
