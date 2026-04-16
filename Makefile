.PHONY: apply commit

apply:
	sudo darwin-rebuild switch --flake "/etc/nix-darwin#default"

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
