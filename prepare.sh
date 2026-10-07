#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  prepare.sh — préparer une carte SD pour Raspberry Pi 4 / 5, DEPUIS UN PC LINUX
#
#   1. télécharge la dernière Raspberry Pi OS Lite 64 bits (Debian) + vérifie SHA-256
#   2. l'écrit avec dd sur le périphérique choisi (carte SD, clé, SSD USB)
#   3. prépare le premier démarrage (cloud-init) :
#        nom d'hôte, utilisateur + mot de passe, SSH, fuseau, clavier,
#        Wi-Fi / Bluetooth activés ou non (config.txt),
#        installation automatique de pi-server et des modules choisis
#
#  Usage :   bash prepare.sh                 (questions interactives)
#            bash prepare.sh --help          (toutes les options)
#
#  Ce script est autonome : il peut être téléchargé seul.
#     curl -fsSLO https://raw.githubusercontent.com/flavi1/pi-server/main/prepare.sh
# =============================================================================
set -euo pipefail

# --- Valeurs par défaut -------------------------------------------------------
PI_SERVER_REPO="https://github.com/flavi1/pi-server.git"
PI_SERVER_BRANCH="main"
declare -A MODULE_REPO=(
    [sound]="https://github.com/flavi1/pi-sound-server.git"
    [data]="https://github.com/flavi1/pi-data-server.git"
)
declare -A MODULE_DESC=(
    [sound]="serveur de son (PipeWire, MASTER, knob, Mopidy) — réseau local"
    [data]="serveur de données (automontage lecture seule, HTTP, FTP)"
)
MODULE_ORDER=(data sound)

IMAGE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
CACHE_DIR="${XDG_CACHE_HOME:-$REAL_HOME/.cache}/pi-server"
MAX_SIZE_GB=256

OPT_DEVICE="" OPT_IMAGE="" OPT_BOOTFS="" OPT_HOSTNAME="" OPT_USER="" OPT_PASSWORD_FILE=""
OPT_WIFI="" OPT_BT="" OPT_MODULES="" OPT_AUTOINSTALL="" OPT_SSHKEY="" OPT_YES=0 OPT_FORCE_LARGE=0
OPT_TZ="Europe/Paris" OPT_KEYMAP="fr"

usage() {
cat <<EOF
Usage : bash prepare.sh [options]

Cible (une des deux) :
  --device /dev/sdX       périphérique à écraser (sinon : choix dans une liste)
  --bootfs DIR            ne PAS flasher : seulement préparer une partition de boot
                          déjà montée (image écrite par un autre moyen)
Image :
  --image FICHIER         image locale .img ou .img.xz (sinon : téléchargement)
Système :
  --hostname NOM          nom d'hôte (défaut : hifi) — SANS « .local »
  --user NOM              utilisateur administrateur (défaut : admin)
  --password-file F       lire le mot de passe dans F (sinon : saisie)
  --ssh-key FICHIER|no    clé publique à autoriser en plus du mot de passe
  --timezone TZ           défaut : $OPT_TZ
  --keymap  KM            défaut : $OPT_KEYMAP
  --wifi yes|no           activer la puce Wi-Fi (défaut : no)
  --bluetooth yes|no      activer le Bluetooth (défaut : no)
Installation au premier démarrage :
  --modules "data sound"  modules à installer (« none » : aucun)
  --autoinstall yes|no    installer pi-server automatiquement (défaut : yes)
Divers :
  --yes                   ne pas poser les questions qui ont une valeur par défaut
                          (la confirmation d'écrasement du disque reste demandée,
                          sauf avec --device ET --yes)
  --force-large           autoriser un disque de plus de ${MAX_SIZE_GB} Go
EOF
}

die()  { printf '\n\033[1;31mERREUR :\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) OPT_DEVICE="$2"; shift 2 ;;
        --bootfs) OPT_BOOTFS="$2"; shift 2 ;;
        --image) OPT_IMAGE="$2"; shift 2 ;;
        --hostname) OPT_HOSTNAME="$2"; shift 2 ;;
        --user) OPT_USER="$2"; shift 2 ;;
        --password-file) OPT_PASSWORD_FILE="$2"; shift 2 ;;
        --ssh-key) OPT_SSHKEY="$2"; shift 2 ;;
        --timezone) OPT_TZ="$2"; shift 2 ;;
        --keymap) OPT_KEYMAP="$2"; shift 2 ;;
        --wifi) OPT_WIFI="$2"; shift 2 ;;
        --bluetooth) OPT_BT="$2"; shift 2 ;;
        --modules) OPT_MODULES="$2"; shift 2 ;;
        --autoinstall) OPT_AUTOINSTALL="$2"; shift 2 ;;
        --yes|-y) OPT_YES=1; shift ;;
        --force-large) OPT_FORCE_LARGE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "option inconnue : $1" ;;
    esac
done

# --- Questions -------------------------------------------------------------------
# ask "Question" "défaut" -> réponse (défaut si vide ou --yes)
ask() {
    local q="$1" def="$2" r
    if [[ $OPT_YES -eq 1 ]]; then printf '%s\n' "$def"; return; fi
    read -r -p "$q [$def] : " r </dev/tty
    printf '%s\n' "${r:-$def}"
}
# ask_yn "Question" yes|no -> yes|no
ask_yn() {
    local q="$1" def="$2" hint r
    [[ "$def" == yes ]] && hint="O/n" || hint="o/N"
    if [[ $OPT_YES -eq 1 ]]; then printf '%s\n' "$def"; return; fi
    while true; do
        read -r -p "$q [$hint] : " r </dev/tty
        r="${r,,}"
        case "${r:-$def}" in
            o|oui|y|yes) echo yes; return ;;
            n|non|no) echo no; return ;;
        esac
    done
}
norm_yn() { case "${1,,}" in o|oui|y|yes|1|true|on) echo yes ;; *) echo no ;; esac; }

need() { command -v "$1" >/dev/null 2>&1 || die "commande manquante : $1 (sudo apt install $2)"; }
need curl curl; need xz xz-utils; need dd coreutils; need lsblk util-linux
need sha256sum coreutils; need openssl openssl; need findmnt util-linux

SUDO=""
[[ $EUID -eq 0 ]] || { need sudo sudo; SUDO="sudo"; }

echo
echo "=================================================================="
echo "  Préparation d'une carte SD pi-server (Raspberry Pi 4 / 5)"
echo "=================================================================="
echo

# --- Nom d'hôte ----------------------------------------------------------------
# On saisit le nom COURT. Le suffixe « .local » est ajouté par mDNS (avahi) :
# si on tape « hifi.local », on obtient « hifi.local.local ». On le retire donc.
HOST="${OPT_HOSTNAME:-$(ask "Nom d'hôte (sans .local ; on s'y connectera par <nom>.local)" "hifi")}"
HOST="${HOST,,}"; HOST="${HOST%.}"; HOST="${HOST%.local}"
[[ "$HOST" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "nom d'hôte invalide : « $HOST » (lettres, chiffres, tirets)"

# --- Utilisateur -----------------------------------------------------------------
AUSER="${OPT_USER:-$(ask "Utilisateur administrateur (connexion SSH, sudo)" "admin")}"
[[ "$AUSER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "nom d'utilisateur invalide : $AUSER"
case "$AUSER" in
    root|pi|hifi|ftpuser|nobody|daemon) die "« $AUSER » est réservé, choisissez un autre nom" ;;
esac

if [[ -n "$OPT_PASSWORD_FILE" ]]; then
    PASS="$(head -n1 "$OPT_PASSWORD_FILE")"
else
    while true; do
        read -r -s -p "Mot de passe de $AUSER : " PASS </dev/tty; echo
        read -r -s -p "Confirmez : " PASS2 </dev/tty; echo
        [[ "$PASS" == "$PASS2" ]] || { warn "les mots de passe diffèrent"; continue; }
        [[ ${#PASS} -ge 8 ]] || { warn "8 caractères minimum"; continue; }
        break
    done
    unset PASS2
fi
[[ ${#PASS} -ge 8 ]] || die "mot de passe trop court (8 caractères minimum)"
PASS_HASH="$(printf '%s' "$PASS" | openssl passwd -6 -stdin)"
unset PASS

# --- Clé SSH (facultative : la connexion par mot de passe reste possible) ----------
SSH_PUBKEY=""
if [[ "$OPT_SSHKEY" == "no" ]]; then
    :
elif [[ -n "$OPT_SSHKEY" ]]; then
    SSH_PUBKEY="$(head -n1 "$OPT_SSHKEY")"
else
    for k in "$REAL_HOME"/.ssh/id_ed25519.pub "$REAL_HOME"/.ssh/id_ecdsa.pub "$REAL_HOME"/.ssh/id_rsa.pub; do
        if [[ -f "$k" ]]; then
            [[ "$(ask_yn "Autoriser aussi votre clé SSH ${k/#$REAL_HOME/\~} (en plus du mot de passe) ?" no)" == yes ]] \
                && SSH_PUBKEY="$(head -n1 "$k")"
            break
        fi
    done
fi

# --- Matériel radio -------------------------------------------------------------
WIFI="$(norm_yn "${OPT_WIFI:-$(ask_yn "Activer le Wi-Fi ? (connexion prévue en Ethernet)" no)}")"
BT="$(norm_yn "${OPT_BT:-$(ask_yn "Activer le Bluetooth ?" no)}")"

# --- Installation automatique -------------------------------------------------------
AUTO="$(norm_yn "${OPT_AUTOINSTALL:-$(ask_yn "Installer pi-server automatiquement au premier démarrage ?" yes)}")"
MODULES=()
if [[ "$AUTO" == yes ]]; then
    if [[ -n "$OPT_MODULES" ]]; then
        [[ "$OPT_MODULES" == none ]] || read -r -a MODULES <<<"$OPT_MODULES"
    else
        for m in "${MODULE_ORDER[@]}"; do
            [[ "$(ask_yn "  Module « $m » : ${MODULE_DESC[$m]} ?" yes)" == yes ]] && MODULES+=("$m")
        done
    fi
    for m in "${MODULES[@]}"; do
        [[ -n "${MODULE_REPO[$m]:-}" ]] || die "module inconnu : $m (connus : ${!MODULE_REPO[*]})"
    done
fi

# =============================================================================
#  Image + écriture (sauf --bootfs)
# =============================================================================
part_name() {   # part_name /dev/sdb 1 -> /dev/sdb1 ; /dev/mmcblk0 1 -> /dev/mmcblk0p1
    if [[ "$1" =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "${1}$2"; fi
}

# Disques qui portent le système du PC (à ne jamais proposer)
system_disks() {
    local t src
    for t in / /boot /boot/efi /home /usr /var; do
        src="$(findmnt -no SOURCE "$t" 2>/dev/null || true)"
        [[ "$src" == /dev/* ]] || continue
        lsblk -nspo NAME,TYPE "$src" 2>/dev/null | awk '$2=="disk"{print $1}'
    done
    # disques portant un swap actif
    awk 'NR>1 && $1 ~ /^\/dev\// {print $1}' /proc/swaps 2>/dev/null | while read -r s; do
        lsblk -nspo NAME,TYPE "$s" 2>/dev/null | awk '$2=="disk"{print $1}'
    done
}

choose_device() {
    local sys; sys="$(system_disks | sort -u)"
    local -a names=() descs=()
    local NAME SIZE TYPE RM HOTPLUG TRAN MODEL line
    while IFS= read -r line; do
        eval "$line"   # sortie lsblk -P : NAME="..." SIZE="..." (échappée par lsblk)
        [[ "$TYPE" == disk ]] || continue
        grep -qxF "$NAME" <<<"$sys" && continue
        [[ "$RM" == 1 || "$HOTPLUG" == 1 || "$TRAN" == usb || "$TRAN" == mmc || "$NAME" == /dev/mmcblk* ]] || continue
        names+=("$NAME"); descs+=("$(printf '%-14s %8s  %-5s %s' "$NAME" "$SIZE" "${TRAN:-?}" "${MODEL:-}")")
    done < <(lsblk -dnpP -o NAME,SIZE,TYPE,RM,HOTPLUG,TRAN,MODEL)
    [[ ${#names[@]} -gt 0 ]] || die "aucun périphérique amovible détecté (insérez la carte SD)"
    echo >&2
    echo "Périphériques amovibles détectés (le disque de votre PC est exclu) :" >&2
    local i
    for i in "${!names[@]}"; do echo "  $((i+1))) ${descs[$i]}" >&2; done
    local n
    read -r -p "Numéro du périphérique à ÉCRASER : " n </dev/tty
    [[ "$n" =~ ^[0-9]+$ && $n -ge 1 && $n -le ${#names[@]} ]] || die "choix invalide"
    echo "${names[$((n-1))]}"
}

if [[ -z "$OPT_BOOTFS" ]]; then
    # --- Image ---------------------------------------------------------------
    if [[ -n "$OPT_IMAGE" ]]; then
        IMG="$OPT_IMAGE"; [[ -f "$IMG" ]] || die "image introuvable : $IMG"
    else
        mkdir -p "$CACHE_DIR"
        info "Recherche de la dernière Raspberry Pi OS Lite 64 bits…"
        URL="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$IMAGE_URL")" || die "téléchargement impossible (réseau ?)"
        [[ "$URL" == *.img.xz ]] || die "URL inattendue : $URL"
        IMG="$CACHE_DIR/$(basename "$URL")"
        info "Image : $(basename "$URL")"
        if ! curl -fsSL -o "$IMG.sha256" "$URL.sha256"; then
            rm -f "$IMG.sha256"
            die "somme de contrôle introuvable ($URL.sha256)"
        fi
        WANT="$(awk '{print $1; exit}' "$IMG.sha256")"
        if [[ -f "$IMG" ]] && [[ "$(sha256sum "$IMG" | awk '{print $1}')" == "$WANT" ]]; then
            info "Déjà en cache : $IMG"
        else
            info "Téléchargement dans $CACHE_DIR…"
            curl -fL -C - --progress-bar -o "$IMG" "$URL" || die "téléchargement interrompu (relancez : il reprendra)"
            info "Vérification SHA-256…"
            [[ "$(sha256sum "$IMG" | awk '{print $1}')" == "$WANT" ]] || { rm -f "$IMG"; die "SHA-256 incorrect, fichier supprimé"; }
        fi
        info "SHA-256 vérifié."
        # ne garder que la dernière image en cache
        find "$CACHE_DIR" -maxdepth 1 -name '*.img.xz' ! -name "$(basename "$IMG")" -delete 2>/dev/null || true
        find "$CACHE_DIR" -maxdepth 1 -name '*.img.xz.sha256' ! -name "$(basename "$IMG").sha256" -delete 2>/dev/null || true
    fi

    # --- Périphérique ----------------------------------------------------------
    DEV="${OPT_DEVICE:-$(choose_device)}"
    [[ -b "$DEV" ]] || die "$DEV n'est pas un périphérique bloc"
    DTYPE="$(lsblk -dno TYPE "$DEV")"
    # (PREPARE_ALLOW_LOOP=1 : uniquement pour les tests automatiques sur /dev/loopN)
    [[ "$DTYPE" == disk || ( "$DTYPE" == loop && "${PREPARE_ALLOW_LOOP:-0}" == 1 ) ]] || die "$DEV n'est pas un disque entier (ex. /dev/sdb, pas /dev/sdb1)"
    system_disks | sort -u | grep -qxF "$DEV" && die "$DEV porte le système de ce PC : refusé"
    SIZE_B="$(lsblk -dnbo SIZE "$DEV")"
    if (( SIZE_B > MAX_SIZE_GB * 1000000000 )) && [[ $OPT_FORCE_LARGE -ne 1 ]]; then
        die "$DEV fait plus de ${MAX_SIZE_GB} Go : ajoutez --force-large si c'est voulu"
    fi
    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEV"
    echo
    warn "TOUT le contenu de $DEV ($(lsblk -dno SIZE "$DEV" | tr -d ' '), $(lsblk -dno MODEL "$DEV" | sed 's/ *$//')) va être EFFACÉ."
    if ! [[ $OPT_YES -eq 1 && -n "$OPT_DEVICE" ]]; then
        read -r -p "Pour confirmer, tapez le nom du périphérique ($(basename "$DEV")) : " c </dev/tty
        [[ "$c" == "$(basename "$DEV")" ]] || die "abandon"
    fi

    # --- Démontage ----------------------------------------------------------------
    info "Démontage des partitions de $DEV"
    while read -r p; do
        [[ -n "$p" ]] || continue
        $SUDO umount "$p" 2>/dev/null || true
    done < <(lsblk -nrpo NAME "$DEV" | tail -n +2)
    if lsblk -nrpo MOUNTPOINT "$DEV" | grep -q .; then
        die "une partition de $DEV est encore montée (fermez les fenêtres qui l'utilisent)"
    fi

    # --- Écriture ---------------------------------------------------------------
    info "Écriture de l'image sur $DEV (quelques minutes)…"
    if [[ "$IMG" == *.xz ]]; then
        xz -dc "$IMG" | $SUDO dd of="$DEV" bs=4M iflag=fullblock conv=fsync status=progress
    else
        $SUDO dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
    fi
    sync
    # relire la table de partitions (partprobe = paquet parted ; partx = util-linux)
    $SUDO partprobe "$DEV" 2>/dev/null || $SUDO partx -u "$DEV" 2>/dev/null \
        || $SUDO partx -a "$DEV" 2>/dev/null || $SUDO blockdev --rereadpt "$DEV" 2>/dev/null || true
    command -v udevadm >/dev/null && $SUDO udevadm settle || sleep 3

    # --- Montage de la partition de boot --------------------------------------------
    P1="$(part_name "$DEV" 1)"
    for _ in $(seq 1 20); do [[ -b "$P1" ]] && break; sleep 0.5; done
    [[ -b "$P1" ]] || die "partition $P1 introuvable après écriture"
    sleep 2   # laisser l'éventuel automontage du bureau se faire
    BOOT="$(findmnt -rno TARGET -S "$P1" | head -n1 || true)"
    MOUNTED_HERE=0
    if [[ -z "$BOOT" ]]; then
        BOOT="$(mktemp -d)"
        $SUDO mount -t vfat "$P1" "$BOOT"
        MOUNTED_HERE=1
    fi
else
    BOOT="$OPT_BOOTFS"
    MOUNTED_HERE=0
fi
[[ -f "$BOOT/config.txt" ]] || die "$BOOT ne ressemble pas à une partition de boot Raspberry Pi (config.txt absent)"
info "Partition de boot : $BOOT"

# =============================================================================
#  Fichiers de premier démarrage
# =============================================================================
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

yaml_q() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

# --- cloud-init : user-data ------------------------------------------------------------
{
    echo "#cloud-config"
    echo "# Généré par pi-server/prepare.sh le $(date -Iseconds)"
    echo "# Le hachage du mot de passe est effacé de ce fichier après le premier démarrage."
    echo
    echo "hostname: $HOST"
    echo "manage_etc_hosts: true"
    echo "timezone: $(yaml_q "$OPT_TZ")"
    echo "keyboard:"
    echo "  layout: $(yaml_q "$OPT_KEYMAP")"
    echo
    echo "users:"
    echo "  - name: $AUSER"
    echo "    gecos: \"Administrateur pi-server\""
    echo "    groups: users,adm,dialout,audio,netdev,video,plugdev,input,gpio,render,sudo"
    echo "    shell: /bin/bash"
    echo "    lock_passwd: false"
    echo "    passwd: $(yaml_q "$PASS_HASH")"
    if [[ -n "$SSH_PUBKEY" ]]; then
        echo "    ssh_authorized_keys:"
        echo "      - $(yaml_q "$SSH_PUBKEY")"
    fi
    echo
    echo "# SSH avec utilisateur + mot de passe (le pare-feu le limite au réseau local)"
    echo "enable_ssh: true"
    echo "ssh_pwauth: true"
    echo "disable_root: true"
    if [[ "$AUTO" == yes ]]; then
        cat <<'EOF'

# Installation automatique : service relancé à chaque démarrage tant que
# /boot/firmware/pi-server/init.sh existe (il se supprime après réussite).
write_files:
  - path: /etc/systemd/system/pi-server-firstboot.service
    permissions: "0644"
    content: |
      [Unit]
      Description=pi-server : installation au premier démarrage
      ConditionPathExists=/boot/firmware/pi-server/init.sh
      Wants=network-online.target
      After=network-online.target cloud-final.service time-sync.target

      [Service]
      Type=oneshot
      ExecStart=/bin/bash /boot/firmware/pi-server/init.sh
      TimeoutStartSec=infinity
      StandardOutput=journal+console
      StandardError=journal+console

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, pi-server-firstboot.service ]
  - [ systemctl, start, --no-block, pi-server-firstboot.service ]
EOF
    fi
} > "$STAGE/user-data"

cat > "$STAGE/meta-data" <<EOF
instance-id: pi-server-$HOST-$(date +%Y%m%d%H%M%S)
local-hostname: $HOST
EOF

cat > "$STAGE/network-config" <<'EOF'
# Ethernet en DHCP (IPv4 + IPv6). Réservez l'adresse dans votre box.
network:
  version: 2
  ethernets:
    eth0:
      renderer: NetworkManager
      dhcp4: true
      dhcp6: true
      optional: true
EOF

# --- Configuration pi-server + script de premier démarrage ---------------------------------
if [[ "$AUTO" == yes ]]; then
    mkdir -p "$STAGE/pi-server"
    {
        echo "# pi-server.conf — copié dans /etc/pi-server/pi-server.conf au premier démarrage"
        echo "PI_SERVER_REPO=\"$PI_SERVER_REPO\""
        echo "PI_SERVER_BRANCH=\"$PI_SERVER_BRANCH\""
        echo "# Modules installés (dépôts git). Ajout ultérieur : sudo pi-server add <dépôt>"
        echo "MODULES=("
        for m in "${MODULES[@]}"; do echo "    \"${MODULE_REPO[$m]}\""; done
        echo ")"
        echo "MODULES_BRANCH=\"main\""
    } > "$STAGE/pi-server/pi-server.conf"

    cat > "$STAGE/pi-server/init.sh" <<'INIT'
#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Premier démarrage : installe git, clone pi-server, lance son installation.
# Lancé par pi-server-firstboot.service à chaque démarrage tant que ce fichier
# existe ; il se supprime lui-même après une installation réussie.
# Relance manuelle possible :  sudo bash /boot/firmware/pi-server/init.sh
set -uo pipefail
BOOTDIR=/boot/firmware/pi-server
LOG=/var/log/pi-server-firstboot.log
exec > >(tee -a "$LOG") 2>&1
echo "===== pi-server firstboot : $(date -Iseconds) ====="

fail() {
    echo "ÉCHEC : $*"
    mkdir -p /var/lib/pi-server
    echo "$*" > /var/lib/pi-server/firstboot.failed
    exit 1
}

# shellcheck source=/dev/null
. "$BOOTDIR/pi-server.conf" || fail "pi-server.conf illisible"

# Attendre le réseau (10 min max)
for i in $(seq 1 120); do
    getent hosts github.com >/dev/null 2>&1 && getent hosts deb.debian.org >/dev/null 2>&1 && break
    [[ $i -eq 120 ]] && fail "pas de réseau (câble Ethernet ?)"
    sleep 5
done

# Horloge (la Pi n'a pas de pile RTC) : apt refuse des dépôts « pas encore valides »
for _ in $(seq 1 60); do
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == yes ]] && break
    sleep 2
done

export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -o DPkg::Lock::Timeout=900 -y)
"${APT[@]}" update || fail "apt-get update"
"${APT[@]}" install git ca-certificates || fail "installation de git"

if [[ -d /opt/pi-server/.git ]]; then
    git -C /opt/pi-server pull --ff-only || fail "git pull pi-server"
else
    rm -rf /opt/pi-server
    git clone --branch "$PI_SERVER_BRANCH" "$PI_SERVER_REPO" /opt/pi-server || fail "git clone $PI_SERVER_REPO"
fi

mkdir -p /etc/pi-server
[[ -f /etc/pi-server/pi-server.conf ]] || install -m 644 "$BOOTDIR/pi-server.conf" /etc/pi-server/pi-server.conf

bash /opt/pi-server/install.sh --non-interactive || fail "install.sh (voir $LOG)"

# Réussite : on retire le hachage du mot de passe de la partition de boot,
# puis ce script (le service ne se relancera plus).
if [[ -f /boot/firmware/user-data ]]; then
    sed -i -E 's/^([[:space:]]*passwd:).*/\1 "(effacé après le premier démarrage)"/' /boot/firmware/user-data
fi
rm -f /var/lib/pi-server/firstboot.failed
rm -rf "$BOOTDIR"
systemctl disable pi-server-firstboot.service 2>/dev/null
echo "===== pi-server firstboot : terminé $(date -Iseconds) ====="
if [[ -f /var/run/reboot-required ]]; then
    echo "Redémarrage nécessaire (noyau, config.txt…) : redémarrage dans 10 s"
    sleep 10
    systemctl reboot
fi
INIT
fi

# --- Copie sur la partition de boot -----------------------------------------------------
info "Écriture des fichiers de premier démarrage"
$SUDO cp "$STAGE/user-data" "$STAGE/meta-data" "$STAGE/network-config" "$BOOT/"
$SUDO rm -rf "$BOOT/pi-server"
if [[ "$AUTO" == yes ]]; then
    $SUDO mkdir -p "$BOOT/pi-server"
    $SUDO cp "$STAGE/pi-server/pi-server.conf" "$STAGE/pi-server/init.sh" "$BOOT/pi-server/"
fi

# --- config.txt : Wi-Fi / Bluetooth ------------------------------------------------------
CFG="$BOOT/config.txt"
[[ -f "$CFG.orig" ]] || $SUDO cp "$CFG" "$CFG.orig"
# retirer un éventuel bloc précédent
$SUDO sed -i '/^# >>> pi-server$/,/^# <<< pi-server$/d' "$CFG"
{
    echo "# >>> pi-server"
    echo "# Bloc géré par pi-server/prepare.sh (radio). Le serveur de son ajoute"
    echo "# son propre bloc pour l'audio."
    echo "[all]"
    [[ "$WIFI" == yes ]] && echo "# Wi-Fi activé" || echo "dtoverlay=disable-wifi"
    [[ "$BT" == yes ]]   && echo "# Bluetooth activé" || echo "dtoverlay=disable-bt"
    echo "# <<< pi-server"
} | $SUDO tee -a "$CFG" >/dev/null

sync
if [[ -z "$OPT_BOOTFS" ]]; then
    # démonter toutes les partitions (y compris celles montées par le bureau)
    while read -r p; do
        [[ -n "$p" ]] && $SUDO umount "$p" 2>/dev/null || true
    done < <(lsblk -nrpo NAME "$DEV" | tail -n +2)
    [[ "${MOUNTED_HERE:-0}" -eq 1 ]] && rmdir "$BOOT" 2>/dev/null || true
    sync
    info "Partitions démontées : vous pouvez retirer $DEV."
fi

echo
echo "=================================================================="
echo "  Carte prête."
echo "=================================================================="
cat <<EOF
  Nom d'hôte   : $HOST            (SSH : ssh $AUSER@$HOST.local)
  Utilisateur  : $AUSER (mot de passe saisi)$( [[ -n "$SSH_PUBKEY" ]] && echo " + clé SSH" )
  Wi-Fi        : $WIFI      Bluetooth : $BT
  Installation : $( [[ "$AUTO" == yes ]] && echo "automatique — modules : ${MODULES[*]:-aucun}" || echo "manuelle" )

  1. Retirez la carte, insérez-la dans la Raspberry Pi, branchez l'Ethernet,
     puis l'alimentation.
  2. Patientez : ~3 min pour le premier démarrage$( [[ "$AUTO" == yes ]] && echo ", puis 10 à 20 min
     d'installation (la Pi redémarre seule à la fin si nécessaire)" ).
  3. Connectez-vous :   ssh $AUSER@$HOST.local
     Suivre l'installation :  journalctl -fu pi-server-firstboot
EOF
