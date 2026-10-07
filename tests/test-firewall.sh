#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Vérifie que files/nftables.conf est valide, seul et avec des fragments de
# modules au format du contrat (variables $LAN4 / $LAN6). « nft -c » : rien n'est
# appliqué. Root requis (netlink).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "root requis"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/d"
cat > "$W/d/00-lan.nft" <<'EOF'
define LAN4 = { 192.168.1.0/24 }
define LAN6 = { fe80::/10, fc00::/7 }
EOF
sed "s#/etc/nftables.d#$W/d#g" "$HERE/files/nftables.conf" > "$W/nftables.conf"

echo "== socle seul"
nft -c -f "$W/nftables.conf" && echo "  ok"

echo "== socle + fragments de modules"
cat > "$W/d/10-pi-data-server.nft" <<'EOF'
add rule inet filter input tcp dport { 8080, 21, 40000-40100 } accept
EOF
cat > "$W/d/20-pi-sound-server.nft" <<'EOF'
add rule inet filter input ip  saddr $LAN4 tcp dport { 6680, 6600 } accept
add rule inet filter input ip6 saddr $LAN6 tcp dport { 6680, 6600 } accept
EOF
nft -c -f "$W/nftables.conf" && echo "  ok"
