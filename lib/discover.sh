# shellcheck shell=bash
# DISCOVER: enumerate what this build depends on, and be explicit about the
# limits of the enumeration. See DESIGN.md, "Discovery: exact scope of validity".

# Produce discovery.json for $NSE_INSTALLABLE.
nse_discover() {
  local out_json=$NSE_DIR/discovery.json
  local work=$NSE_DIR/work
  mkdir -p "$work"

  local flakeref; flakeref=$(nse_flakeref_of "$NSE_INSTALLABLE")
  local storedir; storedir=$(nse_store_dir)

  nse_step "DISCOVER $NSE_INSTALLABLE"

  # ---- 1. flake inputs -----------------------------------------------------
  # `nix flake archive --dry-run --json` gives the *whole* input tree, nested,
  # without copying anything. The lock file gives identity (type/rev/narHash).
  # Both are walked together: see the resolveEdge/walkInputs pair below for why
  # neither "read the root inputs" nor "alias == lock node id" is good enough.
  nse_log "enumerating flake inputs (nix flake archive --dry-run, full tree)"
  nse_nix flake archive --json --dry-run "$flakeref" > "$work/flake-archive.json" \
    || nse_die "nix flake archive --dry-run failed for '$flakeref'"

  nse_nix flake metadata --json "$flakeref" > "$work/flake-metadata.json" \
    || nse_die "nix flake metadata failed for '$flakeref'"

  # ---- 2. derivation graph -------------------------------------------------
  nse_log "instantiating derivation graph (nix derivation show -r)"
  nse_nix derivation show -r "$NSE_INSTALLABLE" > "$work/drvs.json" \
    || nse_die "nix derivation show -r failed for '$NSE_INSTALLABLE'"

  local top_drv
  top_drv=$(nse_nix path-info --derivation "$NSE_INSTALLABLE") \
    || nse_die "cannot resolve derivation for '$NSE_INSTALLABLE'"

  # ---- 3. IFD probe --------------------------------------------------------
  # Import-from-derivation happens at *evaluation* time and is invisible in the
  # derivation graph. If evaluation still succeeds with IFD disabled there is
  # none on this code path; otherwise we have to say so out loud.
  nse_log "probing for import-from-derivation"
  local ifd_status ifd_detail
  if NIX_CONFIG="experimental-features = nix-command flakes
allow-import-from-derivation = false" \
     nix path-info --derivation "$NSE_INSTALLABLE" >/dev/null 2>"$work/ifd-probe.log"; then
    ifd_status=absent; ifd_detail="evaluation succeeds with allow-import-from-derivation = false"
  else
    ifd_status=present
    ifd_detail=$(head -c 400 "$work/ifd-probe.log" | tr '\n' ' ')
  fi

  # ---- 4. build the JSON ---------------------------------------------------
  local origin_hosts_json
  origin_hosts_json=$(printf '%s' "$NSE_ORIGIN_HOSTS_DEFAULT" | tr ' ' '\n' \
                      | jq -R . | jq -s 'map(select(length>0))')

  jq -n \
    --arg installable "$NSE_INSTALLABLE" \
    --arg flakeref "$flakeref" \
    --arg storedir "$storedir" \
    --arg topdrv "$top_drv" \
    --arg ifd_status "$ifd_status" \
    --arg ifd_detail "$ifd_detail" \
    --argjson originHosts "$origin_hosts_json" \
    --slurpfile archive "$work/flake-archive.json" \
    --slurpfile meta "$work/flake-metadata.json" \
    --slurpfile drvs "$work/drvs.json" \
    '
    def host($u):
      if ($u|type) != "string" then null
      elif ($u | test("^[a-zA-Z][a-zA-Z0-9+.-]*://")) then
        ($u | sub("^[^:]+://";"") | sub("/.*$";"") | sub("^[^@]*@";"") | sub(":[0-9]+$";""))
      else null end;

    # --- lock graph ---------------------------------------------------------
    # An input edge in flake.lock is either a node id (a string) or a `follows`
    # path (an array of aliases resolved from the root node). Node ids are NOT
    # the alias: two different inputs both called "systems" become "systems"
    # and "systems_2", and which is which depends on the graph, not the name.
    def resolveEdge($nodes; $root; $from; $alias):
      if $from == null then null
      else
        ((($nodes[$from] // {}).inputs // {})[$alias]) as $e
        | if   ($e|type) == "string" then $e
          elif ($e|type) == "array"  then
            reduce $e[] as $a ($root;
              if . == null then null else resolveEdge($nodes; $root; .; $a) end)
          else null end
      end;

    # Walk the archive tree and the lock graph in lockstep. Emits one entry per
    # edge, including transitive ones; duplicates are merged afterwards.
    def walkInputs($nodes; $root; $arch; $nodeId; $aliasPath):
      ( ($arch.inputs // {}) | to_entries
        | map( .key as $a
             | .value as $child
             | (resolveEdge($nodes; $root; $nodeId; $a)) as $cid
             | [ { alias: $a,
                   aliasPath: ($aliasPath + [$a] | join("/")),
                   nodeId: $cid,
                   storePath: $child.path } ]
               + walkInputs($nodes; $root; $child; $cid; $aliasPath + [$a]) )
        | add // [] );

    def attr($d; $k):
      (($d.structuredAttrs // {}) as $s | ($d.env // {}) as $e
       | if ($s|has($k)) then $s[$k]
         elif ($e|has($k)) then $e[$k]
         else null end);

    def urlsOf($d):
      ( attr($d;"urls") ) as $u
      | if ($u|type)=="array" then $u
        elif ($u|type)=="string" and ($u|length)>0 then ($u|split(" ")|map(select(length>0)))
        else ( attr($d;"url") ) as $s
             | if ($s|type)=="string" and ($s|length)>0 then [$s] else [] end
        end;

    ($meta[0].locks.nodes // {})   as $nodes |
    ($meta[0].locks.root // "root") as $lockRoot |

    # ---------------- flake inputs ----------------
    ( walkInputs($nodes; $lockRoot; $archive[0]; $lockRoot; []) ) as $inputEdges |
    ( $inputEdges
      | group_by(.storePath)
      | map(
          ( . | sort_by(.aliasPath | length) | .[0] ) as $primary
          | ($primary.nodeId) as $nid
          | (if $nid == null then {} else ($nodes[$nid].locked // {}) end) as $lk
          | {
              name: $primary.aliasPath,
              aliasPaths: (map(.aliasPath) | unique),
              lockNodeId: $nid,
              storePath: $primary.storePath,
              transitive: (($primary.aliasPath | contains("/"))),
              locked: $lk,
              type:    (if ($lk|has("type"))    then $lk.type    else "unknown" end),
              rev:     (if ($lk|has("rev"))     then $lk.rev     else null end),
              narHash: (if ($lk|has("narHash")) then $lk.narHash else null end),
              origin: (
                if   ($lk.type // "") == "github" then "github.com/\($lk.owner)/\($lk.repo)"
                elif ($lk.type // "") == "gitlab" then "gitlab.com/\($lk.owner)/\($lk.repo)"
                elif ($lk|has("url"))  then $lk.url
                elif ($lk|has("path")) then $lk.path
                else null end),
              originHost: (
                if   ($lk.type // "") == "github" then "github.com"
                elif ($lk.type // "") == "gitlab" then "gitlab.com"
                else host($lk.url // "") end),
              discovery: {
                method: "nix flake archive --dry-run (full tree) joined with flake.lock via lockstep walk",
                status: (if $nid == null then "UNKNOWN"
                         elif ($lk|has("narHash")) then "COVERED"
                         else "UNKNOWN" end)
              }
            })
      | sort_by(.name) ) as $inputs |

    # ---------------- fixed-output / source derivations ----------------
    ( [ $drvs[0].derivations // {} | to_entries[]
        | ("\($storedir)/" + .key) as $drvPath
        | .value as $d
        | ($d.outputs // {}) | to_entries[]
        | select(.value.hash != null)               # <- the fixed-output test
        | { drvPath: $drvPath, outputName: .key, o: .value, d: $d } ]
      | map(
          .d as $d | .o as $o |
          ( urlsOf($d) ) as $urls |
          ( attr($d;"postFetch") ) as $pf |
          ( (($d.env // {})[.outputName]) ) as $outPath |
          {
            kind: (
              if ($d.builder // "") == "builtin:fetchurl" then "builtin:fetchurl"
              elif ($urls|length) > 0 and (($pf|type)=="string" and ($pf|length)>0) then "fetchzip-like"
              elif ($urls|length) > 0 then "fetchurl"
              else "no-fetcher" end),
            name: (if ($d|has("name")) then $d.name else null end),
            drvPath: .drvPath,
            outputName: .outputName,
            storePath: $outPath,
            expectedHash: $o.hash,
            hashMode: (if ($o|has("method")) then $o.method else null end),
            origin: {
              urls: $urls,
              hosts: ([ $urls[] | host(.) ] | map(select(. != null)) | unique),
              knownForge: ([ $urls[] | host(.) ] | map(select(. != null))
                           | any(. as $h | $originHosts | index($h) != null))
            },
            transform: {
              postFetch: (($pf|type)=="string" and ($pf|length)>0),
              stripRoot:      attr($d;"stripRoot"),
              downloadToTemp: attr($d;"downloadToTemp"),
              recursiveHash:  attr($d;"recursiveHash")
            },
            discovery: {
              method: "nix derivation show -r; outputs[*].hash != null",
              status: (
                if $outPath == null then "UNSUPPORTED"
                elif ($urls|length) > 0 then "COVERED"
                elif ($d.builder // "") == "builtin:fetchurl" then "COVERED"
                # A fixed-output derivation with no URL has no origin to lose.
                # It cannot be re-fetched upstream; it comes from a cache/escrow
                # or from a documented manual reconstruction. The nixpkgs
                # minimal-bootstrap sources are the canonical example.
                else "EXTERNAL_RECOVERY" end)
            }
          })
      | sort_by(.storePath // .drvPath) ) as $sources |

    {
      schemaVersion: 2,
      installable: $installable,
      flakeRef: $flakeref,
      storeDir: $storedir,
      topLevelDerivation: $topdrv,
      flakeSourcePath: $archive[0].path,
      lockRoot: $lockRoot,
      originHostsClassified: $originHosts,
      flakeInputs: $inputs,
      sources: $sources,
      evalTimeFetches: {
        ifd: { status: $ifd_status, detail: $ifd_detail },
        staticEnumeration: "impossible",
        note: ("builtins.fetchTarball / fetchGit / fetchurl with a pinned hash are "
             + "invisible in the derivation graph and CANNOT be enumerated here. "
             + "They are covered only by the offline evaluation probe inside the "
             + "origin-independence test; until that probe has run, discovery "
             + "completeness is UNVERIFIED, never PASS. See DESIGN.md.")
      },
      counts: {
        flakeInputs: ($inputs|length),
        flakeInputEdgesWalked: ($inputEdges|length),
        flakeInputsTransitive: ([$inputs[]|select(.transitive)]|length),
        flakeInputsUnknown:    ([$inputs[]|select(.discovery.status=="UNKNOWN")]|length),
        sources: ($sources|length),
        sourcesCovered:          ([$sources[]|select(.discovery.status=="COVERED")]|length),
        sourcesExternalRecovery: ([$sources[]|select(.discovery.status=="EXTERNAL_RECOVERY")]|length),
        sourcesUnknown:          ([$sources[]|select(.discovery.status=="UNKNOWN")]|length),
        sourcesUnsupported:      ([$sources[]|select(.discovery.status=="UNSUPPORTED")]|length),
        sourcesQuarantined: 0,
        sourcesWithPostFetch: ([$sources[]|select(.transform.postFetch)]|length),
        sourcesFlatHash:      ([$sources[]|select(.hashMode=="flat")]|length),
        sourcesNarHash:       ([$sources[]|select(.hashMode=="nar")]|length),
        sourcesOnKnownForge:  ([$sources[]|select(.origin.knownForge)]|length)
      }
    }' | nse_json_canonical | nse_write_file "$out_json"

  nse_discovery_summary "$out_json"
}

nse_discovery_summary() {
  local f=$1
  jq -r '
    "FLAKE_INPUTS=\(.counts.flakeInputs) (from \(.counts.flakeInputEdgesWalked) input-tree edges, unknown=\(.counts.flakeInputsUnknown))",
    "FOD_SOURCES=\(.counts.sources)",
    "  covered=\(.counts.sourcesCovered) external-recovery=\(.counts.sourcesExternalRecovery) unknown=\(.counts.sourcesUnknown) unsupported=\(.counts.sourcesUnsupported)",
    "  flat=\(.counts.sourcesFlatHash) nar=\(.counts.sourcesNarHash) with-postFetch=\(.counts.sourcesWithPostFetch)",
    "  on-known-forge=\(.counts.sourcesOnKnownForge)",
    "IFD=\(.evalTimeFetches.ifd.status)"
  ' "$f" >&2
}
