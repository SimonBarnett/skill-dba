---
name: mssql-cost-capacity-review
description: >
  MSSQL / cloud SQL cost and capacity review: edition, SKU, unused space, fat indexes, recovery chatter. Triggers: SQL cost review, RDS vs IONOS, over-provisioned storage, /mssql-cost-capacity-review.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL cost / capacity review

## When

Rightsizing cloud or on-prem SQL (e.g. RDS to IONOS move, storage growth, edition choice).

## Collect

- Edition / SKU / vCore or instance class
- Allocated vs used data/log file size
- Top tables by rows/size; large unused NCIs
- Recovery model and backup frequency (FULL log chatter costs I/O)
- Backup and HA add-ons

## Output

Options ranked: trim now, move SKU/engine later, split hot catalogues only when revenue justifies. Mark sample numbers clearly if not live.

## Success

Actionable options with honest uncertainty; no fabricated AWS/IONOS prices - look up or say missing.
