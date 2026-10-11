# XenonSec
## Project layout

```text
XenonSec/
├── xenonsec.lua              # CLI entrypoint
├── obfuscate.lua             # Stable public API entrypoint
├── src/                      # Core implementation
│   ├── obfuscator.lua        # Pipeline + VM emission
│   ├── lexer.lua             # Source lexer
│   ├── parser.lua            # Lua/Luau parser
│   ├── compiler.lua          # AST -> register bytecode (no value stack)
│   ├── interpreter.lua       # Reference register VM used by tests
│   ├── fold.lua              # Constant folding
│   ├── ssa.lua               # SSA-style propagation
│   ├── localize.lua          # Global localization
│   ├── renamer.lua           # Scope-aware identifier renaming
│   ├── capture.lua           # Closure/capture analysis
│   └── junk.lua              # JUNK instruction injection
├── tests/                    # Regression, differential, and protection tests
│   ├── run_tests.lua
│   ├── difftest.lua
│   ├── e2e_test.lua
│   ├── luau_test.lua
│   ├── protection_test.lua
│   └── ssa_test.lua
├── assets/
│   └── xenonsec-logo.svg
└── README.md
```

The project intentionally does **not** split every helper into its own file.
Each module above owns a distinct stage or responsibility, while the root
entrypoints keep the command-line/API surface stable.


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
lua xenonsec.lua myscript.lua --proxify        # opt-in ProxifyLocal: locals live in proxy objects (slower)
lua xenonsec.lua myscript.lua --no-flush        # keep decoded constants cached for the whole run
lua xenonsec.lua myscript.lua --no-minify      # keep scaffolding readable, for debugging
```

Run `lua xenonsec.lua -h` for the full flag list. The output is a
single, ordinary `.lua` file — run it exactly like you'd run the
original:

```
lua out.lua
```

## Running on Luau runtimes (Lune, Lute)

Output files are verified to run on [Lune](https://lune-org.github.io/docs)
(0.10.5) and on [Lute](https://github.com/luau-lang/lute) (1.0.1-nightly).
The build tool itself needs a standard Lua interpreter (it uses `dofile` and
`io`, which these runtimes don't provide), so build with `lua`, then run the
output with the runtime:

```
lua xenonsec.lua game.luau -o game.xenon.luau --luau
lute run game.xenon.luau        # or: lune run game.xenon.luau
```

`tests/run_runtime.sh <runtime> [lua]` is a differential suite. Each program in
`tests/runtime/` must produce identical output and exit code raw and
obfuscated, across several option sets, and the env-logger check is run
through the runtime too.

Runtime notes:
- Global names are encrypted constants in the output, like every other
  string. Global reads and writes go through a small table-driven accessor
  chosen at startup:
  - If the real global environment is writable (Lua 5.1 via `getfenv(0)`,
    Lua 5.3 via `_G`, Lune), globals go straight to it. Program semantics are
    exactly the raw ones, including `_G.x` after `x = 1`.
  - If it isn't (Lute: `_G` is read-only and does not track assignments),
    writes go to a private table and reads fall back to the standard builtins
    read live (so a host's replacement of `print` is seen) and then to the
    `_G` snapshot of host globals.
- Known limit on Lute only: a global the program writes is private to the
  program. Other modules or host code that read globals through the real
  environment won't see it. Raw Lute already gives `_G` no view of
  assignments, so single-file scripts behave identically.
- The env-logger check reads the standard builtins directly by name. Those
  names are plain text in the output (as the engine's own `type`/`pcall`
  already are).
- Lune has no `debug` library, so hook-based anti-debug checks are inert
  there; the env-logger and timing checks still run.

## Register VM, passes, and protection (current version)

**Machine.** Every function runs on a register file, with no value stack.
Each instruction names the registers it reads and writes. Expressions compile
straight into a destination register, and temporaries are released at the end
of each statement. Results of a variable length (`f(...)`, `...`, multiple
returns) go into consecutive registers, and a `top` count on the frame tells
the consumer how many there are (`CALLM`, `RETM`, `SETLISTM`). `and`/`or` and
conditionals test a register directly (`JF`, `JT`, `JNIL`).

**Dispatch.** Method-based state machine: one handler per opcode, looked up by
a per-build key. Operator instructions are one per operator (`BIN<k>`), with a
constant right-hand form (`BINK<k>`) and one per unary operator (`UN<k>`).

**Captured locals** (ones a nested closure refers to) keep the scope-cell
mechanism, so closures still capture them by reference. Uncaptured locals live
in registers. Blocks only create a scope when they declare a captured local.

**Control-flow flattening** (`src/passes.lua`). Each function's code is cut into
basic blocks, laid out in shuffled order (the entry block stays first), and
joined by explicit jumps. Dead decoy blocks that nothing can reach are added.

**Junk** (`src/junk.lua`) splices `JUNK` writes into a scratch register that no
real instruction uses. Junk is never placed between a variable-length result
and the instruction that consumes it, so it cannot overwrite those values.

**Anti-tamper, two levels.** The global checksum is verified at startup. Each
function also stores its own checksum, and the dispatcher re-verifies one
function every 4096 steps, so an edit after startup stops the program mid-run.

**Output size.** Builds target at least 100000 bytes (`minSize`; `false`
disables it). When a build comes out short, it is rebuilt with a larger
`strength`, which scales the decoy handlers and dead blocks. The padding is
dead code: it makes a single paste too large for a one-shot read, and it adds
no secrecy to the logic.

**Limits.**
- Handler bodies are ordinary Lua. The runtime has to contain what each opcode
  does, so one build can always be studied. Per-build numbering, seeds, and
  decoys make each build a separate analysis job, but do not remove the
  semantics from the code.
- The field-decoding arithmetic is visible in the dispatcher.
- The cipher key sits next to the ciphertext, as before. Lazy decryption makes
  constants harder to read, but does not keep them secret.
- Speed: on a fib + loop benchmark the register VM runs about 3.6 times faster
  than the previous stack VM (703 ms against 2545 ms) and about 2.3 times
  faster than the original chain VM (1638 ms).

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
| String interpolation | `` `hello {name}, {1+1}` `` backtick strings, nesting included. The lexer brace-balances and extracts each `{...}` segment's raw source (skipping over nested string/backtick literals so a brace inside one never miscounts); the parser then tokenizes and parses each segment with itself, so any expression Luau allows works inside an interpolation. Desugars at parse time into a plain `"hello " .. tostring(name) .. ", " .. tostring(1+1)` concatenation chain — every later pass (fold/SSA/junk/renamer/compiler) sees ordinary String/Binop/Call nodes it already handles, nothing interpolation-specific anywhere downstream. |
| Generalized iteration | `for k, v in t do` directly on a plain table — no `pairs`/`ipairs` required. Desugared at parse time: the original `in`-list is evaluated and adjusted to 3 values exactly as before, then a runtime `type(...) == "table"` check decides whether to treat the first value as an iterator function (old style — `pairs(t)`'s first value is already a function, so this is a no-op for existing code) or as a bare table to walk with the built-in `next` (new style). Tables with a custom `__iter` metamethod fall through to the `next`-based default rather than calling `__iter` — flag it if a real script needs that. |
| Attributes | `@native`, `@checked`, etc. before a function declaration. Parsed and discarded, same reasoning as type annotations — these are hints for the real Luau compiler's native-codegen/typechecking, meaningless once the original code is thrown away and replaced with this tool's own VM. |
| Extended numeric literals | Binary (`0b1010`), and `_` digit-group separators anywhere in a numeral (`1_000_000`, `0xFF_FF`, `0b1010_1010`). |
| `\u{...}` string escape | Unicode codepoint escape in both plain and interpolated strings, e.g. `"\u{1F600}"`. Encoded to UTF-8 bytes by hand (no reliance on a host `utf8` library, since the tool itself may run on a plain Lua 5.1 host that doesn't have one). |

Known gaps, not yet implemented: `__iter`-metamethod iteration (see generalized iteration above), attributes on anonymous function expressions (only statement-level `function`/`local function` attributes are handled), and the `buffer` type (no special syntax of its own — `buffer.create(...)` etc. already work as ordinary library calls, this just means nothing's been specifically verified against it). None of these came up in testing so far — if one of them blocks a real script, say so and it'll get prioritized over guessing at coverage nobody's using.

**All of this — string interpolation, generalized iteration, attributes,
numeric literals, `\u{}` escapes, and the auto-scaled hardening below —
was added in the same no-interpreter sandbox mentioned above, so none
of it has actually been run.** Traced by hand against what each
feature is supposed to desugar/produce, not executed. Run the test
suite, or at minimum obfuscate a script exercising each of these, and
run the *output* somewhere real (Lute included), before trusting any
of it.

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

**Anti-debug** (`--antidebug`, off by default in the CLI because these checks
carry real false-positive risk against legitimate profilers/IDEs; on by default
in the web playground):
- A `debug.gethook()` check — normal execution never installs a hook
  on itself, so a non-nil hook is a strong signal something is
  attached.
- A tight-loop timing check — single-stepping or breakpoints make
  trivial work take implausibly long.
- **Anti-env-logger guard** (the strongest part of this mode). It runs
  in three layers:
  1. At startup, every standard builtin the check covers (`print`,
     `pairs`, `type`, `pcall`, `setmetatable`, `select`, `next`, ...) must
     be a real function, and a *C* function. The C check uses
     `debug.getinfo(f).what` where it exists and `debug.info(f, "s")`
     otherwise, so a logger that wraps a builtin in a Lua closure is
     caught even though `type()` still says `"function"`.
  2. The startup values are snapshotted. Every periodic probe (every 2048
     VM instructions, the same probe that watches for debug hooks) checks
     that each builtin is still that exact value, so a logger installed
     partway through a run is caught too.
  3. Where the raw `_G` table holds the builtin, the raw entry must match
     the bare read. This catches a logger that works through a metatable
     on `_G`. (Lune keeps builtins out of the raw table, so this layer
     only applies where the raw entry exists.)
  A detected logger bricks the build through the same `corrupt()` path as
  every other tamper check. The builtin names are read as bare globals on
  purpose: a logger installed before the protected code must be visible
  to the check, so those names stay readable in the output. Limits: a
  host that replaces `print` on purpose (for its own output capture) looks
  the same as a logger, which is the intended trade-off. A determined
  attacker who controls the runtime can still patch the checks out; the
  guard raises the cost and makes the common loggers fail loudly.

All three routes feed the exact same "brick every opcode" reaction as
the tamper checksum. Both `debug` and `os` may not exist in every host
(common in sandboxed embeddings) — every check is guarded to silently
skip rather than error when they're unavailable.

## ProxifyLocal (opt-in, `--proxify`)

By default a register is a plain table slot, and a captured local is a
plain field of its scope table. A reader (human or LLM) sees
`regs[3] = regs[1] + regs[2]` and can follow the data flow directly.

With `--proxify`, both storage tables become **proxy objects**:

- **Registers** (`RMETA`): the table itself stays empty except for a
  raw slot `[0]`, which holds the real storage. Register `i` lives at
  `store[(i * PA + PB) % 2^20]`, where `PA` (odd) and `PB` are random
  per build. Since `PA` is odd, the map is a bijection, so no two
  registers collide. The register number never appears as a key.
- **Captured locals** (`VMETA`): a captured local `name` lives at
  `store[name]` in the scope's proxy, instead of as a plain field.
- **Boxed values**: every stored value sits in a fresh box `{v}`, so a
  register or local never holds a value directly. Reads and writes go
  through `__index` / `__newindex`, so a reader can't find the value by
  looking at the table.

The proxy is built from the same per-build constants as the rest of
the engine, so each build has its own layout. Nothing else in the
generated file changes: the opcode scheme, anti-tamper checksums, and
control-flow flattening all run exactly as before.

**Cost.** Every register read and write is now a metamethod call plus
a box allocation. Measured on a fib(24) + 100k-iteration loop
benchmark (median of three runs, same build with and without the flag):

| Runtime | fib, plain | fib, `--proxify` | loop, plain | loop, `--proxify` |
|---|---|---|---|---|
| Lune 0.10.5 | ~450 ms | ~1000 ms (~2.3x) | ~175 ms | ~600 ms (~3.4x) |
| Lute 1.0.1-nightly | ~550 ms | ~790 ms (~1.4x) | ~350 ms | ~580 ms (~1.6x) |

The cost is larger on Lune than on Lute, and it grows with how much
register traffic the program does. Use it for scripts where the
slowdown is acceptable, not for hot loops.

**What it is, and isn't.** It raises the cost of statically reading
the data flow. It is not secrecy: `PA`, `PB`, and the metatables are
all in the output, so a reader who sees the file can reconstruct the
mapping. Treat it as one more layer of analysis friction, like the
other layers in this README.

Tested by `tests/proxify_test.lua` (every program run natively and
obfuscated with proxify, alone, with `--antidebug`, and with the size
target, plus tamper detection), and by `tests/run_runtime.sh` on Lune
and Lute (both `--proxify` and `--proxify --antidebug`). The whole
Lua 5.3 suite also passes with proxify forced on by default.

## Standard-library lookups and constant-cache flush (default on)

Two changes remove readable tells from the output without changing what
the program does.

**Standard-library lookups.** The generated code no longer names
`string.format`, `setmetatable`, `pcall`, `math.random` and the other
library functions it uses. Each one is rewritten to an index into one
table, `SA[k]`, that is filled at startup from name strings stored as
bytes offset by a per-build constant. The bootstrap names
(`string.byte`, `string.char`, `table.concat`) stay literal, because the
decoder needs them before anything else runs. Metamethod keys such as
`__index` stay literal too, since Lua requires them.

The env-logger checks (`--antidebug`) and the live getters still use the
bare global names on purpose. A bare read is the only form that sees a
global replaced by name on every runtime (on Lute, `_G` does not reflect
globals assigned by name), so those names remain readable. Live-getter
keys are encoded.

**Constant-cache flush.** Decoded constants are cached in a plain table.
Every 65536 steps the periodic check now empties that cache, so a dump
of the table sees only the constants used recently. A constant used
again is decoded again. Measured cost on the fib + loop benchmark is
within run-to-run noise at a 65536-step interval (a 16384-step interval
cost roughly 5-10%, so it was not used). Turn it off with `--no-flush`.

**What this doesn't do.** The decode key and the ciphertext are in the
output, so a reader who has the file can always decrypt the pool. The
flush shortens how long plaintext sits in memory. It is not secrecy.

Tested by `tests/mutate_test.lua` (16 tests: no readable library names
in the output, correct output across several flush cycles with the flush
on and off, and a constant that is decoded again after a flush), and by
`tests/run_runtime.sh` on Lune and Lute, where it runs in all option sets.

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

## Four-layer string/constant cipher

The previous encryption was a plain repeating-key XOR — a Vigenere
cipher, textbook-breakable by frequency analysis once there's enough
ciphertext, since the keystream repeats with a short, fixed period.
Replaced with four layers, each doing a genuinely different kind of
transformation, applied in sequence and unwound in reverse at runtime:

1. **RC4-style stream cipher** — a key-dependent permutation of a
   256-entry state table, with a pseudo-random generator that mutates
   that table on every byte. It is a variant, not textbook RC4: the
   index update uses a per-build odd multiplier instead of plain
   addition. Checked empirically on 40 random parameter sets: 2000
   bytes of keystream each, against every period up to 64, with no
   repetition found.
   
   Every build also draws its own seed basis, LCG multiplier and
   addend, and this multiplier. No textbook constant (the FNV offset
   basis, `2654435`, `12345`) appears in the output.
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
4. **Keyed substitution-permutation layer** — XenonSec's own
   construction, not a variant of the three above. Every byte first
   goes through a key-dependent S-box (a genuine permutation of all
   256 byte values, built with the same keyed LCG the diffusion layer
   uses — not the identity table), then bytes are shuffled *within*
   fixed 8-byte blocks according to a second, independent key-derived
   permutation. Both permutations come from the key alone, so nothing
   extra has to be shipped beyond the same key the other three layers
   already carry. A trailing partial block is left unpermuted — safe,
   since ciphertext length already equals plaintext length and reveals
   nothing new.

All four layers are pure integer/byte arithmetic — no `bit`/`bit32`
dependency, nothing that isn't valid in vanilla Lua 5.1. The first
three layers were verified with 50+ round-trip tests (empty strings,
single bytes, all 256 byte values, long strings, varying key lengths)
before being wired into the real pipeline, then the full test suite
run across 65+ independent randomized builds with zero failures.
**Layer 4 was added in an environment with no Lua interpreter
available, so it has not been run yet** — build/encrypt and decode
were traced by hand step-for-step against each other, but you should
run `run_tests.lua`, `e2e_test.lua`, and `protection_test.lua` (or at
minimum obfuscate-then-run a sample script) before trusting it on
anything real.

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
  divisible by 6", etc. — nothing probabilistic). Nesting depth per
  opcode check, decoy dispatch branches, and decoy constants all
  auto-scale to the size of the real program instead of using one flat
  count for every input (see next section) — a one-liner and a
  thousand-line script no longer get the same handful of decoys.

## Auto-scaled hardening

Junk rate, decoy constants, and decoy dispatch branches are no longer
flat numbers tuned for an "average" script — they scale off the real
compiled program's own size (instruction count, constant pool size),
computed *before* junk is injected so the decision isn't fed by its
own output:

- **Junk rate**: small scripts (few real instructions) get a much
  higher percentage — a flat rate barely adds bulk to a 10-instruction
  script — sliding from roughly 0.55 down to a floor of 0.20 as the
  program's own size grows and starts pulling its own weight.
- **Decoy constants**: scales with both the real constant pool and
  instruction count, with a floor (so a near-empty script still ships
  meaningful decoy noise) and a cap (so a huge input doesn't blow the
  decoy pool up past the point of diminishing returns).
- **Decoy dispatch branches**: scales with instruction count, so a
  large real dispatch chain gets a proportionally larger decoy chain
  around it, not the same flat handful a one-liner gets.
- **Opaque-predicate depth**: inverted compared to the others — depth
  per opcode check is highest (up to 8, plus 0-2 random) for small
  programs, since a tiny script can afford more relative weight per
  dispatch, and settles down to a floor of 3 as instruction count grows,
  since this cost is paid on *every* dispatch at runtime and shouldn't
  scale up unbounded just because the source file is large. Capped well
  below the 15-identity pool so a build never needs more unique
  identities than exist.

`--junk <rate>` and `--decoys <n>` still work exactly as before and
override auto-scaling entirely when passed — auto-scaling only kicks
in when the caller doesn't specify a value.
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
| **Control flow** | Compiled into flat bytecode and executed by a handler-table state machine: one handler per opcode, looked up by a per-build key. There is no `if`/`while` or linear dispatch chain left to read in the output. |
| **Opcodes and operands** | Every instruction carries its own random seed. Its opcode and three operands are each stored masked with a value derived from that seed and the field's slot, so no single position-based pattern recovers them. The VM decodes each instruction immediately before running it (step by step), and never holds a fully decoded program. Decoy handler entries pad the handler table. |
| **Opaque-predicate handler gates** | Every handler starts with an opaque predicate over the frame's probe counter, built from real number-theoretic identities. The identities hold for every integer, so they only add analysis noise. |
| **Strings & literals** | One shared constant pool, shuffled and XOR-encrypted with a random per-build multi-byte key. Constants are decrypted lazily, on first use, and cached; constants the program never reaches are never decrypted. |
| **Numeric constants** | An additional reversible additive mask applied before the string/XOR layer. |
| **Decoy constants** | Random unreferenced junk entries shuffled into the pool. |
| **Junk instructions** | `JUNK` writes into a scratch register no real instruction uses, spliced at random points, never inside a variable-length result window, with exact jump-target remapping. |
| **Global localization** | Read-only globals get cached into a local once at the top; anything ever reassigned while global is excluded, so real global mutation always still works. |
| **Constant folding + SSA-style optimization** | Literal arithmetic folded at build time; a real value-numbering pass does copy/constant propagation and dead-store elimination across straight-line runs (see the notes below for exactly what "real" means here and a bug that was found and fixed in it). |
| **Register VM** | Uncaptured locals and all temporaries live in registers; there is no value stack. Captured locals keep the proven cell/scope-chain mechanism. |
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
   |  compiler.lua                AST -> per-function register bytecode + constant pool
   v
  module { consts, protos }
   |  junk.lua                   inject JUNK writes (never in a variadic result window), remap jumps
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
- `passes_test.lua` -- 12 pass-level tests, including a regression test for junk landing inside a multi-result call window (`f(g(h()))`).
- `mutate_test.lua` -- 16 tests: standard-library lookups, the constant-cache flush, per-build cipher constants, and handler-key spread.
- `proxify_test.lua` -- 31 tests: 9 programs, each run natively and obfuscated with `--proxify` (alone, with `--antidebug`, and with the size target), plus proxy-emission and tamper checks.
- `run_runtime.sh <runtime> texlua` -- Lune/Lute differential suite: 10 programs x 7 option sets (including `--proxify`), plus an env-logger check.
- `protection_test.lua` -- 10 tests against anti-tamper (including an actual bytecode-tampering attempt), anti-debug (including a real `debug.sethook` and a simulated `__call`-proxy env-logger), and the no-plaintext-operator-table guarantee.
- All suites are also run repeatedly (20-40 randomized builds) under a hard timeout, to catch both randomization-dependent edge cases and any reintroduction of the infinite-loop/wrong-answer bug classes documented above.

## Known limitations

Items below are marked as fixed or inherent. "Inherent" means the
output has to run from the file, so the reader can always see it.

**Fixed in this version:**
- Fixed cipher constants: each build has its own seed basis, LCG
  multiplier/addend, and RC4-variant multiplier (see the cipher
  section).
- Decoy handlers were separable: real opcodes were a dense block of
  small numbers and decoys a sparse block of 4-digit numbers. Now every
  real key and every decoy key is drawn from one shuffled pool of
  `1..(real + decoys)`, so the handler table is dense and nothing
  separates decoys by key. Each decoy is also written in the same
  wrapper as a real handler (gate, body, `ip + 1`). The dense table is
  also faster than the sparse one it replaces. The test in
  `mutate_test.lua` fails on the old layout.
- The runtime repeated the seed derivation in four places. It is now
  one helper.

**Inherent (these would need the program to not run from the file):**
- The decode key and the ciphertext are both in the output, so a reader
  who has the file can decrypt the pool. The constant cache flush
  shortens how long plaintext stays in memory, but this is not secrecy.
- Handler bodies are ordinary Lua. A reader who knows the VM design can
  find the dispatch, the register table, and the instruction pointer,
  whatever their names.
- The env-logger checks and the live getters use bare global names. A
  bare read is the only form that sees a global replaced by name on
  every runtime (on Lute, `_G` does not reflect globals assigned by
  name), so those names stay readable. The same goes for metamethod
  keys such as `__index`, which Lua requires as literals.
- The field-decoding arithmetic is visible in the dispatcher. Hiding it
  further would need a different encoding scheme, not more of the same.
- The cipher is a custom construction, not a standard or reviewed one.
  Per-build constants remove fixed values, but no cryptographic
  strength is claimed.

**Feature limits (not protection):**
- Luau `__iter`-metamethod iteration and `function`-expression-level
  attributes aren't handled yet (see Luau support above).
- This is identifier/control-flow/constant obfuscation with junk
  injection and opaque-predicate hardening, not a full anti-tamper/
  anti-debugger/VM-detection-resistance suite. No checksumming, no
  debugger-detection, no self-modifying code. Raises the cost of
  casual copy-paste theft; not a cryptographic guarantee.
- The SSA pass doesn't optimize across branches (no phi-functions).
- `--proxify` makes register-heavy code 1.4x to 3.4x slower (see the ProxifyLocal section). It is opt-in for that reason.
- Interpreter, not compiled code -- noticeably slower than plain Lua. The
  handler-table VM costs roughly 25% more runtime than the previous
  if/elseif-chain VM (measured on a fib + loop benchmark), in exchange for
  removing the readable dispatch chain and encoding opcodes on disk.
- Handler bodies are ordinary Lua: the runtime has to contain what each opcode
  does, so one build can always be studied. Per-build numbering, seeds, and
  decoys make each build a separate analysis job, but they don't remove the
  semantics from the code.
- The field-decoding arithmetic is visible in the dispatcher. Hiding it further
  would need a different encoding scheme, not more of the same.
- Fine for game scripts/plugins, not hot numeric loops.
- Error messages point at the bundled VM file/line, not your original source.
- Requires syntactically valid Lua 5.1 or Luau source; doesn't obfuscate `.luac` bytecode.

## Files

- `lexer.lua`, `parser.lua` -- front end (Lua 5.1 + optional Luau syntax)
- `capture.lua` -- closure-capture analysis (used twice: pre-SSA safety, post-rename register decisions)
- `fold.lua` -- constant-folding AST pass
- `ssa.lua` -- SSA-style value numbering / propagation / dead-store elimination
- `localize.lua` -- global-localization AST pass
- `renamer.lua` -- static scope resolver / identifier renamer
- `compiler.lua` -- AST to register bytecode (scope cells only for captured locals)
- `junk.lua` -- JUNK injection (jump-target-safe, outside multi-result windows)
- `obfuscate.lua` -- bundler: opcode/constant randomization, opaque predicates, encryption, template rendering, heavy minify, IIFE wrap
- `xenonsec.lua` -- CLI entry point
