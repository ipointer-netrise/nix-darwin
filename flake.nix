{
  description = "Ivan MacBook nix-darwin system flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{
      self,
      nix-darwin,
      nixpkgs,
    }:
    let
      configuration =
        { pkgs, config, ... }:
        let
          primaryUser = "ivanpointer";
          homeDir = "/Users/${primaryUser}";
        in
        {
          nixpkgs.config.allowUnfree = true;
          # profile = "/nix/etc-darwin";

          # List packages installed in system profile. To search by name, run:
          # $ nix-env -qaP | grep wget
          environment.systemPackages = [
            # tmux
            pkgs.tmux
            pkgs.tmuxPlugins.catppuccin
            pkgs.tmuxPlugins.cpu
            pkgs.tmuxPlugins.battery

            # neovim
            pkgs.neovim
            pkgs.tree-sitter

            # Mason LSP dependencies
            pkgs.nodejs
            pkgs.cargo

            pkgs.go
            pkgs.wget
            pkgs.grpcurl
            pkgs.bat
            pkgs.obsidian
            pkgs.mas # Mac App Store CLI
            pkgs.google-cloud-sdk
            pkgs.glab
            pkgs.jq
            pkgs.ripgrep
            pkgs.fd
            pkgs.fzf
            pkgs.atuin
            pkgs.zoxide
            pkgs.git
            pkgs.lazygit
            pkgs.jujutsu
            pkgs.lazyjj
            pkgs.eza
            pkgs.starship
            pkgs.carapace
            pkgs.sesh
            pkgs.claude-code
            pkgs.gemini-cli
            pkgs.btop
            pkgs.chezmoi
            pkgs._1password-cli
            pkgs.devbox
            pkgs.tmatrix
            pkgs.raycast
            pkgs.lua5_1
            pkgs.luarocks
            pkgs.mark # Publish markdown to confluence
            pkgs.fswatch
            pkgs.watchexec
            pkgs.gotestfmt
            pkgs.gum

            # AI
            pkgs.aichat
            pkgs.opencode

            # CLI Clients
            pkgs.acli # Atlassian
          ];

          environment.variables.CATPPUCCIN_TMUX_PATH = "${pkgs.tmuxPlugins.catppuccin.rtp}";
          environment.variables.TMUX_CPU_PATH = "${pkgs.tmuxPlugins.cpu.rtp}";
          environment.variables.TMUX_BATTERY_PATH = "${pkgs.tmuxPlugins.battery.rtp}";

          fonts.packages = [
            pkgs.inconsolata
            pkgs.open-sans
            pkgs.nerd-fonts.inconsolata
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
              "raycast"
              "finicky"
              "zed"
              "cmux"
              "bettertouchtool"
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
          security.pam.services.sudo_local.reattach = true;

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

          system.activationScripts.extraActivation.text =
            let
              srcZip = ./assets/keyboard-layouts/programmer-dvorak.bundle.zip;
            in
            ''
              	  set -euo pipefail

              	  # --- Programmer Dvorak keyboard layout ---
              	  echo "Installing Programmer Dvorak from ${srcZip}"

              	  DVORAK_TMP="$(mktemp -d)"
              	  DVORAK_DST_ROOT="/Library/Keyboard Layouts"
              	  DVORAK_DST_BUNDLE="$DVORAK_DST_ROOT/Programmer Dvorak.bundle"

              	  cleanup() {
              	    rm -rf "$DVORAK_TMP"
              	  }
              	  trap cleanup EXIT

              	  mkdir -p "$DVORAK_DST_ROOT"
              	  rm -rf "$DVORAK_DST_BUNDLE"

              	  ditto -x -k "${srcZip}" "$DVORAK_TMP"

              	  DVORAK_BUNDLE_PATH="$(find "$DVORAK_TMP" -type d -name 'Programmer Dvorak.bundle' -print -quit)"

              	  if [ -z "$DVORAK_BUNDLE_PATH" ]; then
              	    echo "Could not find Programmer Dvorak.bundle inside ${srcZip}" >&2
              	    exit 1
              	  fi

              	  cp -R "$DVORAK_BUNDLE_PATH" "$DVORAK_DST_BUNDLE"

              	  echo "Installed bundle to: $DVORAK_DST_BUNDLE"
              	  ls -la "$DVORAK_DST_BUNDLE"
              	'';

          # https://nix-darwin.github.io/nix-darwin/manual/
          system.defaults = {
            NSGlobalDomain = {
              AppleKeyboardUIMode = 3;
            };

            controlcenter.Sound = true;
            controlcenter.Bluetooth = true;

            hitoolbox.AppleFnUsageType = "Change Input Source";
            CustomUserPreferences = {

              # Disable Universal Control (built-in keyboard/mouse sharing between
              # Macs/iPads). Synergy handles this instead and the two conflict.
              "com.apple.universalcontrol" = {
                Disable = true;
              };

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
            dock.autohide-delay = 0.16;
            dock.autohide-time-modifier = 1.5;
            dock.expose-animation-duration = 1.5;
            dock.expose-group-apps = true;
            dock.magnification = true;
            dock.largesize = 48;
            dock.tilesize = 36;
            dock.mru-spaces = false;
            dock.scroll-to-open = true;
            dock.show-recents = false;
            dock.showAppExposeGestureEnabled = true;
            dock.showLaunchpadGestureEnabled = true;
            dock.showMissionControlGestureEnabled = true;

            # Hot corners on the desktop
            # 1:Disabled 2:MissionControl 3:ApplicationWindows 4:Desktop 5:StartScreenSaver 6:DisableScreenSaver 7:Dashboard 10:PutDisplayToSleep 11:Launchpad 12:NotificationCenter 13:LockScreen 14:QuickNote
            # dock.wvous-bl-corner
            # dock.wvous-br-corner
            # dock.wvous-tl-corner
            # dock.wvous-tr-corner

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
            finder.FXDefaultSearchScope = "SCcf";
            finder.FXEnableExtensionChangeWarning = false;
            finder.NewWindowTarget = "Home";
            finder.ShowPathbar = true;
            finder.ShowStatusBar = true;
            finder._FXShowPosixPathInTitle = true;
            finder._FXSortFoldersFirst = true;

            iCal.CalendarSidebarShown = true;
            iCal."TimeZone support enabled" = true;

            loginwindow.LoginwindowText = "Ivan + NetRise = ❤️";
            loginwindow.GuestEnabled = false;
            loginwindow.autoLoginUser = primaryUser;

            menuExtraClock.Show24Hour = true;
            menuExtraClock.ShowDate = 1;

            spaces.spans-displays = false;

            trackpad.TrackpadFourFingerHorizSwipeGesture = 2; # 0:disable 2:enable
            trackpad.TrackpadFourFingerPinchGesture = 2;
            trackpad.TrackpadFourFingerVertSwipeGesture = 2;
            trackpad.TrackpadPinch = true;
            trackpad.TrackpadRightClick = true;
            trackpad.TrackpadRotate = true;
            trackpad.TrackpadThreeFingerDrag = true;
            trackpad.TrackpadThreeFingerHorizSwipeGesture = 1; # 0:disable 1:pages 2:full-screen-apps # NOTE: four-finger swipe for apps is enabled, freeing three-finger for pages...
            trackpad.TrackpadTwoFingerFromRightEdgeSwipeGesture = 3; # 0:disable 3:notification-center

          };
        };
    in
    {
      darwinConfigurations.default = nix-darwin.lib.darwinSystem {
        modules = [ configuration ];
      };
    };
}
