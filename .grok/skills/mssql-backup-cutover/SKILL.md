---
name: mssql-backup-cutover
description: >
  Phased MSSQL backup-path and recovery-model cutover with human gates. Triggers: backup cutover, move backups to new volume, SIMPLE cutover, /mssql-backup-cutover.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL backup cutover (human-gated)

## When

Moving backup roots, aligning jobs to `mssql-backup-standard`, or changing recovery model (e.g. FULL to SIMPLE on non-prod).

## Phases (typical)

1. Inventory + free space on target volume (`mssql-backup-audit`).
2. Non-prod first: set BackupDirectory, create/enable Agent jobs, baseline FULL, validate.
3. Production: keep FULL chain; move t-log + full/diff destinations; baseline FULL; validate chain.
4. Disable legacy maint plans; fix cleanup jobs; update weekly check.
5. Optional archive prune of old trees - **only** with explicit confirm.

## Do not

- Auto-prune old backup trees
- Cut over production before non-prod validation
- Push skill harvests to main (use PR)

## Success

Jobs succeed on new roots; VERIFYONLY / restore smoke as required; weekly check updated.
