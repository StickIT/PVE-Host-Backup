# Sauvegarde autonome du host Proxmox VE

Sauvegarde vérifiée du **host PVE** vers un NAS NFS, sans dépendre de Proxmox
Backup Server pour la restauration.

Les VM et conteneurs restent sauvegardés séparément par les jobs `vzdump` de
PVE. Ce projet sauvegarde la configuration et le système du host.

## Réglages par défaut

| Réglage | Valeur |
|---|---|
| Nœud PVE | `nukebox` |
| Stockage NFS PVE | `dreambox-backup` |
| Export Synology | `192.168.11.133:/volume1/Proxmox` |
| Sauvegarde du host | dimanche à `04:15` |
| Rétention | 3 sauvegardes |
| Notifications de succès | désactivées |
| Notifications d’échec | toujours actives avec l’erreur |

## Installation rapide

Sur le host PVE, en `root` :

```bash
git clone https://github.com/StickIT/PVE-Host-Backup.git /var/tmp/PVE-Host-Backup
cd /var/tmp/PVE-Host-Backup
bash scripts/install.sh
```

L’installateur :

- installe les dépendances nécessaires ;
- installe `/usr/local/sbin/pve-host-backup` ;
- crée la configuration et les unités systemd ;
- contrôle le montage NFS et son accès en écriture ;
- laisse la programmation désactivée jusqu’au premier test.

## Configurer simplement

Lancer l’assistant :

```bash
pve-host-backup configure
```

Il demande uniquement :

```text
Heure du dimanche, HH:MM [04:15] :
Nombre de sauvegardes à conserver [3] :
Notifier aussi les succès ? oui/non [non] :
```

Les modifications sont enregistrées immédiatement. Si le timer était actif,
il est automatiquement rechargé avec la nouvelle heure.

Afficher les réglages actuels :

```bash
pve-host-backup settings
```

Configuration non interactive, utile dans un script :

```bash
pve-host-backup configure \
  --time 03:30 \
  --retention 5 \
  --notify-success off
```

Valeurs acceptées pour `--notify-success` : `on`, `off`, `oui`, `non`, `1` ou
`0`.

> L’heure utilise le fuseau horaire local du host PVE. La programmation reste
> hebdomadaire, le dimanche.

## Fonctionnement des notifications

Par défaut :

- aucune notification n’est envoyée quand une sauvegarde réussit ;
- un échec déclenche toujours une notification contenant l’erreur détectée et
  invite à consulter le journal systemd ;
- le résultat est également écrit dans `LAST_RUN_STATUS.txt` sur le NAS.

Le programme utilise le système `sendmail` local. Il faut configurer le relais
mail ou l’adresse de `root` dans PVE pour recevoir le message à l’extérieur.

Tester volontairement le système mail, même si les succès sont désactivés :

```bash
pve-host-backup notify-test
```

## Premier test obligatoire

### 1. Contrôler le stockage

```bash
pve-host-backup check
```

Le script refuse d’écrire si `/mnt/pve/dreambox-backup` n’est pas monté depuis
`192.168.11.133:/volume1/Proxmox`.

### 2. Lancer une sauvegarde manuelle

```bash
systemctl start --no-block pve-host-backup.service
journalctl -fu pve-host-backup.service
```

`Ctrl+C` quitte seulement l’affichage du journal ; la sauvegarde continue.

### 3. Vérifier le résultat

```bash
pve-host-backup status
pve-host-backup verify latest
```

### 4. Tester une extraction sans restaurer

```bash
pve-host-backup stage latest
```

L’extraction se fait uniquement sous `/var/tmp/pve-host-restore/<DATE>/`.
Elle ne modifie pas le système actif.

Après inspection :

```bash
pve-host-backup unstage latest
```

## Activer ou désactiver les sauvegardes automatiques

Activer :

```bash
pve-host-backup auto-on
```

Afficher l’état et la prochaine exécution :

```bash
pve-host-backup auto-status
```

Désactiver :

```bash
pve-host-backup auto-off
```

`auto-off` n’interrompt pas une sauvegarde déjà en cours ; il empêche seulement
les prochains déclenchements.

## Arborescence sur le NAS

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
                └── <DATE-UTC>/
                    ├── rootfs.tar.zst
                    ├── etc-pve.tar.zst
                    ├── boot-efi.tar.zst
                    ├── recovery.tar.zst
                    ├── SHA256SUMS
                    ├── MANIFEST.txt
                    ├── RESTORE_HOST_PVE.txt
                    ├── pve-host-backup
                    └── pve-host-backup.conf
```

`boot.tar.zst` ou `boot-efi.tar.zst` peut être absent lorsque le répertoire
correspondant n’est pas un système de fichiers séparé.

## Contenu sauvegardé

- système du host PVE ;
- `/etc/pve` dans une archive distincte ;
- copie SQLite cohérente de `config.db` ;
- configuration réseau, boot, modules et services ;
- inventaires des disques, partitions, LVM, ZFS, PCI et USB ;
- liste des stockages, jobs, VM et CT ;
- programme et configuration nécessaires à la reprise.

Ne sont pas inclus :

- disques des VM et CT ;
- montages NFS/SMB externes ;
- ISO, caches, journaux et données volatiles ;
- sockets Postfix et système de fichiers `lxcfs`.

Les archives sont testées avec Zstandard et protégées par `SHA256SUMS` avant
d’être considérées comme finalisées.

## Rétention

La rétention concerne uniquement les sauvegardes finalisées du host. Elle ne
modifie pas la rétention des dumps VM/CT configurée dans PVE.

Pour passer, par exemple, à 7 sauvegardes :

```bash
pve-host-backup configure --retention 7
```

Le nettoyage est effectué après la réussite d’une nouvelle sauvegarde. Les
dossiers incomplets `.partial-*` ne sont jamais considérés comme valides.

## Visibilité dans PVE

Cette sauvegarde du host n’est pas un job `vzdump` natif :

- elle n’apparaît pas dans l’onglet **Backups** du stockage ;
- son service personnalisé n’apparaît généralement pas dans
  **nukebox → System → Services** ;
- aucun fichier interne de PVE n’est modifié pour contourner cette limite.

Le suivi se fait avec :

```bash
pve-host-backup status
pve-host-backup auto-status
journalctl -u pve-host-backup.service -n 100 --no-pager
```

## Restauration

La sauvegarde est autonome : les `.tar.zst` peuvent être lus avec GNU tar et
Zstandard, sans PBS.

Toujours commencer par :

```bash
pve-host-backup verify latest
pve-host-backup stage latest
```

Ne jamais extraire `rootfs.tar.zst` directement sur `/` d’un host en
fonctionnement. Après une perte totale, réinstaller une version majeure
compatible de PVE avec le même nom de nœud, remonter le NFS, mettre les archives
en staging, puis restaurer sélectivement.

Procédure détaillée : [docs/RESTORE.md](docs/RESTORE.md).

## Mise à jour depuis une ancienne version

Récupérer la nouvelle version du dépôt puis relancer :

```bash
bash scripts/install.sh
```

L’installateur :

- sauvegarde les anciens fichiers locaux avec un horodatage ;
- conserve la configuration existante ;
- récupère automatiquement l’ancienne heure de la version 1.0.0 ;
- ajoute `NOTIFY_SUCCESS=0` si le réglage n’existait pas ;
- désactive le timer par sécurité après la mise à jour.

Contrôler ensuite :

```bash
pve-host-backup configure
pve-host-backup check
systemctl start --no-block pve-host-backup.service
pve-host-backup verify latest
pve-host-backup auto-on
```

## Copier/coller sans téléchargement dans `/root`

Ouvrir `scripts/install.sh` sur GitHub, copier son contenu puis :

```bash
nano /var/tmp/install-pve-host-backup.sh
```

Coller, enregistrer avec `Ctrl+O`, valider avec Entrée, quitter avec `Ctrl+X`,
puis :

```bash
bash /var/tmp/install-pve-host-backup.sh
rm -f /var/tmp/install-pve-host-backup.sh
```

## Nettoyer les tests

```bash
bash scripts/cleanup-tests.sh
```

Ce script conserve les sauvegardes finalisées et les dumps VM/CT.

## Désinstallation

Afficher d’abord les conséquences :

```bash
bash scripts/uninstall.sh
```

Confirmer :

```bash
bash scripts/uninstall.sh --yes
```

Les sauvegardes finalisées du NAS, les dumps VM/CT et le stockage PVE sont
conservés.

## Commandes disponibles

```text
pve-host-backup configure
pve-host-backup configure --time HH:MM --retention N --notify-success on|off
pve-host-backup settings
pve-host-backup check
pve-host-backup run
pve-host-backup status
pve-host-backup verify [latest|DATE]
pve-host-backup stage [latest|DATE]
pve-host-backup unstage [latest|DATE]
pve-host-backup cleanup-partials
pve-host-backup manual
pve-host-backup notify-test
pve-host-backup auto-on
pve-host-backup auto-off
pve-host-backup auto-status
```

## Vérifier le dépôt

```bash
bash tests/validate.sh
```

## Documentation complémentaire

- [Architecture technique](docs/ARCHITECTURE.md)
- [Guide de restauration](docs/RESTORE.md)
- [Dépannage](docs/TROUBLESHOOTING.md)
- [Références officielles](docs/OFFICIAL-REFERENCES.md)

> Ce projet est un script communautaire et non une fonction officielle de
> Proxmox VE.
