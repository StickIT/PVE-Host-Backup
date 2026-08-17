# PVE Host Backup

Sauvegarde autonome, vérifiée et restaurable du **host Proxmox VE** vers un
NAS NFS. Les archives utilisent `tar`, Zstandard et SHA-256 ; Proxmox Backup
Server n'est pas nécessaire pour les lire.

> Version 1.2.0 : profil initial audité pour `nukebox`, PVE 9.2.10,
> Debian 13, nœud autonome. Lire [le périmètre exact](docs/COMPATIBILITY.md).

Cette édition personnalisée refuse volontairement son installation sur un
autre hostname, un cluster, PVE hors majeure 9 ou Debian hors majeure 13. Une
version généralisée pourra remplacer ces garde-fous après audit.

## Ce que le projet couvre

- fichiers système et configuration Debian/PVE du host ;
- archive séparée de `/etc/pve` ;
- copie SQLite cohérente de `config.db` ;
- inventaires matériel, réseau, boot, disques, LVM, stockages et guests ;
- comparaison des paquets et sources APT, sans installation automatique ;
- assistant de restauration avec verdict vert/orange/rouge ;
- comparaison avant copie, rollback local et vérification post-redémarrage ;
- timer systemd, rétention, notifications et limites CPU/RAM.

Il ne couvre pas les disques des VM/CT : ils restent sauvegardés avec les jobs
`vzdump` intégrés à PVE dans `backups/PVE/guests`.

Ce n'est pas une image bare-metal. Après perte du NVMe, PVE doit normalement
être réinstallé avant la restauration sélective. Pour un retour direct du
disque complet, utiliser en complément la
[procédure de clone NVMe hors ligne](docs/NVME-CLONE.md).

## Profil par défaut

| Réglage | Valeur |
|---|---|
| Nœud | `nukebox` |
| Stockage NFS PVE | `dreambox-backup` |
| Export Synology | `192.168.11.133:/volume1/Proxmox` |
| Dossier host | `backups/PVE/host/nukebox` |
| Planification | dimanche à `04:15`, heure locale du host |
| Rétention host | 3 sauvegardes finalisées |
| Succès | notification désactivée par défaut |
| Échec | notification toujours active avec le détail |
| Compression | 2 threads Zstandard |
| CPU | quota systemd de 200 % = deux cœurs logiques |
| Mémoire | `MemoryHigh=2G`, pas de limite dure par défaut |

## Mise à jour depuis la 1.1.0

Une désinstallation complète n'est **pas** nécessaire. L'installation en place
préserve `/etc/pve-host-backup.conf` et les backups du NAS. Elle désactive
volontairement le timer jusqu'au nouveau test.

### 1. Sécuriser l'existant

```bash
pve-host-backup verify latest
pve-host-backup auto-off
systemctl is-active pve-host-backup.service
```

La dernière commande doit répondre `inactive`. Si elle répond `active`,
attendre la fin de la sauvegarde.

### 2. Installer Git s'il manque

L'erreur `git: command not found` signifie seulement que le client Git n'est
pas installé :

```bash
apt-get update
apt-get install -y git
```

### 3. Télécharger et valider la nouvelle version

Choisir un nouveau dossier vide :

```bash
git clone https://github.com/StickIT/PVE-Host-Backup.git \
  /var/tmp/PVE-Host-Backup-1.2.0
cd /var/tmp/PVE-Host-Backup-1.2.0
bash tests/validate.sh
```

Si ce chemin existe déjà, utiliser un autre nom ; ne pas écraser un dossier
dont le contenu n'a pas été vérifié.

### 4. Mettre à jour

```bash
bash scripts/install.sh
```

L'installateur :

- refuse la mise à jour si un backup est en cours ;
- conserve la configuration 1.1.0 et ajoute les nouvelles valeurs par défaut ;
- sauvegarde les anciens fichiers locaux sous
  `/usr/local/share/doc/pve-host-backup/` ;
- installe `pve-host-backup` et `pve-host-restore` ;
- installe le drop-in systemd de ressources ;
- contrôle le NFS et laisse le timer désactivé.

### 5. Tester avant de réactiver

```bash
pve-host-backup check
pve-host-backup settings
pve-host-backup resources
systemctl start --no-block pve-host-backup.service
journalctl -fu pve-host-backup.service
```

Après le succès :

```bash
pve-host-backup verify latest
pve-host-restore audit latest
pve-host-backup auto-on
pve-host-backup auto-status
```

Créer au moins un backup 1.2.0 : les anciens backups restent utilisables mais
n'ont pas le profil matériel détaillé nécessaire au verdict vert.

## Nouvelle installation

Sur le host PVE, en root :

```bash
apt-get update
apt-get install -y git
git clone https://github.com/StickIT/PVE-Host-Backup.git \
  /var/tmp/PVE-Host-Backup
cd /var/tmp/PVE-Host-Backup
bash tests/validate.sh
bash scripts/install.sh
```

Ne pas définir `OVERWRITE_CONFIG=1` lors d'une mise à jour normale : cette
option est réservée à la recréation volontaire des valeurs par défaut.

## Le programme est-il léger ? Est-ce un cron ?

Ce n'est pas un cron. Un **timer systemd** dormant déclenche un service
`oneshot` une fois par semaine. Hors exécution, il ne compresse rien et ne
consomme pratiquement pas de ressources. Pendant le backup :

- `Nice=10`, planification CPU `batch` ;
- priorité E/S basse ;
- deux threads de compression ;
- quota global de deux cœurs logiques ;
- pression mémoire souple au-delà de 2 Gio ;
- aucune limite dure par défaut, afin de ne pas tuer une archive en cours.

Afficher les valeurs effectives :

```bash
pve-host-backup resources
systemctl cat pve-host-backup.service
```

Pour une petite machine :

```bash
pve-host-backup configure-resources \
  --threads 1 \
  --cpu-percent 100 \
  --memory-high 1G \
  --memory-max 0
```

`100 %` correspond à un cœur logique. `MemoryHigh` est un seuil souple.
`MemoryMax=0` signifie « pas de limite dure ». Une limite dure trop basse peut
faire échouer le backup et doit être activée seulement après mesure.

Assistant interactif :

```bash
pve-host-backup configure-resources
```

Les nouvelles limites s'appliquent au lancement suivant, jamais au service
déjà actif.

## Heure, rétention et notifications

Assistant simple :

```bash
pve-host-backup configure
```

Exemple non interactif :

```bash
pve-host-backup configure \
  --time 03:30 \
  --retention 5 \
  --notify-success off
```

L'heure est celle du fuseau local du host. Depuis la 1.2.0, le dossier reprend
aussi cette heure et inclut le décalage UTC :

```text
2026-08-18T03-30-02+0900
```

Les anciens noms UTC finissant par `Z` sont toujours acceptés.

Les notifications utilisent le `sendmail` local :

```bash
pve-host-backup notify-test
```

Un échec tente toujours d'envoyer le détail et écrit aussi
`LAST_RUN_STATUS.txt` sur le NAS. Un succès n'envoie un mail que si
`NOTIFY_SUCCESS=1`.

## Premier test obligatoire

```bash
pve-host-backup check
systemctl start --no-block pve-host-backup.service
journalctl -fu pve-host-backup.service
```

`Ctrl+C` quitte seulement le journal. Vérifier ensuite :

```bash
pve-host-backup status
pve-host-backup verify latest
pve-host-backup stage latest
pve-host-backup unstage latest
```

Enfin, exécuter l'audit de restauration :

```bash
pve-host-restore audit latest
```

## Activer ou désactiver l'automatisation

```bash
pve-host-backup auto-on
pve-host-backup auto-status
pve-host-backup auto-off
```

`auto-off` empêche les prochains déclenchements sans interrompre une
sauvegarde déjà en cours.

## Assistant de restauration

```bash
pve-host-restore audit latest
pve-host-restore wizard latest
pve-host-restore guided latest
```

Fonctions principales :

1. vérification SHA-256, Zstandard et chemins d'archive ;
2. question « même machine physique ? » ;
3. comparaison backup/PVE actuel ;
4. verdict de compatibilité ;
5. zones rouges toujours protégées ;
6. candidat réseau validé, jamais rechargé automatiquement ;
7. stockage recréé avec `pvesm` ;
8. comparaison et confirmation de chaque fichier ;
9. rapport, rollback et recontrôle après redémarrage.

Après une session :

```bash
pve-host-restore verify-session IDENTIFIANT-DE-SESSION
pve-host-restore rollback IDENTIFIANT-DE-SESSION
```

Une copie USB d'un dossier finalisé peut être auditée avant le retour du NFS :

```bash
pve-host-restore audit /mnt/usb/DATE
```

Guide complet : [docs/RESTORE.md](docs/RESTORE.md). Répétition matérielle :
[docs/RESTORE-TEST.md](docs/RESTORE-TEST.md).

## Arborescence NAS

```text
/volume1/Proxmox/
└── backups/
    └── PVE/
        ├── guests/
        │   ├── vzdump-qemu-<VMID>-<DATE>.vma.zst
        │   └── vzdump-lxc-<CTID>-<DATE>.tar.zst
        └── host/
            └── nukebox/
                ├── LAST_RUN_STATUS.txt
                ├── LATEST.txt
                └── <DATE-LOCALE+FUSEAU>/
                    ├── rootfs.tar.zst
                    ├── etc-pve.tar.zst
                    ├── boot-efi.tar.zst
                    ├── recovery.tar.zst
                    ├── SHA256SUMS
                    ├── MANIFEST.txt
                    ├── RESTORE_HOST_PVE.txt
                    ├── pve-host-backup
                    ├── pve-host-restore
                    └── pve-host-backup.conf
```

`boot.tar.zst` et `boot-efi.tar.zst` ne sont créés comme archives séparées que
si les répertoires correspondants sont des points de montage distincts.

## Visibilité dans PVE

Le backup du host n'est pas un job `vzdump` natif : il n'apparaît pas dans
l'onglet **Backups**. Le projet ne modifie pas les fichiers internes de
l'interface PVE. Le suivi stable se fait avec :

```bash
pve-host-backup status
pve-host-backup auto-status
journalctl -u pve-host-backup.service -n 100 --no-pager
systemctl status pve-host-backup.timer
```

Les dumps VM/CT restent, eux, visibles et restaurables dans l'interface.

## Nettoyage et désinstallation

Supprimer uniquement staging et dossiers incomplets :

```bash
bash scripts/cleanup-tests.sh
```

Désinstaller le service, l'assistant et les états locaux, tout en conservant
les backups finaux et les dumps NAS :

```bash
bash scripts/uninstall.sh --yes
```

## Documentation

- [Architecture technique](docs/ARCHITECTURE.md)
- [Restauration du host](docs/RESTORE.md)
- [Test sur la même machine](docs/RESTORE-TEST.md)
- [Clone NVMe hors ligne](docs/NVME-CLONE.md)
- [Compatibilité et version auditée](docs/COMPATIBILITY.md)
- [Dépannage](docs/TROUBLESHOOTING.md)
- [Références officielles](docs/OFFICIAL-REFERENCES.md)

## Confidentialité

Les archives ne sont pas chiffrées par ce projet. Elles peuvent contenir clés
SSH, certificats et configurations sensibles. Restreindre les droits NFS/SMB,
activer les snapshots Synology et conserver au moins une copie hors ligne ou
hors site.
