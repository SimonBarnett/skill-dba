---
name: mssql-deadlock-triage
description: >
  Generic MSSQL deadlock (1205) and hung-delete evidence checklist: graph,
  statements, indexes, sign-flip hangs that look like deadlocks. Triggers:
  deadlock triage, error 1205, hung delete, sign flip hang, deadlock graph,
  /mssql-deadlock-triage.
---

Foundation: harvest-agent-skills (honesty box) -> report back to https://github.com/SimonBarnett/skill-dba.

# MSSQL deadlock triage (generic)

## When

App or batch hits error 1205 / deadlock victim, **or** a delete/update hangs with no 1205 and sessions wait on locks / each other.

## Steps

1. Capture deadlock graph (extended events / system_health / trace) when 1205 fires.
2. Map SPIDs to statements and objects; note lock mode and index.
3. Compare environments if multi-tier (dev vs test vs prod) for trigger/proc drift.
4. Check supporting indexes and lock patterns; propose fix levers (index, query rewrite, retry) - do not blind-apply.
5. **Sign-flip / logic hang (not always 1205):** if a pre-delete or check uses a compare that accidentally equals the negative of the key (e.g. `col = -col` for non-zero ints), sessions can spin or block without a classic deadlock graph. Diff trigger/proc text across environments; look for unary minus on keys before checkpoint deletes.
6. After SQL object changes, run the app's prepare/compile gate if the stack has one (Priority Form Prep lives in formprep - do not duplicate here).

## Success

Evidence pack + recommended next action. No production schema change without owner confirm.
