#!/bin/bash
# from
# https://github.com/oneclickvirt/pve
# 2025.07.06
cd /mnt/wireless || exit 1
for i in {1..6}; do
    INSTALLED_PACKAGES=""
    FAILED_PACKAGES=""
    for deb in *.deb; do
        if apt install -y "./$deb" &>/dev/null; then
            INSTALLED_PACKAGES="$INSTALLED_PACKAGES $deb"
        else
            FAILED_PACKAGES="$FAILED_PACKAGES $deb"
        fi
    done
done
apt-get install -f -y &>/dev/null
if [ -n "$INSTALLED_PACKAGES" ]; then
    echo "Successfully installed packages:$INSTALLED_PACKAGES"
else
    echo "No new packages were installed"
fi
if [ -n "$FAILED_PACKAGES" ]; then
    echo "Failed to install packages:$FAILED_PACKAGES"
fi
rfkill unblock wifi
WIFI_INTERFACE=$(ip a | grep -o "wlp[^:]*" | head -1)
if [ -z "$WIFI_INTERFACE" ]; then
    echo "Could not detect WiFi interface"
    exit 1
fi
echo "Detected WiFi interface: $WIFI_INTERFACE"
while true; do
    read -p "Enter WiFi SSID: " SSID
    read -p "Enter WiFi Password: " PASSWORD
    echo "WiFi Configuration:"
    echo "SSID: $SSID"
    echo "Password: $PASSWORD"
    read -p "Is this correct? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        SCAN_RESULT=$(iwlist $WIFI_INTERFACE scan 2>/dev/null | grep -i "ESSID:\"$SSID\"")
        if [ -n "$SCAN_RESULT" ]; then
            break
        else
            echo "Error: WiFi network '$SSID' not found in available networks."
            echo "Please check the SSID and try again."
            echo "Available networks:"
            iwlist $WIFI_INTERFACE scan 2>/dev/null | grep "ESSID:" | grep -v "ESSID:\"\"" | sort | uniq
            echo "Please re-enter the WiFi credentials..."
        fi
    else
        echo "Please re-enter the WiFi credentials..."
    fi
done
rm -rf /etc/wpa_supplicant/wpa_supplicant.conf
wpa_passphrase "$SSID" "$PASSWORD" >> /etc/wpa_supplicant/wpa_supplicant.conf
if [ ! -f /etc/systemd/system/wpa_supplicant.service ]; then
    cat > /etc/systemd/system/wpa_supplicant.service << EOF
[Unit]
Description=WPA supplicant
Before=network.target
After=dbus.service
Wants=network.target
IgnoreOnIsolate=true

[Service]
Type=dbus
BusName=fi.w1.wpa_supplicant1
ExecStart=/sbin/wpa_supplicant -u -s -c /etc/wpa_supplicant/wpa_supplicant.conf -i $WIFI_INTERFACE
Restart=always

[Install]
WantedBy=multi-user.target
Alias=dbus-fi.w1.wpa_supplicant1.service
EOF
    systemctl daemon-reload
fi
if ! grep -q "^auto $WIFI_INTERFACE$" /etc/network/interfaces; then
    if grep -q "^iface $WIFI_INTERFACE inet \(auto\|static\|manual\)" /etc/network/interfaces; then
        echo "Found existing iface configuration for $WIFI_INTERFACE, commenting it out..."
        cp /etc/network/interfaces /etc/network/interfaces.backup
        sed -i "/^iface $WIFI_INTERFACE inet \(auto\|static\|manual\)/,/^$/s/^/#/" /etc/network/interfaces
    fi
    if grep -q '^iface vmbr0 inet static' /etc/network/interfaces && \
       ! grep -A 5 '^iface vmbr0 inet static' /etc/network/interfaces | grep -q '^\s*metric\s\+100'; then
        sed -i '/^iface vmbr0 inet static$/a\    metric 100' /etc/network/interfaces
    fi
    cat >> /etc/network/interfaces << EOF
auto $WIFI_INTERFACE
iface $WIFI_INTERFACE inet static
    address 192.168.124.144/24
    gateway 192.168.124.1
    dns-nameservers 144.144.144.144
    metric 10
EOF
# auto vmbr1
# iface vmbr1 inet static
#     address 172.16.100.1
#     netmask 255.255.255.0
#     bridge_ports none
#     bridge_stp off
#     bridge_fd 0
#     post-up echo 1 > /proc/sys/net/ipv4/ip_forward
#     post-up iptables -t nat -A POSTROUTING -s '172.16.100.0/24' -o $WIFI_INTERFACE -j MASQUERADE
#     post-down iptables -t nat -D POSTROUTING -s '172.16.100.0/24' -o $WIFI_INTERFACE -j MASQUERADE
# EOF
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p
    echo "Added network interface configuration for $WIFI_INTERFACE"
else
    echo "Network interface $WIFI_INTERFACE already configured"
fi
ifup $WIFI_INTERFACE
sleep 5
ip link set $WIFI_INTERFACE up
sleep 5
systemctl restart networking
sleep 5
echo "Waiting for network to stabilize..."
sleep 5
if [ ! -f /usr/local/bin/dns-setup.sh ]; then
    cat > /usr/local/bin/dns-setup.sh << 'EOF'
#!/bin/bash
sleep 50
DNS_SERVER="144.144.144.144"
RESOLV_CONF="/etc/resolv.conf"
rfkill unblock wifi
sleep 10
WPA_STATUS=$(systemctl is-active wpa_supplicant 2>/dev/null)
if [ "$WPA_STATUS" != "active" ] && [ "$WPA_STATUS" != "activating" ]; then
    systemctl start wpa_supplicant || systemctl restart wpa_supplicant
fi
if ! grep -q "^nameserver 8.8.8.8$" ${RESOLV_CONF}; then
    echo "nameserver 8.8.8.8" >>${RESOLV_CONF}
fi
if ! grep -q "^nameserver 144.144.144.144$" ${RESOLV_CONF}; then
    echo "nameserver 144.144.144.144" >>${RESOLV_CONF}
fi
sleep 5
systemctl restart networking
sleep 5
systemctl restart wpa_supplicant
EOF
    chmod +x /usr/local/bin/dns-setup.sh
fi
cat > /etc/systemd/system/dns-setup.service << EOF
[Unit]
Description=DNS Setup Service (One-time)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dns-setup.sh
User=root
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable dns-setup.service
DNS_SERVER="144.144.144.144"
RESOLV_CONF="/etc/resolv.conf"
rfkill unblock wifi
sleep 3
WPA_STATUS=$(systemctl is-active wpa_supplicant 2>/dev/null)
systemctl start wpa_supplicant
sleep 5
if ! grep -q "^nameserver 8.8.8.8$" ${RESOLV_CONF}; then
    echo "nameserver 8.8.8.8" >>${RESOLV_CONF}
fi
if ! grep -q "^nameserver 144.144.144.144$" ${RESOLV_CONF}; then
    echo "nameserver 144.144.144.144" >>${RESOLV_CONF}
fi
sleep 3
echo "Restarting wpa_supplicant and networking services..."
systemctl restart wpa_supplicant
sleep 5
systemctl restart networking
echo "Configuration completed. Rebooting in 15 seconds ..."
sleep 15 && reboot
