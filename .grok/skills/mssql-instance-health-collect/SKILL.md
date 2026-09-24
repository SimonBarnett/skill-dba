---
name: mssql-instance-health-collect
description: >
  Portable MSSQL instance health collection (disk/mounts, memory, waits, early outage signals). Triggers: instance health pack, dba health collect, /mssql-instance-health-collect.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL instance health collect

## When

Baseline before change, incident triage, or scheduled health snap.

## How

Run `scripts/dba_instance_health_collect.sql` via sqlcmd / Invoke-Sqlcmd against each target (config-driven). Prefer Windows integrated auth from the jump host.

## Output

Timestamped text/JSON under a reports folder. Flag mount-point free space separately from drive-letter stubs.

## Success

One pack per instance; critical disk/memory signals called out first.
