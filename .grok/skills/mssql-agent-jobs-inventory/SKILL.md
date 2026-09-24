---
name: mssql-agent-jobs-inventory
description: >
  Inventory SQL Server Agent jobs: enabled flag, schedules, last run, category.
  Triggers: Agent jobs list, nightly maintenance jobs, job inventory, /mssql-agent-jobs-inventory.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL Agent jobs inventory

## When

After a host move, cutover, or "what maintenance is scheduled?"

## Steps

1. Confirm SQL Server Agent service is running (start type Automatic when jobs are required).
2. Query `msdb.dbo.sysjobs` / `sysjobschedules` / `sysjobhistory` (or SMO) for name, enabled, date_created, last run outcome, next run.
3. Flag disabled jobs that look like active maintenance; flag enabled jobs with no successful run in policy window.
4. Emit markdown table; do not enable/disable unless asked.

## Success

Complete job list with enabled + last outcome. Gaps called out vs expected maintenance (backups, stats, index).
