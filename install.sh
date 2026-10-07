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
# --no-install-recommends : seulement les dépendances strictes (carte SD de petite
# taille ; les « recommandés » tirent des centaines de Mo inutiles ici).
APT=(apt-get -o DPkg::Lock::Timeout=900 -o APT::Install-Recommends=false -y)
# apt_run ARGS… : apt-get qui patiente si apt est déjà occupé (mises à jour
# automatiques, autre installation). DPkg::Lock::Timeout ne couvre que le verrou
# de dpkg, pas ceux du cache et des listes : on réessaie tant qu'un autre apt tourne.
# apt_busy : vrai si un autre programme tient un verrou d'apt/dpkg. On teste les
# verrous eux-mêmes (fcntl, comme apt), pas les noms de processus : le démon de
# veille d'unattended-upgrades tourne en permanence et ne doit pas compter.
apt_busy() {
    python3 - <<'PY'
import fcntl, os, sys
for f in ("/var/lib/dpkg/lock-frontend", "/var/lib/dpkg/lock",
          "/var/cache/apt/archives/lock", "/var/lib/apt/lists/lock"):
    try:
        fd = os.open(f, os.O_RDWR)
    except OSError:
        continue
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.lockf(fd, fcntl.LOCK_UN)
    except OSError:
        sys.exit(0)          # verrou tenu par un autre programme
    finally:
        os.close(fd)
sys.exit(1)
PY
}
apt_run() {
    local _ waited=0
    for _ in $(seq 1 120); do
        while apt_busy; do
            if [[ $waited -eq 0 ]]; then
                echo "   apt est occupé par un autre programme : attente (voir : sudo journalctl -fu apt-daily -u apt-daily-upgrade)"
                waited=1
            fi
            sleep 5
        done
        "${APT[@]}" "$@" && return 0
        apt_busy || return 1      # échec réel (paquet introuvable…) : on s'arrête
        sleep 5
    done
    return 1
}
log() { printf '\n\033[1;34m[pi-server]\033[0m %s\n' "$*"; }

# --- Configuration -------------------------------------------------------------
mkdir -p /etc/pi-server
[[ -f /etc/pi-server/pi-server.conf ]] || install -m 644 "$HERE/pi-server.conf.example" /etc/pi-server/pi-server.conf
# shellcheck source=pi-server.conf.example
. /etc/pi-server/pi-server.conf

# --- Paquets / mise à jour --------------------------------------------------------
# --- apt : jamais de paquets « recommandés », pas de traductions -------------------
# Vaut aussi pour les mises à jour automatiques : une mise à jour ne doit pas tirer
# des dizaines de Mo de suggestions sur une petite carte SD.
cat > /etc/apt/apt.conf.d/50pi-server-slim <<'APTCONF'
// pi-server : installations minimales
APT::Install-Recommends "false";
APT::Install-Suggests "false";
Acquire::Languages "none";
APTCONF

# --- Journal système plafonné (sinon jusqu'à 10 % de la carte) ----------------------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-pi-server.conf <<JCONF
# pi-server : journal plafonné (voir TODO.md : journal hors carte SD)
[Journal]
SystemMaxUse=${JOURNAL_MAX:-50M}
RuntimeMaxUse=30M
JCONF
systemctl restart systemd-journald || true

log "Mise à jour du système"
apt-get clean
apt_run update
if [[ "${SLIM:-yes}" == yes ]]; then
    bash "$F/slim.sh"
    apt_run update
fi
apt_run -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt_run install unattended-upgrades apt-listchanges nftables git python3 ca-certificates \
                    openssh-server avahi-daemon needrestart

timedatectl set-timezone "${TIMEZONE:-Europe/Paris}" || true

# --- Langue ---------------------------------------------------------------------
# Génère la langue du système, plus celles qu'envoient habituellement les clients
# SSH (LANG / LC_*), sinon perl et apt affichent « Setting locale failed ».
LOC="${LOCALE:-fr_FR.UTF-8}"
apt_run install locales
for l in "$LOC" en_GB.UTF-8 en_US.UTF-8 fr_FR.UTF-8; do
    sed -i -E "s/^# *(${l//./\\.} UTF-8)/\1/" /etc/locale.gen
    grep -qE "^${l//./\\.} UTF-8" /etc/locale.gen || echo "$l UTF-8" >> /etc/locale.gen
done
locale-gen >/dev/null
update-locale LANG="$LOC"
echo "   langue : $LOC"

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

apt-get clean
log "Socle OK ($(df -Ph / | awk 'NR==2 {print $4 " libres sur " $2}'))"
[[ $BASE_ONLY -eq 1 ]] && exit 0

# --- Modules -------------------------------------------------------------------------
if [[ ${#MODULES[@]} -eq 0 ]]; then
    log "Aucun module configuré (sudo pi-server add sound|data)"
    exit 0
fi
ARGS=()
[[ $NONINT -eq 1 ]] && ARGS+=(--non-interactive)
/usr/local/sbin/pi-server install-modules "${ARGS[@]}"
