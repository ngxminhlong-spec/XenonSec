#!/bin/sh
# Differential test for any Luau runtime (Lune, Lute, ...).
#  - each tests/runtime/p_*.luau runs raw under the runtime, then obfuscated
#    under several option sets; output and exit code must match exactly.
#  - env-logger detection: a logger installed BEFORE the protected code must
#    brick the --antidebug build (logged=0), while the plain build is a control.
#
#   usage: tests/run_runtime.sh <runtime-binary> [lua-interpreter]
#   <runtime-binary> is run as: <runtime> run <file>
#   the Lua interpreter (default: lua) builds xenonsec.lua; the runtime
#   itself can't, since the build tool needs dofile/io.
set -u
RT="${1:?usage: run_runtime.sh <runtime> [lua]}"
LUA="${2:-lua}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$DIR/../xenonsec.lua"
TMP="$(mktemp -d)"
pass=0; fail=0

for p in "$DIR"/runtime/p_*.luau; do
  name=$(basename "$p")
  "$RT" run "$p" > "$TMP/ref.txt" 2>&1; rref=$?
  for opts in "" "--antidebug" "--no-minify" "--junk 0 --decoys 0" "--no-ssa --no-fold --no-localize" "--proxify" "--proxify --antidebug"; do
    if ! "$LUA" "$TOOL" "$p" -o "$TMP/out.luau" --luau $opts >/dev/null 2>&1; then
      fail=$((fail+1)); echo "BUILD FAIL $name [$opts]"; continue
    fi
    "$RT" run "$TMP/out.luau" > "$TMP/got.txt" 2>&1; rgot=$?
    if cmp -s "$TMP/ref.txt" "$TMP/got.txt" && [ "$rref" = "$rgot" ]; then
      pass=$((pass+1))
    else
      fail=$((fail+1)); echo "MISMATCH $name [$opts]"; diff "$TMP/ref.txt" "$TMP/got.txt" | head -4
    fi
  done
done

printf 'print("secret output")\n' > "$TMP/victim.luau"
"$LUA" "$TOOL" "$TMP/victim.luau" -o "$TMP/v_ad.luau" --luau --antidebug >/dev/null 2>&1
"$LUA" "$TOOL" "$TMP/victim.luau" -o "$TMP/v_plain.luau" --luau >/dev/null 2>&1
mk(){ cat "$DIR/runtime/envlog_prefix.luau" "$1" "$DIR/runtime/envlog_suffix.luau" > "$2"; }
mk "$TMP/v_ad.luau" "$TMP/h_ad.luau"; mk "$TMP/v_plain.luau" "$TMP/h_plain.luau"
ad=$("$RT" run "$TMP/h_ad.luau" 2>&1 | tail -1)
pl=$("$RT" run "$TMP/h_plain.luau" 2>&1 | tail -1)
# The antidebug build must be bricked (ok=false) AND log nothing. "logged=0"
# alone is not enough: a broken build also logs nothing, so that would pass
# for the wrong reason.
case "$ad" in *"ok=false logged=0"*) pass=$((pass+1)); echo "[ OK ] env-logger detected, build bricked";;
  *) fail=$((fail+1)); echo "[FAIL] env-logger not detected cleanly: $ad";; esac
case "$pl" in *"ok=true logged=1"*) pass=$((pass+1)); echo "[ OK ] plain build runs and logger sees its call (control)";;
  *) fail=$((fail+1)); echo "[FAIL] control did not run cleanly: $pl";; esac

rm -rf "$TMP"
echo "runtime suite ($(basename "$RT")): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
