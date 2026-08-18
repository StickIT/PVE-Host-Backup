# Journal des versions

## 1.3.0 — 2026-08-19

- Remplacement du timer systemd par une tâche Debian cron sous
  `/etc/cron.d/pve-host-backup`.
- Cron déclenche toujours le service systemd afin de conserver les quotas,
  priorités, journaux et protections existants.
- Migration automatique : désactivation et suppression de l'ancien timer lors
  de l'installation ; la nouvelle tâche reste désactivée jusqu'aux tests.
- Ajout du menu interactif `pve-host-backup menu`.
- Ajout des commandes simples `now`, `info`, `logs`, `follow`,
  `verify-latest`, `on` et `off`.
- Réécriture du README autour des actions courantes, de l'impact ressources et
  de la limite de rattrapage de cron.
- Ajout de `docs/COMMANDS.md` comme aide-mémoire opérationnel.
- Désinstallation sécurisée de la tâche cron sans arrêter le démon cron
  général du host.

## 1.2.0 — 2026-08-18

- Ajout de `pve-host-restore` avec modes `audit`, `wizard` et `guided`.
- Comparaison PVE/Debian, hostname, cluster, DMI, CPU, boot, NVMe, UUID et réseau.
- Verdict vert/orange/rouge et blocage des écritures incompatibles.
- Profil initial documenté pour `nukebox`, PVE 9.2.10 et Debian 13.
- Protection permanente de `config.db`, GPT/LVM, fstab, boot/EFI, certificats et copie récursive de `/etc/pve`.
- Candidat réseau `bond0`/`vmbr0` validé par ifupdown2, application refusée via SSH.
- Recréation du NFS avec `pvesm` et restauration native optionnelle d'un guest pilote.
- Rollback par session et commande `verify-session` après redémarrage.
- Copie de l'assistant dans chaque backup et audit possible depuis une clé USB.
- Ajout du profil de reprise matériel/réseau dans `recovery/inventory`.
- Quota CPU, `MemoryHigh`, `MemoryMax` et threads Zstandard configurables.
- Noms de dossiers en heure locale avec décalage UTC ; compatibilité conservée avec les noms `Z`.
- Procédures de répétition sur la même machine et de clone NVMe hors ligne avec GNU ddrescue.
- Désinstallation étendue à l'assistant, aux drop-ins et aux états de restauration locaux.

## 1.1.0 — 2026-08-17

- Ajout de `pve-host-backup configure`, assistant interactif unique.
- Heure hebdomadaire configurable simplement au format `HH:MM`.
- Rétention configurable sans modifier manuellement le script.
- Notifications de succès désactivées par défaut.
- Notifications d’échec toujours actives avec le détail de l’erreur.
- Ajout de `pve-host-backup settings` pour afficher les réglages.
- Suppression du délai aléatoire afin que l’heure configurée soit prévisible.
- Migration automatique de l’heure définie par la version 1.0.0.

## 1.0.0 — 2026-08-17

- Première version du dépôt GitHub.
- Archive du système PVE, de `/etc/pve`, du démarrage et des métadonnées de reprise.
- Exclusion des disques VM/CT, montages externes et systèmes de fichiers volatils.
- Correction des erreurs provoquées par `lxcfs` et les sockets Postfix.
- Copie SQLite cohérente de `config.db` avec `PRAGMA integrity_check`.
- Validation SHA-256 et Zstandard avant finalisation atomique.
- Rétention des trois dernières sauvegardes finalisées par défaut.
- Commandes `auto-on`, `auto-off` et `auto-status`.
- Extraction sûre en staging avec `stage` et suppression avec `unstage`.
- Scripts séparés de nettoyage et de désinstallation conservant les sauvegardes finales.
