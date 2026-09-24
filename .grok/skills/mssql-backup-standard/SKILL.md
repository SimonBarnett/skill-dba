---
name: mssql-backup-standard
description: >
  MSSQL backup policy reference: data vs log/backup roots, FULL vs SIMPLE chains, Agent job naming, retention, CHECKSUM+COMPRESSION. Triggers: backup standard, recovery model policy, bak retention, /mssql-backup-standard.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL backup standard (reference)

Policy other DBA skills measure against. Deployment paths and host names live in **config** (`config/instances.example.json`, env), not hard-coded in skill logic.

## Target layout (config-driven)

| Role | Pattern |
|------|---------|
| Data files | Dedicated data volume / mount per instance |
| Logs + backups | Separate log/backup volume; default BackupDirectory on that root |
| Monitoring | Monitor **mount points**, not tiny drive-letter stubs |

## Recovery and chains

| Tier | Recovery | Backup chain |
|------|----------|--------------|
| Production | FULL (tempdb may stay SIMPLE) | Weekly FULL + daily DIFF + hourly TLOG |
| Non-prod | SIMPLE | Weekly FULL + daily DIFF - no t-log chain |

## Agent jobs (naming pattern)

Per instance `INST`:

- `{INST}_FULL_WEEKLY`
- `{INST}_DIFF_DAILY`
- `{INST}_BAK_CLEANUP`
- `{INST}_TLOG_HOURLY` - production / FULL only

## Retention

- `.bak` older than **14** days (configurable)
- `.trn` older than **3** days (configurable)
- Scope: that instance backup root only

## Technical defaults

- CHECKSUM + COMPRESSION on native backups
- Leave legacy maint-plan jobs **disabled** (not deleted) after cutover unless explicitly approved
- Do **not** prune archived backup trees without **explicit** human confirm

## Success

Auditor or cutover skill can map every instance to this table with no ambiguous paths.

## Do not

- Hard-code one customer host as the only valid target
- Store SQL passwords in skills
