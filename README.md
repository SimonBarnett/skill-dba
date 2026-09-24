# skill-dba

Fleet **skill book** for **general Microsoft SQL Server DBA** playbooks (Grok Bot / Bob agents).

**Not** Priority ERP / form-prep — that stays in [`agentic_fomprep`](https://github.com/SimonBarnett/agentic_fomprep).

## Foundation

Every consumer of this book owes harvests back here (honesty box):

- `.grok/skills/harvest-agent-skills/SKILL.md`

## Skills (`.grok/skills/`)

| Skill | Role |
|-------|------|
| `harvest-agent-skills` | Honesty-box foundation |
| `mssql-backup-standard` | Backup policy reference (FULL vs SIMPLE, retention, job naming) |
| `mssql-backup-audit` | Read-only gap audit vs standard |
| `mssql-backup-cutover` | Phased backup-path / recovery cutover (human-gated) |
| `mssql-weekly-backup-check` | Post-overnight job + file verification |
| `mssql-instance-health-collect` | Portable instance health SQL pack |
| `mssql-post-move-health` | Post-move / path-change smoke + VERIFYONLY |
| `mssql-disk-mount-layout-report` | IT report: paths, jobs, mount free space |
| `mssql-deadlock-triage` | Generic deadlock 1205 and sign-flip hung-delete evidence checklist |
| `mssql-cost-capacity-review` | Instance/edition/storage cost drivers |
| `mssql-discover-registered-host` | Find and verify MSSQL on a registered Windows host |
| `mssql-agent-jobs-inventory` | Inventory SQL Agent jobs: enabled flag, schedules, last run |

## Config

Hosts, instance names, and paths come from **config/env** (example: `config/instances.example.json`). No passwords in skills — Windows integrated or secret-store auth only.

## Scripts

Supporting scripts under `scripts/` (harvested from live DBA work; generalize paths via parameters).

## Install

Copy or symlink `.grok/skills/*` into the agent's skill load path (fleet installers may automate this later).
