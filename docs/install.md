# Installing ship

## Clone

```bash
git clone git@github.com:quidmonkey/ship-skill.git ~/.claude/skills/ship
```

The [scaffold skill](https://github.com/quidmonkey/scaffold-skill) clones it when it creates a project, and a scaffolded project's `make setup` clones it on a teammate's machine. To update, run `git -C ~/.claude/skills/ship pull`.

The `version` in `SKILL.md` follows semver. The scaffold skill names the minimum version it needs and asks before pulling a newer one.

## Permission rules

Add these rules to `~/.claude/settings.json`, so starting a ship always shows a permission prompt and the read-only calls don't:

```json
"allow": [
  "Bash(bash *.claude/skills/ship/scripts/ship.sh --plan*)",
  "Bash(bash *.claude/skills/ship/scripts/ship.sh --status*)",
  "Bash(bash *.claude/skills/ship/scripts/ship.sh --watch*)"
],
"ask": [
  "Bash(bash *.claude/skills/ship/scripts/ship.sh --detach*)",
  "Bash(bash *.claude/skills/ship/scripts/ship.sh --yes*)",
  "Bash(make ship)",
  "Bash(make ship *)"
]
```

The `ask` rule is the confirmation step. Without it, a session in auto mode can start a ship with no prompt.

## Requirements

- A git repo with an `origin` remote, a feature branch checked out, and `origin/develop` (or the branch you target). Nothing has to be copied into the repo.
- `claude` and `git` on PATH.
- `gh` or `az` for the `open_pr` stage and above.
- `uv` and `gcloud` for `verify_deploy`.

## make targets

`make ship` and the other `make ship*` targets come from `ship.mk`. A scaffolded project's `Makefile` includes it. To use them in another repo, add this after the `Makefile`'s first target:

```make
SHIP_SKILL ?= $(HOME)/.claude/skills/ship
-include $(SHIP_SKILL)/ship.mk
```

Without a `Makefile`, call the script directly: `bash ~/.claude/skills/ship/scripts/ship.sh --plan --stage push` plans a ship, and `--help` lists the rest. `/ship` in a session always calls the script directly.
