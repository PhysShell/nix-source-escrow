{
  description = "nix-source-escrow: locally controlled source escrow for Nix, with an origin-independence acceptance test";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        default = nix-source-escrow;

        nix-source-escrow = pkgs.stdenvNoCC.mkDerivation {
          pname = "nix-source-escrow";
          version = "0.1.0";
          src = builtins.path {
            path = ./.;
            name = "nix-source-escrow-src";
            filter =
              path: _type:
              let
                rel = builtins.baseNameOf path;
              in
              !(builtins.elem rel [ "escrow" "result" ".direnv" ".git" ]);
          };

          nativeBuildInputs = [ pkgs.makeWrapper ];

          runtimeDeps = [
            pkgs.jq
            pkgs.coreutils
            pkgs.gnused
            pkgs.gnugrep
            pkgs.gawk
            pkgs.curl
            pkgs.iproute2
            pkgs.util-linux # unshare
            # No git: the package carries its revision in
            # share/nix-source-escrow/build-info.json, stamped in at build
            # time. The runtime git query is only the dev-checkout fallback,
            # and a checkout has git by definition (and in the devShell).
          ];

          # The package has no .git (the src filter drops it) and an immutable
          # /nix/store tree has no "working tree" to be dirty. So the revision
          # is stamped in at build time from the flake itself, and the runtime
          # git query is only ever a fallback for a dev checkout.
          buildInfo = builtins.toJSON {
            toolRevision = self.rev or self.dirtyRev or "unknown";
            workingTreeDirty =
              if self ? rev then false else if self ? dirtyRev then true else null;
            revisionSource = "flake";
          };
          passAsFile = [ "buildInfo" ];

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/lib" "$out/share/nix-source-escrow"
            cp "$buildInfoPath" "$out/share/nix-source-escrow/build-info.json"
            cp -r lib/*.sh "$out/lib/"
            cp bin/nix-source-escrow "$out/bin/.nix-source-escrow-wrapped"
            makeWrapper "$out/bin/.nix-source-escrow-wrapped" "$out/bin/nix-source-escrow" \
              --prefix PATH : "${pkgs.lib.makeBinPath [
                pkgs.jq pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.gawk
                pkgs.curl pkgs.iproute2 pkgs.util-linux
              ]}"
            # The policy-governed line's tooling. A SECOND executable, not a
            # subcommand: the closed line's tool is an instrument this
            # experiment reuses, not this experiment's judge, and merging them
            # would make a frozen tool's behaviour a function of new code.
            cp bin/nse-pg "$out/bin/.nse-pg-wrapped"
            makeWrapper "$out/bin/.nse-pg-wrapped" "$out/bin/nse-pg" \
              --prefix PATH : "${pkgs.lib.makeBinPath [
                pkgs.jq pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.gawk
                pkgs.curl pkgs.iproute2 pkgs.util-linux
              ]}"
            runHook postInstall
          '';

          meta = {
            description = "Source escrow for Nix dependency graphs with an origin-independence gate";
            mainProgram = "nix-source-escrow";
            platforms = pkgs.lib.platforms.linux;
          };
        };
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            jq
            curl
            iproute2
            util-linux
            shellcheck
            git
            python3 # tests only: a throwaway HTTP binary cache for t16
          ];
          shellHook = ''
            export PATH="$PWD/bin:$PATH"
            echo "nix-source-escrow dev shell. Try: nix-source-escrow escrow 'path:$PWD/fixture#default'"
          '';
        };
      });

      checks = forAll (pkgs: {
        shellcheck = pkgs.runCommand "nix-source-escrow-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${self}
          shellcheck -x -e SC1091 --shell=bash bin/nix-source-escrow bin/nse-pg lib/*.sh tests/*.sh
          touch $out
        '';
      });
    };
}
