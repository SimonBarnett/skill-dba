---
name: mssql-deadlock-triage
description: >
  Generic MSSQL deadlock (1205) evidence checklist: graph, statements, indexes, repro. Triggers: deadlock triage, error 1205, deadlock graph, /mssql-deadlock-triage.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL deadlock triage (generic)

## When

App or batch hits error 1205 / deadlock victim; need evidence before changing code or indexes.

## Steps

1. Capture deadlock graph (extended events / system_health / trace).
2. Map SPIDs to statements and objects.
3. Compare environments if multi-tier (dev vs test vs prod) for trigger/proc drift.
4. Check supporting indexes and lock patterns; propose fix levers (index, query rewrite, retry) - do not blind-apply.
5. After SQL object changes, run the app's prepare/compile gate if the stack has one (Priority Form Prep lives in formprep - do not duplicate here).

## Success

Evidence pack + recommended next action. No production schema change without owner confirm.
