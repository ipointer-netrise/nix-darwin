{
  description = "Ivan MacBook nix-darwin system flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix-darwin.url = "github:nix-darwin/nix-darwin/master";
    nix-darwin.inputs.nixpkgs.follows = "nixpkgs";

    # Hermes Agent ships its own Nix package. Keep it as a flake input because
    # this nixpkgs revision does not package it.
    hermes-agent = {
      url = "github:NousResearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Graft's dogfood fork, built from source by the graft package below rather
    # than installed from npm. Not a flake -- just the source tree.
    graft-src = {
      url = "github:ivanpointer/Graft/085801a85bd49a943e751bc3412dab71e9614d7f";
      flake = false;
    };

    mac-xeneon-edge-touch-driver = {
      url = "github:ajvwhite/MacXeneonEdgeTouchDriver/main";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nix-darwin,
      nixpkgs,
      graft-src,
      mac-xeneon-edge-touch-driver,
      hermes-agent,
    }:
    let
      # ── graft ────────────────────────────────────────────────────
      # Built from source rather than installed from npm, because the install has to honour
      # graft's package-lock.json.  Its tree-sitter-wasm range is "^1.1.6", and 1.1.6 is the
      # only release in that range carrying the Terraform and HCL grammars -- upstream dropped
      # them in 1.1.8 and restored them in 2.0.  Resolving the range fresh (which `npm install`
      # of a packed tarball does, ignoring the lockfile inside it) lands on 1.1.8, and .tf files
      # are then skipped in silence: requireWasm returns null and the language never warms.
      #
      # Crux output is capped at 8192 tokens regardless of model, which cannot hold entries for
      # files of ~100+ symbols.  20480 clears them; the SDK rejects >=32768 on a non-streaming
      # call.  Patched in source here rather than sed'd into dist/ after install, which the read
      # only store forbids -- graft-refresh.sh greps the built output for the marker.
      #
      # The companion crux-id patch is gone: this dogfood fork fixes that defect properly in
      # resolveReturnedId(), so there is no `id: s.id` line left to rewrite.  Moving the pin back
      # to published @nanonets/graft 0.19.x/0.20.0 reintroduces the defect and needs the patch
      # restored -- symptom is every crux target missing and good summaries silently discarded.
      mkGraftPkg = pkgs: pkgs.buildNpmPackage {
        pname = "nanonets-graft";
        version = "0.20.0-dogfood-085801a";
        src = inputs.graft-src;
        npmDepsHash = "sha256-oynP3gsWXGQmm5qguGdusBXtW9FAeE2voXyNVBpPCs4=";

        # Applies to every npm invocation, `npm rebuild` included, so the native grammars are
        # compiled explicitly in preBuild.  Unconditional because graft's own `prepare` and
        # `postinstall`, and tree-sitter-cli's prebuilt-binary downloader, all reach the network.
        npmFlags = [ "--ignore-scripts" ];

        nativeBuildInputs = [
          pkgs.python3
          pkgs.nodejs
        ];

        postPatch = ''
          substituteInPlace src/ai/crux.ts \
            --replace-fail 'maxTokens: 8192,' 'maxTokens: 20480, // graft-patch-cap'
        '';

        preBuild = ''
          # Its postinstall fetches a release binary; nothing in graft's runtime needs the CLI.
          rm -rf node_modules/tree-sitter-cli

          # tree-sitter 0.21.1 pins its binding to C++17, but node 24's bundled V8 headers
          # (cppgc/macros.h) use concepts and will not compile below C++20.
          substituteInPlace node_modules/tree-sitter/binding.gyp \
            --replace-fail '"CLANG_CXX_LANGUAGE_STANDARD": "c++17"' '"CLANG_CXX_LANGUAGE_STANDARD": "c++20"' \
            --replace-warn '"-std=c++17"' '"-std=c++20"'

          export npm_config_nodedir=${pkgs.nodejs}
          for gyp in node_modules/*/binding.gyp node_modules/@*/*/binding.gyp; do
            [ -f "$gyp" ] || continue
            echo "building native grammar in $(dirname "$gyp")"
            (cd "$(dirname "$gyp")" && npm exec --offline -- node-gyp rebuild --nodedir=${pkgs.nodejs})
          done
        '';

        installPhase = ''
          runHook preInstall

          npm prune --omit=dev $npmFlags

          MODULE="$out/lib/node_modules/@nanonets/graft"
          mkdir -p "$MODULE"
          cp -r dist package.json scripts node_modules "$MODULE/"

          mkdir -p $out/bin
          makeWrapper ${pkgs.nodejs}/bin/node $out/bin/graft \
            --add-flags "$MODULE/dist/cli.js"

          runHook postInstall
        '';

        meta = {
          description = "Graft repo context graph (ivanpointer dogfood fork, 085801a)";
          mainProgram = "graft";
        };
      };

      mkToastMonitorPkg = pkgs:
        pkgs.stdenvNoCC.mkDerivation {
          pname = "ToastMonitor";
          version = "1.16.3";
          src = pkgs.fetchurl {
            url = "https://github.com/Toast1zz/ToastMonitor/releases/download/v1.16.3/ToastMonitor-1.16.3-arm64.zip";
            hash = "sha256-RYj6y55VU4HAmam4/JtoGloUeLVBQB2fKm0zQDp5wgk=";
          };

          nativeBuildInputs = [ pkgs.unzip ];
          unpackPhase = "unzip -qq $src";
          installPhase = ''
            mkdir -p "$out/Applications"
            cp -R ToastMonitor.app "$out/Applications/"
          '';

          # Its signed bundle must not be altered; upgrades are managed by this flake.
          dontFixup = true;

          meta = {
            description = "Native macOS menu-bar AI usage monitor";
            platforms = [ "aarch64-darwin" ];
          };
        };

      mkMacXeneonEdgeTouchDriverPkg = pkgs:
        pkgs.stdenv.mkDerivation {
          pname = "mac-xeneon-edge-touch-driver";
          version = "unstable";
          src = inputs.mac-xeneon-edge-touch-driver;

          nativeBuildInputs = [ pkgs.swift pkgs.swiftpm ];

          buildPhase = ''
            runHook preBuild
            swift build --configuration release --disable-sandbox --scratch-path "$TMPDIR/swift-build"
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 "$TMPDIR/swift-build/release/MacXeneonEdgeTouchDriver" \
              "$out/bin/MacXeneonEdgeTouchDriver"
            install -Dm755 "$TMPDIR/swift-build/release/DisplayInfo" "$out/bin/DisplayInfo"
            install -Dm755 "$TMPDIR/swift-build/release/HIDDump" "$out/bin/HIDDump"
            runHook postInstall
          '';

          meta = {
            description = "User-space macOS touch driver for the Corsair Xeneon Edge";
            homepage = "https://github.com/ajvwhite/MacXeneonEdgeTouchDriver";
            license = pkgs.lib.licenses.mit;
            platforms = [ "aarch64-darwin" ];
          };
        };

      configuration =
        { pkgs, config, ... }:
        let
          primaryUser = "ivanpointer";
          homeDir = "/Users/${primaryUser}";
          toastMonitorPkg = mkToastMonitorPkg pkgs;
          macXeneonEdgeTouchDriverPkg = mkMacXeneonEdgeTouchDriverPkg pkgs;

          # Locally packed tarballs that npmGlobals entries pin against. Not
          # tracked by any repo -- `npm pack` regenerates them from the source
          # checkout. A missing tarball warns and leaves the entry alone
          # rather than silently reinstalling something else.
          npmPackageDir = "${homeDir}/.local/share/npm-packages";
          npmGlobalPrefix = "${homeDir}/.local/share/npm-global";

          # ── Declarative global npm CLIs ──────────────────────────────
          # Add { package, bin } entries to npmGlobals. Each entry will
          # be installed/updated to the latest version on every
          # `darwin-rebuild switch`, and its binary symlinked into
          # /usr/local/bin. Harnesses share a writable npm global prefix so
          # their native `npm install -g` updaters reach the launched binary.
          #
          # `tarball` pins an entry to a local pack instead of @latest. The
          # pin token is the tarball's filename, so repacking under the same
          # name is a no-op -- put the source commit in the filename and bump
          # it whenever the contents change.
          # `bin = null` installs a library with no executable to link;
          # such an entry must name its own `dir`.
          mkNpmGlobal =
            {
              package,
              bin ? null,
              dir ? bin,
              tarball ? null,
              global ? true,
            }:
            let
              prefix = if global then npmGlobalPrefix else "${homeDir}/.local/share/npm-globals/${dir}";
            in
            ''
              # --- npm global: ${package} (${dir}) ---
              PREFIX="${prefix}"

              mkdir -p "$PREFIX"
              chown -R ${primaryUser}:staff "${homeDir}/.local"
              # npm cache must be user-owned (root-run npm can clobber it)
              if [ -d "${homeDir}/.npm" ]; then
                chown -R ${primaryUser}:staff "${homeDir}/.npm"
              fi

            ''
            + (
              if tarball == null then
                ''
                  # npm install is idempotent when already at latest; let it
                  # be the source of truth rather than shelling out for a
                  # version check.
                  echo "Ensuring ${package}@latest..."
                  sudo -u ${primaryUser} \
                    HOME="${homeDir}" \
                    PATH="${pkgs.nodejs}/bin:$PATH" \
                    ${pkgs.nodejs}/bin/npm install \
                      ${pkgs.lib.optionalString global "--global"} \
                      --prefix "$PREFIX" \
                      --no-audit --no-fund --silent \
                      "${package}@latest"
                ''
              else
                ''
                  PIN_FILE="$PREFIX/.nix-darwin-pin"
                  PIN_TOKEN="${baseNameOf tarball}"
                  if [ ! -f "${tarball}" ]; then
                    echo "  (${package} left as-is: pinned tarball missing at ${tarball})" >&2
                  elif [ -f "$PIN_FILE" ] && [ "$(cat "$PIN_FILE")" = "$PIN_TOKEN" ]; then
                    :
                  else
                    echo "Installing pinned ${package} from $PIN_TOKEN..."
                    sudo -u ${primaryUser} \
                      HOME="${homeDir}" \
                      PATH="${pkgs.nodejs}/bin:$PATH" \
                      ${pkgs.nodejs}/bin/npm install \
                        --prefix "$PREFIX" \
                        --no-audit --no-fund --silent \
                        "${tarball}"
                    printf '%s\n' "$PIN_TOKEN" >"$PIN_FILE"
                    chown ${primaryUser}:staff "$PIN_FILE"
                  fi
                ''
            )
            + pkgs.lib.optionalString (bin != null) ''

              mkdir -p /usr/local/bin
              ln -sf "${if global then "$PREFIX/bin/${bin}" else "$PREFIX/node_modules/.bin/${bin}"}" /usr/local/bin/${bin}
            '';

          npmGlobals = [
            {
              package = "@earendil-works/pi-coding-agent";
              bin = "pi";
            }
            {
              package = "@opencode/cli";
              bin = "opencode";
            }
            {
              package = "@a5c-ai/babysitter-opencode";
              bin = "babysitter-opencode";
            }
            {
              package = "@openai/codex";
              bin = "codex";
            }
            {
              package = "@anthropic-ai/claude-code";
              bin = "claude";
            }
            {
              # Jev, the reuse/crux hook graft loads by path through
              # GRAFT_HOOK (ivanpointer/graft-jev, ed99762). A library with
              # no executable, so it names its own prefix directory and
              # links nothing into /usr/local/bin.
              package = "@ivanpointer/graft-jev";
              dir = "graft-jev";
              tarball = "${npmPackageDir}/ivanpointer-graft-jev-0.1.0-ed99762.tgz";
              global = false;
            }
          ];

          graftPkg = mkGraftPkg pkgs;

          # Two stable paths into the current generation's graft, re-pointed on every switch.
          #
          # /usr/local/bin/graft is the raw binary, by absolute path, for harness MCP configs that
          # do not inherit a login PATH.  mkNpmGlobal used to create it; graft no longer goes
          # through npm, so it is maintained here instead.
          #
          # /usr/local/share/graft/module is the installed package directory.  Sibling host
          # adapters -- the Claude statusline shim, graft-usage, chezmoi's skill refresh --
          # import graft's compiled dist/claude modules directly rather than shelling out to the
          # CLI, and graft-refresh.sh greps dist/ai/crux.js for the patch marker.  It is not
          # reachable through the system profile: environment.pathsToLink covers /bin and a few
          # /share subtrees, not /lib, and widening that to link every package's lib is not worth
          # one consumer.
          mkGraftSymlinks = ''
            # --- graft: stable paths into the current generation ---
            mkdir -p /usr/local/bin /usr/local/share/graft
            ln -sf "${graftPkg}/bin/graft" /usr/local/bin/graft
            ln -sfn "${graftPkg}/lib/node_modules/@nanonets/graft" /usr/local/share/graft/module
          '';

          mkSelfUpdatingHarness =
            {
              name,
              bin,
              marker,
              installerUrl,
              installerArgs ? "",
            }:
            let
              argsSuffix = pkgs.lib.optionalString (installerArgs != "") " -s -- ${installerArgs}";
            in
            ''
              # --- self-updating harness: ${name} ---
              if [ ! -e "${marker}" ]; then
                echo "Installing ${name}..."
                sudo -u ${primaryUser} \
                  HOME="${homeDir}" \
                  PATH="${pkgs.curl}/bin:${pkgs.bash}/bin:/usr/local/bin:$PATH" \
                  ${pkgs.bash}/bin/bash -c '${pkgs.curl}/bin/curl -fsSL ${installerUrl} | ${pkgs.bash}/bin/bash${argsSuffix}'
              fi

              mkdir -p /usr/local/bin
              ln -sf "${homeDir}/.local/bin/${bin}" /usr/local/bin/${bin}
            '';

          selfUpdatingHarnesses = [
            {
              name = "Antigravity CLI";
              bin = "agy";
              marker = "${homeDir}/.local/bin/agy";
              installerUrl = "https://antigravity.google/cli/install.sh";
              installerArgs = "--dir ${homeDir}/.local/bin";
            }
          ];

          # ── Declarative pi-coding-agent packages ─────────────────────
          # Pi packages (extensions/skills/themes) are managed via
          # `pi install npm:<name>`, which records them in
          # ~/.pi/agent/settings.json under `packages`. We make this
          # declarative here so a fresh machine gets the same set.
          # Unpinned: every activation updates to latest, and a failure never blocks the switch.
          mkPiPackage = pkg: ''
            # --- pi package: ${pkg} ---
            PI_SETTINGS="${homeDir}/.pi/agent/settings.json"
            if [ ! -f "$PI_SETTINGS" ] || ! ${pkgs.jq}/bin/jq -e \
                --arg p "npm:${pkg}" \
                '(.packages // []) | index($p)' "$PI_SETTINGS" >/dev/null 2>&1; then
              echo "Installing pi package ${pkg}..."
              sudo -u ${primaryUser} \
                HOME="${homeDir}" \
                PATH="${pkgs.nodejs}/bin:/usr/local/bin:$PATH" \
                /usr/local/bin/pi install "npm:${pkg}" || true
            else
              echo "Updating pi package ${pkg}..."
              sudo -u ${primaryUser} \
                HOME="${homeDir}" \
                PATH="${pkgs.nodejs}/bin:/usr/local/bin:$PATH" \
                /usr/local/bin/pi update "npm:${pkg}" || true
            fi
          '';

          piPackages = [
            "pi-mcp-adapter"
          ];

          # ── aven coding-agent skill ──────────────────────────────────
          # `aven skill install` drops the task-workflow skill into each
          # agent's config tree (~/.claude/skills, etc). Agents are named
          # explicitly rather than relying on aven's auto-detection so a
          # fresh machine installs the full set deterministically. This
          # must run after mkNpmGlobal -- opencode/codex/pi don't exist
          # until those npm installs complete, and aven skips agents it
          # can't find.
          avenSkillAgents = [
            "claude"
            "opencode"
            "codex"
            "pi"
          ];
          mkAvenSkill = ''
            # --- aven coding-agent skill ---
            echo "Ensuring aven agent skill..."
            sudo -u ${primaryUser} \
              HOME="${homeDir}" \
              PATH="/opt/homebrew/bin:/usr/local/bin:${pkgs.nodejs}/bin:$PATH" \
              /opt/homebrew/bin/aven skill install \
              ${pkgs.lib.concatMapStringsSep " " (a: "--agent ${a}") avenSkillAgents} \
              || echo "  (aven skill install failed; run manually)"

            # Hermes is a fifth harness aven doesn't know about -- `--agent`
            # accepts only claude/opencode/codex/pi -- but it reads the same
            # SKILL.md format from ~/.hermes/skills/<category>/<name>/. Mirror
            # the file aven just generated rather than committing a copy, so
            # the text tracks the installed aven version and there is no
            # frontmatter duplicated here to drift.
            #
            # chezmoi owns ~/.hermes/skills, but none of those directories are
            # exact_, so this unmanaged skill survives `chezmoi apply`.
            AVEN_SRC="${homeDir}/.claude/skills/aven/SKILL.md"
            AVEN_HERMES="${homeDir}/.hermes/skills/workflows/aven"
            if [ -f "$AVEN_SRC" ]; then
              sudo -u ${primaryUser} mkdir -p "$AVEN_HERMES"
              sudo -u ${primaryUser} cp "$AVEN_SRC" "$AVEN_HERMES/SKILL.md"
              echo "Ensured aven skill for Hermes at $AVEN_HERMES/SKILL.md"
            else
              echo "  (skipped Hermes aven skill; $AVEN_SRC missing)"
            fi
          '';

          # ── aven sync daemon ─────────────────────────────────────────
          # Without the LaunchAgent, aven only syncs when you run `aven sync`
          # by hand -- `sync.interval_seconds` in config.yaml does nothing.
          # `aven daemon install` is idempotent and rewrites the plist with the
          # current binary path, so re-running keeps it correct across upgrades.
          mkAvenDaemon = ''
            # --- aven sync daemon (LaunchAgent) ---
            echo "Ensuring aven sync daemon..."
            sudo -u ${primaryUser} \
              HOME="${homeDir}" \
              PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" \
              /opt/homebrew/bin/aven daemon install \
              || echo "  (aven daemon install failed; run manually)"
          '';

          # ── Synergy 3 ────────────────────────────────────────────────
          # Closed-source, so there is no cask or nixpkgs package. Pinned by version and
          # sha256; bump all three together. The token is Symless's public guest token.
          synergyVersion = "3.7.2";
          synergySha256 = "3bc0fbcc1ed8b646c830ab4b02ad0c66b36447d3488312a42243bb1e7a822a9f";
          synergyUrl = "https://symless.com/synergy/api/download/synergy-${synergyVersion}-macos-arm64.dmg?token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJwcm9kdWN0UGFja2FnZUlkIjoxMjU2LCJ1c2VySWQiOm51bGwsImlhdCI6MTc5MTA0NzM2Mn0.13OUtDT-V13Y-F8AxQADnossgTMVPu9NQecFWzWdlIc";
          mkSynergy = ''
            # --- Synergy 3 (pinned DMG install) ---
            SYNERGY_APP="/Applications/Synergy.app"
            SYNERGY_HAVE=$(/usr/bin/defaults read "$SYNERGY_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
            if [ "$SYNERGY_HAVE" != "${synergyVersion}" ]; then
              echo "Installing Synergy ${synergyVersion} (have: ''${SYNERGY_HAVE:-none})..."
              (
                set -e
                SYNERGY_TMP=$(/usr/bin/mktemp -d)
                trap '/usr/bin/hdiutil detach "$SYNERGY_TMP/mnt" -quiet 2>/dev/null || true; rm -rf "$SYNERGY_TMP"' EXIT
                /usr/bin/curl -fsSL -o "$SYNERGY_TMP/synergy.dmg" "${synergyUrl}"
                echo "${synergySha256}  $SYNERGY_TMP/synergy.dmg" | /usr/bin/shasum -a 256 -c -
                /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$SYNERGY_TMP/mnt" "$SYNERGY_TMP/synergy.dmg" -quiet
                rm -rf "$SYNERGY_APP"
                /usr/bin/ditto "$SYNERGY_TMP/mnt/Synergy.app" "$SYNERGY_APP"
              ) || echo "  (Synergy install failed; run activation again or install manually)"
            fi
          '';

          # ── Firecrawl (self-hosted, docker compose) ──────────────────
          # Cloned to ${firecrawlDir}, run as a launchd user agent so it
          # starts on login (Docker Desktop is per-user, so a system
          # daemon won't have a socket to talk to). The .env is only
          # bootstrapped if missing — edit it in place to set secrets
          # like OPENAI_API_KEY or rotate BULL_AUTH_KEY.
          firecrawlDir = "${homeDir}/.local/share/firecrawl";
          firecrawlRepo = "https://github.com/firecrawl/firecrawl.git";
          secondBrainDir = "${homeDir}/Source/personal/second-brain";

          # ── Homebrew taps ────────────────────────────────────────────
          # Homebrew 6.0 turned on HOMEBREW_REQUIRE_TAP_TRUST by default:
          # formulae from non-official taps refuse to load until trusted.
          # nix-darwin already handles this -- homebrew.brews.*.trusted
          # defaults to true, appending `trusted: true` to each Brewfile
          # line, and `brew bundle` persists those entries (see
          # bundle/installer.rb) *before* it installs, so a fresh machine
          # needs no manual `brew trust`.
          #
          # Footgun: do NOT hand-write ~/.homebrew/trust.json to solve
          # this. `--force-cleanup` invokes Homebrew::Trust.replace!,
          # which rebuilds the file from Brewfile-derived entries only
          # and silently drops every key it did not generate (a
          # hand-written `trustedtaps` vanishes on each activation).
          brewTaps = [
            "auth0/auth0-cli"
            "chainguard-dev/tap"
            "hashicorp/tap"
            "raine/aven"
            "raine/workmux"
          ];
        in
        {
          nixpkgs.config.allowUnfree = true;
          # profile = "/nix/etc-darwin";

          # List packages installed in system profile. To search by name, run:
          # $ nix-env -qaP | grep wget
          environment.systemPackages = [
            pkgs.python3
            graftPkg
            toastMonitorPkg
            macXeneonEdgeTouchDriverPkg

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

            # uv: Python tooling
            pkgs.uv
            # Required by the MOSS-TTS installer for voice-reference cropping.
            pkgs.ffmpeg
            inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default

            pkgs.go
            # Keeps linting reproducible across rebuilds; a `go install`ed
            # golangci-lint drifts ahead of CI and reports findings CI won't.
            pkgs.golangci-lint
            pkgs.wget
            pkgs.grpcurl
            pkgs.ngrok
            # Provides the `playwright` CLI. Its browsers come from
            # PLAYWRIGHT_BROWSERS_PATH below and are version-locked to this
            # package; a project pinning a different @playwright/test will not
            # find its browser revision there.
            pkgs.playwright-test
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
            # opencode is installed via npm in the postActivation script
            # below (see npmGlobals / system.activationScripts.postActivation).
            # pi-coding-agent is installed via npm in the postActivation
            # script below (see system.activationScripts.postActivation).
            # Codex and Claude are npm-managed (see npmGlobals) so their
            # native updaters can write to the user-owned global prefix.

            # CLI Clients
            pkgs.acli # Atlassian

            # Infrastructure as code
            pkgs.terraform
            pkgs.doctl # DigitalOcean CLI (aven sync droplet -- see server/aven-sync/)
          ];

          environment.systemPath = [ "/opt/homebrew/bin" "/opt/homebrew/sbin" ];

          environment.variables.CATPPUCCIN_TMUX_PATH = "${pkgs.tmuxPlugins.catppuccin.rtp}";
          environment.variables.TMUX_CPU_PATH = "${pkgs.tmuxPlugins.cpu.rtp}";
          environment.variables.TMUX_BATTERY_PATH = "${pkgs.tmuxPlugins.battery.rtp}";
          environment.variables.PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";

          fonts.packages = [
            pkgs.inconsolata
            pkgs.monaspace
            pkgs.open-sans
            pkgs.nerd-fonts.inconsolata
            # Glyphs only, no Latin: safe as a fallback behind MonoLisa,
            # which has Powerline but no Devicons/Seti/Material/Octicons.
            # A fully-patched font here would shadow MonoLisa's letterforms.
            pkgs.nerd-fonts.symbols-only
          ];

          homebrew = {
            enable = true;
            taps = brewTaps;
            brews = [
              "auth0/auth0-cli/auth0"
              "chainguard-dev/tap/chainctl"
              "hashicorp/tap/packer"
              # Not in nixpkgs; upstream ships a tap (same author as workmux).
              "raine/aven/aven"
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
              "slack"
              # Official slackapi CLI; `slack api` is a Web API passthrough.
              # nixpkgs' slack-cli is the unrelated, archived rockymadden tool.
              "slack-cli"
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
              "visual-studio-code"
              "cmux"
              "bettertouchtool"
              "figma"
              "hex-fiend"
              "microsoft-office"
              "microsoft-edge"
              "microsoft-teams"
              "firefox"
              "vivaldi"
              "audacity"
              "openchamber"
              "jetbrains-toolbox"
              "todoist-app"
              "zen"
              "blender"
              "discord"
              "ankerwork"
              "farrago"
              "loopback"
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

          # Tailscale: private overlay network. Carries aven sync traffic to
          # the self-hosted server (see server/aven-sync/) without exposing it
          # publicly -- aven ships no TLS of its own.
          #
          # This runs the open-source tailscaled daemon, not the GUI cask, so
          # it is reproducible from the flake. `tailscale up` still needs an
          # interactive browser login once per machine.
          services.tailscale.enable = true;

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

                    # npm harness updaters invoke `npm install -g`; direct that to their shared,
                    # user-owned prefix rather than Nix's immutable store.
                    sudo -u ${primaryUser} \
                      HOME="${homeDir}" \
                      PATH="${pkgs.nodejs}/bin:$PATH" \
                      ${pkgs.nodejs}/bin/npm config set prefix \
                        "${npmGlobalPrefix}" --location=user

                    ${pkgs.lib.concatMapStrings mkSelfUpdatingHarness selfUpdatingHarnesses}

                    ${mkGraftSymlinks}

                    # --- Pi packages (declared in piPackages above) ---
                    ${pkgs.lib.concatMapStrings mkPiPackage piPackages}

                    ${mkAvenSkill}

                    ${mkAvenDaemon}

                    ${mkSynergy}

                    # --- Firecrawl repo + .env bootstrap ---
                    FIRECRAWL_DIR="${firecrawlDir}"
                    sudo -u ${primaryUser} mkdir -p "$(dirname "$FIRECRAWL_DIR")"
                    if [ ! -d "$FIRECRAWL_DIR/.git" ]; then
                      echo "Cloning firecrawl into $FIRECRAWL_DIR..."
                      sudo -u ${primaryUser} HOME="${homeDir}" \
                        ${pkgs.git}/bin/git clone --depth 1 \
                        ${firecrawlRepo} "$FIRECRAWL_DIR"
                    else
                      echo "Updating firecrawl in $FIRECRAWL_DIR..."
                      sudo -u ${primaryUser} HOME="${homeDir}" \
                        ${pkgs.git}/bin/git -C "$FIRECRAWL_DIR" \
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

          # The driver reads the Edge's HID digitizer and emits ordinary macOS pointer events.
          # It must run per-user: Input Monitoring and Accessibility approval are scoped to this binary.
          launchd.user.agents.mac-xeneon-edge-touch-driver = {
            serviceConfig = {
              Label = "com.ajvwhite.MacXeneonEdgeTouchDriver";
              ProgramArguments = [ "${macXeneonEdgeTouchDriverPkg}/bin/MacXeneonEdgeTouchDriver" ];
              RunAtLoad = true;
              KeepAlive = {
                SuccessfulExit = false;
                Crashed = true;
              };
              ThrottleInterval = 10;
              StandardOutPath = "${homeDir}/Library/Logs/MacXeneonEdgeTouchDriver/stdout.log";
              StandardErrorPath = "${homeDir}/Library/Logs/MacXeneonEdgeTouchDriver/stderr.log";
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

          # graft-refresh: keep the --deep meaning layer current across every graft-indexed
          # repo under ~/Source.  Weekday mornings; everything is content-hash cached so an
          # unchanged repo is free.  RunAtLoad is off deliberately -- a `darwin-rebuild
          # switch` should not kick off an hours-long build.  The key is read from ~/.zshenv
          # by the script, never from here: EnvironmentVariables lands in the world-readable
          # nix store.
          launchd.user.agents.graft-refresh = {
            serviceConfig = {
              Label = "io.graft.refresh";
              ProgramArguments = [
                "/bin/zsh"
                "${./scripts/graft-refresh.sh}"
              ];
              StartCalendarInterval = [
                { Weekday = 1; Hour = 7; Minute = 0; }
                { Weekday = 2; Hour = 7; Minute = 0; }
                { Weekday = 3; Hour = 7; Minute = 0; }
                { Weekday = 4; Hour = 7; Minute = 0; }
                { Weekday = 5; Hour = 7; Minute = 0; }
              ];
              RunAtLoad = false;
              EnvironmentVariables = {
                PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin";
              };
              StandardOutPath = "${homeDir}/Library/Logs/graft-refresh.err.log";
              StandardErrorPath = "${homeDir}/Library/Logs/graft-refresh.err.log";
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

              # --- Mac Xeneon Edge touch driver logs ---
              XENEON_LOG_DIR="${homeDir}/Library/Logs/MacXeneonEdgeTouchDriver"
              install -d -o ${primaryUser} -g staff "$XENEON_LOG_DIR"
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

              # Universal Control is off so it doesn't fight Synergy for the pointer.
              # The keys mirror Displays → Advanced; all three are 1 (disabled).
              "com.apple.universalcontrol" = {
                Disable = 1;
                DisableMagicEdges = 1;
                DisableAutoDiscovery = 1;
              };

              # Handoff stays on; it is independent of Universal Control.
              "com.apple.coreservices.useractivityd" = {
                ActivityAdvertisingAllowed = true;
                ActivityReceivingAllowed = true;
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

      # `nix build .#graft` builds the same derivation the system installs, without a
      # rebuild of everything else.  graft-claude-dir is the compiled dist/claude tree,
      # which sibling host adapters import directly rather than through the CLI.
      packages.aarch64-darwin =
        let
          pkgs = nixpkgs.legacyPackages.aarch64-darwin;
          graft = mkGraftPkg pkgs;
          macXeneonEdgeTouchDriver = mkMacXeneonEdgeTouchDriverPkg pkgs;
        in
        {
          inherit graft macXeneonEdgeTouchDriver;
          default = graft;
          graft-claude-dir = pkgs.runCommand "graft-claude-dir" { } ''
            ln -s ${graft}/lib/node_modules/@nanonets/graft/dist/claude $out
          '';
        };
    };
}
