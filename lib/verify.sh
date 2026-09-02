# shellcheck shell=bash
# VERIFY: does the escrow actually hold what the manifest claims, and is what
# it holds bit-for-bit the thing the derivations demand?

nse_verify() {
  local manifest=$NSE_DIR/manifest.json
  local closure=$NSE_DIR/closure.json
  local work=$NSE_DIR/work
  [ -f "$manifest" ] || nse_die "no manifest.json; run 'nix-source-escrow preserve' first"
  [ -f "$closure" ]  || nse_die "no closure.json; run 'nix-source-escrow preserve' first"
  mkdir -p "$work" "$NSE_DIR/evidence"

  nse_step "VERIFY $NSE_CACHE"

  # ---- 1. presence ---------------------------------------------------------
  local missing=0 total=0 p hp
  : > "$work/verify-missing.txt"
  while IFS= read -r p; do
    total=$((total + 1))
    hp=${p##*/}; hp=${hp%%-*}
    if [ ! -f "$NSE_CACHE/$hp.narinfo" ]; then
      missing=$((missing + 1)); printf '%s\n' "$p" >> "$work/verify-missing.txt"
    fi
  done < <(jq -r '.paths[]' "$closure")
  nse_log "presence: $((total - missing))/$total closure paths have a narinfo in the escrow"

  # ---- 2. content identity: narinfo CA == the hash the derivation demands ---
  # This is the check that matters for a *source* escrow. A binary cache can
  # hand you any bytes; a fixed-output store path is only the right object if
  # its content address equals the derivation's outputHash.
  local id_ok=0 id_bad=0 id_skip=0 sp expected ni ca got_sri exp_sri
  : > "$work/verify-hash-mismatch.txt"
  while IFS=$'\t' read -r sp expected; do
    [ -n "$sp" ] || continue
    hp=${sp##*/}; hp=${hp%%-*}
    ni=$NSE_CACHE/$hp.narinfo
    if [ ! -f "$ni" ]; then id_skip=$((id_skip + 1)); continue; fi
    ca=$(sed -n 's/^CA: //p' "$ni")
    if [ -z "$ca" ]; then
      id_bad=$((id_bad + 1))
      printf '%s\tno-CA-field\t%s\n' "$sp" "$expected" >> "$work/verify-hash-mismatch.txt"
      continue
    fi
    got_sri=$(nse_to_sri "$ca") || nse_die "cannot normalise CA hash '$ca' of $sp"
    exp_sri=$(nse_to_sri "$expected") || nse_die "cannot normalise expected hash '$expected' of $sp"
    if [ "$got_sri" = "$exp_sri" ]; then
      id_ok=$((id_ok + 1))
    else
      id_bad=$((id_bad + 1))
      printf '%s\t%s\t%s\n' "$sp" "$got_sri" "$exp_sri" >> "$work/verify-hash-mismatch.txt"
    fi
  done < <(jq -r '.sources[] | select(.escrow.present and .storePath != null and .expectedHash != null)
                 | [.storePath, .expectedHash] | @tsv' "$manifest")
  nse_log "content identity: ok=$id_ok mismatched=$id_bad not-in-escrow=$id_skip"

  # ---- 3. NAR integrity ----------------------------------------------------
  # nix store verify recomputes the NAR hash of every object it is given.
  # Exit codes: 1 corrupted, 2 untrusted, 4 other. We pass --no-trust because
  # trust is measured separately in step 4.
  #
  # Scope is the WHOLE preserved closure by default. Checking only the source
  # objects and then reporting the closure size as "verified" would overstate
  # the result: presence of a narinfo is not integrity of a NAR.
  local integrity_rc=0 integrity_status integrity_scope integrity_checked=0
  if [ "${NSE_VERIFY_SOURCES_ONLY:-0}" = 1 ]; then
    integrity_scope="sources+flake-inputs"
    {
      jq -r ".sources[] | select(.escrow.present and .storePath != null) | .storePath" "$manifest"
      jq -r ".flakeInputs[] | select(.escrow.present) | .storePath" "$manifest"
    } | LC_ALL=C sort -u > "$work/verify-integrity-set.txt"
  else
    integrity_scope="full-closure"
    jq -r ".paths[]" "$closure" | LC_ALL=C sort -u > "$work/verify-integrity-set.txt"
  fi

  if [ -s "$work/verify-integrity-set.txt" ]; then
    integrity_checked=$(wc -l < "$work/verify-integrity-set.txt")
    nse_log "NAR integrity ($integrity_scope): recomputing the NAR hash of $integrity_checked escrowed objects"
    if nse_nix store verify --store "$(nse_cache_url_plain)" --no-trust --stdin \
         < "$work/verify-integrity-set.txt" > "$work/verify-integrity.log" 2>&1; then
      integrity_status=OK
    else
      integrity_rc=$?
      integrity_status=FAILED
      nse_warn "nix store verify exited $integrity_rc; see $work/verify-integrity.log"
    fi
  else
    integrity_status=EMPTY
  fi
  nse_log "NAR integrity: $integrity_status ($integrity_checked of $total closure paths checked)"

  # ---- 4. trust composition (observed, not assumed) ------------------------
  local n_ca=0 n_sig=0 n_neither=0 f
  for f in "$NSE_CACHE"/*.narinfo; do
    [ -e "$f" ] || break
    if grep -q '^CA: ' "$f"; then n_ca=$((n_ca + 1))
    elif grep -q '^Sig: ' "$f"; then n_sig=$((n_sig + 1))
    else n_neither=$((n_neither + 1)); fi
  done
  nse_log "trust composition: content-addressed=$n_ca signature-only=$n_sig neither=$n_neither"

  local status=PASS
  [ "$missing" -eq 0 ] || status=FAIL
  [ "$id_bad" -eq 0 ] || status=FAIL
  [ "$integrity_status" != FAILED ] || status=FAIL

  jq -n \
    --arg status "$status" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson total "$total" --argjson missing "$missing" \
    --argjson idOk "$id_ok" --argjson idBad "$id_bad" --argjson idSkip "$id_skip" \
    --arg integrity "$integrity_status" --argjson integrityRc "$integrity_rc" \
    --arg integrityScope "$integrity_scope" --argjson integrityChecked "$integrity_checked" \
    --argjson ca "$n_ca" --argjson sig "$n_sig" --argjson neither "$n_neither" \
    '{schemaVersion:1, kind:"verify", timestamp:$ts, status:$status,
      presence:{closurePaths:$total, missing:$missing},
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
