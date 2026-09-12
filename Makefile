.PHONY: apply update brew outdated up commit

# ── Apply / update ────────────────────────────────────────────────────
# `apply` rebuilds from the current flake.lock — reproducible, no network
# resolution of pins. `update` moves the pins. `up` does both, then
# sweeps Homebrew (which nix-darwin installs but never upgrades:
# homebrew.onActivation.upgrade is left off so a switch can't restart
# apps you're using).

apply:
	sudo darwin-rebuild switch --flake "/etc/nix-darwin#default"

# flake.lock is root-owned, so this needs sudo to rewrite it.
update:
	sudo nix flake update --flake "/etc/nix-darwin"

brew:
	brew update
	brew upgrade
	@echo
	@echo "Casks that self-update were skipped; force them with:"
	@echo "  brew upgrade --cask --greedy"

outdated:
	@echo "── nix inputs ──"
	@nix flake metadata "/etc/nix-darwin" --json | jq -r \
		'.locks.nodes | to_entries[] | select(.value.locked.lastModified) | \
		 "\(.key)\t\(.value.locked.lastModified | todate)"'
	@echo
	@echo "── homebrew ──"
	@brew outdated || true

up: update apply brew

# ── Commit ────────────────────────────────────────────────────────────

commit:
	@echo "Staging all changes..."
	@git add -A
	@echo "Generating commit message with opencode..."
	@DIFF_FILE=$$(mktemp /tmp/opencode-diff.XXXXXX.diff); \
	git diff --cached > "$$DIFF_FILE"; \
	COMMIT_MSG=$$(opencode run \
		"Write a conventional commit message for the attached diff. Format: a short subject line, then a blank line, then a bullet list summarizing each distinct change (skip the bullet list if there is only one change). Reply with only the commit message — no explanation, no markdown code fences, just the plain text of the commit message." \
		-f "$$DIFF_FILE" \
		2>/dev/null); \
	rm -f "$$DIFF_FILE"; \
	COMMIT_MSG=$$(gum write --header "Edit commit message (ctrl+d to confirm)" --value "$$COMMIT_MSG"); \
	if [ -z "$$COMMIT_MSG" ]; then \
		echo "Commit aborted: empty message."; \
		exit 1; \
	fi; \
	git commit -m "$$COMMIT_MSG"; \
	if gum confirm "Push to remote?"; then \
		git push; \
	fi
