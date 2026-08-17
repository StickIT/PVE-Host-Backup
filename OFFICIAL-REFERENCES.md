# Références officielles

Consultées pour la version 1.0.0 du dépôt. Toujours vérifier la documentation
correspondant à la version majeure de PVE installée avant une restauration.

## Proxmox VE

- [Backup and Restore — chapitre `vzdump`](https://pve.proxmox.com/pve-docs/chapter-vzdump.html)  
  Sauvegarde et restauration natives des VM QEMU et conteneurs LXC.

- [Proxmox VE Storage](https://pve.proxmox.com/pve-docs/chapter-pvesm.html)  
  Modèle de stockage, identifiants de volumes et commande `pvesm`.

- [Backend NFS de Proxmox VE](https://pve.proxmox.com/pve-docs/pve-storage-nfs-plain.html)  
  Configuration du serveur, de l’export, du contenu et des options NFS.

- [pmxcfs — Proxmox Cluster File System](https://pve.proxmox.com/pve-docs/pmxcfs.8.html)  
  Fonctionnement de `/etc/pve`, réplication de la configuration et contraintes
  du système de fichiers.

- [Système de notifications Proxmox VE](https://pve.proxmox.com/pve-docs/chapter-notifications.html)  
  Cibles, matchers et acheminement des notifications PVE. Le `sendmail` local
  utilisé par ce dépôt reste un mécanisme plus simple et séparé.

- [Manuel `qmrestore`](https://pve.proxmox.com/pve-docs/qmrestore.1.html)  
  Restauration en ligne de commande d’un dump de VM QEMU.

- [Manuel `pct`](https://pve.proxmox.com/pve-docs/pct.1.html)  
  Gestion et restauration des conteneurs LXC.

## Pourquoi le service n’est pas ajouté à l’interface

Les dépôts officiels montrent que la vue des services PVE et son API travaillent
avec une liste définie de services, et non avec toutes les unités personnalisées
du host :

- [Source de la vue `ServiceView`](https://github.com/proxmox/proxmox-widget-toolkit/blob/master/src/node/ServiceView.js)
- [Source de l’API PVE `Services.pm`](https://github.com/proxmox/pve-manager/blob/master/PVE/API2/Services.pm)

Le projet utilise donc l’interface stable de systemd et ne modifie aucun fichier
interne de PVE.

## Formats et planification

- [SQLite CLI — commande `.backup`](https://sqlite.org/cli.html)  
  Création d’une copie cohérente de `config.db`.

- [GNU tar — manuel officiel](https://www.gnu.org/software/tar/manual/)  
  Archives, propriétaires numériques, systèmes de fichiers, ACL et attributs.

- [Zstandard — documentation officielle](https://facebook.github.io/zstd/)  
  Compression et test d’intégrité des flux `.zst`.

- [systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)  
  Timers, persistance et déclenchement des services.

- [systemd.time](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html)  
  Syntaxe des calendriers `OnCalendar` et durées.

## Récupération avancée de pmxcfs

La procédure principale de ce dépôt utilise `etc-pve.tar.zst` et évite de
remplacer la base pmxcfs. Pour comprendre le dernier recours hors ligne :

- [Forum Proxmox — récupération de `config.db`](https://forum.proxmox.com/threads/how-to-recover-var-lib-pve-cluster-config-db.27393/)  
  Un membre du staff indique que `pmxcfs -l` peut servir à extraire la
  configuration en mode local dans un contexte de récupération, tout en
  avertissant de ne pas l’utiliser sur un véritable cluster à conserver.

Un fil de forum, même avec une réponse du staff, ne remplace pas une procédure
adaptée à l’état réel d’un cluster. En cas de doute, ouvrir un ticket Proxmox en
fournissant la version, la topologie, l’état du quorum et la copie vérifiée de
`config.db`.

