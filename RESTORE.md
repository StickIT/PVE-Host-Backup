# Guide de restauration du host PVE

## Avant toute action

Une restauration du host peut couper le réseau, empêcher PVE de démarrer ou
réintroduire une configuration incompatible. Respecter ces règles :

1. utiliser la console locale ou la console distante de la machine, pas
   uniquement SSH ;
2. ne jamais extraire `rootfs.tar.zst` directement sur `/` ;
3. vérifier les archives avant de les lire ;
4. extraire dans une zone séparée ;
5. comparer et restaurer un ensemble limité à la fois ;
6. créer une copie `.before-restore` de chaque fichier remplacé ;
7. ne pas remplacer globalement `config.db` sur un cluster actif.

Les exemples ci-dessous utilisent :

```bash
BACKUP=/mnt/pve/dreambox-backup/backups/PVE/host/nukebox/2026-08-17T11-31-31Z
```

Adapter la date à la sauvegarde voulue.

## Vérification sans le programme

Les fichiers sont standards. PBS n’est pas nécessaire :

```bash
cd "$BACKUP"
sha256sum -c SHA256SUMS
zstd -t rootfs.tar.zst
zstd -t etc-pve.tar.zst
zstd -t recovery.tar.zst
tar --zstd -tf etc-pve.tar.zst | less
```

Extraction manuelle vers un répertoire vide :

```bash
install -d -m 0700 /var/tmp/restauration-pve
tar --zstd -xpf "$BACKUP/etc-pve.tar.zst" \
  -C /var/tmp/restauration-pve --no-same-owner
```

Sur un PC Windows récent, 7-Zip peut généralement ouvrir le flux `.zst`, puis
l’archive `.tar`. Pour une reprise système, Linux avec GNU tar et Zstandard
reste recommandé afin de conserver les noms, modes et liens correctement.

## Vérification et staging avec l’outil embarqué

Si le programme n’est plus installé, chaque dossier finalisé en contient une
copie :

```bash
apt-get update
apt-get install -y sqlite3 zstd gdisk fdisk
install -m 0750 "$BACKUP/pve-host-backup" /usr/local/sbin/pve-host-backup
install -m 0600 "$BACKUP/pve-host-backup.conf" /etc/pve-host-backup.conf
```

Vérifier puis extraire :

```bash
pve-host-backup verify 2026-08-17T11-31-31Z
pve-host-backup stage 2026-08-17T11-31-31Z
```

Le résultat se trouve sous :

```text
/var/tmp/pve-host-restore/2026-08-17T11-31-31Z/
├── rootfs/
├── etc-pve/
├── boot/
├── boot-efi/
└── recovery/
```

Les sous-dossiers absents correspondent à des archives qui n’existaient pas.

## Scénario 1 — récupérer un seul fichier

Exemple : retrouver l’ancienne configuration réseau sans l’appliquer :

```bash
STAGE=/var/tmp/pve-host-restore/2026-08-17T11-31-31Z
diff -u /etc/network/interfaces "$STAGE/rootfs/etc/network/interfaces"
```

Pour afficher un fichier PVE :

```bash
sed -n '1,240p' "$STAGE/etc-pve/storage.cfg"
```

Si un remplacement est réellement nécessaire :

```bash
cp -a /etc/network/interfaces \
  "/etc/network/interfaces.before-restore-$(date +%Y%m%d-%H%M%S)"
cp -a "$STAGE/rootfs/etc/network/interfaces" /etc/network/interfaces
```

Ne recharger le réseau qu’en console locale. Comparer d’abord les noms des
interfaces : ils peuvent changer après une réinstallation ou une modification
matérielle.

## Scénario 2 — PVE démarre mais une configuration est endommagée

### Configurations Debian du host

Comparer les blocs utiles :

```bash
diff -ruN /etc/network "$STAGE/rootfs/etc/network"
diff -ruN /etc/modprobe.d "$STAGE/rootfs/etc/modprobe.d"
diff -ruN /etc/modules-load.d "$STAGE/rootfs/etc/modules-load.d"
diff -ruN /etc/systemd/system "$STAGE/rootfs/etc/systemd/system"
```

Restaurer fichier par fichier. Ne recopier ni les sources APT d’une ancienne
version majeure, ni `/etc/fstab`, ni la configuration de boot sans contrôler
les UUID et le partitionnement actuels.

### Configurations `/etc/pve`

`/etc/pve` est géré par pmxcfs. Il faut éviter une copie récursive aveugle.
Privilégier, dans cet ordre :

1. recréer le réglage par l’interface ou les commandes PVE ;
2. comparer le fichier sauvegardé avec le fichier actuel ;
3. ne copier qu’un fichier texte bien identifié si la situation le justifie.

Exemples à inspecter :

```bash
diff -u /etc/pve/storage.cfg "$STAGE/etc-pve/storage.cfg"
find "$STAGE/etc-pve" -maxdepth 3 -type f -print | sort
```

Ne pas recopier les fichiers de configuration VM/CT avant une restauration de
dump : `qmrestore` et `pct restore` créent eux-mêmes la configuration du guest.

## Scénario 3 — perte totale du host

### 1. Préparer la reprise

- vérifier au moins une sauvegarde du host et les dumps VM/CT ;
- relever la version dans
  `recovery/inventory/pveversion.txt` après staging ;
- relever le partitionnement, les UUID et le mode de démarrage dans les
  inventaires ;
- conserver une copie externe de la procédure et des paramètres NFS.

### 2. Réinstaller PVE

Réinstaller une version majeure compatible, avec le même nom de nœud
`nukebox`. L’installateur Proxmox reformate le disque choisi : vérifier
soigneusement la cible et ne pas sélectionner un disque contenant la seule
copie de données utiles.

Ne pas tenter de transformer l’archive `rootfs` en image amorçable. Elle sert
de source de fichiers et d’inventaire après une installation propre.

### 3. Rétablir le réseau et le NFS

Configurer d’abord une connectivité minimale. Si le stockage n’existe pas déjà
dans PVE :

```bash
pvesm add nfs dreambox-backup \
  --server 192.168.11.133 \
  --export /volume1/Proxmox \
  --path /mnt/pve/dreambox-backup \
  --content backup \
  --content-dirs 'backup=backups/PVE/guests' \
  --options 'vers=4.1' \
  --prune-backups 'keep-last=3,keep-weekly=4,keep-monthly=3'
```

Contrôler impérativement :

```bash
pvesm status --storage dreambox-backup
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /mnt/pve/dreambox-backup
```

### 4. Vérifier et mettre en staging

Installer la copie du programme embarquée comme indiqué plus haut, puis :

```bash
pve-host-backup verify latest
pve-host-backup stage latest
```

### 5. Recréer le host par blocs

Ordre conseillé :

1. réseau, hostname et résolution locale ;
2. stockage PVE ;
3. modules, passthrough et paramètres matériels nécessaires ;
4. utilisateurs, certificats et règles PVE uniquement si requis ;
5. scripts locaux, cron et unités personnalisées ;
6. réglages de sauvegarde et notifications ;
7. contrôle de santé et redémarrage de test.

Après une modification liée au démarrage, vérifier les fichiers et n’utiliser
les commandes suivantes que si elles correspondent au mode de boot installé :

```bash
update-initramfs -u -k all
update-grub
proxmox-boot-tool status
proxmox-boot-tool refresh
```

### 6. Restaurer les VM et CT

Les guests sont indépendants de la sauvegarde du host. Ils se restaurent avec
l’interface PVE depuis le stockage `dreambox-backup`, ou en ligne de commande.

Exemples génériques :

```bash
qmrestore <VOLID-DU-DUMP-QEMU> <VMID> --storage <STOCKAGE-CIBLE>
pct restore <CTID> <VOLID-DU-DUMP-LXC> --storage <STOCKAGE-CIBLE>
```

Consulter d’abord les paramètres de la version PVE installée :

```bash
qmrestore --help
pct restore --help
```

Restaurer un guest à la fois, le démarrer et le tester avant de passer au
suivant.

## À propos de `config.db`

La copie se trouve ici après staging :

```text
recovery/critical/var/lib/pve-cluster/config.db
```

Elle contient l’arborescence logique de `/etc/pve`. Elle est utile pour
l’expertise et la récupération de fichiers, mais **ce guide ne propose pas son
remplacement automatique** : la bonne procédure dépend d’un host autonome ou
en cluster, du quorum, du nom des nœuds et de l’état de pmxcfs.

Sur une installation en cluster que l’on souhaite conserver, ne pas lancer
`pmxcfs -l` et ne pas remplacer la base. La documentation et un membre du
support Proxmox doivent guider cette opération.

Pour une récupération hors ligne d’un système abandonné, un membre du staff
Proxmox indique que `pmxcfs -l` peut servir à exposer la base en mode local afin
d’extraire des fichiers, tout en précisant de ne pas le faire sur un véritable
cluster à conserver. Dans notre sauvegarde, `etc-pve.tar.zst` rend normalement
cette manipulation inutile.

## Fin de restauration et nettoyage

Après chaque bloc :

```bash
pvesm status
pveversion -v
systemctl --failed
journalctl -p err -b --no-pager
```

Quand le staging n’est plus nécessaire :

```bash
pve-host-backup unstage 2026-08-17T11-31-31Z
```

Conserver les fichiers `.before-restore` jusqu’à la validation complète et à
un redémarrage réussi.

