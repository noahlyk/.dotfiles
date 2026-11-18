#!/bin/bash

# Log to file for debugging
exec 2>>/tmp/ipaddr.sh.log
echo "[$(date)] Running ipaddr.sh" >>/tmp/ipaddr.sh.log

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo '{"text":"Error","tooltip":"jq not installed"}' >>/tmp/ipaddr.sh.log
    exit 1
fi

# Get first non-loopback IPv4 for main display
ip=$(ip -4 addr show up 2>>/tmp/ipaddr.sh.log | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v '127.0.0.1' | head -n 1)
if [ -n "$ip" ]; then
    main_text="$ip"
else
    main_text="No con"
fi

# Collect detailed connection info for tooltip
tooltip_lines=()
add_separator=0
while IFS=: read -r num iface _; do
    if [ "$iface" = "lo" ]; then continue; fi
    if [ $add_separator -eq 1 ]; then
        tooltip_lines+=("")
    fi
    add_separator=1
    status=$(ip link show "$iface" 2>>/tmp/ipaddr.sh.log | grep -oP '(?<=state\s)\w+' || echo "UNKNOWN")
    tooltip_lines+=("${iface} (${status})")
    # Add all IPv4 addresses
    while read -r ipv4; do
        tooltip_lines+=("  IPv4: $ipv4")
    done < <(ip -4 addr show "$iface" 2>>/tmp/ipaddr.sh.log | grep 'inet ' | awk '{print $2}')
    # Add all IPv6 addresses
    while read -r ipv6; do
        tooltip_lines+=("  IPv6: $ipv6")
    done < <(ip -6 addr show "$iface" 2>>/tmp/ipaddr.sh.log | grep 'inet6 ' | awk '{print $2}')
done < <(ip link show 2>>/tmp/ipaddr.sh.log | grep -E '^[0-9]+: ' | awk '{print $1 $2}')

# Join tooltip_lines with \r
tooltip=$(IFS=$'\r'; echo "${tooltip_lines[*]}")

# Output JSON for Waybar
jq -nc --arg text "$main_text" --arg tooltip "$tooltip" '{ipv4: $text, tooltip: $tooltip}' 2>>/tmp/ipaddr.sh.log
