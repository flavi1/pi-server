#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Tests de prepare.sh
#   bash tests/test-prepare.sh bootfs   préparation d'une partition de boot factice
#   sudo bash tests/test-prepare.sh dd  chaîne complète : image factice .img.xz
#                                       écrite par dd sur un périphérique loop
#                                       (outils requis : sfdisk, mkfs.vfat, xz)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-bootfs}"
W="$(mktemp -d)"
LOOPS=()
cleanup() {
    for m in "$W"/mnt*; do mountpoint -q "$m" 2>/dev/null && umount "$m"; done
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null || true; done
    rm -rf "$W" 2>/dev/null || sudo rm -rf "$W"
}
trap cleanup EXIT
FAILS=0
ok()   { echo "  ok   : $*"; }
fail() {
    echo "  FAIL : $*"; FAILS=$((FAILS+1))
    [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::error title=test-prepare ($MODE)::$*"
    return 0
}

CONFIG_TXT='# For more options and information see
dtparam=audio=on
dtoverlay=vc4-kms-v3d
max_framebuffers=2
[all]
'
printf 'motdepasse-test\n' > "$W/pw"
COMMON=(--hostname "HiFi.local" --user admin --password-file "$W/pw" --ssh-key no
        --wifi no --bluetooth no --modules "data sound" --autoinstall yes --yes)

check_bootfs() {   # check_bootfs DIR
    local b="$1"
    for f in user-data meta-data network-config pi-server/init.sh pi-server/pi-server.conf config.txt; do
        [[ -s "$b/$f" ]] && ok "$f" || fail "$f manquant"
    done
    head -n1 "$b/user-data" | grep -qx '#cloud-config' && ok "en-tête #cloud-config" || fail "en-tête"
    grep -qx 'hostname: hifi' "$b/user-data" && ok "nom d'hôte normalisé (HiFi.local -> hifi)" || fail "nom d'hôte"
    grep -q 'passwd: "\$6\$' "$b/user-data" && ok "mot de passe haché (SHA-512)" || fail "hachage"
    grep -q 'motdepasse-test' "$b/user-data" && fail "mot de passe EN CLAIR" || ok "pas de mot de passe en clair"
    grep -qx 'ssh_pwauth: true' "$b/user-data" && ok "SSH par mot de passe" || fail "ssh_pwauth"
    grep -qx 'dtoverlay=disable-wifi' "$b/config.txt" && ok "Wi-Fi désactivé" || fail "disable-wifi"
    grep -qx 'dtoverlay=disable-bt' "$b/config.txt" && ok "Bluetooth désactivé" || fail "disable-bt"
    [[ "$(grep -c '^# >>> pi-server$' "$b/config.txt")" == 1 ]] && ok "un seul bloc pi-server" || fail "bloc pi-server dupliqué"
    grep -q 'pi-data-server.git' "$b/pi-server/pi-server.conf" && grep -q 'pi-sound-server.git' "$b/pi-server/pi-server.conf" \
        && ok "modules dans pi-server.conf" || fail "modules"
    bash -n "$b/pi-server/init.sh" && ok "init.sh : syntaxe" || fail "init.sh syntaxe"
    if command -v shellcheck >/dev/null; then
        shellcheck -S warning "$b/pi-server/init.sh" && ok "init.sh : shellcheck" || fail "init.sh shellcheck"
    fi
    python3 - "$b" <<'PY' && ok "YAML valides" || fail "YAML invalide"
import sys, yaml
b = sys.argv[1]
ud = yaml.safe_load(open(b + "/user-data"))
assert ud["users"][0]["name"] == "admin"
assert ud["users"][0]["lock_passwd"] is False
assert any("pi-server-firstboot" in " ".join(map(str, c)) for c in ud["runcmd"])
yaml.safe_load(open(b + "/meta-data"))["instance-id"]
assert yaml.safe_load(open(b + "/network-config"))["network"]["ethernets"]["eth0"]["dhcp4"] is True
PY
    if command -v cloud-init >/dev/null; then
        # enable_ssh est une extension Raspberry Pi OS, inconnue du schéma générique
        grep -v '^enable_ssh:' "$b/user-data" > "$W/ud-schema.yaml"
        if cloud-init schema --config-file "$W/ud-schema.yaml" >"$W/schema.log" 2>&1; then
            ok "cloud-init schema (user-data)"
        else
            fail "cloud-init schema : $(tr '\n' ' ' < "$W/schema.log" | cut -c1-900)"
        fi
    fi
}

case "$MODE" in
bootfs)
    echo "== prepare.sh --bootfs"
    mkdir -p "$W/boot"; printf '%s' "$CONFIG_TXT" > "$W/boot/config.txt"
    if ! bash "$HERE/prepare.sh" --bootfs "$W/boot" "${COMMON[@]}" >"$W/prep.log" 2>&1; then
        fail "prepare.sh --bootfs : $(tail -n 5 "$W/prep.log" | tr '\n' ' ')"
    fi
    check_bootfs "$W/boot"
    echo "== seconde exécution (idempotence de config.txt)"
    bash "$HERE/prepare.sh" --bootfs "$W/boot" "${COMMON[@]}" >/dev/null
    [[ "$(grep -c '^# >>> pi-server$' "$W/boot/config.txt")" == 1 ]] && ok "bloc non dupliqué" || fail "bloc dupliqué"
    echo "== nom d'hôte invalide refusé"
    if bash "$HERE/prepare.sh" --bootfs "$W/boot" "${COMMON[@]}" --hostname "mauvais_nom" >/dev/null 2>&1; then
        fail "nom invalide accepté"; else ok "nom invalide refusé"; fi
    ;;
dd)
    [[ $EUID -eq 0 ]] || { echo "root requis pour le mode dd"; exit 1; }
    echo "== image factice"
    truncate -s 64M "$W/src.img"
    printf 'label: dos\nstart=2048, size=32768, type=c\nstart=34816, type=83\n' | sfdisk -q "$W/src.img"
    L="$(losetup -fP --show "$W/src.img")"; LOOPS+=("$L")
    udevadm settle 2>/dev/null || sleep 2
    mkfs.vfat -n bootfs "${L}p1" >/dev/null
    mkdir -p "$W/mnt1"; mount "${L}p1" "$W/mnt1"; printf '%s' "$CONFIG_TXT" > "$W/mnt1/config.txt"; umount "$W/mnt1"
    losetup -d "$L"; LOOPS=()
    xz -T0 -1 "$W/src.img"
    echo "== écriture sur un périphérique loop"
    truncate -s 128M "$W/target.img"
    T="$(losetup -fP --show "$W/target.img")"; LOOPS+=("$T")
    if PREPARE_ALLOW_LOOP=1 bash "$HERE/prepare.sh" --image "$W/src.img.xz" --device "$T" "${COMMON[@]}" >"$W/prep.log" 2>&1; then
        ok "prepare.sh terminé"
    else
        fail "prepare.sh (dd) : $(tail -n 5 "$W/prep.log" | tr '\n' ' ')"
    fi
    lsblk -nrpo MOUNTPOINT "$T" | grep -q . && fail "partition encore montée" || ok "tout est démonté"
    partx -u "$T" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2
    mkdir -p "$W/mnt2"; mount "${T}p1" "$W/mnt2"
    check_bootfs "$W/mnt2"
    umount "$W/mnt2"
    echo "== refus d'un disque non amovible / non entier"
    if bash "$HERE/prepare.sh" --image "$W/src.img.xz" --device "${T}p1" "${COMMON[@]}" >/dev/null 2>&1; then
        fail "partition acceptée comme cible"; else ok "partition refusée comme cible"; fi
    if bash "$HERE/prepare.sh" --image "$W/src.img.xz" --device "$T" "${COMMON[@]}" >/dev/null 2>&1; then
        fail "loop accepté sans PREPARE_ALLOW_LOOP"; else ok "loop refusé hors test"; fi
    ;;
*) echo "mode inconnu : $MODE (bootfs | dd)"; exit 2 ;;
esac

echo
echo "$FAILS échec(s)"
[[ $FAILS -eq 0 ]]
