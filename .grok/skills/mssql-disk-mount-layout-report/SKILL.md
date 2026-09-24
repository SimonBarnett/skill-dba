---
name: mssql-disk-mount-layout-report
description: >
  IT-facing MSSQL disk/mount layout report: MDF/LDF/backup paths, jobs, free space on mounts. Triggers: disk mount report, SQL path PDF, monitor mount points, /mssql-disk-mount-layout-report.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL disk / mount layout report

## When

Handing IT a clear picture of where SQL lives and what to monitor.

## Content

- Per-instance data/log/backup physical paths
- Mount point free space (not stub volume size)
- Maintenance/backup job summary

## Do

Call out: **monitor mount points**, not ~1 GB drive-letter stubs.

## Success

Readable report (md/PDF) an infra owner can act on without SQL expertise.
