# Skill sources

General Microsoft SQL Server DBA playbooks for this book.

Priority ERP and form-prep skills stay in [SimonBarnett/agentic_fomprep](https://github.com/SimonBarnett/agentic_fomprep). This repo does not carry `priority-*` catalog folders.

Customer hostnames, IP addresses, machine ids, and user profile paths are omitted. Live topology belongs in local config. `config/instances.example.json` is the shape only.

## Files in this repo

| Artifact | Path |
|----------|------|
| Backup policy note | `docs/skill-sources/BACKUP_STANDARD.md` |
| Backup audit | `scripts/Invoke-BackupAudit.ps1` |
| Live audit | `scripts/Invoke-LiveAudit.ps1` |
| Post-move health | `scripts/Invoke-PostMoveHealth.ps1` |
| Instance health SQL | `scripts/dba_instance_health_collect.sql` |
| Instance config shape | `config/instances.example.json` |

## Skills

Agents load `.grok/skills/`. Home: https://github.com/SimonBarnett/skill-dba

## Standing rules

- Hosts, instance names, and paths come from config. No passwords in git.
- Production uses a FULL chain. Non-production uses SIMPLE (no t-log chain) unless config says otherwise.
- Retention defaults: bak 14 days / trn 3 days (override in config).
- Monitor mount points, not drive-letter stubs.
- Consumers harvest playbook changes back here (`harvest-agent-skills`).
