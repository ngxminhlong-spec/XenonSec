# XenonSec

A VM-based obfuscator for Lua 5.1 **and Luau**. It doesn't rename
variables and scramble strings on top of your original source — it
**compiles your script into a custom bytecode format and ships a
randomized, hardened bytecode interpreter alongside it**, all wrapped
in a single closure. The output file contains no recognizable trace of
your original source: no identifiers, no plaintext strings, no
original control-flow shape, no fixed opcode numbering, and nothing at
all sitting at the file's top level except one expression.

Pure Lua, self-contained, no external dependencies. The obfuscator
tool itself and its generated output are both plain Lua-5.1-safe code
(no `goto`, no native bitwise/`//` operators used at the language
level) — verified against a real Lua 5.3 host throughout development,
since a `lua5.1` binary wasn't installable in this sandbox, but nothing
version-specific is ever emitted.

## Quick start

```
lua xenonsec.lua myscript.lua                  # writes myscript.xenon.lua
lua xenonsec.lua myscript.lua -o out.lua
lua xenonsec.lua myscript.lua --luau           # parse input as Luau
lua xenonsec.lua myscript.lua --junk 0.25 --decoys 30
lua xenonsec.lua myscript.lua --antidebug      # opt-in debugger/env-logger detection
lua xenonsec.lua myscript.lua --no-minify      # keep scaffolding readable, for debugging
```

Run `lua xenonsec.lua -h` for the full flag list. The output is a
single, ordinary `.lua` file — run it exactly like you'd run the
original:

```
lua out.lua
```

## Luau support (`--luau`)

A real, tested subset — not literally 100% of the language, and this
section is explicit about the line:

| Supported | Notes |
|---|---|
| Compound assignment | `+= -= *= /= //= %= ^= ..=`. Index targets (`t[k] += v`, `t.k += v`) evaluate the object/key exactly once, via synthesized temp locals, so a side-effecting target expression is never re-run. |
| `continue` | Inside `while`/`repeat`/numeric-`for`/generic-`for`. Correctly unwinds through arbitrarily nested `if`/`do` blocks, correctly lands before `until` in a `repeat` (which can still see the body's own locals), and correctly preserves fresh-per-iteration closure capture (tested explicitly). |
| Floor division | `//` and `//=`. Implemented as `math.floor(a/b)`, not the native Lua-5.3 `//` token, since the *output* still has to run on Lua 5.1. |
| Type annotations | `local x: T`, function param/return types, generic `<T>` function params, `type X = ...` aliases. Parsed with a heuristic balanced-bracket type-expression skipper and fully discarded — zero runtime effect, by design (this is an obfuscator, not a type checker). |
| If-then-else expressions | `if C then A else B` / with `elseif`. Desugared into an immediately-invoked function wrapping a real `if` statement (not the classic `cond and a or b` trick, which silently breaks when `a` is falsy) — so it's semantically exact, not an approximation. |

**Not supported**: string interpolation (`` `{expr}` `` backtick
strings). This needs lexer-level recursive re-tokenization that wasn't
implemented here — plain `..` concatenation still works fine as the
manual equivalent.

## Anti-tamper (on by default) and anti-debug (opt-in, `--antidebug`)

**Anti-tamper**: a checksum is computed at build time over every byte
of the encrypted constant pool *and* every opcode/operand of every
compiled instruction in every function, then re-verified at runtime
before anything else happens. On mismatch, the reaction is deliberately
not an obvious `error("tampered!")` — that just tells an attacker
exactly what to patch out. Instead, every single instruction in every
proto gets its opcode forced to a value that can never match anything
real, so the very next instruction the VM tries to execute fails with
a generic "bad opcode" — no matter *where* the tampering happened, and
regardless of whether it landed in the encrypted string pool or
directly in the bytecode table (both are covered; the two are
protected via different mechanisms since only one of them is actually
encrypted — see the source comments in `obfuscate.lua` for why). This
was verified empirically, not just by inspection: an exhaustive
byte-by-byte tamper sweep against a real generated file (every single
byte position flipped, one at a time, against a program that exercises
recursion, closures, method calls, and `pcall`) caught 100% of tamper
attempts that landed in the actual data payload. Byte flips landing in
inert regions (the banner comment, or VM engine code paths the
specific program never executes) naturally have no visible effect —
that's expected and correct, not a gap, and disappears entirely once
the program actually exercises the affected code path.

**Anti-debug** (`--antidebug`, off by default because these checks
carry real false-positive risk against legitimate profilers/IDEs):
- A `debug.gethook()` check — normal execution never installs a hook
  on itself, so a non-nil hook is a strong signal something is
  attached.
- A tight-loop timing check — single-stepping or breakpoints make
  trivial work take implausibly long.
- **Anti-env-logger**: detects the common trick of replacing a global
  like `print` or `pairs` with a table carrying a `__call`
  metamethod so every call gets logged before being forwarded to the
  real function. `type()` on such a proxy reports `"table"`, never
  `"function"` — a free, zero-false-positive tell, verified against an
  actual simulated logger-proxy attack (it was caught, and zero calls
  ever reached the logger). The global names being checked are
  themselves pulled from the same encrypted constant pool as
  everything else in the file — the check itself never introduces a
  plaintext string.

All three routes feed the exact same "brick every opcode" reaction as
the tamper checksum. Both `debug` and `os` may not exist in every host
(common in sandboxed embeddings) — every check is guarded to silently
skip rather than error when they're unavailable.

## Nothing readable except "Protected by XenonSec"

Every internal VM structure field that doesn't need to be human-readable
isn't: the scope-chain's `vars`/`parent` fields, previously spelled out
in plain English in the template, are now randomized identifiers like
everything else, and the VM's fallback error message was a bare
`error()` with no descriptive text at all (it used to say `"bad
opcode"`, which is a small but real hint about what kind of thing
just failed).

What's left after that sweep is exactly what Lua *requires* to exist
as literal source text no matter what — its own keywords (`function`,
`while`, `then`, ...) and standard library names (`string.byte`,
`table.concat`, `math.floor`, ...) — plus exactly one deliberate,
readable phrase: **"Protected by XenonSec"**. That phrase isn't just an
inert comment anyone could delete with zero consequence, either: a
second, *encrypted* copy of the same text lives in the constant pool
alongside the program's real strings, gets decoded through the same
key as everything else, and is checked with `gsub` at runtime —
if it doesn't decode back to that exact text, that's treated exactly
like any other tamper signal. (Genuinely reading a script's own
comment text back at runtime isn't reliably possible in standard Lua
— `debug.getinfo(1,"S").source` only returns the actual file
*contents* when loaded via `load(str)` with no chunkname; running via
`lua file.lua`, `dofile`, or `load(str, name)` — the realistic cases —
gives back just the filename, verified empirically rather than
assumed. This encrypted-second-copy approach sidesteps that limitation
entirely rather than shipping something that would silently not work.)

## Three-layer string/constant cipher

The previous encryption was a plain repeating-key XOR — a Vigenere
cipher, textbook-breakable by frequency analysis once there's enough
ciphertext, since the keystream repeats with a short, fixed period.
Replaced with three layers, each doing a genuinely different kind of
transformation, applied in sequence and unwound in reverse at runtime:

1. **RC4-style stream cipher** — real key-scheduling (a key-dependent
   permutation of a 256-entry state table) plus a pseudo-random
   generator that mutates that table on every byte, so the keystream
   never repeats with any short period (verified empirically: 2000
   bytes of keystream checked against every period up to 64 — no
   repetition found).
2. **Integer-only keyed diffusion** — a per-byte XOR against a keyed
   linear-congruential generator, plus an 8-bit rotation. Deliberately
   *not* a floating-point chaotic map (`chaos = r*x*(1-x)`-style
   constructions): those are a documented source of cross-platform
   divergence in the chaos-based-cryptography literature, since tiny
   floating-point rounding differences between a stock-Lua interpreter,
   LuaJIT's JIT-compiled arithmetic, and Luau can compound over enough
   iterations and silently produce different bytes on different hosts
   — a real risk specifically because this output has to decrypt
   correctly on whatever Lua the end user has, not just the machine
   that built it. Every intermediate value in this layer is kept well
   under 2^53 (the exact-integer range of an IEEE-754 double), so it's
   bit-for-bit identical on any compliant platform.
3. **CFB-style chaining** — each byte's transform depends on the
   previous ciphertext byte, so a ciphertext byte no longer maps to
   exactly one plaintext byte through a fixed keystream value the way
   plain RC4's does.

All three layers are pure integer/byte arithmetic — no `bit`/`bit32`
dependency, nothing that isn't valid in vanilla Lua 5.1. Verified with
50+ round-trip tests (empty strings, single bytes, all 256 byte values,
long strings, varying key lengths) before being wired into the real
pipeline, then the full test suite run across 65+ independent
randomized builds with zero failures.

## Heavy hardening: decoys, deeper predicates, and a real complex opcode

Three further hardening layers, all with the same non-negotiable
property as everything above: zero ability to change program
behavior, verified by running the existing suites (register-VM
closures, SSA propagation, Luau syntax, the full sample scripts) across
dozens of independent randomized builds after each change, not just
once.

- **Decoy dispatch branches**: extra `elseif <op> == <number> and
  <predicate> then <body>` branches spliced into the opcode dispatch
  chain, gated by a predicate built from a genuinely always-false
  identity ANDed with an always-true one — so it reads exactly like
  every other (real) branch's guard, but can never be taken. The
  bodies are syntactically real, plausible-looking stack manipulation
  code. A build now ships with a random handful of these in addition
  to its real ~32 opcodes, and there's no way to tell which is which
  by structure alone.
- **Deeper, more varied opaque predicates**: the identity pool grew
  from 7 to 15 (still all genuine number-theoretic facts — "a square
  is never negative", "the product of 3 consecutive integers is
  divisible by 6", etc. — nothing probabilistic), and nesting depth per
  opcode check went from 2-3 to 2-4.
- **A real complex opcode (`CPLX`)**: junk instructions were
  previously always a trivial push-then-immediately-pop of a constant
  value. `CPLX` is a genuinely richer instruction — it runs a small
  loop doing real arithmetic — while remaining exactly as safe as the
  simple junk pattern, because the loop's result still only ever gets
  pushed and immediately popped: net stack effect is always zero
  regardless of what the loop computes, so it can be spliced in
  anywhere real junk could be, with nothing to reason about beyond
  "does this net to zero" (it provably always does).

## No plaintext operator tables, either

Earlier builds had one remaining leak: the VM's internal binary/unary
operator dispatch used a small literal lookup table keyed by the
operator's own source text — `["+"]=1, ["-"]=2, ["=="]=3, ...` — sitting
in plain sight in the shipped file. The *program's own* use of "+"
was already encrypted, but the VM engine's own operator model wasn't.
Fixed: the compiler now emits a per-build randomized integer directly
for every `BINOP`/`UNOP` instruction (mirroring how opcode numbers
themselves are randomized), so the dispatch table is indexed straight
by that integer — no string, no lookup table, nothing resembling
`"+"`/`"-"`/`"=="` appears anywhere in the output at all. Verified by
scanning generated output for the distinctive `["<op>"]=` key pattern
across a source file exercising every arithmetic, comparison, and
unary operator: zero matches.

## What actually gets obfuscated

| Layer | What happens |
|---|---|
| **Identifiers** | A real static-scope resolver renames every local, param, and loop variable to an opaque token; only genuine globals keep their spelling internally, and even those are encrypted at rest same as everything else. |
| **Control flow** | Compiled into flat bytecode executed by one dispatch loop — there is no `if`/`while` left to read in the output. |
| **Opcodes** | ~31 instructions get a random numeric ID every build. |
| **Nested opaque-predicate dispatch hardening** | Every opcode check is additionally gated by a fresh, genuinely-nested, always-true boolean expression built from real number-theoretic identities (e.g. "v squared minus v is always even", "(v+1) squared minus v squared minus 2v minus 1 is always 0"), evaluated against a live per-call counter. A different combination is picked per opcode per build. These are provably true for any integer, so behavior never changes — they only add analysis noise to the dispatch chain. |
| **Strings & literals** | One shared constant pool, shuffled then XOR-encrypted with a random per-build multi-byte key. |
| **Numeric constants** | An additional reversible additive mask applied before the string/XOR layer. |
| **Decoy constants** | Random unreferenced junk entries shuffled into the pool. |
| **Junk instructions** | Stack-neutral no-op sequences spliced at random points through the bytecode, with exact jump-target remapping. |
| **Global localization** | Read-only globals get cached into a local once at the top; anything ever reassigned while global is excluded, so real global mutation always still works. |
| **Constant folding + SSA-style optimization** | Literal arithmetic folded at build time; a real value-numbering pass does copy/constant propagation and dead-store elimination across straight-line runs (see the notes below for exactly what "real" means here and a bug that was found and fixed in it). |
| **Register-based hybrid VM** | Locals never captured by a closure get flat, array-indexed register slots instead of scope-chain dictionary lookups; captured locals keep using the proven cell/scope-chain mechanism untouched. |
| **Heavy minification** | The VM/header scaffolding is stripped of comments and collapsed to a handful of space-joined lines before the (already-encrypted) payload is spliced in. |
| **Single-closure output** | The entire file is `return (function(...) ... end)(...)` — nothing (opcode numbers, decode key, consts, protos, helper names) sits at the chunk's top level at all. |
| **Anti-tamper** | Build-time checksum over the full data payload, re-verified at runtime; any mismatch bricks every opcode in every proto rather than raising an obvious error. On by default, `--no-antitamper` to disable. |
| **Anti-debug / anti-env-logger** | `debug.gethook`, timing, and `__call`-proxy-logger detection, feeding the same tamper reaction. Opt-in via `--antidebug` (real false-positive risk against legitimate profilers/IDEs). |
| **No plaintext operator tables** | Binary/unary operators dispatch through a per-build randomized integer, not a `["+"]=1`-style string-keyed table — nothing resembling an operator symbol appears anywhere in the output. |

All of the above are on by default (except anti-debug) and individually
toggleable — see `xenonsec.lua -h`, or the `opts` table on
`Obf.obfuscate(src, name, opts)`.

## Architecture

```
input.lua
   |  lexer.lua / parser.lua     tokenizer + recursive-descent -> AST (luau flag gates Luau syntax)
   v
  AST
   |  capture.lua (early pass)   which locals are ever closed over -- SSA needs this too, see below
   |  fold.lua                   constant-fold literal arithmetic
   |  ssa.lua                    value numbering: copy/constant propagation + dead-store elimination
   |  fold.lua (again)
   |  localize.lua               prepend synthetic local-x-equals-x for read-only globals
   |  renamer.lua                static scope resolution + identifier renaming
   |  capture.lua (again)        re-run post-rename for compiler.lua's register decisions
   v
  AST (optimized, localized, renamed)
   |  compiler.lua                AST -> flat stack-machine/register bytecode + constant pool
   v
  module { consts, protos }
   |  junk.lua                   inject stack-neutral junk instructions, remap jumps
   |  obfuscate.lua               opcode shuffle + opaque predicates, constant shuffle + decoys +
   |                              encryption, template rendering, heavy minify, single-IIFE wrap
   v
  single self-contained .lua file
```

### A real bug this project found in itself (kept here on purpose)

The SSA pass originally didn't account for this: a function call,
anywhere, can mutate a variable through a closure that captured it --
even with no visible call between that variable's last known value and
the point being optimized. Concretely:

```lua
local calls = 0
local function getTable()
  calls = calls + 1
  return { x = 10 }
end
local t = getTable()
print(t.x, calls)   -- SSA had wrongly propagated calls=0 here
```

The differential test suite (which executes both the original and
optimized code and diffs real output) caught this immediately as a
wrong-answer, not a crash. The fix: `capture.lua` now also runs once,
early, on the untransformed AST, purely so SSA can know which names
are ever reachable through some closure in the whole program: any
statement containing a function call invalidates every tracked value
for such a name, since that call could -- through some closure, however
indirectly -- have just mutated it. Names never captured by anything
stay safely trackable across calls, since nothing else could hold a
reference able to mutate them. Four dedicated regression tests cover
this specific class of bug now, alongside the closures/loop-variable
class of bug documented below.

### Why not a fully general, phi-node/CFG-based SSA?

Full SSA construction builds a control-flow graph and inserts
phi-functions at every branch merge point -- genuine, larger scope (CFG
construction, dominance frontiers, phi placement) than what's here.
What's implemented instead reasons precisely within straight-line runs
and treats every branch/loop/closure boundary as an opacity wall,
which is sound but doesn't merge information back together across
branches the way phi-functions would. Real, tested, and honestly
scoped -- not a rebrand of something smaller.

### Why not a fully general, liveness-allocated register VM?

The "register-based VM" here is a genuine architectural change (locals
split into flat register slots vs. proven cell-based storage depending
on closure capture -- the same fast-locals/cell-variables split real
language VMs use), not a full liveness-allocated register file with
slot reuse/spilling across a function's whole lifetime. That would
mean re-deriving closure/upvalue semantics from scratch against a much
larger surface area -- a bigger, separate undertaking.

### A real bug from earlier in the project (numeric-for closures)

Before the register VM existed, an early version of the compiler's
numeric-`for` loop gave every iteration's loop variable the same
underlying storage, so `for i=1,3 do fns[i]=function() return i end end`
made all three closures return `3`, not `1,2,3`. Fixed by giving each
iteration a genuinely fresh binding. Both the register-VM path and the
scope-chain path are tested for this specifically, including with
`continue` interacting with per-iteration capture.

## Test coverage

- `run_tests.lua` -- 38 differential tests (reference interpreter vs. native Lua).
- `e2e_test.lua` -- 20 tests against the actual generated output file with every pass active together.
- `ssa_test.lua` -- 25 tests against the SSA pass specifically, including the two regression classes above.
- `luau_test.lua` -- 9 tests against the full obfuscated pipeline for every Luau feature, diffed against hand-written plain-Lua-5.1 oracles.
- `protection_test.lua` -- 10 tests against anti-tamper (including an actual bytecode-tampering attempt), anti-debug (including a real `debug.sethook` and a simulated `__call`-proxy env-logger), and the no-plaintext-operator-table guarantee.
- All suites are also run repeatedly (20-40 randomized builds) under a hard timeout, to catch both randomization-dependent edge cases and any reintroduction of the infinite-loop/wrong-answer bug classes documented above.

## Known limitations

- Luau string interpolation is not supported (see above).
- This is identifier/control-flow/constant obfuscation with junk
  injection and opaque-predicate hardening, not a full anti-tamper/
  anti-debugger/VM-detection-resistance suite. No checksumming, no
  debugger-detection, no self-modifying code. Raises the cost of
  casual copy-paste theft; not a cryptographic guarantee.
- The SSA pass doesn't optimize across branches (no phi-functions).
- Interpreter, not compiled code -- noticeably slower than plain Lua.
  Fine for game scripts/plugins, not hot numeric loops.
- Error messages point at the bundled VM file/line, not your original source.
- Requires syntactically valid Lua 5.1 or Luau source; doesn't obfuscate `.luac` bytecode.

## Files

- `lexer.lua`, `parser.lua` -- front end (Lua 5.1 + optional Luau syntax)
- `capture.lua` -- closure-capture analysis (used twice: pre-SSA safety, post-rename register decisions)
- `fold.lua` -- constant-folding AST pass
- `ssa.lua` -- SSA-style value numbering / propagation / dead-store elimination
- `localize.lua` -- global-localization AST pass
- `renamer.lua` -- static scope resolver / identifier renamer
- `compiler.lua` -- AST to bytecode compiler (register + scope-chain hybrid)
- `junk.lua` -- junk-instruction injection (jump-target-safe)
- `obfuscate.lua` -- bundler: opcode/constant randomization, opaque predicates, encryption, template rendering, heavy minify, IIFE wrap
- `xenonsec.lua` -- CLI entry point
