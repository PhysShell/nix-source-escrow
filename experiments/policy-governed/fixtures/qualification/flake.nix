{
  description = "policy-governed line: qualification fixture (facts + direct-attr probes)";

  # ONE input, pinned to the SAME nixpkgs revision as fixture/flake.lock:
  #
  #     d2f67949798825fe853f7c5d0492b8bf016d3f88
  #
  # PREREG.md §3.2. Compatibility with an older nixpkgs, where fetchFromGitHub
  # was built differently, is a SEPARATE compatibility surface with a separate
  # pin, and is a STOP condition for this line -- not something to absorb here.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d2f67949798825fe853f7c5d0492b8bf016d3f88";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # The same object the closed line's fixture already fetches, on purpose:
      # a probe that needs its own network fetch is a probe that measures the
      # network. This one is a cache hit or it is nothing.
      pillsArgs = {
        owner = "NixOS";
        repo = "nix-pills";
        rev = "4df971884fa974c49b944ba648f2e48a82404c84";
        hash = "sha256-MIMqNvR3oazdybbVbQv/gF3oY7Tzma6NgRYedJGdqz0=";
      };

      plain = pkgs.fetchFromGitHub pillsArgs;

      # ---------------------------------------------------------------------
      # PROBE 1 -- the sentinel, and the reason the DROPPED verdict is
      # reportable at all.
      #
      # PREREG.md §5: a mechanism whose failure mode is indistinguishable from
      # its success mode has not been measured. If `escrow = true` is absent
      # from the derivation document, that is only evidence of DROPPED once the
      # detector has been shown, ON THE SAME RUN AND THE SAME DOCUMENT, capable
      # of finding an attribute that IS there.
      #
      # This is that attribute. It is added the way this line's annotation
      # mechanism adds one, so a sentinel that fails to appear is not a broken
      # sentinel -- it is §3.3 going red, which is exactly the observation that
      # would justify a wrapper.
      # ---------------------------------------------------------------------
      sentinel = plain.overrideAttrs (_: {
        nsePgSentinel = "PRESENT";
      });

      # ---------------------------------------------------------------------
      # PROBE 2 -- bare `escrow = true`, passed straight to the public fetcher.
      #
      # Three outcomes are permitted in advance and each has a distinguishable
      # trace: REJECTED (this attribute set fails to evaluate), DROPPED (it
      # evaluates and the attribute is nowhere in the derivation document),
      # SURVIVED (it evaluates and the attribute is there, at a named key).
      #
      # Nothing here decides which. That is the measurement.
      # ---------------------------------------------------------------------
      directAttr = pkgs.fetchFromGitHub (pillsArgs // { escrow = true; });

      # ---------------------------------------------------------------------
      # PROBE 3 -- the annotation, and a chain long enough to tell the
      # "direct consumer" apart from the "top level".
      #
      # PREREG.md §3.4 registers SIX drv/output observables across THREE
      # derivations. In the closed line's fixture the annotated source's only
      # consumer IS the top-level derivation, so "direct consumer" and
      # "top-level" would be one derivation counted twice -- two of the six
      # observables would be the other two, and the table would look complete
      # while measuring four things.
      #
      #   src  ->  mid  ->  top
      #
      # The plain and marked chains use the SAME derivation names and the SAME
      # builder text. The ONLY difference anywhere in either chain is the
      # annotation attribute on the source. Anything else that moves is a
      # confound, not a result.
      # ---------------------------------------------------------------------
      marked = plain.overrideAttrs (_: {
        nseEscrowCoverage = "required";
      });

      mid =
        src:
        pkgs.runCommand "nse-ann-mid" { } ''
          mkdir -p "$out"
          cp ${src}/README.md "$out/README.md"
        '';

      top =
        m:
        pkgs.runCommand "nse-ann-top" { } ''
          mkdir -p "$out"
          cp ${m}/README.md "$out/README.md"
          echo "nse-ann ok" > "$out/marker"
        '';
    in
    {
      packages.${system} = {
        # Named so the probe can address each one without a lookup table.
        qual-plain = plain;
        qual-sentinel = sentinel;
        qual-direct-attr = directAttr;

        # The two chains. Same names, same builders, one attribute apart.
        ann-plain-src = plain;
        ann-plain-mid = mid plain;
        ann-plain-top = top (mid plain);

        ann-marked-src = marked;
        ann-marked-mid = mid marked;
        ann-marked-top = top (mid marked);

        default = plain;
      };

      # Nix-VALUE level visibility, which is a different surface from
      # derivation-document visibility and is kept separate on purpose
      # (PREREG.md §3.3 vs §4). `nix eval` reads these; the derivation document
      # may or may not carry the same names, and conflating the two answers is
      # how "the nixpkgs source says so" becomes "the tool can see it".
      #
      # Each is wrapped so that an ATTRIBUTE THAT DOES NOT EXIST evaluates to a
      # recorded ABSENT rather than killing the whole eval -- a probe that dies
      # on its first missing attribute measures one attribute.
      pgValueFacts.${system} =
        let
          f =
            drv: name:
            if drv ? ${name} then
              {
                present = true;
                value = builtins.toJSON drv.${name};
              }
            else
              {
                present = false;
                value = null;
              };
          facts =
            drv:
            builtins.listToAttrs (
              map (n: {
                name = n;
                value = f drv n;
              }) [ "owner" "repo" "rev" "tag" "githubBase" "stripRoot" "extension" "meta" "name" ]
            );
        in
        {
          plain = facts plain;
          sentinel = facts sentinel;
          # PREREG.md §3.3. THE table that decides whether a wrapper is
          # justified: if overrideAttrs preserves owner/repo/rev/tag/meta at
          # the Nix-value level, a wrapper is machinery invented for a failure
          # nobody observed.
          marked = facts marked;
        };
    };
}
