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

# ... (previous functions remain unchanged)

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
ALLOWED_IPS_FILE="$INSTALL_DIR/allowed_ips.txt"
DNS_PORT=53

get_server_ip() {
    hostname -I | awk '{print \$1}'
}

switch_to_whitelist_mode() {
    local use_allowed_ips=\$1
    echo "Switching to whitelist mode..."
    systemctl stop $SERVICE_NAME.service
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    
    local allowed_ips_arg=""
    if [ "\$use_allowed_ips" = "true" ]; then
        allowed_ips_arg="--allowed-ips \$ALLOWED_IPS_FILE"
    fi
    
    cat > /etc/systemd/system/$SERVICE_NAME.service << EOL
[Unit]
Description=DNSProxy Service with Whitelist
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_PATH --ip \$(get_server_ip) --port $DNS_PORT --whitelist $WHITELIST_FILE \$allowed_ips_arg
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME.service
    echo "DNSProxy is now running in whitelist mode."
    if [ "\$use_allowed_ips" = "true" ]; then
        echo "IP restriction is enabled."
    else
        echo "IP restriction is disabled."
    fi
}

switch_to_dns_allow_all_mode() {
    local use_allowed_ips=\$1
    echo "Switching to dns-allow-all mode..."
    systemctl stop $SERVICE_NAME.service
    rm -f /etc/systemd/system/$SERVICE_NAME.service
    
    local allowed_ips_arg=""
    if [ "\$use_allowed_ips" = "true" ]; then
        allowed_ips_arg="--allowed-ips \$ALLOWED_IPS_FILE"
    fi
    
    cat > /etc/systemd/system/$SERVICE_NAME.service << EOL
[Unit]
Description=DNSProxy Service with DNS Allow All
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $SCRIPT_PATH --ip \$(get_server_ip) --port $DNS_PORT --dns-allow-all \$allowed_ips_arg
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable $SERVICE_NAME
    systemctl start $SERVICE_NAME.service
    echo "DNSProxy is now running in dns-allow-all mode."
    if [ "\$use_allowed_ips" = "true" ]; then
        echo "IP restriction is enabled."
    else
        echo "IP restriction is disabled."
    fi
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
            if [ "\$3" = "--allowed-ips" ]; then
                switch_to_whitelist_mode true
            else
                switch_to_whitelist_mode false
            fi
        elif [ "\$2" = "--dns-allow-all" ]; then
            if [ "\$3" = "--allowed-ips" ]; then
                switch_to_dns_allow_all_mode true
            else
                switch_to_dns_allow_all_mode false
            fi
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
        echo "Usage: \$0 {start|stop|restart|status|start --whitelist [--allowed-ips]|start --dns-allow-all [--allowed-ips]|uninstall}"
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
    echo "Use 'dnsproxy {start|stop|restart|status|start --whitelist [--allowed-ips]|start --dns-allow-all [--allowed-ips]|uninstall}' to manage the service."
}

# Main script logic
if [ $# -eq 0 ]; then
    install_dnsproxy
else
    echo "Usage: $0"
    echo "This script will automatically install and set up DNSProxy."
    echo "After installation, use 'dnsproxy {start|stop|restart|status|start --whitelist [--allowed-ips]|start --dns-allow-all [--allowed-ips]|uninstall}' to manage the service."
    exit 1
fi

exit 0
