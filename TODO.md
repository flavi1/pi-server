# TODO — pi-server

## Persistance hors carte SD

La carte SD ne devrait porter que le système (lectures surtout). Prévoir un
stockage persistant externe (SSD USB ou clé déclaré dans `/etc/fstab`) pour :

- [ ] **journald** : `Storage=persistent` avec `/var/log/journal` sur le disque
      externe (bind-mount ou lien), repli en RAM (`volatile`) si le disque est absent
      au démarrage (`nofail` + `ConditionPathIsMountPoint`)
- [ ] `/var/log` des services (vsftpd, unattended-upgrades, fail2ban)
- [ ] `/incoming` (pi-data-server) — déjà prévu via fstab
- [ ] état de Mopidy (`~hifi/.local/share/mopidy` : bibliothèque locale, état)
- [ ] état du volume / WirePlumber (`~hifi/.local/state`)
- [ ] mettre en place l'ordre de montage (le disque persistant avant les services,
      `RequiresMountsFor=` dans des drop-ins)
- [ ] décider : disque persistant obligatoire ou facultatif (repli sur la SD ?)
- [ ] documenter la sauvegarde / restauration de `/etc/pi-*` et des états

## Place sur la carte SD

- [x] apt sans paquets recommandés ni traductions, cache vidé après installation
- [x] journal plafonné (`JOURNAL_MAX`, 50 Mo)
- [x] `files/slim.sh` : retrait de Raspberry Pi Connect, firmwares de clés USB
      tierces, compilateurs / en-têtes noyau (sans DKMS), architecture armhf
- [ ] option : retirer le noyau de l'autre modèle (Pi 4 : `linux-image-*-rpi-2712`,
      Pi 5 : `*-rpi-v8`) — la carte ne démarrerait plus sur l'autre modèle

## Idées

- [ ] `pi-server backup` : archive de `/etc/pi-server`, `/etc/pi-sound-server`,
      `/etc/pi-data-server`, mots de passe exclus
- [ ] `prepare.sh` : option `--wifi-ssid` / `--wifi-pass` (aujourd'hui : puce
      activée mais non configurée, `sudo nmtui` sur la Pi)
- [ ] `prepare.sh` : IP fixe optionnelle dans `network-config`
