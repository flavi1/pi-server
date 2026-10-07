#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  pi-server — installation du socle commun, puis des modules
#
#     sudo bash /opt/pi-server/install.sh [--non-interactive] [--base-only]
#
#  Socle : mises à jour automatiques du système, pare-feu nftables, SSH
#          (utilisateur + mot de passe, réseau local), nom d'hôte, commande
#          « pi-server » (mise à jour manuelle).
#  Modules : chaque dépôt listé dans /etc/pi-server/pi-server.conf est cloné
#          dans /opt/<dépôt> et installé par son propre install.sh.
#  Idempotent : peut être relancé à volonté.
# =============================================================================
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo."; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Le dépôt de référence vit dans /opt/pi-server (c'est lui que « pi-server update »
# met à jour). Si on lance install.sh depuis un clone ailleurs (ex. ~/pi-server),
# on le recopie là-bas, historique git compris, et on relance depuis /opt.
if [[ "$HERE" != /opt/pi-server ]]; then
    if [[ ! -d /opt/pi-server/.git ]]; then
        echo "Copie de $HERE vers /opt/pi-server"
        rm -rf /opt/pi-server
        cp -a "$HERE" /opt/pi-server
        chown -R root:root /opt/pi-server
    else
        echo "/opt/pi-server existe déjà : c'est lui qui est utilisé (sudo pi-server update pour le mettre à jour)."
    fi
    exec bash /opt/pi-server/install.sh "$@"
fi
F="$HERE/files"
NONINT=0 BASE_ONLY=0
for a in "$@"; do
    case "$a" in
        --non-interactive) NONINT=1 ;;
        --base-only) BASE_ONLY=1 ;;
        *) echo "option inconnue : $a"; exit 2 ;;
    esac
done
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -o DPkg::Lock::Timeout=900 -y)
log() { printf '\n\033[1;34m[pi-server]\033[0m %s\n' "$*"; }

# --- Configuration -------------------------------------------------------------
mkdir -p /etc/pi-server
[[ -f /etc/pi-server/pi-server.conf ]] || install -m 644 "$HERE/pi-server.conf.example" /etc/pi-server/pi-server.conf
# shellcheck source=pi-server.conf.example
. /etc/pi-server/pi-server.conf

# --- Paquets / mise à jour --------------------------------------------------------
log "Mise à jour du système"
"${APT[@]}" update
"${APT[@]}" -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
"${APT[@]}" install unattended-upgrades apt-listchanges nftables git python3 ca-certificates \
                    openssh-server avahi-daemon needrestart

timedatectl set-timezone "${TIMEZONE:-Europe/Paris}" || true

# --- Nom d'hôte -------------------------------------------------------------------
if [[ -n "${HOSTNAME_WANTED:-}" ]]; then
    H="${HOSTNAME_WANTED,,}"; H="${H%.local}"
    if [[ "$(hostname)" != "$H" ]]; then
        log "Nom d'hôte : $H"
        old="$(hostname)"
        hostnamectl set-hostname "$H"
        sed -i -E "s/^(127\.0\.1\.1[[:space:]]+).*/\1$H/" /etc/hosts
        grep -qE '^127\.0\.1\.1' /etc/hosts || echo "127.0.1.1	$H" >> /etc/hosts
        systemctl restart avahi-daemon || true
        echo "   (ancien nom : $old — reconnectez-vous avec ssh <utilisateur>@$H.local)"
    fi
fi

# --- cloud-init : uniquement au premier démarrage --------------------------------
# Une fois la Pi installée, on le désactive : il ne réécrira plus jamais le nom
# d'hôte, les utilisateurs ni le réseau.
if [[ -d /etc/cloud ]]; then
    touch /etc/cloud/cloud-init.disabled
fi

# --- Mises à jour automatiques -------------------------------------------------------
log "Mises à jour automatiques (sécurité Debian, stable, archive Raspberry Pi)"
install -m 644 "$F/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
install -m 644 "$F/52unattended-upgrades-pi-server" /etc/apt/apt.conf.d/52unattended-upgrades-pi-server
sed -i -E "s/^(Unattended-Upgrade::Automatic-Reboot )\"[a-z]+\";/\1\"$([[ "${AUTO_REBOOT:-yes}" == yes ]] && echo true || echo false)\";/; \
           s/^(Unattended-Upgrade::Automatic-Reboot-Time )\"[0-9:]+\";/\1\"${AUTO_REBOOT_TIME:-04:30}\";/" \
    /etc/apt/apt.conf.d/52unattended-upgrades-pi-server
# needrestart : redémarrer les services automatiquement, sans question
mkdir -p /etc/needrestart/conf.d
echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/50-pi-server.conf
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service

# --- SSH : utilisateur + mot de passe, jamais root ----------------------------------
log "SSH (mot de passe autorisé, root interdit, réseau local uniquement via le pare-feu)"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-pi-server.conf <<'EOF'
# pi-server
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 4
X11Forwarding no
EOF
sshd -t
systemctl enable ssh
systemctl reload ssh || systemctl restart ssh

# --- Pare-feu ------------------------------------------------------------------------
log "Pare-feu nftables"
mkdir -p /etc/nftables.d
if [[ -z "${LAN4:-}" ]]; then
    IFACE="$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    CIDR="$(ip -o -4 addr show dev "${IFACE:-eth0}" 2>/dev/null | awk '{print $4; exit}')"
    LAN4="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "${CIDR:-192.168.1.2/24}")"
fi
cat > /etc/nftables.d/00-lan.nft <<EOF
# Généré par pi-server/install.sh (LAN4 dans /etc/pi-server/pi-server.conf pour forcer)
define LAN4 = { $LAN4 }
define LAN6 = { fe80::/10, fc00::/7 }
EOF
install -m 755 "$F/nftables.conf" /etc/nftables.conf
nft -c -f /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables
# fail2ban (s'il est installé par un module) recrée sa table après un rechargement
systemctl is-active --quiet fail2ban && systemctl restart fail2ban || true
echo "   réseau local : $LAN4"

# --- Commande pi-server ------------------------------------------------------------
install -m 755 "$HERE/bin/pi-server" /usr/local/sbin/pi-server
# Message de connexion si le premier démarrage a échoué
cat > /etc/profile.d/pi-server.sh <<'EOF'
if [ -f /var/lib/pi-server/firstboot.failed ]; then
    echo "!! L'installation automatique pi-server a échoué : $(cat /var/lib/pi-server/firstboot.failed)"
    echo "!! Journal : /var/log/pi-server-firstboot.log — relancer : sudo bash /boot/firmware/pi-server/init.sh"
fi
if [ -f /var/run/reboot-required ]; then
    echo "** Redémarrage nécessaire : sudo reboot"
fi
EOF
mkdir -p /var/lib/pi-server
git -C "$HERE" rev-parse HEAD > /var/lib/pi-server/base.version 2>/dev/null || true

log "Socle OK"
[[ $BASE_ONLY -eq 1 ]] && exit 0

# --- Modules -------------------------------------------------------------------------
if [[ ${#MODULES[@]} -eq 0 ]]; then
    log "Aucun module configuré (sudo pi-server add sound|data)"
    exit 0
fi
ARGS=()
[[ $NONINT -eq 1 ]] && ARGS+=(--non-interactive)
/usr/local/sbin/pi-server install-modules "${ARGS[@]}"
