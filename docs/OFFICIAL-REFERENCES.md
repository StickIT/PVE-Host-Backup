# Références officielles

Consultées pour la version 1.3.0 le 19 août 2026. Le profil utilise
`pve-manager 9.2.10` et `pve-docs 9.2.4`. Toujours relire la documentation
correspondant à la version réellement installée avant une restauration.

## Proxmox VE

- [Documentation Proxmox VE](https://pve.proxmox.com/pve-docs/)  
  Index de la documentation publiée, version 9.2.4 lors de l'audit.

- [Installation de Proxmox VE](https://pve.proxmox.com/pve-docs/chapter-pve-installation.html)  
  Modes d'installation, systèmes de fichiers et création du stockage
  LVM-thin.

- [Backup and Restore — `vzdump`](https://pve.proxmox.com/pve-docs/chapter-vzdump.html)  
  Sauvegarde et restauration natives des VM QEMU et conteneurs LXC.

- [Proxmox VE Storage](https://pve.proxmox.com/pve-docs/chapter-pvesm.html)  
  Modèle de stockage, identifiants de volumes et commande `pvesm`.

- [Backend NFS](https://pve.proxmox.com/pve-docs/pve-storage-nfs-plain.html)  
  Serveur, export, contenus et options du stockage NFS.

- [Réseau Proxmox VE](https://pve.proxmox.com/pve-docs/pve-network-plain.html)  
  Bridges Linux, bonding et mise en garde sur les changements réseau.

- [pmxcfs](https://pve.proxmox.com/pve-docs/pmxcfs.8.html)  
  Fonctionnement de `/etc/pve`, base de configuration et contraintes du
  système de fichiers.

- [Manuel `qmrestore`](https://pve.proxmox.com/pve-docs/qmrestore.1.html) et
  [manuel `pct`](https://pve.proxmox.com/pve-docs/pct.1.html)  
  Restauration en ligne de commande des VM et conteneurs.

- [Notifications PVE](https://pve.proxmox.com/pve-docs/chapter-notifications.html)  
  Cibles et matchers de la plateforme. Le projet utilise séparément le
  `sendmail` local pour rester autonome.

## Formats et cohérence

- [SQLite CLI — `.backup`](https://sqlite.org/cli.html)  
  Création d'une copie transactionnellement cohérente de `config.db`.

- [GNU tar](https://www.gnu.org/software/tar/manual/)  
  Archives, propriétaires numériques, systèmes de fichiers, ACL et xattrs.

- [Zstandard](https://facebook.github.io/zstd/)  
  Compression et test d'intégrité des flux `.zst`.

## Cron Debian

- [cron(8) — Debian 13 trixie](https://manpages.debian.org/trixie/cron/cron.8.en.html)  
  Lecture de `/etc/cron.d`, propriété root, permissions, rechargement des
  fichiers modifiés, journalisation et fuseau provenant de `/etc/localtime`.

- [crontab(5) — Debian 13 trixie](https://manpages.debian.org/trixie/cron/crontab.5.en.html)  
  Format système avec le champ utilisateur, dimanche `0` ou `7`, `MAILTO` et
  limites lorsqu'une machine est éteinte à l'heure planifiée.

## systemd

- [systemd.timer](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
  et [systemd.time](https://www.freedesktop.org/software/systemd/man/systemd.time.html)  
  Ancienne planification 1.2.0 et propriété `Persistent=true` utilisée pour
  rattraper une échéance manquée. La 1.3.0 utilise cron.

- [systemd.resource-control](https://www.freedesktop.org/software/systemd/man/systemd.resource-control.html)  
  `CPUQuota`, `MemoryHigh` et `MemoryMax`. La documentation recommande
  `MemoryHigh` comme mécanisme principal et `MemoryMax` comme dernière ligne de
  défense.

## Clone et récupération disque

- [Téléchargement SystemRescue](https://www.system-rescue.org/Download/) et
  [création de la clé USB](https://www.system-rescue.org/Installing-SystemRescue-on-a-USB-memory-stick/)  
  ISO, sommes de contrôle et écriture de la clé.

- [Outils SystemRescue](https://www.system-rescue.org/System-tools/)  
  Confirme la présence de `lsblk`, LVM, outils NVMe et GNU ddrescue.

- [Manuel GNU ddrescue](https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html)  
  Ordre source/cible/mapfile, reprise et gestion des erreurs.

- [Journal Clonezilla stable](https://clonezilla.org/downloads/stable/changelog.php)  
  Les versions actuelles détectent le thin provisioning LVM et quittent. C'est
  pourquoi la procédure du dépôt n'utilise pas Clonezilla pour `pve-data`.

## Interface PVE et services personnalisés

La vue Services PVE s'appuie sur une liste de services gérés, pas sur toutes
les unités personnalisées :

- [source `ServiceView`](https://github.com/proxmox/proxmox-widget-toolkit/blob/master/src/node/ServiceView.js) ;
- [source API `Services.pm`](https://github.com/proxmox/pve-manager/blob/master/PVE/API2/Services.pm).

Le projet n'altère donc pas l'interface PVE. Le service reste administré par
les interfaces publiques de systemd.

## Récupération avancée pmxcfs

La procédure normale compare `etc-pve.tar.zst` et ne remplace jamais
`config.db`. Pour comprendre un dernier recours hors ligne :

- [discussion Proxmox sur la récupération de `config.db`](https://forum.proxmox.com/threads/how-to-recover-var-lib-pve-cluster-config-db.27393/).

Une discussion de forum ne remplace pas une procédure adaptée au rôle du
nœud, au quorum et à la version. En cluster, demander une assistance Proxmox.
