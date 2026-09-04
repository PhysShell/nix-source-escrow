# shellcheck shell=bash
# VERIFY: does the escrow actually hold what the manifest claims, and is what
# it holds bit-for-bit the thing the derivations demand?
#
# Everything here goes through the escrow's *URL*, never through a directory
# path, so a file:// cache, an S3 bucket and an Attic server are verified by
# the same code.

nse_verify() {
  local manifest=$NSE_DIR/manifest.json
  local closure=$NSE_DIR/closure.json
  local work=$NSE_DIR/work
  [ -f "$manifest" ] || nse_die "no manifest.json; run 'nix-source-escrow preserve' first"
  [ -f "$closure" ]  || nse_die "no closure.json; run 'nix-source-escrow preserve' first"
  mkdir -p "$work" "$NSE_DIR/evidence"

  nse_step "VERIFY $NSE_SUBSTITUTER_URL"

  # ---- 1. presence ---------------------------------------------------------
  # Two sets, two stores. Under ESCROW_REPLAY the replica set is empty and this
  # collapses to the v0.1 behaviour.
  # `// .paths` keeps an escrow written by an older version readable.
  jq -r '(.escrowPaths // .paths)[]' "$closure" | LC_ALL=C sort -u > "$work/verify-escrow-set.txt"
  jq -r '(.replicaPaths // [])[]' "$closure"    | LC_ALL=C sort -u > "$work/verify-replica-set.txt"

  local n_escrow n_replica total
  n_escrow=$(wc -l < "$work/verify-escrow-set.txt")
  n_replica=$(wc -l < "$work/verify-replica-set.txt")
  total=$((n_escrow + n_replica))

  nse_store_present "$NSE_SUBSTITUTER_URL" < "$work/verify-escrow-set.txt" \
    | LC_ALL=C sort -u > "$work/verify-escrow-present.txt"
  LC_ALL=C comm -23 "$work/verify-escrow-set.txt" "$work/verify-escrow-present.txt" \
    > "$work/verify-missing.txt"

  : > "$work/verify-replica-present.txt"
  if [ -s "$work/verify-replica-set.txt" ]; then
    nse_store_present "$NSE_REPLICA_URL" < "$work/verify-replica-set.txt" \
      | LC_ALL=C sort -u > "$work/verify-replica-present.txt"
    LC_ALL=C comm -23 "$work/verify-replica-set.txt" "$work/verify-replica-present.txt" \
      >> "$work/verify-missing.txt"
  fi

  local missing_escrow missing_replica missing
  missing_escrow=$((n_escrow - $(wc -l < "$work/verify-escrow-present.txt")))
  missing_replica=$((n_replica - $(wc -l < "$work/verify-replica-present.txt")))
  missing=$((missing_escrow + missing_replica))
  nse_log "presence: $((total - missing))/$total preserved paths found (escrow $((n_escrow - missing_escrow))/$n_escrow, replica $((n_replica - missing_replica))/$n_replica)"

  # ---- 2. content identity: the escrow's CA == the hash the derivation wants -
  # This is the check that matters for a *source* escrow. A binary cache can
  # hand you any bytes; a fixed-output store path is only the right object if
  # its content address equals the derivation's outputHash.
  #
  # One jq pass pairs each source with the escrow's own metadata, so this loop
  # spawns no process per source. Every field jq emits is guaranteed non-empty
  # -- __ABSENT__ and __NO_CA__ are explicit sentinels -- because `read` with a
  # tab IFS collapses adjacent separators and would silently shift the columns.
  # That exact mistake cost the trust probe three tests; it does not get a
  # second outing here.
  nse_store_meta "$NSE_SUBSTITUTER_URL" < "$work/verify-escrow-present.txt" \
    > "$work/verify-meta.jsonl"
  jq -s '.' "$work/verify-meta.jsonl" > "$work/verify-meta.json"

  local id_ok=0 id_bad=0 id_skip=0 sp expected ca got_sri exp_sri
  : > "$work/verify-hash-mismatch.txt"
  while IFS=$'\t' read -r sp ca expected; do
    [ -n "$sp" ] || continue
    case $ca in
      __ABSENT__) id_skip=$((id_skip + 1)); continue ;;
      __NO_CA__)
        id_bad=$((id_bad + 1))
        printf '%s\tno-CA-field\t%s\n' "$sp" "$expected" >> "$work/verify-hash-mismatch.txt"
        continue ;;
    esac
    # `nix hash convert` runs only for a hash that is not already SRI, so on a
    # current Nix this loop spawns nothing at all.
    got_sri=$(nse_to_sri "$ca") || nse_die "cannot normalise CA hash '$ca' of $sp"
    exp_sri=$(nse_to_sri "$expected") || nse_die "cannot normalise expected hash '$expected' of $sp"
    if [ "$got_sri" = "$exp_sri" ]; then
      id_ok=$((id_ok + 1))
    else
      id_bad=$((id_bad + 1))
      printf '%s\t%s\t%s\n' "$sp" "$got_sri" "$exp_sri" >> "$work/verify-hash-mismatch.txt"
    fi
  done < <(jq -r --slurpfile meta "$work/verify-meta.json" '
             ($meta[0] | map({key: .path, value: .}) | from_entries) as $m
             | .sources[]
             | select(.escrow.present and .storePath != null and .expectedHash != null)
             | .storePath as $p
             | .expectedHash as $exp
             | ($m[$p] // null) as $rec
             | [ $p,
                 (if   $rec == null          then "__ABSENT__"
                  elif ($rec.ca // "") == "" then "__NO_CA__"
                  else $rec.ca end),
                 $exp ]
             | @tsv' "$manifest")
  nse_log "content identity: ok=$id_ok mismatched=$id_bad not-in-escrow=$id_skip"

  # ---- 3. NAR integrity ----------------------------------------------------
  # nix store verify recomputes the NAR hash of every object it is given.
  # Exit codes: 1 corrupted, 2 untrusted, 4 other. We pass --no-trust because
  # trust is measured separately in step 4.
  #
  # Scope is the WHOLE preserved set by default. Checking only the source
  # objects and then reporting the closure size as "verified" would overstate
  # the result: presence of a narinfo is not integrity of a NAR.
  local integrity_rc=0 integrity_status=EMPTY integrity_scope integrity_checked=0
  if [ "${NSE_VERIFY_SOURCES_ONLY:-0}" = 1 ]; then
    integrity_scope="sources+flake-inputs"
    {
      jq -r ".sources[] | select(.escrow.present and .storePath != null) | .storePath" "$manifest"
      jq -r ".flakeInputs[] | select(.escrow.present) | .storePath" "$manifest"
    } | LC_ALL=C sort -u > "$work/verify-integrity-escrow.txt"
    : > "$work/verify-integrity-replica.txt"
  else
    integrity_scope="full-closure"
    cp "$work/verify-escrow-set.txt"  "$work/verify-integrity-escrow.txt"
    cp "$work/verify-replica-set.txt" "$work/verify-integrity-replica.txt"
  fi

  local pair
  for pair in "escrow:$NSE_SUBSTITUTER_URL" "replica:$NSE_REPLICA_URL"; do
    local label=${pair%%:*} url=${pair#*:}
    local set_file=$work/verify-integrity-$label.txt
    [ -s "$set_file" ] || continue
    local n; n=$(wc -l < "$set_file")
    nse_log "NAR integrity ($integrity_scope, $label): recomputing the NAR hash of $n objects"
    if nse_nix store verify --store "$url" --no-trust --stdin \
         < "$set_file" > "$work/verify-integrity-$label.log" 2>&1; then
      [ "$integrity_status" = FAILED ] || integrity_status=OK
    else
      integrity_rc=$?
      integrity_status=FAILED
      nse_warn "nix store verify ($label) exited $integrity_rc; see $work/verify-integrity-$label.log"
    fi
    integrity_checked=$((integrity_checked + n))
  done
  nse_log "NAR integrity: $integrity_status ($integrity_checked of $total preserved paths checked)"

  # ---- 4. trust composition (observed, not assumed) ------------------------
  # Same metadata, through the SHARED classifier, so VERIFY and TRUST cannot
  # disagree about what "signed" means. They did: this counter printed the
  # correct 53 and 1 while the trust probe, reading the same file with a
  # different parser, found neither.
  local n_ca=0 n_sig=0 n_neither=0
  read -r n_ca n_sig n_neither < <(
    jq -s -r "$NSE_JQ_CLASSIFY"'
      [.[] | nse_class] as $c
      | [ ([$c[] | select(. == "ca-fixed" or . == "ca-text")] | length),
          ([$c[] | select(. == "signed")]   | length),
          ([$c[] | select(. == "unsigned")] | length) ]
      | @tsv' "$work/verify-meta.jsonl" | tr '\t' ' ')
  nse_log "trust composition: content-addressed=$n_ca signature-only=$n_sig neither=$n_neither"

  local status=PASS
  [ "$missing" -eq 0 ] || status=FAIL
  [ "$id_bad" -eq 0 ] || status=FAIL
  [ "$integrity_status" != FAILED ] || status=FAIL

  jq -n \
    --arg status "$status" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg substituter "$NSE_SUBSTITUTER_URL" \
    --arg replica "$([ -s "$work/verify-replica-set.txt" ] && printf '%s' "$NSE_REPLICA_URL")" \
    --argjson total "$total" --argjson missing "$missing" \
    --argjson escrowPaths "$n_escrow" --argjson escrowMissing "$missing_escrow" \
    --argjson replicaPaths "$n_replica" --argjson replicaMissing "$missing_replica" \
    --argjson idOk "$id_ok" --argjson idBad "$id_bad" --argjson idSkip "$id_skip" \
    --arg integrity "$integrity_status" --argjson integrityRc "$integrity_rc" \
    --arg integrityScope "$integrity_scope" --argjson integrityChecked "$integrity_checked" \
    --argjson ca "$n_ca" --argjson sig "$n_sig" --argjson neither "$n_neither" \
    --argjson provenance "$(nse_provenance)" \
    '{schemaVersion:3, kind:"verify", timestamp:$ts, status:$status, provenance:$provenance,
      substituterUrl:$substituter,
      binaryReplicaUrl:(if $replica=="" then null else $replica end),
      presence:{closurePaths:$total, missing:$missing,
                escrowPaths:$escrowPaths, escrowMissing:$escrowMissing,
                replicaPaths:$replicaPaths, replicaMissing:$replicaMissing},
      contentIdentity:{verified:$idOk, mismatched:$idBad, notInEscrow:$idSkip},
      narIntegrity:{status:$integrity, exitCode:$integrityRc,
                    scope:$integrityScope, pathsChecked:$integrityChecked},
      trustComposition:{contentAddressed:$ca, signatureOnly:$sig, unsignedInputAddressed:$neither}}' \
    | nse_json_canonical | nse_write_file "$NSE_DIR/evidence/verify.json"

  printf 'ESCROW_VERIFY=%s\n' "$status"
  printf 'ESCROW_OBJECTS_PRESENT=%d/%d\n' "$((total - missing))" "$total"
  printf 'ESCROW_CONTENT_IDENTITY_VERIFIED=%d\n' "$id_ok"
  printf 'ESCROW_CONTENT_IDENTITY_MISMATCH=%d\n' "$id_bad"
  printf "ESCROW_NAR_INTEGRITY=%s\n" "$integrity_status"
  printf "ESCROW_NAR_VERIFIED=%d/%d (scope: %s)\n" "$integrity_checked" "$total" "$integrity_scope"
  [ "$status" = PASS ] || return 1
}
