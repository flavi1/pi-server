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

## Idées

- [ ] `pi-server backup` : archive de `/etc/pi-server`, `/etc/pi-sound-server`,
      `/etc/pi-data-server`, mots de passe exclus
- [ ] `prepare.sh` : option `--wifi-ssid` / `--wifi-pass` (aujourd'hui : puce
      activée mais non configurée, `sudo nmtui` sur la Pi)
- [ ] `prepare.sh` : IP fixe optionnelle dans `network-config`
