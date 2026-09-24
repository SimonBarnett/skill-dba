---
name: harvest-agent-skills
description: >
  FOUNDATION skill for every skill book. Identify this skill's home GitHub,
  harvest playbooks back as a PR, and report gaps as issues/FRs. Triggers:
  harvest skills, CAST IRON harvest, honesty box, skill book foundation,
  learned a procedure, hourly skill check, /harvest-agent-skills. Prefer
  deterministic scripts over LLM reasoning. Does not dispatch product builds.
github: REPLACE_GITHUB_URL
---

# Harvest agent skills (honesty box)

## Home GitHub (required on every harvest skill)

**This skill's home:** `REPLACE_GITHUB_URL`

Every skill book ships this foundation skill (or a repo-local twin). The twin's
frontmatter `github:` MUST name the public repo that owns that book.

| Playbook domain | Home repo | Foundation skill |
|-----------------|-----------|------------------|
| IRC wire, Jeeves, talk seats, SEAL, moot, file, dumb, Ergo, Watch-Bobiverse | `SimonBarnett/agentic_irc` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| Fleet / build / MRB / Bob jobs / TipForm | `SimonBarnett/agentic_build` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| MUD / Discworld | `SimonBarnett/mud-skill` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| Visionary / new-product strategy | `SimonBarnett/skills-visionary` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| Design UAT | `SimonBarnett/bob-design-uat` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| Club Madeira Awin connector | `SimonBarnett/club-madeira-awin-connector` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| Formprep / Priority ERP | `SimonBarnett/agentic_fomprep` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| General MSSQL DBA | `SimonBarnett/skill-dba` | `.grok/skills/harvest-agent-skills/SKILL.md` |
| IRC client-as-skill | `SimonBarnett/irc-skill` | that repo's harvest skill (if present) |
| Other skill products | that public repo | `.grok/skills/harvest-agent-skills/SKILL.md` |

## CAST IRON - cost of using this skill book

**You used these skills. You owe the home repo a report.**

This is an honesty box. Using any skill from this book binds you to return
what you learned, what broke, and what is missing. Silence after a useful
session is a breach of the bargain. Do not wait for an hourly task, a
reminder, or Bob to dismiss you.

### You MUST report back to the home GitHub when any of these are true

1. You learned a **repeatable** procedure (trigger + steps + owner) not already
   in the book.
2. A skill was **wrong, incomplete, ambiguous, or token-wasteful**.
3. You hit a **bug**, gap, or missing tool that a deterministic script should
   own.
4. You invented a workaround that should become a skill or a code change.

### How to report (strict order - no main pushes)

1. **Skill harvest / playbook / fix with write access** -> branch + **pull
   request** against the home repo. Never `git push origin main` for harvest.
2. **If the PR cannot be opened** (no permission, API fail, fork blocked) ->
   open a **GitHub issue** on the home repo titled `harvest:` or `FR:` and
   paste the intended PR title, branch name, file list, and full body.
3. **Bugs / feature requests without a ready patch** -> GitHub **issue** or
   **FR** on the home repo (use that repo's FR/issue templates if present).
4. Empty harvest (nothing new, nothing broken): **no commit, no empty PR**.
   Still OK to stay silent only in that case.

Prefer `gh` / existing harvest scripts over free-form reasoning. If a script
exists, run it; do not re-derive the procedure in chat.

## Token efficiency (non-negotiable)

- Prefer a **deterministic tool or script** over LLM reasoning whenever both
  could finish the job.
- Do not narrate step-by-step tool plans in skills; write the command or the
  script name.
- One home per fact. Point at the owner skill; do not duplicate.
- ASCII in `SKILL.md`. Short triggers in frontmatter `description`.

## Scan (deterministic first)

1. Diff local installed skills vs repo `.grok/skills/` - promote repeatable
   user-only playbooks.
2. Run repo harvest script if present; do not reinvent it.
3. Check recent `docs/*` FRs and `docs/skill-harvest-log.md` (create if missing).
4. Skip one-off incident notes and noisy chat.

A candidate is useful only if it is **repeatable**, has a clear trigger, and
is not a single incident report.

## Write

1. Edit or add `.grok/skills/<name>/SKILL.md` (`name` + `description`;
   foundation skill also has `github:` of THIS repo).
2. Append a dated line to `docs/skill-harvest-log.md`.
3. Commit on a **branch**, open a **PR**. Link related issues.
4. If this repo has a Test-Pack / skill list gate, add the new name and run it.

## Do not

- Push harvest to `main`.
- Commit "nothing found".
- Force-push, secrets, or live credentials into skills.
- Invent skills from noisy session chat.
- Claim ready for human UAT from a harvest alone.
- Start unrelated product jobs under the harvest label.
- Spend tokens reasoning through a path a script already encodes.

## Inclusion rule

**Every skill book MUST include this foundation skill** (twin with that book's
`github:`). Other skills in the book SHOULD link it in one line:
`Foundation: harvest-agent-skills (honesty box) -> report back to <github>.`
