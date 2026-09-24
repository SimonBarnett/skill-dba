# BRIEF — bootstrap SimonBarnett/skill-dba

Goal: land this seed as the initial content of https://github.com/SimonBarnett/skill-dba

## Must do

1. Commit the tree under this seed onto the repo (branch `bootstrap/initial-skill-book` + PR to main is preferred; if repo is empty of real content, merging the PR is fine).
2. Keep `.grok/skills/*/SKILL.md` ASCII, with frontmatter name+description.
3. `harvest-agent-skills` must have `github: https://github.com/SimonBarnett/skill-dba`.
4. Generalize any leftover Priority/CE/Clarkson/Haitch/FormPrep-specific wording in scripts comments if you touch them; Priority ERP skills stay in agentic_fomprep — do not copy priority-* catalog folders as-is.
5. Include README, config/instances.example.json, scripts/, docs/skill-harvest-log.md, docs/skill-sources/.
6. Do not commit secrets. Do not invent prices.

## Out of scope

- Priority form-prep, HT-delete Priority product flows, hours-to-Haitch (formprep only)
- Changing agentic_fomprep in this PR (optional follow-up: note in PR that DBA general skills moved here)

## Done when

PR open (or main updated if that is the repo's bootstrap convention) with all mssql-* skills + harvest; CI not required if none exists.
