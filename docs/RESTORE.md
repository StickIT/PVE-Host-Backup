# Guide de restauration du host PVE

## Réponse courte : PVE doit-il être réinstallé ?

Oui, pour une perte du NVMe sans clone amorçable. Cette sauvegarde n'est pas
une image disque : elle contient les fichiers, `/etc/pve`, une copie cohérente
de `config.db`, les inventaires et les outils. L'ordre fiable est :

1. réinstaller Proxmox VE ;
2. vérifier la compatibilité ;
3. restaurer sélectivement le host ;
4. restaurer séparément les VM/CT depuis leurs dumps.

Si un clone bloc à bloc validé existe, il peut remettre directement le disque
à l'état du clonage. Voir [NVME-CLONE.md](NVME-CLONE.md).

## Principes de sécurité

- Travailler depuis la console locale, surtout pour le réseau.
- Ne jamais extraire `rootfs.tar.zst` directement sur `/`.
- Ne jamais recopier tout `/etc/pve` sur une installation active.
- Ne jamais remplacer automatiquement `config.db`.
- Ne pas restaurer `/etc/fstab`, GPT, LVM, EFI ou GRUB depuis l'ancien disque.
- Ne pas démarrer automatiquement les guests restaurés.
- Conserver le NVMe original/clone physiquement déconnecté pendant le test.

## Ce qui est indispensable dans une nouvelle installation

| Lot | Rôle | Restauration recommandée |
|---|---|---|
| PVE/Debian de base | noyau, paquets, pmxcfs, boot | Réinstaller proprement, ne pas recopier l'ancien système en bloc. |
| Réseau | `nic0`, `nic1`, `bond0`, `vmbr0`, IP et route | Comparer, générer un candidat, valider avec ifupdown2, appliquer en console. |
| Stockages PVE | définition du NFS et stockages locaux | Recréer avec `pvesm`; ne pas copier `storage.cfg` en bloc. |
| Modules/passthrough | chargement de modules et options matérielles | Restaurer fichier par fichier si le matériel est identique. |
| Paquets additionnels | dépendances de scripts/services locaux | Comparer la liste ; réinstaller explicitement depuis les dépôts actuels, jamais recopier les anciens binaires en bloc. |
| Scripts/services locaux | automatisations personnalisées | Restaurer après lecture du diff. |
| Utilisateurs/ACL/jobs/notifications | configuration logique PVE | Recréer par l'interface/API après comparaison ; pas de copie automatique. |
| Configurations VM/CT | définition des guests | Laisser `qmrestore`/`pct restore` les recréer depuis les dumps. |
| Boot, UUID, fstab | dépend du nouveau NVMe | Utiliser les valeurs de la nouvelle installation. Anciennes valeurs = référence uniquement. |

La majorité de `rootfs.tar.zst` sert donc d'inventaire et de source de fichiers
ponctuels. Tous ses fichiers ne doivent pas être restaurés.

## Les trois modes de l'assistant

### Audit — aucune modification de configuration

```bash
pve-host-restore audit latest
```

Il vérifie SHA-256/Zstandard, extrait dans `/var/tmp`, compare backup et PVE
actuel, produit les candidats et un rapport. Il crée seulement des fichiers de
staging/rapport locaux.

### Wizard — chemin prudent pour le scénario connu

```bash
pve-host-restore wizard latest
```

Il suit l'ordre réseau → stockage → fichiers sûrs → revue PVE → guest pilote.
Même avec un verdict vert, les opérations réseau, stockage et guest exigent
une confirmation explicite. Les zones rouges restent exclues.

### Guidé — choix de chaque lot

```bash
pve-host-restore guided latest
```

Ce mode montre un menu. Chaque fichier restaurable est comparé et confirmé
individuellement. Les unités systemd et tâches cron ne sont proposées que dans
ce mode.

## Comment le risque est estimé

Chaque backup 1.2.0 contient `recovery/inventory/restore-profile.txt`.
L'assistant le compare à un profil capturé sur le PVE réinstallé :

- version PVE et Debian ;
- hostname et présence d'un cluster ;
- produit/numéro DMI, CPU et mode de boot ;
- modèle, taille, série et UUID du disque ;
- système de fichiers racine ;
- adresse, passerelle, bridge et esclaves du bond.

Verdicts détaillés : [COMPATIBILITY.md](COMPATIBILITY.md).

## Reprise totale, étape par étape

### 1. Préparer le support de reprise

Le meilleur scénario conserve sur une clé USB :

- un dossier de backup finalisé complet ;
- `SHA256SUMS` ;
- `pve-host-restore` ;
- `pve-host-backup.conf` ;
- ce guide.

Cette copie casse la dépendance circulaire « il faut le réseau pour monter le
NAS, mais le réseau est dans le backup ».

### 2. Réinstaller PVE

Pour le profil actuel :

- PVE 9 / Debian 13 ;
- hostname exact `nukebox` ;
- nœud autonome ;
- démarrage UEFI ;
- `pve-root` ext4 sur LVM et `pve-data` LVM-thin ;
- idéalement `pve-manager 9.2.10` avant restauration.

L'absence de `/etc/kernel/proxmox-boot-uuids` est cohérente avec le démarrage
GRUB observé. Ne pas lancer `proxmox-boot-tool refresh` par réflexe si la
nouvelle installation utilise GRUB.

### 3. Amorcer depuis une copie USB

Après montage de la clé :

```bash
install -m 0750 /mnt/usb/DATE/pve-host-restore /usr/local/sbin/pve-host-restore
install -m 0600 /mnt/usb/DATE/pve-host-backup.conf /etc/pve-host-backup.conf
apt-get update
apt-get install -y zstd sqlite3 gdisk fdisk dmidecode
pve-host-restore audit /mnt/usb/DATE
```

`DATE` est le nom complet du dossier, par exemple
`2026-08-18T04-15-03+0900`. Les anciens dossiers finissant par `Z` restent
acceptés.

### 4. Restaurer le réseau

Le profil attendu est :

```text
nic0 + nic1 → bond0 (802.3ad, layer2+3) → vmbr0
vmbr0        → 192.168.11.104/24
passerelle   → 192.168.11.1
```

Le wizard :

1. vérifie que `nic0` et `nic1` existent ;
2. demande l'adresse et la passerelle souhaitées ;
3. génère un fichier candidat ;
4. le valide avec `ifquery` ;
5. affiche le diff et `/etc/hosts` à titre informatif ;
6. refuse l'application via SSH ;
7. installe le fichier uniquement après `APPLIQUER RESEAU` ;
8. ne recharge pas le réseau automatiquement ;
9. arrête immédiatement la session avant les autres lots et demande un
   redémarrage de contrôle.

Le switch doit toujours avoir les deux ports dans le LAG LACP. Après
application, relire le fichier en console, puis redémarrer et vérifier :

```bash
ip -br link
ip -br address
ip route
cat /proc/net/bonding/bond0
ifquery -i /etc/network/interfaces -a
```

Tant que le NFS n'est pas recréé, relancer depuis la même copie USB :

```bash
pve-host-restore audit /mnt/usb/DATE
pve-host-restore wizard /mnt/usb/DATE
```

### 5. Recréer le NFS

L'assistant utilise `pvesm`, jamais une copie globale de `storage.cfg`. La
commande correspondant au profil est :

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

Vérifier la source exacte :

```bash
pvesm status --storage dreambox-backup
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /mnt/pve/dreambox-backup
```

Le résultat attendu commence par
`192.168.11.133:/volume1/Proxmox`.

### 6. Relancer depuis le NAS

Une fois le NFS actif :

```bash
pve-host-restore audit latest
pve-host-restore wizard latest
```

Si la version ou le matériel diffère, choisir `guided` et suivre le verdict.

### 7. Restaurer les fichiers du host

Le wizard peut proposer :

- `/etc/modules` ;
- `/etc/modules-load.d/*` ;
- `/etc/modprobe.d/*` ;
- `/usr/local/bin/*` et `/usr/local/sbin/*` hors outils du projet.

Il compare aussi le fuseau horaire et peut rétablir celui du backup avec
`timedatectl`, après confirmation. Ce changement est enregistré dans le
rollback de la session.

Il génère aussi les listes complètes des paquets absents et des versions
différentes, et affiche les écarts de sources APT. Aucun paquet ni ancien dépôt
n'est appliqué automatiquement : les dépôts disponibles au jour de la reprise
font foi.

Le mode guidé ajoute les unités systemd et `/etc/cron.d`. Avant chaque copie,
le fichier actuel est conservé sous le dossier de rollback de la session. La
copie est immédiatement comparée et son SHA-256 est enregistré.

### 8. Recréer la configuration PVE logique

L'assistant montre les différences de :

- `storage.cfg` ;
- `datacenter.cfg` ;
- `user.cfg` ;
- `jobs.cfg` ;
- `notifications.cfg` ;
- règles firewall.

Ces fichiers sont exportés dans le rapport, mais pas appliqués. Recréer les
réglages par l'interface PVE ou les commandes natives. `user.cfg` peut modifier
authentification, ACL et jetons ; son remplacement automatique est interdit.

### 9. Réinstaller l'automatisation du host

Les anciens exécutables et unités sont conservés comme preuve, mais
l'assistant ne les remplace pas. Réinstaller la version du dépôt qui vient
d'être auditée :

```bash
cd /CHEMIN/PVE-Host-Backup
bash tests/validate.sh
bash scripts/install.sh
pve-host-backup check
```

L'installateur laisse le timer désactivé. Ne lancer `auto-on` qu'après un
backup manuel, `verify latest` et un nouvel audit réussis.

### 10. Restaurer les VM/CT

Lister les dumps :

```bash
pvesm list dreambox-backup --content backup
```

Puis utiliser l'interface PVE, ou :

```bash
qmrestore VOLID-QEMU VMID --storage local-lvm
pct restore CTID VOLID-LXC --storage local-lvm
```

Le wizard reconnaît les noms `vzdump-qemu-*` et `vzdump-lxc-*`, demande le
VMID/CTID et le stockage, puis laisse le guest arrêté.

### 11. Vérifier après redémarrage

La fin du wizard affiche un identifiant de session. Après redémarrage :

```bash
pve-host-restore verify-session IDENTIFIANT-DE-SESSION
```

Le rapport vérifie les SHA-256 attendus, le parseur réseau, le stockage ajouté
et les unités systemd. Contrôler également :

```bash
systemctl is-active pve-cluster pvedaemon pveproxy pvestatd
systemctl --failed
pvesm status --storage dreambox-backup
qm list
pct list
journalctl -p err -b --no-pager
```

## Retour arrière d'une session

```bash
pve-host-restore rollback IDENTIFIANT-DE-SESSION
```

Les fichiers remplacés sont restaurés depuis
`/var/lib/pve-host-restore/sessions/<SESSION>/rollback/`. Les fichiers créés
par la session sont supprimés. Une définition de stockage ajoutée n'est
retirée qu'après une nouvelle confirmation. Le réseau n'est jamais rechargé
automatiquement.

Ce rollback est local et sélectif ; il n'annule pas l'installation PVE ou le
partitionnement.

## Vérification/extraction manuelle sans l'outil

Les archives restent standards et ne dépendent pas de PBS :

```bash
cd /CHEMIN/DU/BACKUP
sha256sum -c SHA256SUMS
zstd -t rootfs.tar.zst
zstd -t etc-pve.tar.zst
zstd -t recovery.tar.zst
tar --zstd -tf etc-pve.tar.zst | less
```

Extraction isolée :

```bash
install -d -m 0700 /var/tmp/restauration-pve
tar --zstd -xpf etc-pve.tar.zst \
  -C /var/tmp/restauration-pve --no-same-owner
```

Ne jamais remplacer la destination par `/`.

## `config.db` : dernier recours, pas restauration normale

La copie cohérente se trouve après staging sous :

```text
recovery/critical/var/lib/pve-cluster/config.db
```

Elle sert à l'expertise et à récupérer la configuration logique pmxcfs. Son
remplacement complet dépend du rôle standalone/cluster, du hostname, du quorum
et de la version. La version 1.2.0 ne l'automatise jamais. Sur un cluster, ne
pas lancer `pmxcfs -l` et ne pas remplacer cette base sans une procédure
Proxmox adaptée.

## Répétition recommandée

La procédure la plus probante, avec critères d'acceptation et retour sur le
NVMe original, est décrite dans [RESTORE-TEST.md](RESTORE-TEST.md).
