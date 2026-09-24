# MSSQL backup standard (source note)

The playbook agents follow is `.grok/skills/mssql-backup-standard/SKILL.md`.

Host names, IP addresses, and instance folder names are not stored here. Paths come from `config/instances.example.json` (example only) or the deployment config.

## Policy pattern

| Tier | Recovery | Chain |
|------|----------|-------|
| Production | FULL (tempdb may stay SIMPLE) | Weekly FULL + daily DIFF + hourly TLOG |
| Non-production | SIMPLE | Weekly FULL + daily DIFF (no TLOG) |

## Backup root

Each instance has a dedicated backup directory on the log/backup volume, separate from data files. That path is also the instance default BackupDirectory.

## Agent jobs

Pattern per instance id `INST`:

| Job | Typical schedule |
|-----|------------------|
| `{INST}_FULL_WEEKLY` | Weekly, off-peak |
| `{INST}_DIFF_DAILY` | Daily, off-peak |
| `{INST}_TLOG_HOURLY` | Hourly (FULL recovery only) |
| `{INST}_BAK_CLEANUP` | Daily, after backups |

## Retention (cleanup jobs)

- `.bak` older than 14 days
- `.trn` older than 3 days
- Scope is that instance backup root only
- Do not prune retired backup trees without explicit human confirm

## Left alone

- Hypervisor or cloud snapshot jobs
- Index maintenance, code compare, SQL reports, `syspolicy_purge_history`

## Old maint-plan backup jobs

Remain disabled (not deleted) on each instance after cutover.
