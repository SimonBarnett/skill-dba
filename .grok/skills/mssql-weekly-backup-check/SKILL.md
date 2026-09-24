---
name: mssql-weekly-backup-check
description: >
  Post-overnight MSSQL backup verification (jobs, msdb, files, t-log truncation on FULL). Triggers: Sunday backup check, weekly backup health, overnight bak verify, /mssql-weekly-backup-check.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL weekly backup check

## When

After scheduled overnight backups (often Sunday morning local).

## Checks

1. Agent job history for `{INST}_FULL_WEEKLY`, `_DIFF_DAILY`, `_BAK_CLEANUP`, and production `_TLOG_HOURLY`.
2. msdb backupset freshness vs policy.
3. Files present on configured backup roots; no unexpected growth on retired volumes.
4. On FULL recovery: confirm log reuse / recent t-log success.
5. Short PASS/FAIL blurb for the human owner (route via ops process - do not invent Teams targets).

## Success

Single overall PASS/FAIL with per-instance evidence. No silent "fixes" unless reversible and in scope.
