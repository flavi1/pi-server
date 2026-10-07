#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# =============================================================================
#  slim.sh — allège Raspberry Pi OS Lite pour un serveur sans écran sur petite carte
#  Appelé par install.sh (SLIM=yes). Utilisable seul :
#     sudo bash /opt/pi-server/files/slim.sh            (applique)
#     sudo bash /opt/pi-server/files/slim.sh --dry-run  (montre seulement)
#
#  Prudence : chaque groupe est d'abord SIMULÉ ; si apt voulait retirer un autre
#  paquet que ceux du groupe (un paquet qui en dépend), le groupe est ignoré.
#  Rien n'est compilé par pi-server : les compilateurs ne servent qu'à fabriquer
#  des modules noyau (DKMS) ; ils ne sont retirés que si aucun module DKMS n'existe.
# =============================================================================
set -uo pipefail
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo."; exit 1; }
# shellcheck source=/dev/null
[[ -f /etc/pi-server/pi-server.conf ]] && . /etc/pi-server/pi-server.conf
export DEBIAN_FRONTEND=noninteractive

say() { echo "   $*"; }
before="$(df -Pm / | awk 'NR==2 {print $3}')"

# Paquets installés correspondant aux motifs donnés
# Jamais retirées : bibliothèques d'exécution dont dépend tout le système
PROTECT='^(gcc-[0-9]+-base|libgcc-s[0-9]*|libstdc\+\+[0-9]+|libc6|libc-bin|cpp-[0-9]+-base)(:.*)?$'
installed() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null \
        | awk '$1 ~ /^.i/ {print $2}' | grep -Ev "$PROTECT" | sort -u
}

# purge_group NOM MOTIFS… : purge le groupe si la simulation ne touche rien d'autre
purge_group() {
    local name="$1"; shift
    local -a pkgs
    mapfile -t pkgs < <(installed "$@")
    [[ ${#pkgs[@]} -gt 0 ]] || { say "$name : rien à retirer"; return 0; }
    local out sim extra missing want
    if ! out="$(apt-get -s purge "${pkgs[@]}" 2>&1)"; then
        say "$name : ignoré (apt refuse : $(echo "$out" | grep -E '^E:' | head -n1))"
        return 0
    fi
    sim="$(echo "$out" | awk '/^(Purg|Remv) / {print $2}' | sed 's/:.*//' | sort -u)"
    want="$(printf '%s\n' "${pkgs[@]}" | sed 's/:.*//' | sort -u)"
    extra="$(comm -23 <(echo "$sim") <(echo "$want"))"
    missing="$(comm -13 <(echo "$sim") <(echo "$want"))"
    if [[ -n "$missing" ]]; then
        say "$name : ignoré (simulation incomplète : $(echo "$missing" | tr '\n' ' '))"
        return 0
    fi
    if [[ -n "$extra" ]]; then
        say "$name : ignoré (retirerait aussi : $(echo "$extra" | tr '\n' ' '))"
        return 0
    fi
    local size
    size="$(dpkg-query -W -f='${Installed-Size}\n' "${pkgs[@]}" 2>/dev/null | awk '{s+=$1} END {printf "%d", s/1024}')"
    if [[ $DRY -eq 1 ]]; then
        say "$name : retirerait ${#pkgs[@]} paquet(s), ≈ ${size} Mo : ${pkgs[*]}"
    else
        say "$name : retrait de ${#pkgs[@]} paquet(s), ≈ ${size} Mo"
        apt-get -o DPkg::Lock::Timeout=900 -y purge "${pkgs[@]}" >/dev/null \
            || say "$name : échec du retrait (sans conséquence, voir apt)"
    fi
}

echo "Allègement du système (SLIM) :"

# 1. Accès à distance via le cloud Raspberry Pi : inutile ici, et une porte en moins
[[ "${SLIM_RPI_CONNECT:-yes}" == yes ]] && purge_group "Raspberry Pi Connect" 'rpi-connect*'

# 2. Firmwares de clés Wi-Fi / Bluetooth USB tierces. Le Wi-Fi/BT intégré de la Pi
#    (firmware-brcm80211) est conservé.
[[ "${SLIM_FIRMWARE:-yes}" == yes ]] && purge_group "Firmwares de clés USB tierces" \
    firmware-atheros firmware-mediatek firmware-realtek firmware-libertas \
    firmware-ti-connectivity firmware-intel-sound firmware-iwlwifi

# 3. Compilateurs et en-têtes du noyau, seulement sans module DKMS
if [[ "${SLIM_TOOLCHAIN:-yes}" == yes ]]; then
    if command -v dkms >/dev/null && [[ -n "$(dkms status 2>/dev/null)" ]]; then
        say "Compilateurs : conservés (modules DKMS présents)"
    else
        purge_group "Compilateurs et en-têtes du noyau" \
            build-essential dkms 'gcc' 'gcc-*' 'g++' 'g++-*' 'cpp' 'cpp-*' \
            'libstdc++-*-dev' 'libgcc-*-dev' 'libobjc-*-dev' 'linux-headers-*'
    fi
fi

# 4. Architecture 32 bits armhf : double les listes de paquets si rien ne l'utilise
if [[ "${SLIM_ARMHF:-yes}" == yes ]] && dpkg --print-foreign-architectures | grep -qx armhf; then
    if [[ -z "$(dpkg-query -W -f='${Architecture}\n' 2>/dev/null | grep -x armhf)" ]]; then
        if [[ $DRY -eq 1 ]]; then say "Architecture armhf : serait retirée (listes apt ÷ 2)"
        else dpkg --remove-architecture armhf && say "Architecture armhf retirée (listes apt ÷ 2)"; fi
    else
        say "Architecture armhf : conservée (des paquets armhf sont installés)"
    fi
fi

if [[ $DRY -eq 0 ]]; then
    apt-get -o DPkg::Lock::Timeout=900 -y autoremove --purge >/dev/null
    apt-get clean
    after="$(df -Pm / | awk 'NR==2 {print $3}')"
    say "gagné : $(( before - after )) Mo — $(df -Ph / | awk 'NR==2 {print $4 " libres sur " $2}')"
fi
