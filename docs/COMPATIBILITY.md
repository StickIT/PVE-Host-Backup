# Compatibilité et périmètre audité

## Profil `nukebox-pve9`

La version 1.3.0 a été conçue et auditée le 19 août 2026 à partir de
l'inventaire suivant :

| Élément | Valeur de référence |
|---|---|
| Host | `nukebox` |
| Topologie PVE | nœud autonome, sans `corosync.conf` |
| `proxmox-ve` | `9.2.0` |
| `pve-manager` | `9.2.10` |
| Documentation PVE installée | `pve-docs 9.2.4` |
| Debian | 13.6 `trixie` |
| Noyau | `7.0.14-11-pve` |
| CPU | 24 threads logiques |
| RAM | environ 30 Gio, swap 8 Gio |
| Boot | UEFI avec GRUB ; absence attendue de `/etc/kernel/proxmox-boot-uuids` |
| Racine | `pve-root`, ext4, LVM |
| Données locales | thin-pool LVM `pve-data` |
| NVMe observé | WDC PC SN730 1 To |
| Bridge | `vmbr0`, `192.168.11.104/24`, passerelle `192.168.11.1` |
| Bond | `bond0`, esclaves `nic0 nic1`, mode `802.3ad`, hash `layer2+3` |
| NAS | `192.168.11.133:/volume1/Proxmox` |
| Stockage PVE | `dreambox-backup` |

## Ce que signifie « audité »

Les scripts passent :

- l'analyse syntaxique Bash ;
- des tests internes sur les identifiants, IP, profils et transformations de
  réseau ;
- l'analyse du service systemd et de la ligne `/etc/cron.d` ;
- des contrôles statiques des exclusions, ressources et commandes exposées.

Cela ne signifie pas qu'une perte réelle du NVMe a été reproduite sur votre
matériel. La validation finale exige la répétition décrite dans
[RESTORE-TEST.md](RESTORE-TEST.md). Le dépôt ne promet jamais une restauration
bare-metal sans réinstallation : les archives du host sont sélectives.

## Verdicts de l'assistant

| Verdict | Situation | Effet |
|---|---|---|
| Vert | PVE/docs/noyau/boot/FS racine audités et identiques, Debian 13, hostname identique, profil détaillé présent, même machine déclarée et preuves DMI/CPU cohérentes | Wizard prudent autorisé. Chaque action critique reste confirmée. |
| Orange | Même majeure PVE mais version plus récente, matériel différent/incertain, ou ancien backup sans profil 1.2.0 | Comparaison et confirmations lot par lot. Le réseau personnalisé n'est appliqué que sur la même machine. |
| Rouge | Cluster, majeure différente, PVE actuel plus ancien que le backup, hostname différent, Debian non auditée ou incohérence matérielle grave | Aucune écriture ; audit seulement. |

Le numéro de série et l'UUID du NVMe peuvent légitimement changer lors d'un
remplacement. Ils sont affichés mais ne provoquent pas à eux seuls un verdict
rouge. En revanche, DMI, CPU ou mode UEFI incohérents alors que l'utilisateur
déclare « même machine » bloquent les écritures.

## Backups antérieurs

Les archives 1.1.0 restent vérifiables et extractibles. Elles n'ont pas le
fichier `recovery/inventory/restore-profile.txt` complet, donc l'assistant ne
peut pas produire un verdict vert. Les backups 1.2.0 disposent déjà du profil
de reprise et restent utilisables. Créer au moins une sauvegarde 1.3.0 validée
après la migration afin d'embarquer les derniers outils et la configuration
cron.

## Versions PVE ultérieures

- Une mise à jour de correctifs dans PVE 9 doit déclencher un nouvel audit des
  différences et une répétition `audit`.
- Une nouvelle version mineure peut fonctionner en mode orange, mais il faut
  revoir les fichiers et commandes PVE qui ont changé.
- PVE 10 ou une autre majeure est volontairement bloquée tant que le code et
  la documentation n'ont pas été réaudités.
- Le passage d'un nœud autonome à un cluster exige une procédure distincte ;
  ne pas contourner le blocage.

Mettre à jour dans le code les constantes `AUDITED_PVE_MANAGER`,
`AUDITED_PVE_DOCS`, `SUPPORTED_PVE_MAJOR` et `AUDIT_DATE` uniquement après un
audit réel, puis augmenter la version du dépôt et documenter les tests.
