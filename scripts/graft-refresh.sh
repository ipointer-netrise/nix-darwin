#!/usr/bin/env zsh
# Refresh graft's --deep meaning layer across every graft-indexed repo under ~/Source.
#
# Scheduled by launchd.user.agents.graft-refresh in flake.nix.  Everything is content-hash
# cached, so a repo that has not changed costs nothing and a repo that has costs only its
# diff.  A run that hits the budget simply stops; the next one resumes from the cache.
#
# Secrets: sources ~/.zshenv for ANTHROPIC_API_KEY rather than carrying the key in the
# plist, which nix renders into the world-readable store.

emulate -L zsh
setopt pipefail

SRC="${HOME}/Source"
LOG="${HOME}/Library/Logs/graft-refresh.log"
BUDGET="${GRAFT_REFRESH_BUDGET:-5400}"   # seconds of wall clock per run; unfinished work resumes
# Deliberately the raw pinned binary, not the ~/.local/bin/graft wrapper.  The wrapper
# loads ~/.config/graft/environment, which points interactive graft at OpenRouter and the
# Jev hook; this is bulk per-file summarization where Haiku is the whole point, so it
# carries its own provider, model and key instead.
GRAFT="/run/current-system/sw/bin/graft"
GRAFT_MODULE="/usr/local/share/graft/module"
REFRESH_MODEL="${GRAFT_REFRESH_MODEL:-claude-haiku-4-5-20251001}"

mkdir -p "${LOG:h}"
exec >>"$LOG" 2>&1

zmodload zsh/datetime
START=$EPOCHSECONDS
say() { print -r -- "[$(strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS)] $*" }

# ~/.zshenv is a chezmoi template that resolves ANTHROPIC_API_KEY from 1Password at apply
# time, so the deployed file holds a literal and no vault unlock is needed here.
[[ -r "${HOME}/.zshenv" ]] && source "${HOME}/.zshenv"

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  say "FATAL: ANTHROPIC_API_KEY unset after sourcing ~/.zshenv; nothing to do"
  exit 1
fi
[[ -x "$GRAFT" ]] || { say "FATAL: $GRAFT missing"; exit 1 }

# The patch graft needs to be worth running at all.  Unpatched, the crux pass discards
# most of what it pays for, and it does so quietly -- refusing to run beats a silent bill.
# One marker, not two: the pinned dogfood fork fixes the crux-id defect in its own source.
CRUX="${GRAFT_MODULE}/dist/ai/crux.js"
if [[ $(grep -c 'graft-patch' "$CRUX" 2>/dev/null) -ne 1 ]]; then
  say "FATAL: graft crux patch missing (expected 1 marker in $CRUX)."
  say "       run: sudo darwin-rebuild switch --flake /etc/nix-darwin"
  exit 1
fi

say "=== graft refresh starting (budget ${BUDGET}s) ==="

# Integration point for a refresh: the default branch, preferring the remote unless the
# local one leads it (a repo that commits straight to main, e.g. turbine-ui-e2e-tests).
integration_ref() {
  local repo=$1 def remote
  def=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  def=${def#origin/}
  [[ -n "$def" ]] || for c in main master trunk; do
    git -C "$repo" show-ref --verify --quiet "refs/heads/$c" && { def=$c; break }
  done
  [[ -n "$def" ]] || return 1
  remote="origin/$def"
  git -C "$repo" show-ref --verify --quiet "refs/remotes/$remote" || { print -r -- "$def"; return 0 }
  # local ahead of remote -> the local branch is the real integration point
  if [[ $(git -C "$repo" rev-list --count "$remote".."$def" 2>/dev/null || print 0) -gt 0 ]]; then
    print -r -- "$def"
  else
    print -r -- "$remote"
  fi
}

refresh_repo() {
  local repo=$1 name=${1:t} ref wt rc
  # Linked worktrees share their parent's history; building one separately duplicates work
  # it would otherwise inherit by seeding.
  [[ -d "$repo/.git" ]] || { say "skip $name (linked worktree)"; return 0 }

  git -C "$repo" fetch origin --quiet 2>/dev/null
  ref=$(integration_ref "$repo") || { say "skip $name (no default branch)"; return 0 }

  wt=$(mktemp -d "/tmp/graft-refresh-${name}.XXXXXX") && rmdir "$wt"
  git -C "$repo" worktree add "$wt" "$ref" --detach --quiet 2>/dev/null \
    || { say "skip $name (worktree add failed for $ref)"; return 0 }
  [[ -f "$repo/.graft/config.json" ]] && { mkdir -p "$wt/.graft"; cp "$repo/.graft/config.json" "$wt/.graft/" }

  # Carry both caches in by hand: seeding brings wiring.json and the sidecars but not
  # summaries.json, and without it passes 1 and 2 are paid again in full.
  mkdir -p "$wt/graft/.graph" "$wt/graft/.cache"
  [[ -f "$repo/graft/.graph/wiring.json" ]]   && cp "$repo/graft/.graph/wiring.json"   "$wt/graft/.graph/"
  [[ -f "$repo/graft/.cache/summaries.json" ]] && cp "$repo/graft/.cache/summaries.json" "$wt/graft/.cache/"

  say "-> $name @ $ref"
  # GRAFT_HOOK is deliberately NOT cleared: Jev's crux selector and deep-build router are
  # the point of running this on a schedule.  It comes from ~/.config/graft/environment via
  # the ~/.zshenv sourced above, together with JEV_OPENROUTER_API_KEY.  Jev talks to
  # OpenRouter on its own key; GRAFT_API_KEY below still points graft's prose passes at
  # Anthropic, so the two providers stay separate.  A hook error falls open to a normal
  # deep build rather than failing the run.
  if [[ -z "${GRAFT_HOOK:-}" || ! -r "${GRAFT_HOOK}" ]]; then
    say "   (no Jev hook at '${GRAFT_HOOK:-unset}'; building without reuse routing)"
  fi
  # GRAFT_BASE_URL, GRAFT_PROVIDER and GRAFT_MODEL must be cleared, not just overridden.
  # ~/.zshenv sourced them for interactive graft (OpenRouter, gpt-6-luna) and --provider
  # does not displace a base URL, so Anthropic-shaped requests were being posted to
  # OpenRouter and every deep pass failed at 0% coverage.  Jev's own OpenRouter settings
  # are separate variables and are deliberately left in place.
  env -u GRAFT_BASE_URL -u GRAFT_PROVIDER -u GRAFT_MODEL \
      GRAFT_API_KEY="$ANTHROPIC_API_KEY" \
    "$GRAFT" --provider anthropic --model "$REFRESH_MODEL" \
             build --deep -j 4 "$wt" >/dev/null 2>&1
  rc=$?

  # A non-zero exit still leaves real work on disk -- files that failed stay pending and
  # retry next run, so the result is always worth transplanting.
  if [[ -f "$wt/graft/.graph/wiring.json" ]]; then
    rm -f "$repo"/graft/*.md
    cp "$wt"/graft/*.md "$repo/graft/" 2>/dev/null
    cp "$wt/graft/.graph/wiring.json"    "$repo/graft/.graph/wiring.json"
    cp "$wt/graft/.cache/summaries.json" "$repo/graft/.cache/summaries.json" 2>/dev/null
    # Without the manifest, checkContext returns `missing` and `graft check` reports
    # "deep layer: not built" over a layer that is complete.
    cp "$wt/graft/manifest.json"         "$repo/graft/manifest.json" 2>/dev/null
    "$GRAFT" build "$repo" >/dev/null 2>&1
    say "   transplanted $name (graft exit $rc)"
  else
    say "   $name produced no graph (graft exit $rc)"
  fi

  git -C "$repo" worktree remove --force "$wt" 2>/dev/null
  git -C "$repo" worktree prune 2>/dev/null
}

typeset -a repos
repos=(${(f)"$(find "$SRC" -maxdepth 7 -path '*/graft/.graph/wiring.json' \
  -not -path '*/node_modules/*' -not -path '*/.claude/worktrees/*' 2>/dev/null \
  | sed 's|/graft/.graph/wiring.json$||' | sort)"})

say "found ${#repos} graft-indexed repo(s)"

for repo in $repos; do
  if (( EPOCHSECONDS - START >= BUDGET )); then
    say "budget reached; remaining repos resume next run"
    break
  fi
  refresh_repo "$repo"
done

say "=== done in $(( EPOCHSECONDS - START ))s ==="
