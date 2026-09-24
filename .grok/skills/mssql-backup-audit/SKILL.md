---
name: mssql-backup-audit
description: >
  Read-only MSSQL backup inventory vs mssql-backup-standard. Triggers: backup audit, msdb jobs, backup path gap report, /mssql-backup-audit.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL backup audit (read-only)

## When

Gap analysis before/after cutover, Sunday check prep, or "are we on standard?"

## Steps

1. Load instance list from config.
2. For each instance (integrated auth / approved secret store): recovery models, Default BackupDirectory, Agent jobs matching `{INST}_FULL_WEEKLY` / `_DIFF_DAILY` / `_BAK_CLEANUP` / `_TLOG_HOURLY`, msdb recent backup history, files on backup root.
3. Diff against `mssql-backup-standard`.
4. Emit markdown + JSON gap report. No changes.

## Scripts

- `scripts/Invoke-BackupAudit.ps1`
- `scripts/Invoke-LiveAudit.ps1`

Parameterize server/instance/backup roots; strip any Priority-only defaults before reuse.

## Success

Clear PASS/GAP per instance with evidence paths. No writes to SQL or disk trees.
