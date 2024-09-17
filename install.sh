#!/bin/bash

# Configuration
INSTALL_DIR="/etc/dnsproxy"
PYTHON_SCRIPT_PATH="$INSTALL_DIR/dns_server.py"
WHITELIST_FILE="$INSTALL_DIR/whitelist.txt"
PID_FILE="/var/run/dnsproxy.pid"
LOG_FILE="/var/log/dnsproxy.log"
DNS_PORT=53

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

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
    local cmd="python3 $PYTHON_SCRIPT_PATH --ip $ip_address --port $DNS_PORT"
    
    if [ "$1" = "--whitelist" ]; then
        if [ ! -f "$WHITELIST_FILE" ]; then
            echo "Whitelist file not found. Creating an empty one."
            touch "$WHITELIST_FILE"
        fi
        cmd+=" --whitelist $WHITELIST_FILE"
        echo "Starting DNSProxy in whitelist mode."
    else
        cmd+=" --dns-allow-all"
        echo "Starting DNSProxy in allow-all mode."
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

# Main script logic
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

exit 0
