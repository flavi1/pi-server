# pi-server

[![CI](https://github.com/flavi1/pi-server/actions/workflows/ci.yml/badge.svg)](https://github.com/flavi1/pi-server/actions/workflows/ci.yml)

Socle commun pour Raspberry Pi 4 / 5 sous **Raspberry Pi OS Lite 64 bits** (Debian),
sans bureau graphique, connecté en Ethernet :

- **`prepare.sh`** (sur votre PC Linux) : télécharge la dernière image, l'écrit avec
  `dd` sur la carte SD choisie, prépare le premier démarrage (nom d'hôte, utilisateur,
  SSH, Wi-Fi/Bluetooth, installation automatique) ;
- **`install.sh`** (sur la Pi) : mises à jour automatiques du système, pare-feu,
  SSH, puis installation des modules ;
- **`pi-server`** (sur la Pi) : mise à jour **manuelle** du socle et des modules.

Modules disponibles (dépôts indépendants, installables aussi sans pi-server) :

| Module | Rôle | Exposition |
|---|---|---|
| [pi-data-server](https://github.com/flavi1/pi-data-server) | automontage lecture seule dans `/media`, HTTP, FTP | public (FTP avec mot de passe) |
| [pi-sound-server](https://github.com/flavi1/pi-sound-server) | PipeWire, MASTER, knob, Mopidy | réseau local |

---

## 1. Préparer la carte SD (sur le PC)

Carte SD : **8 Go minimum, 16 Go conseillés**. Le système occupe à lui seul environ
2,5 Go ; sur une carte de 4 Go il reste trop peu de place pour les mises à jour.

```bash
curl -fsSLO https://raw.githubusercontent.com/flavi1/pi-server/main/prepare.sh
bash prepare.sh
```

Le script demande (valeur par défaut entre crochets, Entrée pour l'accepter) :

| Question | Défaut | Remarque |
|---|---|---|
| Nom d'hôte | `hifi` | **sans `.local`** : tapez `hifi`. Le suffixe `.local` est ajouté par mDNS ; un nom d'hôte `hifi.local` donnerait `hifi.local.local`. Si vous tapez `hifi.local`, le script le corrige. |
| Utilisateur | `admin` | compte de connexion SSH, membre de `sudo` (`root` est interdit en SSH) |
| Mot de passe | — | 8 caractères minimum, saisi deux fois, enregistré **haché** |
| Clé SSH | non | facultatif : votre clé publique en plus du mot de passe |
| Wi-Fi | non | `dtoverlay=disable-wifi` dans `config.txt` sinon |
| Bluetooth | non | `dtoverlay=disable-bt` sinon |
| Installation automatique | oui | puis un oui/non par module |

Puis il :

1. télécharge la dernière Raspberry Pi OS Lite 64 bits (même image pour Pi 4 et Pi 5)
   dans `~/.cache/pi-server/`, et **vérifie son SHA-256** ;
2. liste **uniquement les périphériques amovibles** (le disque de votre PC est exclu,
   ainsi que ceux de plus de 256 Go sauf `--force-large`) et vous fait **retaper le
   nom** du périphérique avant de l'écraser ;
3. écrit l'image avec `dd`, puis dépose dans la partition de boot :
   - `user-data`, `meta-data`, `network-config` (cloud-init, le mécanisme officiel de
     Raspberry Pi OS pour le premier démarrage) ;
   - `pi-server/init.sh` + `pi-server/pi-server.conf` (installation automatique) ;
   - un bloc Wi-Fi / Bluetooth dans `config.txt`.

Options utiles : `bash prepare.sh --help` (`--device`, `--image`, `--hostname`,
`--modules "data sound"`, `--bootfs DIR` pour seulement préparer une carte déjà
flashée…).

## 2. Premier démarrage

Carte dans la Pi, **câble Ethernet branché**, puis alimentation.

1. Premier démarrage du système : 2 à 3 minutes (cloud-init crée l'utilisateur, active
   SSH, règle le nom d'hôte).
2. Si l'installation automatique est choisie, `init.sh` démarre ensuite tout seul :
   installe git, clone pi-server dans `/opt/pi-server`, lance `install.sh`, qui
   installe le socle puis chaque module. Compter **10 à 20 minutes**. À la fin la Pi
   **redémarre seule** si nécessaire (noyau mis à jour, HAT activé dans `config.txt`).
3. En cas d'échec (réseau absent…), `init.sh` est relancé à chaque démarrage tant
   qu'il n'a pas réussi ; il s'efface après réussite, et efface aussi le hachage du
   mot de passe de la partition de boot.

## 3. Se connecter en SSH

Depuis le PC, sur le même réseau local :

```bash
ssh admin@hifi.local
```

- Première connexion : SSH affiche l'empreinte de la Pi et demande
  `Are you sure you want to continue connecting (yes/no)?` → tapez `yes`.
- Puis le mot de passe choisi dans `prepare.sh`.

Suivre l'installation automatique en cours :

```bash
journalctl -fu pi-server-firstboot          # ou : less /var/log/pi-server-firstboot.log
sudo pi-server status
```

### Si `hifi.local` ne répond pas

- Attendez encore une minute (premier démarrage).
- Le PC doit résoudre les noms `.local` (mDNS) : c'est le cas d'Ubuntu par défaut
  (`avahi-daemon`, `libnss-mdns`). Test : `ping hifi.local`.
- Sinon, cherchez l'adresse IP de la Pi :
  - dans l'interface de votre box (liste des appareils connectés) ;
  - ou depuis le PC : `sudo nmap -sn 192.168.1.0/24` (adaptez au réseau de votre box),
    ou `ip neigh` après un ping de diffusion ;
  - puis `ssh admin@192.168.1.42`.
- Réservez cette adresse dans le DHCP de la box (nécessaire pour les redirections de
  ports du serveur de données).

### Après un reflash : « REMOTE HOST IDENTIFICATION HAS CHANGED »

Une nouvelle installation génère de nouvelles clés SSH : normal. Oubliez l'ancienne :

```bash
ssh-keygen -R hifi.local
ssh-keygen -R 192.168.1.42      # si vous vous connectiez par IP
```

## 4. Installation manuelle (sans installation automatique)

```bash
ssh admin@hifi.local
sudo apt update && sudo apt install -y git
git clone https://github.com/flavi1/pi-server
sudo bash pi-server/install.sh
```

`install.sh` recopie le dépôt dans `/opt/pi-server` (c'est cette copie qui sera mise à
jour), crée `/etc/pi-server/pi-server.conf` (modules à installer) puis installe tout.
Pour choisir les modules : éditez `/etc/pi-server/pi-server.conf` puis relancez, ou
`sudo pi-server add sound`, `sudo pi-server add data`.

## 5. Ce que fait le socle

| Domaine | Détail |
|---|---|
| Mises à jour du système | `unattended-upgrades` chaque jour : sécurité Debian, stable, archive Raspberry Pi (noyau, firmware) ; redémarrage automatique à 4 h 30 si nécessaire (`AUTO_REBOOT`) ; `needrestart` redémarre les services concernés |
| Pare-feu | nftables, tout refusé en entrée sauf SSH/mDNS (réseau local) et les ports déclarés par les modules dans `/etc/nftables.d/` |
| SSH | utilisateur + mot de passe, root interdit, réseau local uniquement (pare-feu) |
| Nom d'hôte | défini au premier démarrage ; modifiable avec `HOSTNAME_WANTED` dans la config |
| cloud-init | désactivé après la première installation (il ne réécrira plus rien) |

Les **mises à jour de pi-server et des modules** (le code de ce dépôt et des modules)
ne sont **jamais** automatiques :

```bash
sudo pi-server status            # versions installées, état du système
sudo pi-server update            # git pull de tout + réinstallation (idempotente)
sudo pi-server update pi-sound-server     # un seul module
sudo pi-server add sound|data|<url git>   # ajouter un module
sudo pi-server remove <module>            # le retirer de la liste (ne désinstalle rien)
```

Les fichiers de configuration (`/etc/pi-server/`, `/etc/pi-sound-server/`,
`/etc/pi-data-server/`) ne sont jamais écrasés par une mise à jour.

### Comptes

- **SSH** : l'utilisateur et le mot de passe choisis dans `prepare.sh`.
- **FTP** (pi-data-server) : le même compte par défaut — voir son README pour un
  compte FTP séparé (`sudo passwd <compte>` pour l'activer).

## 6. Contrat avec les modules

Un module est un dépôt git qui contient un `install.sh` :

- exécuté en root, **idempotent**, option `--non-interactive` (aucune question : ce qui
  manque est signalé à la fin) ;
- **autonome** : il installe lui-même ses paquets et fonctionne sans pi-server ;
- configuration dans `/etc/<module>/`, jamais écrasée ;
- pare-feu : si `/etc/nftables.d/00-lan.nft` existe (pare-feu pi-server), il dépose
  `/etc/nftables.d/NN-<module>.nft` (variables `$LAN4`, `$LAN6` disponibles) et
  recharge ; sinon il prévient simplement ;
- redémarrage nécessaire : il crée `/var/run/reboot-required` (convention Debian).

## 7. Dépannage

| Symptôme | Piste |
|---|---|
| Message « installation automatique a échoué » à la connexion | `less /var/log/pi-server-firstboot.log`, puis `sudo bash /boot/firmware/pi-server/init.sh` |
| Pas de SSH du tout | câble Ethernet ? attendre 3 min ; sinon brancher écran + clavier, se connecter avec le même utilisateur, puis `hostname -I` et `sudo cloud-init status --long` |
| `pi-server update` : « git pull a échoué » | modification locale dans `/opt/<dépôt>` : `sudo git -C /opt/<dépôt> status` |
| Ports d'un module fermés | `sudo nft list ruleset`, `ls /etc/nftables.d/` |

## 8. Tests et intégration continue

Chaque dépôt a un workflow GitHub Actions (`.github/workflows/ci.yml`) lancé à chaque
push : ShellCheck, puis des tests réels sur la machine de GitHub. Les mêmes tests se
lancent sur un PC Linux :

```bash
bash tests/test-prepare.sh bootfs      # préparation d'une partition de boot factice
sudo bash tests/test-prepare.sh dd     # image factice écrite par dd sur /dev/loopN
sudo bash tests/test-firewall.sh       # nftables.conf + fragments de modules (nft -c)
```

## Licence

GPL-3.0-or-later.
