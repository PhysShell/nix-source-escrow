{
  description = "nix-source-escrow test fixture: a small, fully pinned dependency graph";

  inputs = {
    # Flake input #1: a real flake, fetched from a real origin host (github.com).
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Flake input #2: a non-flake input from github.com. Deliberately tiny; it
    # exercises `flake = false` input material, which `nix flake archive` must
    # also preserve.
    gitignore-src = {
      url = "github:github/gitignore";
      flake = false;
    };

    # Flake inputs #3..#5 exist to break naive discovery, not to be used.
    # Between them they cover the three ways an input tree stops being flat:
    #
    #   * `flake-utils` has an input of its own, so the tree is NESTED and a
    #     walker that only reads root inputs misses `systems_2`;
    #   * that nested input gets a RENAMED lock node (`systems_2`), so any code
    #     assuming alias == lock node id resolves the wrong node;
    #   * `flake-utils-follows` is the same flake wired with `follows`, so the
    #     lock edge is an array path rather than a node id, and two distinct
    #     lock nodes share one store path (a dedup case).
    systems.url = "github:nix-systems/default";
    flake-utils.url = "github:numtide/flake-utils";
    flake-utils-follows = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
  };

  outputs =
    { self, nixpkgs, gitignore-src, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      helloUrl = "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz";

      # ---------------------------------------------------------------------
      # Source #1: fetchFromGitHub -> fetchzip -> fetchurl
      #   outputHashMode = "recursive" (NAR), and the hash covers the tree
      #   AFTER unpack + stripRoot + postFetch. This is the `postFetch` mine:
      #   upstream tarball bytes != FOD output. See DESIGN.md.
      # ---------------------------------------------------------------------
      srcGitHub = pkgs.fetchFromGitHub {
        owner = "NixOS";
        repo = "nix-pills";
        rev = "4df971884fa974c49b944ba648f2e48a82404c84";
        hash = "sha256-MIMqNvR3oazdybbVbQv/gF3oY7Tzma6NgRYedJGdqz0=";
      };

      # ---------------------------------------------------------------------
      # Sources #2..#4 all download THE SAME BYTES FROM THE SAME URL and end up
      # as three different Nix objects. That is the whole postFetch argument,
      # made without any other variable moving:
      #
      #   #2 fetchurl            flat hash over the tarball bytes
      #   #3 fetchzip stripRoot=false   NAR hash of the unpacked tree
      #   #4 fetchzip stripRoot=true    NAR hash of the same tree, root stripped
      #
      # #3 vs #4 differ in exactly one attribute, so they isolate the effect of
      # stripRoot alone.
      # ---------------------------------------------------------------------
      srcTarball = pkgs.fetchurl {
        url = helloUrl;
        hash = "sha256-jZkUKv2SV28wsM18tCqNxoCZmLxdYH2Idh9RLibH2yA=";
      };

      srcZipUnstripped = pkgs.fetchzip {
        url = helloUrl;
        stripRoot = false;
        hash = "sha256-uF+m0+CSORgGv0cmuIt9aVpY1V88Oq7wypYK8qDIwa8=";
      };

      srcZipStripped = pkgs.fetchzip {
        url = helloUrl;
        stripRoot = true;
        hash = "sha256-1kJjhtlsAkpNB7f6tZEs+dbKd8z7KoNHyDHEJ0tmhnc=";
      };

      # ---------------------------------------------------------------------
      # Source #5: the SAME kind of fetch, with a DIFFERENT HASH ALGORITHM.
      #
      # Every other source here is sha256, so a compatibility test across two
      # Nix versions was only ever exercising the subset of the derivation
      # format where the two happen to agree. `nse_to_sri` defaulted a bare
      # digest to sha256, and nothing in this fixture could have noticed.
      #
      # A different URL on purpose: sources #2-#4 make the postFetch argument
      # by sharing one URL and differing in one attribute each, and this must
      # not become a fourth member of that set. Small and permanent -- the
      # detached signature that sits beside the tarball forever.
      # ---------------------------------------------------------------------
      srcSha512 = pkgs.fetchurl {
        url = "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz.sig";
        hash = "sha512-7+A+OIwdDIssDp5FKmPXXAg7O4HlhZRI4RbaSuWIg65MawoueO3pD+no+oTE7uFFfkpj7hrFRMfPPLdBGKTdNQ==";
      };
    in
    {
      packages.${system} = {
        # The acceptance target. stdenvNoCC keeps the *toolchain* closure small
        # so the escrow stays a test fixture and not a distro mirror.
        default = pkgs.runCommand "escrow-fixture-0.1" { } ''
          mkdir -p "$out"
          # Consume every escrowed source so none can be dropped silently.
          cp ${srcGitHub}/README.md                     "$out/from-fetchFromGitHub.txt"
          cp ${srcTarball}                              "$out/from-fetchurl.tar.gz"
          cp ${srcZipUnstripped}/hello-2.12.1/README    "$out/from-fetchzip-unstripped.txt"
          cp ${srcZipStripped}/README                   "$out/from-fetchzip-stripped.txt"
          cp ${gitignore-src}/Nix.gitignore             "$out/from-flake-input.txt"
          cp ${srcSha512}                               "$out/from-sha512-fetchurl.sig"
          echo "escrow-fixture ok" > "$out/marker"
        '';

        # Individually addressable, for tests that need one source at a time.
        src-github = srcGitHub;
        src-tarball = srcTarball;
        src-zip-unstripped = srcZipUnstripped;
        src-zip-stripped = srcZipStripped;
        src-sha512 = srcSha512;
      };
    };
}
