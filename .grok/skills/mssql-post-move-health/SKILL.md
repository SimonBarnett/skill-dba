---
name: mssql-post-move-health
description: >
  Post-move MSSQL health: services, paths, jobs, smoke backup + VERIFYONLY. Triggers: post-move health, after backup path move, VERIFYONLY smoke, /mssql-post-move-health.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL post-move health

## When

After relocating data/log/backup files, changing BackupDirectory, or finishing a cutover phase.

## Checks

1. SQL Server + Agent services running.
2. Database file paths online; backup root writable.
3. Smoke DIFF or TLOG (as recovery model allows) to new root + VERIFYONLY.
4. Job owners/schedules still enabled.

## Script

`scripts/Invoke-PostMoveHealth.ps1` (parameterize; do not assume one customer layout).

## Success

PASS/FAIL report with VERIFYONLY evidence. No destructive prune.
