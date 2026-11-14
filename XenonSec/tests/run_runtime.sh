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

# Env-logger detection, once per builtin the in-file check watches. Each
# logger wraps one builtin in a counting proxy, and the victim calls it. The
# antidebug build must be bricked (ok=false) AND log nothing: "logged=0"
# alone would also pass for a broken build. The plain build is the control.
victim_for(){
  case "$1" in
    print)        echo 'print("secret output")' ;;
    tostring)     echo 'local _v = tostring(1) print("secret output")' ;;
    type)         echo 'local _v = type(1) print("secret output")' ;;
    pcall)        echo 'local _v = pcall(print, "") print("secret output")' ;;
    pairs)        echo 'for _k in pairs({}) do end print("secret output")' ;;
    select)       echo 'local _v = select("#", 1) print("secret output")' ;;
    setmetatable) echo 'local _v = setmetatable({}, nil) print("secret output")' ;;
    error)        echo 'local _v = pcall(error, "x") print("secret output")' ;;
  esac
}
for nm in print tostring type pcall pairs select setmetatable error; do
  printf '%s\n' "$(victim_for $nm)" > "$TMP/victim.luau"
  "$LUA" "$TOOL" "$TMP/victim.luau" -o "$TMP/v_ad.luau" --luau --antidebug >/dev/null 2>&1
  "$LUA" "$TOOL" "$TMP/victim.luau" -o "$TMP/v_plain.luau" --luau >/dev/null 2>&1
  # The victim is a whole chunk (it starts with a top-level return), so it
  # runs inside a function under pcall; the suffix then reports the result.
  mk(){ { sed "s/@NAME@/$nm/g" "$DIR/runtime/envlog_prefix.luau"; echo 'local __ok, __err = __realPcall(function(...)'; cat "$1"; echo; echo 'end)'; cat "$DIR/runtime/envlog_suffix.luau"; } > "$2"; }
  mk "$TMP/v_ad.luau" "$TMP/h_ad.luau"; mk "$TMP/v_plain.luau" "$TMP/h_plain.luau"
  adall=$("$RT" run "$TMP/h_ad.luau" 2>&1)
  ad=$(echo "$adall" | tail -1)
  pl=$("$RT" run "$TMP/h_plain.luau" 2>&1 | tail -1)
  # Bricked and silent: no protected output. For print the logger must also
  # see nothing; other builtins are used by the header before the check runs,
  # so their logger may count those calls.
  leak=0; echo "$adall" | grep -q "secret output" && leak=1
  if [ "$nm" = print ]; then want_logged="ok=false logged=0"; else want_logged="ok=false"; fi
  case "$ad" in *"$want_logged"*) [ "$leak" = 0 ] && { pass=$((pass+1)); echo "[ OK ] env-logger on $nm detected, build bricked"; } || { fail=$((fail+1)); echo "[FAIL] env-logger on $nm leaked output";};;
    *) fail=$((fail+1)); echo "[FAIL] env-logger on $nm not detected cleanly: $ad";; esac
  case "$pl" in *"ok=true"*"logged=0"*) fail=$((fail+1)); echo "[FAIL] control for $nm logged nothing: $pl";;
    *"ok=true"*) pass=$((pass+1)); echo "[ OK ] plain build runs and logger on $nm sees the call (control)";;
    *) fail=$((fail+1)); echo "[FAIL] control for $nm did not run cleanly: $pl";; esac
done

rm -rf "$TMP"
echo "runtime suite ($(basename "$RT")): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
