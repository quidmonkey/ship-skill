# 🚢 ship

Sick of PRs? This Claude Code skill ships your branch in the background. It reviews the code, fixes what the review finds, pushes, opens a PR, merges it and checks the deploy, stopping at whichever stage you choose. It runs in its own git worktree, so your checkout stays untouched while you keep working.

## 💻 Install

```bash
git clone git@github.com:quidmonkey/ship-skill.git ~/.claude/skills/ship
```

Then ask Claude to finish the setup from [docs/install.md](docs/install.md).

## 🧐 Use

On your feature branch, in a Claude Code session:

```bash
/ship            # review, push and open a PR into develop
/ship merge      # also approve and merge it
/ship main       # release develop to prod
/ship status     # see what's running
```

You see a plan first, and nothing starts until you approve it.

## 📚 More

- [docs/reference.md](docs/reference.md) has every command, stage and setting, plus how a ship runs.
- [docs/spec.md](docs/spec.md) is the design spec.
