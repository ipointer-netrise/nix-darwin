# Git overrides for the nix-darwin repo.
#
# This repo lives on GitHub under the `ipointer-netrise` account, but the
# 1Password SSH agent holds several GitHub keys and offers the personal
# `ivanpointer` key first -- which has no push access here. Pinning the
# ipointer-netrise public key with IdentitiesOnly makes SSH offer only that
# key (still served by the 1Password agent), so pushes authenticate as the
# correct account.
#
# Activated via an `includeIf "gitdir:/etc/nix-darwin/"` directive in
# ~/.gitconfig (managed by chezmoi).
[core]
	sshCommand = "ssh -i /etc/nix-darwin/git/ipointer-netrise.pub -o IdentitiesOnly=yes"
