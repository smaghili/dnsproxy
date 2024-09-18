#!/bin/bash

ALLOWED_IPS_FILE="/etc/dnsproxy/allowed_ips.txt"

# Function to clear all iptables rules and allow all traffic
clear_and_allow_all() {
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    echo "All existing iptables rules have been cleared. No restrictions are applied."
}

# Clear all existing iptables rules initially
clear_and_allow_all

# Check if the file exists and is not empty (ignoring comments and blank lines)
if [ -f "$ALLOWED_IPS_FILE" ] && grep -q '[^[:space:]]' "$ALLOWED_IPS_FILE"; then
    # File exists and is not empty
    echo "Applying rules based on $ALLOWED_IPS_FILE"
    
    # Set default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # Allow loopback and established connections
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow access for IPs in the file
    while IFS= read -r line
    do
        # Skip empty lines and comments
        ip=$(echo "$line" | sed 's/[[:space:]]//g')
        if [[ -n "$ip" && "$ip" != \#* ]]; then
            iptables -A INPUT -s "$ip" -p tcp --dport 53 -j ACCEPT
            iptables -A INPUT -s "$ip" -p tcp --dport 80 -j ACCEPT
            iptables -A INPUT -s "$ip" -p tcp --dport 443 -j ACCEPT
            iptables -A INPUT -s "$ip" -p udp --dport 53 -j ACCEPT
        fi
    done < "$ALLOWED_IPS_FILE"

    # Block access for all other IPs
    iptables -A INPUT -p tcp --dport 53 -j DROP
    iptables -A INPUT -p tcp --dport 80 -j DROP
    iptables -A INPUT -p tcp --dport 443 -j DROP
    iptables -A INPUT -p udp --dport 53 -j DROP

    echo "Rules applied. Only IPs in $ALLOWED_IPS_FILE are allowed access to ports 53, 80, and 443."
else
    # File doesn't exist or is empty (or contains only comments/blank lines)
    echo "Warning: $ALLOWED_IPS_FILE does not exist or is empty. All IPs are allowed."
    clear_and_allow_all
fi

echo "iptables configuration completed."
