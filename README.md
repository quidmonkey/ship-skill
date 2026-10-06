# 🚢 ship

Are you sick of PRs? Did you feel like all you're doing is going through the motions so that somebody is happy that a process is being followed? After writing your code, do you wish you could magically deploy it?

Well, this is the skill for you!

This Claude Code skill ships a branch in the background. The `/ship` skill reviews the branch, fixes what the review finds, pushes it, then opens a PR, merges it, and verifies the dev deploy, as far as the configured stage goes. It will even go so far as to notify you when your code has been deployed! It works from its own git worktree, so you can keep vibing while it runs.

By default, this skill targets the `develop` branch (or dev environment), but it can be invoked to target any branch!

## 💻 Install

```bash
git clone git@github.com:quidmonkey/ship-skill.git ~/.claude/skills/ship
```

Then ask Claude to finish the setup from [docs/install.md](docs/install.md). It adds permission rules so a ship always asks before it starts.

## 🧐 Use

In a Claude Code session, on your feature branch:

```bash
/ship            # 📦 review, push and open a PR into develop
/ship merge      # 🤝 go further: approve and merge the PR
/ship staging    # 🗺️ target another branch
/ship main       # 🧐🚀 release develop to prod
/ship status     # 🔭 what's running
/ship stop       # 🛑 stop it
```

`/ship` shows you a plan first and starts only after you say yes. Your checkout is never touched. 🙌

## 🧭 How far it goes

Each stage includes the ones before it.

| Stage | Does |
|---|---|
| `push` | 🔍 Review, fix, push |
| `open_pr` | 📬 Open a PR (the default) |
| `merge` | 🔀 Approve and merge the PR |
| `verify_deploy` | ✅ Check the dev deploy is healthy and running your commit |

## 🎛️ Settings

The first `/ship` in a repo creates a `.shiprc` file with the defaults and keeps it out of git. Edit it to change your default stage, add PR reviewers, or set up deploy checks. You can also override a setting for one run with `/ship key=value`.

Every setting, and more on how a ship works, is in [docs/reference.md](docs/reference.md).
