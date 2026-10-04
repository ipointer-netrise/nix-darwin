#!/usr/bin/env bash
set -euo pipefail

source_dir="${CHEZMOI_SOURCE:-$(chezmoi source-path)}"
canonical="$source_dir/.chezmoitemplates/nix-darwin-chezmoi-skill.md.tmpl"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/validate-machine-skill.XXXXXX")"
trap 'rm -rf -- "$tmp_dir"' EXIT

[[ -f "$canonical" ]] || {
  echo "Missing canonical machine skill: $canonical" >&2
  exit 1
}

render() {
  chezmoi --source "$source_dir" execute-template --file "$1"
}

canonical_rendered="$tmp_dir/canonical.md"
render "$canonical" > "$canonical_rendered"
head -n 1 "$canonical_rendered" | grep -qx -- '---'
grep -qx -- 'name: nix-darwin-chezmoi' "$canonical_rendered"
printf '{{ includeTemplate "nix-darwin-chezmoi-skill.md.tmpl" . }}\n' > "$tmp_dir/wrapper.tmpl"
baseline_rendered="$tmp_dir/rendered.md"
first_wrapper=true

while IFS=$'\t' read -r source_path target_path; do
  wrapper_rendered="$tmp_dir/${source_path//\//_}"
  target_rendered="$tmp_dir/${target_path//\//_}"

  cmp -s "$tmp_dir/wrapper.tmpl" "$source_dir/$source_path" || {
    echo "Source wrapper is not the canonical include: $source_path" >&2
    exit 1
  }

  render "$source_dir/$source_path" > "$wrapper_rendered"
  if "$first_wrapper"; then
    cp "$wrapper_rendered" "$baseline_rendered"
    first_wrapper=false
  else
    cmp -s "$baseline_rendered" "$wrapper_rendered" || {
      echo "Rendered wrapper differs: $source_path" >&2
      exit 1
    }
  fi

  chezmoi --source "$source_dir" cat "$target_path" > "$target_rendered"
  cmp -s "$baseline_rendered" "$target_rendered" || {
    echo "Rendered target differs: $target_path" >&2
    exit 1
  }

  cmp -s "$baseline_rendered" "$target_path" || {
    echo "Deployed target differs: $target_path" >&2
    exit 1
  }
done <<EOF
dot_claude/skills/nix-darwin-chezmoi/SKILL.md.tmpl	$HOME/.claude/skills/nix-darwin-chezmoi/SKILL.md
dot_codex/skills/nix-darwin-chezmoi/SKILL.md.tmpl	$HOME/.codex/skills/nix-darwin-chezmoi/SKILL.md
dot_config/opencode/skills/nix-darwin-chezmoi/SKILL.md.tmpl	$HOME/.config/opencode/skills/nix-darwin-chezmoi/SKILL.md
dot_pi/agent/skills/nix-darwin-chezmoi/SKILL.md.tmpl	$HOME/.pi/agent/skills/nix-darwin-chezmoi/SKILL.md
private_dot_hermes/private_skills/macos/nix-darwin-chezmoi/private_SKILL.md.tmpl	$HOME/.hermes/skills/macos/nix-darwin-chezmoi/SKILL.md
EOF

echo "Machine skill rendering and deployed copies match."
