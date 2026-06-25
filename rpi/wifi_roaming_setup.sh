#!/usr/bin/env bash
# wifi_roaming_setup.sh
# Roaming USB Wi-Fi dongle setup for Raspberry Pi nodes (netplan + power-save off + DHCP kick service).
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

set -euo pipefail

IFACE="wlxXXXXXXXXXXXX"     # nazwa dongla (od jego MAC; ta sama na kazdej malinie)
SSID="YOUR_SSID"
HIDDEN="false"             # SSID rozglaszany - WYMAGANE dla tego dongla
KEYMGMT="psk"             # WPA2=psk ; czyste WPA3 -> "sae"
REGDOM="PL"

read -rs -p "Password for network ${SSID}: " WIFI_PASS; echo
[ -n "$WIFI_PASS" ] || { echo "Empty password - aborting."; exit 1; }

echo ">>> [1/6] Tools (iw, rfkill, wpasupplicant, busybox)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iw rfkill wpasupplicant busybox

echo ">>> [2/6] netplan /etc/netplan/60-wifi.yaml"
sudo tee /etc/netplan/60-wifi.yaml >/dev/null <<YAML
network:
  version: 2
  wifis:
    ${IFACE}:
      dhcp4: true
      optional: true
      regulatory-domain: "${REGDOM}"
      access-points:
        "${SSID}":
          hidden: ${HIDDEN}
          auth:
            key-management: ${KEYMGMT}
            password: "${WIFI_PASS}"
YAML
sudo chmod 600 /etc/netplan/60-wifi.yaml

echo ">>> [3/6] removing Wi-Fi for the built-in wlan0 from cloud-init (conflict source)"
if [ -f /etc/netplan/50-cloud-init.yaml ] && grep -q "wifis:" /etc/netplan/50-cloud-init.yaml; then
  sudo tee /etc/netplan/50-cloud-init.yaml >/dev/null <<'CI'
network:
  version: 2
  ethernets:
    eth0:
      optional: true
      dhcp4: true
      dhcp6: true
CI
  sudo chmod 600 /etc/netplan/50-cloud-init.yaml
  echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null
fi

echo ">>> [4/6] power-save off service + disable the generic wpa_supplicant"
sudo tee /etc/systemd/system/wifi-powersave-off.service >/dev/null <<'SVC'
[Unit]
Description=Wylacz power save WiFi (dongle USB)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for d in /sys/class/net/wlx*; do [ -e "$d" ] && iw dev $(basename $d) set power_save off 2>/dev/null; done'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SVC

echo ">>> [5/6] DHCP kick service (workaround for DORMANT operstate on rtw88-USB)"
sudo tee /usr/local/sbin/wifi-dhcp-kick.sh >/dev/null <<EOF
IF=${IFACE}
for i in \$(seq 1 40); do
  [ "\$(cat /sys/class/net/\$IF/carrier 2>/dev/null)" = "1" ] && break
  sleep 2
done
for i in \$(seq 1 12); do
  ip -4 addr show dev \$IF | grep -q "inet " && exit 0
  busybox udhcpc -i \$IF -n -q -t 4 -T 2 >/dev/null 2>&1
  networkctl renew \$IF >/dev/null 2>&1
  sleep 4
done
exit 0
EOF
sudo chmod +x /usr/local/sbin/wifi-dhcp-kick.sh
sudo tee /etc/systemd/system/wifi-dhcp-kick.service >/dev/null <<'KICK'
[Unit]
Description=AirBorn WiFi: kick DHCP po skojarzeniu (rtw88 USB operstate workaround)
After=network.target systemd-networkd.service
Wants=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wifi-dhcp-kick.sh
[Install]
WantedBy=multi-user.target
KICK

echo ">>> [6/6] enable services and apply"
sudo systemctl daemon-reload
sudo systemctl enable wifi-powersave-off.service wifi-dhcp-kick.service
sudo systemctl disable --now wpa_supplicant.service 2>/dev/null || true
sudo netplan apply
sudo systemctl start wifi-powersave-off.service 2>/dev/null || true
sudo systemctl start wifi-dhcp-kick.service 2>/dev/null || true

echo
echo "Done. Check the IP:  ip -4 addr show ${IFACE}   (target: an address on the Wi-Fi subnet)"
echo "Most reliable test: sudo reboot, then ip -4 addr show ${IFACE}"
echo "IF NEEDED (moving the dongle): plug in -> sudo reboot (the kick service handles DHCP)."
echo "No IP despite association? -> the access point (DHCP guard / client isolation / band steering),"
echo "  simplest fix: a fixed-IP reservation for the dongle MAC in the access point/controller."
