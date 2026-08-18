# PVE Host Backup

Sauvegarde autonome et vérifiée du **host Proxmox VE** vers un NAS NFS.
Les archives sont lisibles avec `tar` et Zstandard : PBS n'est pas requis.

> Version 1.3.0 : profil audité pour `nukebox`, PVE 9.2.10, Debian 13 et
> nœud autonome. Voir [Compatibilité](docs/COMPATIBILITY.md).

Ce projet sauvegarde le host. Les disques des VM et CT doivent rester couverts
par les jobs `vzdump` intégrés à PVE.

## Le plus simple : le menu

```bash
pve-host-backup menu
```

Le menu permet de consulter l'état, lancer un backup, suivre le journal,
vérifier la dernière sauvegarde, activer/désactiver cron et changer les
réglages.

## Commandes essentielles

| Besoin | Commande |
|---|---|
| Ouvrir le menu | `pve-host-backup menu` |
| Voir l'état général | `pve-host-backup info` |
| Lancer un backup maintenant | `pve-host-backup now` |
| Suivre le backup en direct | `pve-host-backup follow` |
| Voir les 100 dernières lignes | `pve-host-backup logs` |
| Vérifier le dernier backup | `pve-host-backup verify-latest` |
| Activer le backup automatique | `pve-host-backup on` |
| Désactiver le backup automatique | `pve-host-backup off` |
| Changer heure/rétention/notifications | `pve-host-backup configure` |
| Changer les limites CPU/RAM | `pve-host-backup configure-resources` |
| Auditer une restauration | `pve-host-restore audit latest` |

La fiche complète est dans [Commandes](docs/COMMANDS.md).

## Fonctionnement en une minute

```text
cron, dimanche à HH:MM
        │
        ▼
pve-host-backup.service
        │  limites CPU/RAM, faible priorité, journal systemd
        ▼
pve-host-backup run
        │  contrôle du vrai montage NFS, verrou anti-chevauchement
        ▼
archives + SHA-256 + vérification Zstandard + rétention
```

Cron ne lance donc pas directement `tar`. Il demande à systemd de démarrer le
même service que lors d'un lancement manuel. Les protections et limites de
ressources restent appliquées.

Le fichier créé à l'activation est :

```text
/etc/cron.d/pve-host-backup
```

Il contient par défaut :

```cron
15 4 * * 0 root /usr/bin/systemctl start --no-block pve-host-backup.service
```

`0` signifie dimanche. L'heure utilisée est l'heure locale du host.

### Limite importante de cron

Si le PVE est arrêté exactement à l'heure prévue, le lancement hebdomadaire est
manqué. Cron ne le rattrape pas au redémarrage. L'ancien timer systemd utilisait
`Persistent=true`, qui permettait ce rattrapage.

Le timer avait donc été choisi initialement pour sa résilience, son affichage
de la prochaine exécution avec `systemctl list-timers` et son intégration aux
journaux. Cron est maintenant utilisé parce qu'il est plus familier et plus
simple à inspecter. Sur un PVE normalement allumé 24 h/24, la différence
pratique est faible.

## Impact sur les performances

Hors sauvegarde :

- le script ne tourne pas ;
- seul le démon cron contrôle les horaires une fois par minute ;
- aucun scan, aucune compression et aucun accès au NAS n'est effectué par ce
  projet.

Si cron était déjà utilisé par le host, le coût supplémentaire est seulement
une ligne de planification en mémoire. S'il ne l'était pas, un petit démon
reste actif ; sa charge CPU au repos est négligeable pour un host PVE.

Pendant la sauvegarde, le choix cron/timer ne change pratiquement rien : c'est
le même service qui travaille. Les valeurs par défaut sont :

| Limite | Valeur |
|---|---|
| Compression | 2 threads Zstandard |
| CPU | `CPUQuota=200%`, soit deux cœurs logiques maximum |
| Priorité CPU | `Nice=10`, politique `batch` |
| Priorité E/S | basse |
| Mémoire souple | `MemoryHigh=2G` |
| Mémoire dure | désactivée |

Pour une petite machine :

```bash
pve-host-backup configure-resources \
  --threads 1 \
  --cpu-percent 100 \
  --memory-high 1G \
  --memory-max 0
```

`MemoryMax=0` signifie « pas de limite dure ». C'est volontaire : une limite
trop basse pourrait tuer l'archive en cours.

## Profil par défaut

| Réglage | Valeur |
|---|---|
| Nœud | `nukebox` |
| Stockage NFS PVE | `dreambox-backup` |
| Export | `192.168.11.133:/volume1/Proxmox` |
| Destination host | `backups/PVE/host/nukebox` |
| Planification | dimanche à `04:15`, heure locale |
| Rétention | 3 sauvegardes host finalisées |
| Notification de succès | désactivée |
| Notification d'échec | toujours active avec le détail |

## Nouvelle installation

Exécuter en root sur le host PVE :

```bash
apt-get update
apt-get install -y git
git clone https://github.com/StickIT/PVE-Host-Backup.git \
  /var/tmp/PVE-Host-Backup
cd /var/tmp/PVE-Host-Backup
bash tests/validate.sh
bash scripts/install.sh
```

L'installateur contrôle le host, installe les dépendances et laisse la
planification désactivée. Il ne lance pas automatiquement un premier backup.

## Mise à jour depuis la 1.2.0

Une désinstallation complète n'est pas nécessaire. La configuration et les
backups du NAS sont conservés.

### 1. Vérifier et arrêter l'ancienne planification

Ces commandes sont compatibles avec la 1.2.0 :

```bash
pve-host-backup verify latest
pve-host-backup auto-off
systemctl is-active pve-host-backup.service
```

La dernière commande doit répondre `inactive`. Si elle répond `active`,
attendre la fin.

### 2. Mettre le dépôt à jour puis installer

Dans la copie à jour du dépôt :

```bash
bash tests/validate.sh
bash scripts/install.sh
```

La mise à jour :

- préserve `/etc/pve-host-backup.conf` ;
- sauvegarde les anciens fichiers locaux dans
  `/usr/local/share/doc/pve-host-backup/` ;
- désactive et supprime l'ancien `pve-host-backup.timer` ;
- installe le service 1.3.0 et le support cron ;
- laisse cron non programmé jusqu'à vos tests.

### 3. Tester puis activer

```bash
pve-host-backup check
pve-host-backup now
pve-host-backup follow
```

`Ctrl+C` quitte seulement l'affichage du journal. Après le succès :

```bash
pve-host-backup verify-latest
pve-host-restore audit latest
pve-host-backup on
pve-host-backup auto-status
```

## Changer l'heure, la rétention et les notifications

Assistant interactif :

```bash
pve-host-backup configure
```

Ou directement :

```bash
pve-host-backup configure \
  --time 03:30 \
  --retention 5 \
  --notify-success off
```

Si cron est actif, son fichier est réécrit automatiquement avec la nouvelle
heure. Si cron est désactivé, seul le réglage est mémorisé.

Les échecs restent toujours notifiés et sont aussi écrits dans
`LAST_RUN_STATUS.txt`. Les notifications utilisent le `sendmail` local :

```bash
pve-host-backup notify-test
```

## Ce qui est sauvegardé

- système et configuration Debian/PVE du host ;
- `/etc/pve` dans une archive séparée ;
- copie SQLite cohérente de `config.db` ;
- boot/EFI lorsqu'ils sont montés séparément ;
- inventaires matériel, réseau, disques, LVM, paquets, stockages et guests ;
- outils et manuel de reprise.

Ce qui n'est pas sauvegardé :

- disques des VM/CT ;
- contenu des montages externes ;
- image brute du NVMe.

Après la perte du NVMe, PVE doit normalement être réinstallé avant une
restauration sélective. Pour une image du disque complet, voir
[Clone NVMe hors ligne](docs/NVME-CLONE.md).

## Restauration

```bash
pve-host-restore audit latest
pve-host-restore wizard latest
pve-host-restore guided latest
```

Le mode `audit` ne modifie rien. Le wizard vérifie la version, le matériel et
le réseau avant toute proposition de copie. Lire le
[guide de restauration](docs/RESTORE.md) et le
[protocole de test](docs/RESTORE-TEST.md) avant un sinistre réel.

## Arborescence NAS

```text
/volume1/Proxmox/
└── backups/
    └── PVE/
        ├── guests/                 # dumps VM/CT gérés par PVE
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
                    ├── pve-host-backup
                    └── pve-host-restore
```

## Visibilité dans PVE

Ce backup du host n'est pas un job `vzdump` natif : il n'apparaît pas dans
l'onglet **Backups** de PVE. Le projet ne modifie pas l'interface Proxmox.

Suivi recommandé :

```bash
pve-host-backup info
pve-host-backup auto-status
pve-host-backup logs
systemctl status cron.service --no-pager
```

Les dumps VM/CT restent visibles et restaurables dans l'interface PVE.

## Désinstallation

```bash
bash scripts/uninstall.sh --yes
```

La désinstallation retire le programme, sa tâche cron et son service. Elle ne
supprime ni les backups finalisés du NAS, ni les dumps VM/CT, ni le stockage
PVE. Le service cron général reste actif afin de ne pas casser d'autres tâches.

## Documentation

- [Commandes et recettes rapides](docs/COMMANDS.md)
- [Architecture technique](docs/ARCHITECTURE.md)
- [Restauration du host](docs/RESTORE.md)
- [Test de restauration](docs/RESTORE-TEST.md)
- [Clone NVMe hors ligne](docs/NVME-CLONE.md)
- [Compatibilité](docs/COMPATIBILITY.md)
- [Dépannage](docs/TROUBLESHOOTING.md)
- [Références officielles](docs/OFFICIAL-REFERENCES.md)

## Confidentialité

Les archives ne sont pas chiffrées. Elles peuvent contenir des clés SSH,
certificats et configurations sensibles. Restreindre les droits NFS/SMB,
activer les snapshots du NAS et conserver au moins une copie hors ligne ou
hors site.
