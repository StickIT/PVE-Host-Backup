# Dépannage

## Diagnostic rapide

Exécuter dans cet ordre :

```bash
pve-host-backup check
pve-host-backup auto-status
systemctl status pve-host-backup.service --no-pager -l
journalctl -u pve-host-backup.service -n 200 --no-pager
pvesm status --storage dreambox-backup
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /mnt/pve/dreambox-backup
```

## `Source NFS inattendue`

Le script refuse d’écrire si le stockage monté n’est pas exactement :

```text
192.168.11.133:/volume1/Proxmox
```

Comparer `/etc/pve/storage.cfg` et le montage réel :

```bash
awk '/^nfs: dreambox-backup$/{show=1} show{print} show && /^$/{exit}' \
  /etc/pve/storage.cfg
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /mnt/pve/dreambox-backup
```

Après un changement d’export, un ancien montage NFS peut rester actif même si
`storage.cfg` contient la nouvelle valeur. Ne pas contourner le contrôle du
script. S’assurer qu’aucun backup n’est actif, puis remonter proprement le
stockage ; un redémarrage planifié du host est également une solution simple
si les VM/CT peuvent être arrêtés proprement.

`pvesm set` ne possède pas d’option `--export` pour modifier ce backend de la
façon utilisée lors de la création. Pour un changement structurel, supprimer
et recréer l’entrée PVE après avoir démonté proprement l’ancien montage est
souvent plus clair. Cela ne supprime pas les fichiers du NAS, mais il faut
conserver exactement le bon chemin et `content-dirs`.

## Le stockage est `inactive`

Vérifier :

```bash
pvesm nfsscan 192.168.11.133
ping -c 3 192.168.11.133
showmount -e 192.168.11.133
```

Contrôler sur le Synology : service NFS actif, export `/volume1/Proxmox`, droits
accordés à l’adresse IP du host PVE et version NFS compatible. Une erreur
`No route to host` est un problème de réseau ou de routage, pas un problème de
mot de passe du script.

## `tar: socket ignored` ou erreur `lxcfs`

La version 1.0.0 exclut :

```text
/var/spool/postfix
/var/lib/lxcfs
```

Vérifier la version :

```bash
pve-host-backup --help | head
```

Si l’ancienne version est encore installée, relancer `scripts/install.sh`.
L’installateur sauvegarde d’abord les anciens fichiers locaux dans
`/usr/local/share/doc/pve-host-backup`.

Le projet considère un code d’erreur `tar` comme un échec, même si Zstandard a
produit un fichier. Il ne faut pas ignorer globalement l’erreur : cela pourrait
valider une archive incomplète.

## `file changed as we read it`

Une sauvegarde à chaud peut rencontrer un fichier très actif. Relever le chemin
exact dans le journal. Les emplacements volatils connus sont déjà exclus. Si le
fichier appartient à une application ajoutée au host, arrêter brièvement cette
application ou définir une exclusion après avoir confirmé que son contenu
n’est pas requis pour la reprise.

Le dossier `.partial-*` est supprimé automatiquement après l’échec. Sinon :

```bash
pve-host-backup cleanup-partials
```

## `Espace insuffisant`

Le minimum par défaut est 5 Gio :

```bash
df -h /mnt/pve/dreambox-backup
du -sh /mnt/pve/dreambox-backup/backups/PVE/host/nukebox/*
```

Ne pas réduire le seuil avant d’avoir mesuré la taille d’une sauvegarde
complète. La rétention s’exécute après la réussite de la nouvelle copie ; il
faut donc de la place pour la copie en cours en plus des sauvegardes conservées.

## Aucun timer n’est listé

C’est normal juste après l’installation : le timer est volontairement
désactivé. L’activer après la validation manuelle :

```bash
pve-host-backup auto-on
pve-host-backup auto-status
```

Pour vérifier le calendrier :

```bash
systemd-analyze calendar 'Sun *-*-* 04:15:00'
```

Le calendrier utilise le fuseau horaire du host ; le nom du dossier de backup
est, lui, en UTC et se termine par `Z`.

## La sauvegarde ne s’arrête pas après `auto-off`

C’est intentionnel. `auto-off` empêche les prochains déclenchements, mais ne
tue pas une sauvegarde déjà active. Vérifier :

```bash
systemctl is-active pve-host-backup.service
journalctl -fu pve-host-backup.service
```

Attendre sa fin évite de produire inutilement une copie partielle.

## `notify-test` réussit mais aucun e-mail n’arrive

Le test confirme seulement que le binaire `sendmail` local a accepté le
message. Inspecter :

```bash
mailq
journalctl -u postfix -n 100 --no-pager
grep '^root:' /etc/aliases
```

Configurer ensuite le relais mail ou l’adresse de destination selon votre
installation PVE. Le journal et `LAST_RUN_STATUS.txt` restent disponibles même
sans notification externe.

## Rien n’apparaît dans `nukebox → System → Services`

La vue PVE n’énumère pas toutes les unités systemd arbitraires ; elle utilise
une liste interne de services PVE. Le service existe néanmoins :

```bash
systemctl status pve-host-backup.service --no-pager
systemctl status pve-host-backup.timer --no-pager
```

Ne pas patcher les fichiers JavaScript/Perl internes de PVE. Une mise à jour
écraserait la modification et pourrait rendre l’interface incohérente.

## Les archives du host ne sont pas dans l’onglet `Backups`

Cet onglet reconnaît les formats guests gérés par PVE. Les archives du host
sont des fichiers autonomes placés dans un sous-dossier dédié. Les consulter
sur le NAS ou avec :

```bash
pve-host-backup status
find /mnt/pve/dreambox-backup/backups/PVE/host/nukebox \
  -maxdepth 2 -type f -printf '%p\n' | sort
```

## `LATEST.txt absent`

Aucune sauvegarde n’a peut-être encore été finalisée. Lister les dossiers :

```bash
find /mnt/pve/dreambox-backup/backups/PVE/host/nukebox \
  -mindepth 1 -maxdepth 1 -type d -name '20??-??-??T??-??-??Z' -printf '%f\n' | sort -r
```

Si un dossier finalisé existe, le vérifier en passant sa date explicitement :

```bash
pve-host-backup verify 2026-08-17T11-31-31Z
```

Ne pas recréer `LATEST.txt` avant d’avoir réussi cette vérification.

## Échec SHA-256 ou Zstandard

Ne pas restaurer l’archive en défaut. Conserver les journaux, vérifier le NAS,
le réseau et la mémoire, puis tester une autre date :

```bash
pve-host-backup verify <AUTRE-DATE>
```

Une somme différente peut indiquer un fichier tronqué, modifié ou une erreur
de stockage. La présence du fichier n’est pas une preuve d’intégrité.

## `Le staging existe déjà`

Le programme refuse d’écraser une extraction précédente. La supprimer avec la
commande contrôlée :

```bash
pve-host-backup unstage latest
pve-host-backup stage latest
```

Ou utiliser une autre date. Le script `scripts/cleanup-tests.sh` supprime tous
les stagings si aucun backup n’est actif.

## La désinstallation refuse de continuer

Elle refuse volontairement de tuer un backup actif. Attendre :

```bash
journalctl -fu pve-host-backup.service
```

Puis relancer :

```bash
bash scripts/uninstall.sh --yes
```

