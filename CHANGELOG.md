# Journal des versions

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

