# Clone hors ligne du NVMe de `nukebox`

## Objectif

Un clone bloc à bloc du NVMe donne le retour arrière le plus direct en cas de
panne du disque système. Dans votre configuration, il copie en une fois :

- GPT et partition EFI ;
- Debian/Proxmox VE et le chargeur GRUB ;
- le volume LVM `pve-root` ;
- le thin-pool `pve-data` ;
- les disques locaux des VM 100 et 200 présents dans ce thin-pool.

Il s'agit d'un **instantané physique daté**, pas d'une sauvegarde continue. Il
ne remplace ni les dumps VM/CT sur le NAS ni les sauvegardes du host.

## Pourquoi SystemRescue et GNU ddrescue

Le NVMe actuel contient un thin-pool LVM. Le journal officiel de Clonezilla
stable indique que les versions actuelles détectent le thin provisioning LVM
et quittent le programme. Cette procédure utilise donc SystemRescue et GNU
ddrescue, qui copient le périphérique bloc complet sans interpréter le
thin-pool.

Références :

- [limitation LVM-thin de Clonezilla](https://clonezilla.org/downloads/stable/changelog.php) ;
- [outils présents dans SystemRescue](https://www.system-rescue.org/System-tools/) ;
- [téléchargement et sommes de contrôle SystemRescue](https://www.system-rescue.org/Download/) ;
- [manuel GNU ddrescue](https://www.gnu.org/software/ddrescue/manual/ddrescue_manual.html).

## Règles de sécurité non négociables

1. Le clonage se fait **PVE complètement arrêté**, depuis SystemRescue.
2. Le disque cible sera entièrement écrasé.
3. Sa taille exacte en octets doit être supérieure ou égale à celle de la
   source. Deux NVMe vendus comme « 1 To » peuvent différer de quelques octets.
4. Les noms `/dev/nvme0n1` et `/dev/nvme1n1` peuvent changer au démarrage.
   Identifier les deux disques par **modèle, numéro de série et taille**.
5. Le mapfile ddrescue doit se trouver sur un troisième support persistant,
   jamais sur la source ou la cible.
6. Après clonage, ne jamais démarrer avec l'original et le clone connectés en
   même temps : leurs UUID GPT, LVM et fichiers systèmes sont identiques.

## Matériel conseillé

- un NVMe de remplacement au moins aussi grand que le WDC PC SN730 1 To ;
- un boîtier/adaptateur NVMe fiable si la machine n'a qu'un emplacement libre ;
- une clé USB SystemRescue ;
- une petite seconde clé USB pour le mapfile et le rapport de clonage ;
- idéalement un deuxième NVMe de test si l'on veut conserver le clone intact
  tout en répétant une restauration propre.

## 1. Préparer le clone depuis PVE

Vérifier d'abord les sauvegardes :

```bash
pve-host-backup verify latest
pve-host-backup status
pvesm list dreambox-backup --content backup
```

Enregistrer ou photographier l'identité du disque source :

```bash
lsblk -d -e 7 -o NAME,PATH,SIZE,MODEL,SERIAL
nvme list
blockdev --getsize64 /dev/nvme0n1
smartctl -a /dev/nvme0n1
```

Dans la configuration observée le 18 août 2026, la source est un
`WDC PC SN730 SDBPNTY-1T00-1101` de 953,9 Gio. Le **numéro de série réel**
affiché par votre machine reste le critère principal.

Arrêter proprement les VM/CT depuis PVE, puis éteindre le host :

```bash
shutdown -h now
```

Ne jamais lancer le clonage bloc depuis le PVE actif.

## 2. Créer et vérifier la clé SystemRescue

Télécharger l'ISO et son fichier SHA-256 depuis le site officiel. Vérifier la
somme avant d'écrire la clé. Sous Windows, la documentation SystemRescue
propose Rufus et recommande le mode ISO ; voir la
[procédure USB officielle](https://www.system-rescue.org/Installing-SystemRescue-on-a-USB-memory-stick/).

## 3. Identifier source et cible dans SystemRescue

Connecter le NVMe d'origine et le NVMe cible, puis démarrer exclusivement sur
la clé SystemRescue. Dans un terminal root :

```bash
lsblk -d -e 7 -o NAME,PATH,SIZE,MODEL,SERIAL
nvme list
```

Écrire sur papier les deux chemins :

```text
SOURCE = /dev/...  modèle ..., série ..., taille ...
CIBLE  = /dev/...  modèle ..., série ..., taille ...
```

Pour chaque chemin réellement identifié, afficher la taille exacte :

```bash
blockdev --getsize64 /dev/REMPLACER_SOURCE
blockdev --getsize64 /dev/REMPLACER_CIBLE
```

Ne pas continuer si la cible est plus petite, même légèrement, ou si un
numéro de série reste ambigu.

## 4. S'assurer que rien n'est utilisé

Afficher montages, LVM et swap :

```bash
lsblk -e 7 -o NAME,PATH,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
findmnt
swapon --show
pvs
vgs
lvs
```

Fermer le gestionnaire de fichiers graphique, démonter toute partition source
ou cible éventuellement montée, puis :

```bash
swapoff -a
vgchange -an
```

Relancer `lsblk` et `findmnt`. Aucune partition de la source ou de la cible ne
doit avoir de point de montage.

Monter ensuite la **troisième clé** réservée au mapfile. L'exemple ci-dessous
contient volontairement un nom non valide à remplacer :

```bash
install -d -m 0700 /mnt/ddrescue-map
mount /dev/REMPLACER_CLE_MAP /mnt/ddrescue-map
```

## 5. Lancer le clonage

La syntaxe de ddrescue est toujours :

```text
ddrescue [options] SOURCE CIBLE MAPFILE
```

Après une dernière vérification des séries, remplacer les deux chemins dans la
commande suivante. `--ask` ajoute une confirmation native et `--force` est
nécessaire pour écrire vers un périphérique bloc :

```bash
ddrescue --ask --force --verbose --no-scrape \
  /dev/REMPLACER_SOURCE \
  /dev/REMPLACER_CIBLE \
  /mnt/ddrescue-map/nukebox-nvme.map
```

Le mapfile permet de reprendre exactement le même clonage après interruption.
Après tout redémarrage de SystemRescue, **réidentifier les disques** avant de
relancer la commande ; leurs noms peuvent avoir changé.

Afficher le résultat :

```bash
ddrescuelog --show-status /mnt/ddrescue-map/nukebox-nvme.map
ddrescuelog --done-status /mnt/ddrescue-map/nukebox-nvme.map
```

Si ddrescue signale une erreur de lecture, ne pas multiplier aveuglément les
passes. Conserver le mapfile, éteindre la machine et décider si le disque est
en train de tomber en panne. Une passe directe avec retries est utile en
récupération, mais peut aussi solliciter davantage un support défaillant.

## 6. Vérifier un clone provenant d'un NVMe sain

Pour un clonage préventif sans erreur de lecture, une comparaison intégrale
est la preuve la plus forte. Elle relit environ 1 To sur chaque NVMe et peut
prendre plusieurs heures :

```bash
cmp --bytes="$(blockdev --getsize64 /dev/REMPLACER_SOURCE)" \
  /dev/REMPLACER_SOURCE \
  /dev/REMPLACER_CIBLE
```

Un retour sans message avec un code `0` signifie que tous les octets comparés
sont identiques. Ne pas effectuer cette seconde lecture sur un NVMe source qui
présente déjà des erreurs matérielles sans avis adapté à la récupération.

Terminer par :

```bash
sync
umount /mnt/ddrescue-map
poweroff
```

## 7. Tester le clone sans collision d'UUID

1. Couper physiquement l'alimentation.
2. Retirer et étiqueter le NVMe original avec la date.
3. Installer uniquement le clone.
4. Démarrer la machine.
5. Contrôler sans démarrer tous les guests immédiatement :

```bash
pveversion -v
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /
lsblk -e 7 -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
pvs
vgs
lvs -a
pvesm status
qm list
pct list
systemctl --failed
```

Vérifier ensuite l'interface web, le bond `bond0`, `vmbr0`, le NFS et un guest
non critique. Éteindre, retirer le clone et le conserver déconnecté.

## 8. Fréquence et conservation

Refaire un clone après une modification majeure de PVE, du partitionnement ou
des disques locaux. Inscrire sur l'étiquette : date, host, version PVE,
numéro de série source et résultat de la comparaison.

Un clone unique connecté en permanence n'est pas une protection : une erreur
humaine, une surtension ou une corruption peut toucher les deux disques. Le
clone de secours doit rester hors ligne et les sauvegardes NAS doivent avoir
leur propre historique/snapshots.
