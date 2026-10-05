# /ship make targets. A project's Makefile includes this file:
#   SHIP_SKILL ?= $(HOME)/.claude/skills/ship
#   -include $(SHIP_SKILL)/ship.mk
# Recipes run in the project root, against its .codereviewrc and scripts/.

SHIP_SKILL ?= $(HOME)/.claude/skills/ship
ship_sh = bash "$(SHIP_SKILL)/scripts/ship.sh"
ship_stage_sh = bash "$(SHIP_SKILL)/scripts/set-ship-stage.sh"

.PHONY: ship ship-plan ship-stage ship-status ship-watch ship-stop auto-pr

ship: ## Review, push and ship the branch into develop from a worktree (BRANCH= STAGE= SET= NOTES= DETACH=1 YES=1)
	@$(ship_sh) $(ship_args) $(call ship_flag,DETACH,--detach) $(call ship_flag,YES,--yes) \
		$(call ship_arg,ID,--id "$$ID") $(call ship_arg,SHA,--expect-sha "$$SHA") $(call ship_arg,CONFIG,--expect-config "$$CONFIG")

ship-plan: ## Show the config make ship would use and check it; creates nothing (BRANCH= STAGE= SET= NOTES=)
	@$(ship_sh) --plan $(ship_args)

ship-stage: ## Set how far make ship goes: STAGE=push|open_pr|merge|verify_deploy
	@$(ship_stage_sh) "$(STAGE)"

ship-status: ## Show running and recent ships (ID= for one)
	@$(ship_sh) --status $(ID)

ship-watch: ## Print a ship's events as they happen until it finishes (ID=, default latest)
	@$(ship_sh) --watch $(ID)

ship-stop: ## Stop a running ship (ID= when more than one is running)
	@$(ship_sh) --stop $(ID)

auto-pr: ## Alias for make ship-stage STAGE=merge
	@$(ship_stage_sh) merge

# make ship arguments are taken from the command line only, so a stray
# environment variable (YES, ID, SHA...) can't change a ship. The shell reads
# $SET and $STAGE itself, so values with spaces survive:
#   make ship SET='deploy_name=Sales Agent (dev);review_model=sonnet'
ship_arg = $(if $(filter command line,$(origin $(1))),$(2))
ship_flag = $(if $(filter command line,$(origin $(1))),$(if $(filter 1 true yes,$($(1))),$(2)))
ship_args = $(call ship_arg,BRANCH,--target "$$BRANCH") $(call ship_arg,NOTES,--notes-file "$$NOTES") \
	$(call ship_arg,STAGE,--stage "$$STAGE") $(call ship_arg,SET,--sets "$$SET")
