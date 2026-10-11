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
# Env-logger cases. Each logger is installed by a prefix, and the protected
# program is built twice: with --antidebug, and plain as the control. The
# antidebug build must be bricked (ok=false) AND log nothing. "logged=0" alone
# is not enough: a broken build also logs nothing, so that would pass for the
# wrong reason. The plain control must run and show its own logged call.
envcase(){  # $1 case name, $2 logger prefix, $3 protected program, $4 control expectation
  ad_src="$TMP/$1.ad.luau"; pl_src="$TMP/$1.pl.luau"
  want_pl="${4:-ok=true logged=1}"
  "$LUA" "$TOOL" "$3" -o "$ad_src" --luau --antidebug >/dev/null 2>&1
  "$LUA" "$TOOL" "$3" -o "$pl_src" --luau >/dev/null 2>&1
  cat "$2" "$ad_src" "$DIR/runtime/envlog_suffix.luau" > "$TMP/$1.ad.h.luau"
  cat "$2" "$pl_src" "$DIR/runtime/envlog_suffix.luau" > "$TMP/$1.pl.h.luau"
  ad=$("$RT" run "$TMP/$1.ad.h.luau" 2>&1 | tail -1)
  pl=$("$RT" run "$TMP/$1.pl.h.luau" 2>&1 | tail -1)
  case "$ad" in *"ok=false logged=0"*) pass=$((pass+1)); echo "[ OK ] env-logger ($1) detected, build bricked";;
    *) fail=$((fail+1)); echo "[FAIL] env-logger ($1) not detected cleanly: $ad";; esac
  case "$pl" in *"$want_pl"*) pass=$((pass+1)); echo "[ OK ] control ($1): plain build runs ($want_pl)";;
    *) fail=$((fail+1)); echo "[FAIL] control ($1) did not run cleanly: $pl";; esac
}
envcase tableproxy "$DIR/runtime/envlog_prefix.luau" "$TMP/victim.luau"
envcase luaclosure "$DIR/runtime/envlog_lua_prefix.luau" "$TMP/victim.luau"
# The plain build snapshots print at startup (standard-library lookups), so
# it never sees a print swapped mid-run: its control expects logged=0. The
# antidebug build still has to brick, which is the real check here.
envcase latesswap  "$DIR/runtime/envlog_late_prefix.luau" "$DIR/runtime/envlog_late_victim.luau" "ok=true logged=0"
# No logger at all: the antidebug build must NOT false-positive.
"$LUA" "$TOOL" "$TMP/victim.luau" -o "$TMP/clean_ad.luau" --luau --antidebug >/dev/null 2>&1
clean=$("$RT" run "$TMP/clean_ad.luau" 2>&1 | tail -1)
case "$clean" in "secret output") pass=$((pass+1)); echo "[ OK ] antidebug build runs clean with no logger (no false positive)";;
  *) fail=$((fail+1)); echo "[FAIL] antidebug false positive without logger: $clean";; esac

rm -rf "$TMP"
echo "runtime suite ($(basename "$RT")): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
