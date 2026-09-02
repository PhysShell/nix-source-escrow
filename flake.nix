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
          ];

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin" "$out/lib"
            cp -r lib/*.sh "$out/lib/"
            cp bin/nix-source-escrow "$out/bin/.nix-source-escrow-wrapped"
            makeWrapper "$out/bin/.nix-source-escrow-wrapped" "$out/bin/nix-source-escrow" \
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
          shellcheck -x -e SC1091 --shell=bash bin/nix-source-escrow lib/*.sh tests/*.sh
          touch $out
        '';
      });
    };
}
