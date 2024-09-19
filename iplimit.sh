#!/bin/bash

ALLOWED_IPS_FILE="/etc/dnsproxy/allowed_ips.txt"
RESTRICTED_PORTS="53,80,443"

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

# Initially clear all existing iptables rules
clear_and_allow_all

# Check if the file exists and is not empty (ignoring comments and blank lines)
if [ -f "$ALLOWED_IPS_FILE" ] && grep -q '[^[:space:]]' "$ALLOWED_IPS_FILE"; then
    # File exists and is not empty
    echo "Applying rules based on $ALLOWED_IPS_FILE"
    
    # Set default policies
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # Allow access for IPs in the file to all ports
    while IFS= read -r line
    do
        # Skip empty lines and comments
        ip=$(echo "$line" | sed 's/[[:space:]]//g')
        if [[ -n "$ip" && "$ip" != \#* ]]; then
            iptables -A INPUT -s "$ip" -j ACCEPT
        fi
    done < "$ALLOWED_IPS_FILE"

    # Block access to restricted ports for non-allowed IPs
    iptables -A INPUT -p tcp -m multiport --dports $RESTRICTED_PORTS -j DROP
    iptables -A INPUT -p udp -m multiport --dports $RESTRICTED_PORTS -j DROP

    echo "Rules applied."
    echo "IPs in $ALLOWED_IPS_FILE have access to all ports."
    echo "Other IPs are blocked from accessing ports $RESTRICTED_PORTS."
    echo "All other ports are open for all IPs."
else
    # File doesn't exist or is empty (or contains only comments/blank lines)
    echo "Warning: $ALLOWED_IPS_FILE does not exist or is empty. No restrictions applied."
    clear_and_allow_all
fi

echo "iptables configuration completed."
