# Installing ship

## Clone

```bash
git clone git@github.com:quidmonkey/ship-skill.git ~/.claude/skills/ship
```

To update, run `git -C ~/.claude/skills/ship pull`. The `version` in `SKILL.md` follows semver.

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
  "Bash(bash *.claude/skills/ship/scripts/ship.sh --retry*)",
  "Bash(make ship)",
  "Bash(make ship *)"
]
```

The `ask` rule is the confirmation step. Without it, a session in auto mode can start a ship with no prompt.

## Requirements

- A git repo with an `origin` remote, a feature branch checked out, and `origin/develop` (or the branch you target). Nothing has to be copied into the repo.
- `claude` and `git` on PATH.
- `gh` or `az` for the `open_pr` stage and above.
- For `verify_deploy`, whatever your `deploy_check` command runs.

## make targets

`make ship` and the other `make ship*` targets come from `ship.mk`. To use them, add this after the `Makefile`'s first target:

```make
SHIP_SKILL ?= $(HOME)/.claude/skills/ship
-include $(SHIP_SKILL)/ship.mk
```

Without a `Makefile`, call the script directly: `bash ~/.claude/skills/ship/scripts/ship.sh --plan --stage push` plans a ship, and `--help` lists the rest. `/ship` in a session always calls the script directly.
