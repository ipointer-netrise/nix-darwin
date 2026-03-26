{
  description = "Ivan MacBook nix-darwin system flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nix-darwin, nixpkgs }:
  let
    configuration = { pkgs, config, ... }:
    let
      primaryUser = "ivanpointer";
      homeDir = "/Users/${primaryUser}";
    in
    {
      nixpkgs.config.allowUnfree = true;

      # List packages installed in system profile. To search by name, run:
      # $ nix-env -qaP | grep wget
      environment.systemPackages =
        [ pkgs.neovim
          pkgs.obsidian
          pkgs.mas # Mac App Store CLI
          pkgs.nerd-fonts.inconsolata
	  pkgs.google-cloud-sdk
	  pkgs.glab
	  pkgs.tmux
	  pkgs.jq
	  pkgs.ripgrep
	  pkgs.fd
	  pkgs.fzf
	  pkgs.atuin
	  pkgs.zoxide
	  pkgs.git
	  pkgs.jujutsu
	  pkgs.eza
	  pkgs.starship
	  pkgs.carapace
	  pkgs.sesh
	  pkgs.vimPlugins.LazyVim
	  pkgs.claude-code
	  pkgs.gemini-cli
	  pkgs.btop
	  pkgs.chezmoi
	  pkgs._1password-cli
        ];

      homebrew = {
        enable = true;
        casks = [
	  "1password"
          "google-chrome"
          "the-unarchiver"
	  "postman"
	  "yubico-authenticator"
	  "zoom"
	  "ghostty"
	  "slack"
	  "ollama-app"
	  "docker-desktop"
	  "chatgpt"
	  "claude"
	  "tg-pro"
	  "raindropio"
	  "bartender"
	  "daisydisk"
	  "spotify"
	  "expressvpn"
	  "notion"
	  "elgato-stream-deck"
	  "snagit"
	  "warp"
        ];
        masApps = {
	  "Amphetamine" = 937984704;
        };

        onActivation.cleanup = "zap";
      };

      # Necessary for using flakes on this system.
      nix.settings.experimental-features = "nix-command flakes";

      # Enable alternative shell support in nix-darwin.
      # programs.fish.enable = true;

      # Set Git commit hash for darwin-version.
      system.configurationRevision = self.rev or self.dirtyRev or null;

      # Used for backwards compatibility, please read the changelog before changing.
      # $ darwin-rebuild changelog
      system.stateVersion = 6;

      # The platform the configuration will be used on.
      nixpkgs.hostPlatform = "aarch64-darwin";

      system.keyboard = {
        enableKeyMapping = true;
        userKeyMapping = [ ];
      };

      security.pam.services.sudo_local.touchIdAuth = true;

      # System-level git config: rewrite GitLab HTTPS to SSH
      # Lives at /etc/gitconfig — below ~/.gitconfig so chezmoi can layer on top
      environment.etc.gitconfig.text = ''
        [url "git@gitlab.com:"]
            insteadOf = https://gitlab.com/
      '';

      system.primaryUser = primaryUser;

      # Bootstrap SSH + 1Password config (only if missing)
      # Once chezmoi runs, it owns these files
      system.activationScripts.postActivation.text = ''
        SSH_DIR="${homeDir}/.ssh"
        SSH_CONFIG="$SSH_DIR/config"
        OP_SSH_DIR="${homeDir}/.config/1Password/ssh"
        OP_AGENT_TOML="$OP_SSH_DIR/agent.toml"

        # Bootstrap ~/.ssh/config
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chown ${primaryUser}:staff "$SSH_DIR"

        if [ ! -f "$SSH_CONFIG" ]; then
          cat > "$SSH_CONFIG" << 'SSHEOF'
# Bootstrap config — replaced by chezmoi after init
Host *
    IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
SSHEOF
          chmod 600 "$SSH_CONFIG"
          chown ${primaryUser}:staff "$SSH_CONFIG"
          echo "Bootstrapped ~/.ssh/config for 1Password SSH agent"
        fi

        # Ensure ~/.config/1Password/ssh/agent.toml uses the correct vault
        mkdir -p "$OP_SSH_DIR"
        chown -R ${primaryUser}:staff "${homeDir}/.config/1Password"
        if [ ! -f "$OP_AGENT_TOML" ] || grep -q 'vault = "Personal"' "$OP_AGENT_TOML"; then
          cat > "$OP_AGENT_TOML" << 'OPEOF'
# Managed by nix-darwin — replaced by chezmoi after init
[[ssh-keys]]
vault = "SSH Credentials"
OPEOF
          chown ${primaryUser}:staff "$OP_AGENT_TOML"
          echo "Enforced 1Password agent.toml vault = SSH Credentials"
        fi
      '';

      system.activationScripts.extraActivation.text = let
	  srcZip = ./assets/keyboard-layouts/programmer-dvorak.bundle.zip;
	in ''
	  set -euo pipefail

	  echo "Installing Programmer Dvorak from ${srcZip}"

	  tmpDir="$(mktemp -d)"
	  dstRoot="/Library/Keyboard Layouts"
	  dstBundle="$dstRoot/Programmer Dvorak.bundle"

	  cleanup() {
	    rm -rf "$tmpDir"
	  }
	  trap cleanup EXIT

	  mkdir -p "$dstRoot"
	  rm -rf "$dstBundle"

	  ditto -x -k "${srcZip}" "$tmpDir"

	  bundlePath="$(find "$tmpDir" -type d -name 'Programmer Dvorak.bundle' -print -quit)"

	  if [ -z "$bundlePath" ]; then
	    echo "Could not find Programmer Dvorak.bundle inside ${srcZip}" >&2
	    exit 1
	  fi

	  cp -R "$bundlePath" "$dstBundle"

	  echo "Installed bundle to: $dstBundle"
	  ls -la "$dstBundle"
	'';

      system.defaults = {
        NSGlobalDomain = {
          AppleKeyboardUIMode = 3;
        };

        CustomUserPreferences = {

        "com.apple.HIToolbox" = {
          AppleEnabledInputSources = [
              {
                InputSourceKind = "Keyboard Layout";
                "KeyboardLayout ID" = 0;
                "KeyboardLayout Name" = "U.S.";
              }
              {
                InputSourceKind = "Keyboard Layout";
                "KeyboardLayout ID" = 6454;
                "KeyboardLayout Name" = "Programmer Dvorak";
              }
            ];
        };
      };

        dock.autohide = true;
	dock.tilesize = 36;
	dock.persistent-apps = [
	  "/Applications/1Password.app"
	  "/Applications/Ghostty.app"
	  "/System/Applications/Calendar.app"
	  "/System/Applications/Messages.app"
	  "/Applications/Slack.app"
	  "/Applications/Google Chrome.app"
	  "/Applications/ChatGPT.app"
	  "/Applications/Claude.app"
	  "/Applications/Warp.app"
	  "/Applications/Spotify.app"
	  "/Applications/Raindrop.io.app"
	];
	finder.FXPreferredViewStyle = "clmv";
	loginwindow.LoginwindowText = "Ivan + NetRise = ❤️";
      };
    };
  in
  {
    # Build darwin flake using:
    # $ darwin-rebuild build --flake .#Ivans-MacBook-Pro-2
    darwinConfigurations."Ivans-MacBook-Pro-2" = nix-darwin.lib.darwinSystem {
      modules = [ configuration ];
    };
  };
}
