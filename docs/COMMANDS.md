# Commandes et recettes rapides

Cette fiche concerne PVE Host Backup 1.3.0.

## Menu

```bash
pve-host-backup menu
```

## Exploitation quotidienne

```bash
# État, dernier résultat, backups présents et cron
pve-host-backup info

# Lancer un backup sans bloquer la console
pve-host-backup now

# Suivre le travail en direct ; Ctrl+C ferme seulement l'affichage
pve-host-backup follow

# Afficher les 100 dernières lignes
pve-host-backup logs

# Vérifier SHA-256 et Zstandard sur le dernier backup
pve-host-backup verify-latest
```

## Activer ou désactiver l'automatisation

```bash
# Crée /etc/cron.d/pve-host-backup et active le démon cron
pve-host-backup on

# Affiche l'heure, la ligne cron et l'état des services
pve-host-backup auto-status

# Supprime uniquement la tâche de ce projet
pve-host-backup off
```

`off` n'arrête pas un backup déjà lancé et ne désactive pas le démon cron
général, car d'autres tâches du host peuvent l'utiliser.

Cron ne rattrape pas une sauvegarde manquée pendant un arrêt du PVE.

## Régler l'heure, la rétention et les notifications

```bash
# Assistant interactif
pve-host-backup configure

# Exemple direct
pve-host-backup configure \
  --time 03:30 \
  --retention 5 \
  --notify-success off

# Lire les valeurs actuelles
pve-host-backup settings
```

Les notifications d'échec restent toujours actives. Tester le transport local :

```bash
pve-host-backup notify-test
```

## Régler les ressources

```bash
# Assistant interactif
pve-host-backup configure-resources

# Profil léger : un thread et un cœur logique au maximum
pve-host-backup configure-resources \
  --threads 1 \
  --cpu-percent 100 \
  --memory-high 1G \
  --memory-max 0

# Afficher les valeurs configurées et effectives
pve-host-backup resources
```

`100 %` de quota CPU correspond à un cœur logique. `MemoryMax=0` désactive la
limite dure.

## Vérification et extraction sans risque

```bash
# Contrôle NFS et test d'écriture
pve-host-backup check

# Vérifier une date précise
pve-host-backup verify 2026-08-18T04-15-00+0900

# Extraire le dernier backup sous /var/tmp, sans toucher au système
pve-host-backup stage latest

# Supprimer cette extraction de test
pve-host-backup unstage latest

# Supprimer seulement les sauvegardes incomplètes .partial-*
pve-host-backup cleanup-partials
```

## Restauration

```bash
# Audit en lecture seule recommandé en premier
pve-host-restore audit latest

# Restauration automatique prudente avec confirmations
pve-host-restore wizard latest

# Choix détaillés lot par lot
pve-host-restore guided latest
```

Ne jamais extraire `rootfs.tar.zst` directement sur `/`. Lire
[RESTORE.md](RESTORE.md) avant toute écriture.

## Diagnostic système

```bash
# État du service de sauvegarde
systemctl status pve-host-backup.service --no-pager

# État du démon cron
systemctl status cron.service --no-pager

# Voir exactement la tâche installée
sed -n '1,120p' /etc/cron.d/pve-host-backup

# Événements cron récents dans le journal
journalctl -u cron.service -n 100 --no-pager

# Journal complet du dernier démarrage du service
journalctl -u pve-host-backup.service -b --no-pager
```

## Commandes longues toujours acceptées

Les alias courts ne suppriment pas l'ancienne interface :

| Alias simple | Équivalent historique |
|---|---|
| `info` | `status` |
| `verify-latest` | `verify latest` |
| `on` | `auto-on` |
| `off` | `auto-off` |

`now` est préférable à `run` pour un usage manuel : il passe par le service
systemd, applique les quotas et rend immédiatement la console.
