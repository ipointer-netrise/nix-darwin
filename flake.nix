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

          # ── Declarative global npm CLIs ──────────────────────────────
          # Add { package, bin } entries to npmGlobals. Each entry will
          # be installed/updated to the latest version on every
          # `darwin-rebuild switch`, and its binary symlinked into
          # /usr/local/bin. Versions live in ~/.local/share/npm-globals/.
          mkNpmGlobal =
            { package, bin }:
            ''
              # --- npm global: ${package} (${bin}) ---
              PREFIX="${homeDir}/.local/share/npm-globals/${bin}"
              BIN="$PREFIX/node_modules/.bin/${bin}"

              mkdir -p "$PREFIX"
              chown -R ${primaryUser}:staff "${homeDir}/.local"
              # npm cache must be user-owned (root-run npm can clobber it)
              if [ -d "${homeDir}/.npm" ]; then
                chown -R ${primaryUser}:staff "${homeDir}/.npm"
              fi

              # npm install is idempotent when already at latest; let it
              # be the source of truth rather than shelling out for a
              # version check.
              echo "Ensuring ${package}@latest..."
              sudo -u ${primaryUser} \
                HOME="${homeDir}" \
                PATH="${pkgs.nodejs}/bin:$PATH" \
                ${pkgs.nodejs}/bin/npm install \
                  --prefix "$PREFIX" \
                  --no-audit --no-fund --silent \
                  "${package}@latest"

              mkdir -p /usr/local/bin
              ln -sf "$BIN" /usr/local/bin/${bin}
            '';

          npmGlobals = [
            {
              package = "@earendil-works/pi-coding-agent";
              bin = "pi";
            }
            {
              package = "opencode-ai";
              bin = "opencode";
            }
            {
              package = "@a5c-ai/babysitter-opencode";
              bin = "babysitter-opencode";
            }
          ];

          # ── Declarative pi-coding-agent packages ─────────────────────
          # Pi packages (extensions/skills/themes) are managed via
          # `pi install npm:<name>`, which records them in
          # ~/.pi/agent/settings.json under `packages`. We make this
          # declarative here so a fresh machine gets the same set.
          mkPiPackage = pkg: ''
            # --- pi package: ${pkg} ---
            PI_SETTINGS="${homeDir}/.pi/agent/settings.json"
            if [ ! -f "$PI_SETTINGS" ] || ! ${pkgs.jq}/bin/jq -e \
                --arg p "npm:${pkg}" \
                '(.packages // []) | index($p)' "$PI_SETTINGS" >/dev/null 2>&1; then
              echo "Ensuring pi package ${pkg}..."
              sudo -u ${primaryUser} \
                HOME="${homeDir}" \
                PATH="${pkgs.nodejs}/bin:/usr/local/bin:$PATH" \
                /usr/local/bin/pi install "npm:${pkg}" || true
            fi
          '';

          piPackages = [
            "pi-mcp-adapter"
          ];

          # ── Declarative uv-tool CLIs ─────────────────────────────────
          # Python CLIs distributed on PyPI, installed via `uv tool
          # install --upgrade`. uv manages an isolated venv per tool and
          # auto-fetches a compatible managed CPython, so no system
          # Python is required. The tool's bin lands in ~/.local/bin and
          # is symlinked into /usr/local/bin (mirrors mkNpmGlobal).
          mkUvTool =
            { package, bin, withPackages ? [ ] }:
            let
              withFlags = pkgs.lib.concatMapStringsSep " " (p: "--with ${pkgs.lib.escapeShellArg p}") withPackages;
            in
            ''
              # --- uv tool: ${package} (${bin}) ---
              chown -R ${primaryUser}:staff "${homeDir}/.local" || true

              echo "Ensuring ${package}@latest via uv tool..."
              sudo -u ${primaryUser} \
                HOME="${homeDir}" \
                PATH="${pkgs.uv}/bin:$PATH" \
                ${pkgs.uv}/bin/uv tool install --upgrade ${withFlags} "${package}"

              mkdir -p /usr/local/bin
              ln -sf "${homeDir}/.local/bin/${bin}" /usr/local/bin/${bin}
            '';

          uvTools = [
            {
              # [all] pulls in every optional extra (mcp, messaging,
              # voice, vision, etc.). [mcp] alone would suffice for the
              # Open Brain integration but [all] matches what `hermes
              # doctor` recommends and keeps connectors available.
              package = "hermes-agent[all]";
              bin = "hermes";
              # The following Python deps are NOT pulled by
              # hermes-agent[all] — they're in Hermes' lazy-install
              # allowlist (see tools/lazy_deps.py) and only get installed
              # when the feature is first used. We inject them here so:
              #   * sounddevice — needs system PortAudio (pkgs.portaudio
              #     above); declarative install matches the system lib.
              #   * numpy — sounddevice runtime dep.
              #   * faster-whisper — `/voice on` STT backend. Its lazy
              #     prompt gets swallowed by the CLI's rendering layer
              #     and hangs the session, so we pre-install.
              #   * anthropic — native Anthropic SDK (provider=anthropic
              #     paths). Used by the agent default model.
              #   * edge-tts — default TTS backend for `/voice tts`.
              # `uv tool install --upgrade --with X` does a clean
              # re-resolve, so any lazy-installed dep not listed here
              # gets pruned on every `make apply`. Add to this list any
              # Hermes feature you want sticky across rebuilds.
              withPackages = [
                "sounddevice"
                "numpy"
                "faster-whisper"
                "anthropic"
                "edge-tts"
              ];
            }
          ];

          # ── Firecrawl (self-hosted, docker compose) ──────────────────
          # Cloned to ${firecrawlDir}, run as a launchd user agent so it
          # starts on login (Docker Desktop is per-user, so a system
          # daemon won't have a socket to talk to). The .env is only
          # bootstrapped if missing — edit it in place to set secrets
          # like OPENAI_API_KEY or rotate BULL_AUTH_KEY.
          firecrawlDir = "${homeDir}/.local/share/firecrawl";
          firecrawlRepo = "https://github.com/firecrawl/firecrawl.git";
          secondBrainDir = "${homeDir}/Source/personal/second-brain";

          # ── Homebrew taps + trust ────────────────────────────────────
          # Homebrew 5.x sets HOMEBREW_REQUIRE_TAP_TRUST by default and
          # refuses to load formulae from any tap not listed in
          # ~/.homebrew/trust.json. We declare taps once here and write
          # the trust file ourselves in preActivation so a fresh machine
          # doesn't need a manual `brew trust <tap>` step.
          brewTaps = [
            "auth0/auth0-cli"
            "chainguard-dev/tap"
            "hashicorp/tap"
            "raine/workmux"
          ];
          brewTrustJson = builtins.toJSON { trustedtaps = brewTaps; };
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

            # uv: Python tooling (used by uvTools, e.g. hermes-agent)
            pkgs.uv
            pkgs.ffmpeg # optional hermes TTS dependency
            pkgs.portaudio # hermes voice mode: PortAudio C library for sounddevice Python bindings

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
            # opencode is installed via npm in the postActivation script
            # below (see npmGlobals / system.activationScripts.postActivation).
            # pi-coding-agent is installed via npm in the postActivation
            # script below (see system.activationScripts.postActivation).
            pkgs.codex

            # CLI Clients
            pkgs.acli # Atlassian

            # Infrastructure as code
            pkgs.terraform
          ];

          environment.systemPath = [ "/opt/homebrew/bin" "/opt/homebrew/sbin" ];

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
            taps = brewTaps;
            brews = [
              "auth0/auth0-cli/auth0"
              "chainguard-dev/tap/chainctl"
              "hashicorp/tap/packer"
              "raine/workmux/workmux"
              # macmon 0.7.2+ required for M5 Pro — nixpkgs has 0.6.1 which
              # panics on M5 Pro's IOReport channels. See ADR 0013.
              "macmon"
            ];
            casks = [
              "1password"
              "google-chrome"
              "the-unarchiver"
              "postman"
              "yubico-authenticator"
              "zoom"
              "ghostty"
              "hammerspoon"
              "slack"
              "ollama-app"
              "docker-desktop"
              "chatgpt"
              "claude"
              "codex-app"
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
              "figma"
              "hex-fiend"
              "microsoft-office"
              "microsoft-edge"
              "firefox"
              "vivaldi"
              "audacity"
              "openchamber"
              "jetbrains-toolbox"
              "todoist-app"
              "zen"
              "blender"
              "discord"
            ];
            masApps = {
              "Amphetamine" = 937984704;
            };

            onActivation.cleanup = "zap";
            # Homebrew 5.1+ refuses `brew bundle --cleanup` without an
            # explicit force flag; pass it so non-interactive activation
            # doesn't abort.
            onActivation.extraFlags = [ "--force-cleanup" ];
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
          security.pam.services.sudo_local.watchIdAuth = true;
          security.pam.services.sudo_local.reattach = true;
          # The module concatenates touchIdAuth before watchIdAuth, but PAM
          # `sufficient` lines are tried top-down — first match wins. Force
          # Watch ahead of Touch ID so the watch is the primary prompt.
          security.pam.services.sudo_local.text = pkgs.lib.mkForce ''
            auth       optional       ${pkgs.pam-reattach}/lib/pam/pam_reattach.so
            auth       sufficient     ${pkgs.pam-watchid}/lib/pam_watchid.so
            auth       sufficient     pam_tid.so
          '';

          # System-level git config: rewrite GitLab HTTPS to SSH
          # Lives at /etc/gitconfig — below ~/.gitconfig so chezmoi can layer on top
          environment.etc.gitconfig.text = ''
            [url "git@gitlab.com:"]
                insteadOf = https://gitlab.com/
          '';

          system.primaryUser = primaryUser;

          # Pre-trust homebrew taps declared above. Runs before the
          # nix-darwin homebrew activation so `brew bundle` won't refuse
          # to load formulae from a fresh tap on a new machine.
          # ${homeDir}/.homebrew/trust.json is owned by the primary user;
          # we (re)write it on every switch so taps stay in sync with
          # `brewTaps`.
          system.activationScripts.preActivation.text = ''
            TRUST_DIR="${homeDir}/.homebrew"
            sudo -u ${primaryUser} mkdir -p "$TRUST_DIR"
            cat > "$TRUST_DIR/trust.json" <<'BREW_TRUST_EOF'
            ${brewTrustJson}
            BREW_TRUST_EOF
            chown ${primaryUser}:staff "$TRUST_DIR/trust.json"
            chmod 644 "$TRUST_DIR/trust.json"
          '';

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

                    # --- Global npm CLIs (declared in npmGlobals above) ---
                    ${pkgs.lib.concatMapStrings mkNpmGlobal npmGlobals}

                    # --- Pi packages (declared in piPackages above) ---
                    ${pkgs.lib.concatMapStrings mkPiPackage piPackages}

                    # --- uv-tool CLIs (declared in uvTools above) ---
                    ${pkgs.lib.concatMapStrings mkUvTool uvTools}

                    # --- Firecrawl repo + .env bootstrap ---
                    FIRECRAWL_DIR="${firecrawlDir}"
                    sudo -u ${primaryUser} mkdir -p "$(dirname "$FIRECRAWL_DIR")"
                    if [ ! -d "$FIRECRAWL_DIR/.git" ]; then
                      echo "Cloning firecrawl into $FIRECRAWL_DIR..."
                      sudo -u ${primaryUser} ${pkgs.git}/bin/git clone --depth 1 \
                        ${firecrawlRepo} "$FIRECRAWL_DIR"
                    else
                      echo "Updating firecrawl in $FIRECRAWL_DIR..."
                      sudo -u ${primaryUser} ${pkgs.git}/bin/git -C "$FIRECRAWL_DIR" \
                        pull --ff-only --quiet || \
                        echo "  (skipped; resolve manually if needed)"
                    fi

                    if [ ! -f "$FIRECRAWL_DIR/.env" ]; then
                      cat > "$FIRECRAWL_DIR/.env" << 'FIRECRAWL_ENV_EOF'
            PORT=3002
            HOST=0.0.0.0
            USE_DB_AUTHENTICATION=false
            BULL_AUTH_KEY=CHANGEME
            OPENAI_API_KEY=
            FIRECRAWL_ENV_EOF
                      chown ${primaryUser}:staff "$FIRECRAWL_DIR/.env"
                      echo "Bootstrapped $FIRECRAWL_DIR/.env — edit to set secrets."
                    fi
          '';

          # Firecrawl runs as a per-user launchd agent (not a system
          # daemon) because Docker Desktop is per-user — the docker
          # socket only exists once the user has logged in. The agent
          # waits for Docker via KeepAlive; if `docker compose up` exits
          # (e.g. socket not ready yet), launchd restarts it on the
          # ThrottleInterval until Docker Desktop is up.
          launchd.user.agents.firecrawl = {
            serviceConfig = {
              Label = "io.firecrawl.local";
              ProgramArguments = [
                "/bin/sh"
                "-c"
                "exec /usr/local/bin/docker compose up"
              ];
              WorkingDirectory = firecrawlDir;
              RunAtLoad = true;
              KeepAlive = true;
              ThrottleInterval = 30;
              StandardOutPath = "${homeDir}/Library/Logs/firecrawl.log";
              StandardErrorPath = "${homeDir}/Library/Logs/firecrawl.err.log";
              EnvironmentVariables = {
                PATH = "/usr/local/bin:/usr/bin:/bin";
              };
            };
          };

          # macmon-exporter: Apple Silicon GPU/CPU/temp/power → Prometheus text
          # on :9101. Prometheus scrapes it via host.docker.internal:9101.
          # Reads IOReport without sudo (same interface btop uses). See ADR 0013.
          launchd.user.agents.macmon-exporter = {
            serviceConfig = {
              Label = "com.neocortex.macmon-exporter";
              ProgramArguments = [
                "${pkgs.python3}/bin/python3"
                "${secondBrainDir}/scripts/macmon_exporter.py"
              ];
              EnvironmentVariables = {
                # macmon lives in /opt/homebrew/bin (installed via homebrew.brews)
                PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
              };
              RunAtLoad = true;
              KeepAlive = true;
              ThrottleInterval = 10;
              StandardOutPath = "${homeDir}/Library/Logs/macmon-exporter.log";
              StandardErrorPath = "${homeDir}/Library/Logs/macmon-exporter.log";
            };
          };

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
              # "com.apple.universalcontrol" = {
              #   Disable = true;
              # };

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
