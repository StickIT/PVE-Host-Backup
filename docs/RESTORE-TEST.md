# Répétition complète de restauration sur la même machine

## Ce qu'un vrai test doit démontrer

Une vérification SHA-256 prouve que les archives sont lisibles. Elle ne prouve
pas à elle seule que le réseau, le boot, LVM, les stockages et les guests
fonctionneront après un remplacement du NVMe. Le test le plus représentatif
est une réinstallation sur `nukebox`, avec l'ancien NVMe physiquement retiré.

L'assistant 1.2.0 est audité pour PVE `9.2.10`, Debian 13, un nœud autonome et
la topologie réseau décrite dans [COMPATIBILITY.md](COMPATIBILITY.md). Il a des
tests statiques et des garde-fous, mais seule votre répétition matérielle peut
valider l'ensemble de la chaîne sur votre firmware, switch et NAS.

## Organisation selon le nombre de NVMe disponibles

| Matériel disponible | Stratégie fiable |
|---|---|
| Deux NVMe de rechange | Garder un clone intact et utiliser l'autre pour la réinstallation de test. |
| Un NVMe de rechange | Retirer et conserver l'original intact, puis utiliser le rechange pour la réinstallation. L'original constitue le retour arrière. Refaire ensuite un clone si souhaité. |
| Aucun NVMe de rechange | Tester seulement l'audit dans une VM imbriquée. Cela ne valide ni le boot réel, ni les NIC, ni LVM-thin physique. |

Ne jamais connecter simultanément deux systèmes clonés avec le même hostname,
la même IP et les mêmes UUID LVM.

## 1. Préparer les preuves avant l'arrêt

Créer une sauvegarde avec la version 1.2.0, puis :

```bash
pve-host-backup check
systemctl start --no-block pve-host-backup.service
journalctl -fu pve-host-backup.service
pve-host-backup verify latest
pve-host-backup status
```

Quitter le suivi du journal avec `Ctrl+C` ne stoppe pas le service. Attendre
`Deactivated successfully` avant de continuer.

Copier le dernier dossier finalisé sur une clé USB. Copier **le dossier entier**
avec `SHA256SUMS`, les archives, `pve-host-restore` et la configuration. Cette
copie permet de restaurer le réseau avant que le NFS soit joignable.

Conserver également hors de la machine :

- l'ISO PVE 9.2 utilisée ;
- ce dépôt et ses documents ;
- les paramètres réseau `nic0`, `nic1`, `bond0`, `vmbr0` ;
- IP `192.168.11.104/24`, passerelle `192.168.11.1` ;
- NFS `192.168.11.133:/volume1/Proxmox` ;
- accès à l'interface du switch pour vérifier le LAG/LACP ;
- un mot de passe root de reprise stocké de manière sûre.

Noter l'identifiant du dernier backup :

```bash
cat /mnt/pve/dreambox-backup/backups/PVE/host/nukebox/LATEST.txt
```

## 2. Créer le retour arrière matériel

Si vous voulez un clone supplémentaire, suivre
[NVME-CLONE.md](NVME-CLONE.md). Dans tous les cas :

1. arrêter les guests ;
2. éteindre PVE ;
3. retirer le NVMe actuel sans l'altérer ;
4. l'étiqueter et le ranger hors ligne ;
5. installer uniquement le NVMe vierge de test.

L'ancien NVMe ne doit pas rester dans un deuxième slot pendant le test.

## 3. Faire une installation PVE propre

Installer PVE en mode UEFI, sur le NVMe vierge, avec :

- hostname `nukebox` ;
- nœud autonome, sans cluster ;
- Debian 13 / PVE 9 ;
- stockage local LVM-thin ;
- idéalement le même choix ext4 pour `pve-root` ;
- une IP temporaire ou finale qui ne crée aucun conflit.

Mettre le PVE réinstallé à jour **avant** d'appliquer une configuration. Le
verdict le plus sûr est obtenu avec `pve-manager 9.2.10`, identique au backup.
Une version plus récente dans la même majeure donne un verdict orange ; une
version plus ancienne que celle du backup ou une autre majeure bloque les
écritures.

Contrôler :

```bash
pveversion -v
cat /etc/os-release
hostname -s
test -e /etc/pve/corosync.conf && echo CLUSTER || echo AUTONOME
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /
```

## 4. Amorcer l'assistant depuis la clé USB

Monter la clé et repérer le dossier daté complet. Les chemins suivants sont
des exemples à adapter :

```bash
install -m 0750 /mnt/usb/DATE/pve-host-restore /usr/local/sbin/pve-host-restore
install -m 0600 /mnt/usb/DATE/pve-host-backup.conf /etc/pve-host-backup.conf
apt-get update
apt-get install -y zstd sqlite3 gdisk fdisk dmidecode
```

Lancer l'audit directement depuis le dossier USB :

```bash
pve-host-restore audit /mnt/usb/DATE
```

Le mode `audit` crée seulement un staging et des rapports locaux. Il ne copie
aucun fichier dans la configuration active.

À l'étape réseau, choisir « même machine physique ». L'assistant compare DMI,
CPU et mode de boot. Il affiche le fichier candidat, valide sa syntaxe avec
`ifquery`, mais ne l'applique jamais depuis SSH. Utiliser la console locale.

Le réseau sauvegardé suppose que les deux ports du switch sont configurés dans
le même LAG 802.3ad. Si ce n'est plus vrai, ne pas appliquer le candidat.

## 5. Appliquer uniquement après un audit compris

Si le verdict est vert :

```bash
pve-host-restore wizard /mnt/usb/DATE
```

Si le verdict est orange, ou pour choisir chaque lot :

```bash
pve-host-restore guided /mnt/usb/DATE
```

L'assistant demande une phrase exacte avant le réseau et le stockage. Il ne
recharge pas le réseau automatiquement et arrête volontairement la session
dès que ce fichier change. Après l'installation du fichier réseau :

1. noter l'identifiant de session affiché dans le rapport ;
2. vérifier encore `/etc/network/interfaces` en console ;
3. redémarrer sans démarrer les guests ;
4. confirmer l'accès web, l'IP, la route et le bond.

Commandes de contrôle :

```bash
ip -br link
ip -br address
ip route
cat /proc/net/bonding/bond0
ifquery -i /etc/network/interfaces -a
systemctl --failed
```

Le NFS n'a volontairement pas encore été ajouté. Reprendre depuis l'USB ; le
réseau étant désormais identique, le wizard passe au stockage :

```bash
pve-host-restore audit /mnt/usb/DATE
pve-host-restore wizard /mnt/usb/DATE
findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS /mnt/pve/dreambox-backup
pvesm status --storage dreambox-backup
```

Noter aussi l'identifiant de cette deuxième session.

## 6. Vérifier exactement les fichiers appliqués

Après le retour du NFS et, si demandé, un nouveau redémarrage :

```bash
pve-host-restore verify-session SESSION-RESEAU
pve-host-restore verify-session SESSION-SUIVANTE
```

Cette commande :

- recalcule le SHA-256 de chaque fichier réellement copié par la session ;
- vérifie que le stockage ajouté répond ;
- valide `/etc/network/interfaces` avec ifupdown2 ;
- signale les unités systemd en échec ;
- produit un rapport sous `/var/lib/pve-host-restore/sessions/`.

Un résultat vert ne valide pas encore les applications des guests.

## 7. Restaurer un seul guest pilote

Vérifier les dumps :

```bash
pvesm list dreambox-backup --content backup
```

Restaurer d'abord un guest non critique depuis l'interface PVE ou le mode
guidé. Ne pas réutiliser un VMID déjà créé par erreur. Garder le guest arrêté,
contrôler sa configuration, puis le démarrer et vérifier réseau, disque et
application.

Les commandes natives sont :

```bash
qmrestore VOLID VMID --storage local-lvm
pct restore CTID VOLID --storage local-lvm
```

Consulter `qmrestore --help` et `pct restore --help` sur la version installée
avant l'exécution.

## 8. Critères de réussite

Le test est réussi uniquement si :

- les SHA-256 et Zstandard sont valides ;
- le verdict correspond au scénario attendu ;
- PVE redémarre deux fois sans intervention de secours ;
- `pve-cluster`, `pvedaemon`, `pveproxy` et `pvestatd` sont actifs ;
- `vmbr0` porte `192.168.11.104/24` ;
- `bond0` est actif avec `nic0` et `nic1` ;
- la route par défaut utilise `192.168.11.1` ;
- le NFS vient exactement de `192.168.11.133:/volume1/Proxmox` ;
- `verify-session` est réussi ;
- au moins un dump guest est restauré et démarré ;
- la procédure de rollback a été comprise et le rapport est conservé.

## 9. Tester le retour arrière de l'assistant

Sur le NVMe de test uniquement, choisir une session ayant appliqué au moins un
fichier non critique, puis :

```bash
pve-host-restore rollback IDENTIFIANT-DE-SESSION
```

L'assistant rétablit les copies réalisées avant la session, sans recharger le
réseau. Redémarrer et refaire les contrôles. Ce rollback ne remet pas le disque
entier à son état précédent ; le vrai retour arrière intégral reste le NVMe
original/clone hors ligne.

## 10. Revenir à l'installation originale

1. éteindre complètement le host de test ;
2. retirer le NVMe de test ;
3. remettre seul le NVMe original ;
4. démarrer et contrôler PVE ;
5. ne jamais mettre les deux installations en ligne simultanément.

Consigner la date du test, les versions exactes, les écarts rencontrés et les
corrections nécessaires dans votre dépôt. Une nouvelle majeure PVE nécessite
un nouvel audit avant d'autoriser les écritures.
