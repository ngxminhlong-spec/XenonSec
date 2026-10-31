# XenonSec

![XenonSec](assets/xenonsec-logo.svg)

XenonSec is a virtual-machine obfuscator for Lua 5.1 and Luau. It does not
rename identifiers and scramble strings on top of your source. It compiles
your script into a custom register bytecode and ships a randomized,
hardened bytecode interpreter in the same file, wrapped in a single closure.

The output contains no identifiers from your source, no plaintext strings, no
fixed opcode numbering, and nothing at the top level of the file except one
expression. It is pure Lua with no dependencies.

## Quick start

Build with any Lua interpreter. The tests ran on Lua 5.3 (`texlua`), and no
Lua 5.1 binary was available, so the output is written to avoid 5.2+ features
but has not been run on 5.1 itself.

```
lua xenonsec.lua myscript.lua                  # writes myscript.xenon.lua
lua xenonsec.lua myscript.lua -o out.lua
lua xenonsec.lua game.luau --luau              # parse input as Luau
lua xenonsec.lua myscript.lua --antidebug      # opt-in debugger/env-logger detection
lua xenonsec.lua myscript.lua --proxify        # opt-in: locals live in proxy objects (slower)
```

The output is a single ordinary `.lua` file. Run it exactly like the original:

```
lua out.lua
```

## Options

Run `lua xenonsec.lua -h` for the full help text.

| Flag | Effect |
|---|---|
| `-o <file>` | Output path (default: `<input>.xenon.lua`). |
| `--luau` | Parse the input as Luau (see [Luau support](#luau-support)). |
| `--antidebug` | Enable debug-hook, native-hook, coroutine-hook, and env-logger detection. Off by default because of false-positive risk with profilers and IDEs. |
| `--proxify` | Store registers and captured locals in proxy objects. Harder to read statically, slower (see [ProxifyLocal](#proxifylocal-opt-in---proxify)). |
| `--junk <0..1>` | Junk-instruction rate. Default is auto-scaled to input size (about 0.20 to 0.55). `0` disables. |
| `--decoys <n>` | Number of decoy constants. Default is auto-scaled. |
| `--strength <1-4>` | Decoy and clutter level (default 2). Adds bulk, not secrecy. |
| `--no-flush` | Keep decoded constants cached for the whole run. |
| `--no-antitamper` | Disable the build-time checksum and runtime integrity check. |
| `--no-fold` | Disable constant folding of literal arithmetic. |
| `--no-ssa` | Disable value propagation and dead-store elimination. |
| `--no-localize` | Disable global localization. |
| `--no-minify` | Keep the generated VM and header readable (debugging). |

Explicit `--junk` and `--decoys` values override auto-scaling.

## Running on Luau runtimes

The output runs on [Lune](https://lune-org.github.io/docs) 0.10.5 and on
[Lute](https://github.com/luau-lang/lute) 1.0.1-nightly. The build tool itself
needs a standard Lua interpreter, because it uses `dofile` and `io`, which
these runtimes don't provide. Build with `lua`, then run the output with the
runtime:

```
lua xenonsec.lua game.luau -o game.xenon.luau --luau
lute run game.xenon.luau        # or: lune run game.xenon.luau
```

Runtime notes:

- Global names are encrypted constants in the output. Global reads and writes
  go through an accessor chosen at startup:
  - If the real global environment is writable (Lua 5.1 via `getfenv(0)`, Lua
    5.3 via `_G`, Lune), globals go straight to it. Semantics match the raw
    program, including `_G.x` after `x = 1`.
  - If it isn't (Lute: `_G` is read-only and doesn't track assignments), writes
    go to a private table. Reads check the standard builtins live, so a host
    replacement of `print` is seen, and then fall back to a snapshot of host
    globals.
- Known limit on Lute only: a global the program writes is private to the
  program. Other modules or host code that read globals through the real
  environment won't see it. Raw Lute already gives `_G` no view of assignments,
  so single-file scripts behave identically.
- Lune has no `debug` library, so hook-based anti-debug checks are inert there.
  The env-logger check still runs.

## What gets obfuscated

| Layer | What happens |
|---|---|
| **Identifiers** | A static scope resolver renames every local, parameter, and loop variable to an opaque token. Genuine globals keep their names internally, and are encrypted at rest like every other string. |
| **Control flow** | Compiled to register bytecode and run by a handler-table state machine. Control-flow flattening shuffles basic blocks and adds dead decoy blocks. No `if`/`while` or linear dispatch chain is left to read. |
| **Opcodes and operands** | Each instruction carries its own random seed. Its opcode and operands are stored masked with a value derived from that seed and the field's slot. The VM decodes each instruction just before running it and never holds a decoded program. |
| **Operators** | Binary and unary operators dispatch through per-build randomized integers. No operator symbol appears in the output, not even as a table key. |
| **Bytecode per proto** | Each function's instructions are packed and encrypted with its own key, derived from the build key and a per-proto nonce. A proto is decrypted the first time it is called. Protos that never run stay encrypted. |
| **State-dependent decoding** | Each instruction's decode masks depend on a running state that advances from every executed opcode and resets at jumps and returns. The stored tuples can only be decoded by replaying the program's control flow. |
| **MBA arithmetic** | `+` and `-` on non-negative integers below 2^26 are computed with mixed Boolean-arithmetic identities (`a+b = (a^b) + 2(a&b)`), so the dispatcher has no plain integer `+` or `-`. Other operands use the real operator. Disable with `mba = false`. |
| **Strings and constants** | One shared constant pool, shuffled and encrypted with a four-layer cipher and a per-build key. Constants are decrypted lazily on first use and cached. Constants the program never reaches are never decrypted. |
| **Numeric constants** | An additional reversible additive mask applied before the string cipher. |
| **Decoys** | Unreferenced decoy constants, decoy opcode handlers, decoy dispatch branches, and dead blocks, all in the same format as real code. |
| **Junk instructions** | `JUNK` writes into a scratch register that no real instruction uses. They are never placed inside a variable-length result window, and jump targets are remapped exactly. |
| **Standard-library names** | `string.format`, `pcall`, and the other library functions the output uses are looked up through one table at startup, not named in the code (see [Standard-library lookups](#standard-library-lookups-and-the-constant-cache)). |
| **Single closure** | The whole file is `return (function(...) ... end)(...)`. Nothing from the program sits at the chunk's top level. |
| **Anti-tamper** | On by default. See [Anti-tamper](#anti-tamper-on-by-default). |
| **Anti-debug** | Opt-in with `--antidebug`. See [Anti-debug](#anti-debug-opt-in---antidebug). |
| **Minification** | The VM and header scaffolding is stripped of comments and collapsed before the encrypted payload is spliced in. |

Everything above is on by default, except anti-debug and proxify. Each layer
can be turned off individually through the flags above or the `opts` table on
`Obf.obfuscate(src, name, opts)`.

## How the VM works

**Machine.** Every function runs on a register file with no value stack. Each
instruction names the registers it reads and writes. Expressions compile into
a destination register, and temporaries are released at the end of each
statement. Variable-length results (`f(...)`, `...`, multiple returns) go into
consecutive registers, and a `top` count on the frame tells the consumer how
many there are (`CALLM`, `RETM`, `SETLISTM`). `and`, `or`, and conditionals
test a register directly (`JF`, `JT`, `JNIL`).

**Dispatch.** A method-based state machine with one handler per opcode, looked
up by a per-build key. Operators are one instruction per operator (`BIN<k>`),
with a constant right-hand form (`BINK<k>`) and one per unary operator
(`UN<k>`).

**Captured locals** (locals a nested closure refers to) use a scope-cell
mechanism, so closures still capture them by reference. Uncaptured locals live
in registers. A block creates a scope only when it declares a captured local.

**Handler gates.** Every handler starts with an opaque predicate over the
frame's probe counter, built from number-theoretic identities that hold for
every integer, so they only add analysis noise.

**Speed.** On a fib + loop benchmark, the current register VM ran in about 703
ms, compared with about 1638 ms for the earlier chain-based VM and about 2545
ms for the earlier stack VM. These were measured on the versions at the time,
not re-measured for this README.

## Protection details

### Control-flow flattening

Each function's code is cut into basic blocks, laid out in shuffled order with
the entry block kept first, and joined by explicit jumps. Dead decoy blocks
that nothing can reach are added. This runs after junk injection, and every
jump target is remapped exactly.

### Opcode and decoy hardening

- **Decoy dispatch branches**: extra `elseif <op> == <number> and <predicate>`
  branches are spliced into the dispatch chain. Their predicate ANDs an
  always-false identity with an always-true one, so the body reads like a real
  branch but can never run.
- **Opaque predicates**: the identity pool has 15 number-theoretic facts (for
  example, a square is never negative, and the product of three consecutive
  integers is divisible by 6). Nesting depth per handler is auto-scaled.
- **Dense handler table**: real opcodes and decoys are drawn from one shuffled
  pool of `1..(real + decoys)`, so no key range separates decoys from real
  handlers. Each decoy has the same wrapper as a real handler.
- **Complex junk (`CPLX`)**: a junk form that runs a small loop of real
  arithmetic. Its result is pushed and immediately popped, so its net stack
  effect is always zero, and it can go anywhere ordinary junk can.

### Auto-scaled hardening

Junk rate, decoy constants, decoy dispatch branches, and predicate depth scale
with the compiled program's own size, measured before junk is injected.

- **Junk rate** falls from about 0.55 for small programs to a floor of 0.20 as
  the program grows.
- **Decoy constants** scale with the constant pool and instruction count, with
  a floor and a cap.
- **Decoy dispatch branches** scale with instruction count.
- **Predicate depth** is highest for small programs (up to 8, plus 0 to 2
  random), and settles at a floor of 3 for large ones. The cost is paid on
  every dispatch at runtime, so it doesn't grow without bound.

Explicit `--junk`, `--decoys`, and `--strength` values override the auto-scaling.

### Size target

Padding is off by default. Set `minSize` (CLI `--min-size <n>`) to target at least n bytes. If a
build comes out short, it is rebuilt with a higher `strength`, which scales the
decoy handlers and dead blocks. The padding is dead code. It makes one-shot
pastes awkward, and adds no secrecy to the logic.

### Anti-tamper (on by default)

Two levels of checking:

- A **global checksum** covers the encrypted constant pool and every
  opcode and operand of every compiled instruction in every function. It is
  verified before anything else runs.
- Each **function stores its own checksum**, and the dispatcher re-verifies
  one function every 4096 steps. An edit made after startup stops the program
  mid-run.

On a mismatch, the reaction is deliberately not an obvious `error("tampered!")`,
which would tell an attacker exactly what to patch out. Instead, every
instruction's opcode is forced to a value that matches nothing real, so the next
instruction fails with a generic "bad opcode", wherever the tampering happened.

The protection was checked by flipping every byte of a generated file, one at a
time, against a program using recursion, closures, method calls, and `pcall`.
Every flip that landed in the data payload was caught. Flips in inert regions
(the banner, or engine code the program never runs) have no effect, which is
expected.

### Anti-debug (opt-in, `--antidebug`)

These checks carry real false-positive risk against legitimate profilers and
IDEs, so they are off by default.

- **Hook check**: `debug.gethook()` returns non-nil if something is attached.
  Normal execution never installs a hook on itself. The check also looks at
  the hook of the running coroutine, since a debugger can attach to either.
- **Native check**: the hook probe must be the engine's own C function
  (`debug.getinfo(...).what == "C"`). Tooling usually installs itself by
  wrapping that function in a Lua one, which this catches.
- **Encrypted names**: the names the checks use (`debug`, `gethook`, `getinfo`,
  `coroutine`, `running`) are encrypted constants, decoded only when used. They
  never appear as plaintext in the output.
- The timing check was removed. A tight-loop timing test misfired under normal
  load, so it cost more false positives than it caught.
- **Env-logger check**: detects replacing a global like `print` or `pairs` with
  a table carrying a `__call` metamethod. `type()` on such a proxy returns
  `"table"`, never `"function"`, which is a zero-false-positive signal. The
  global names checked are pulled from the same encrypted pool as everything
  else.

The hook, native and env-logger checks feed the same "brick every opcode" reaction as the tamper checksum.
Every check is guarded to skip silently when `debug` or `os` is missing, as is
common in sandboxed hosts.

### ProxifyLocal (opt-in, `--proxify`)

By default a register is a plain table slot, and a captured local is a plain
field of its scope table. A reader can follow `regs[3] = regs[1] + regs[2]`
directly.

With `--proxify`, both storage tables become proxy objects:

- **Registers** live in a table that stays empty except for a raw slot `[0]`.
  Register `i` is stored at `store[(i * PA + PB) % 2^20]`, where `PA` (odd) and
  `PB` are random per build. Since `PA` is odd, the map is a bijection, so
  registers never collide. The register number never appears as a key.
- **Captured locals** live at `store[name]` in the scope's proxy, not as plain
  fields.
- **Boxed values**: each stored value sits in a fresh box `{v}`, reached only
  through `__index` and `__newindex`, so a reader can't find the value by
  looking at the table.

The proxy is built from the same per-build constants as the rest of the engine.
Nothing else changes: opcode scheme, checksums, and flattening run as before.

**Cost.** Every register access becomes a metamethod call plus a box
allocation. Measured on fib(24) plus a 100k-iteration loop (median of three
runs):

| Runtime | fib, plain | fib, `--proxify` | loop, plain | loop, `--proxify` |
|---|---|---|---|---|
| Lune 0.10.5 | ~450 ms | ~1000 ms (~2.3x) | ~175 ms | ~600 ms (~3.4x) |
| Lute 1.0.1-nightly | ~550 ms | ~790 ms (~1.4x) | ~350 ms | ~580 ms (~1.6x) |

The slowdown grows with register traffic. Use it for scripts where that is
acceptable, not for hot loops.

**What it is, and isn't.** It raises the cost of statically reading the data
flow. It is not secrecy. `PA`, `PB`, and the metatables are all in the output,
so a reader can reconstruct the mapping.

### Standard-library lookups and the constant cache

**Library lookups.** The generated code doesn't name `string.format`,
`setmetatable`, `pcall`, `math.random`, and the other library functions it uses.
Each is rewritten to an index into one table, `SA[k]`, filled at startup from
name strings stored as bytes offset by a per-build constant. The bootstrap names
(`string.byte`, `string.char`, `table.concat`) stay literal, because the decoder
needs them first. Metamethod keys such as `__index` stay literal, since Lua
requires them.

The env-logger checks and live getters use bare global names on purpose. A bare
read is the only form that sees a global replaced by name on every runtime, so
those names remain readable, but their keys are encoded.

**Constant-cache flush.** Decoded constants are cached in a plain table. Every
65536 steps, the periodic check empties that cache, so a dump of the table shows
only recently used constants. A constant used again is decoded again. The cost
on the fib + loop benchmark was within run-to-run noise at that interval. A
16384-step interval cost roughly 5 to 10 percent, so it wasn't used. Turn the
flush off with `--no-flush`.

Neither of these is secrecy. The decode key and ciphertext are in the output,
so anyone with the file can decrypt the pool. The flush only shortens how long
plaintext sits in memory.

### Constant cipher

The constant pool uses four layers, each a different kind of transformation,
applied in sequence and reversed at runtime:

1. **RC4-style stream cipher.** A key-dependent permutation of a 256-entry state
   table, with a generator that mutates the table on every byte. It is a
   variant: the index update uses a per-build odd multiplier, not plain
   addition. Every build draws its own seed basis, LCG multiplier, and addend.
   No textbook constant (the FNV offset basis, `2654435`, `12345`) appears in
   the output. On 40 random parameter sets, 2000 bytes of keystream were checked
   against every period up to 64, and no repetition was found.
2. **Integer-only keyed diffusion.** A per-byte XOR against a keyed LCG, plus an
   8-bit rotation. Floating-point chaotic maps were avoided on purpose. Their
   rounding differences can compound across interpreters (stock Lua, LuaJIT,
   Luau), which would produce different bytes on different hosts. Every
   intermediate value stays below 2^53, so the result is bit-identical on any
   compliant platform.
3. **CFB-style chaining.** Each byte's transform depends on the previous
   ciphertext byte, so a ciphertext byte no longer maps to exactly one plaintext
   byte through a fixed keystream value.
4. **Keyed substitution-permutation layer.** Each byte goes through a
   key-dependent S-box (a true permutation of all 256 values, not the identity),
   and bytes are then shuffled within fixed 8-byte blocks by a second
   key-derived permutation. A trailing partial block is left unpermuted. Its
   length already equals the plaintext length, so this reveals nothing new.

All four layers use only integer and byte arithmetic, so they need no `bit` or
`bit32` library.

The lazy-decrypt design makes constants harder to read but does not keep them
secret. The key sits next to the ciphertext.

### Nothing readable except "Protected by XenonSec"

The VM's internal field names are randomized identifiers, and its fallback error
is a bare `error()` with no descriptive text. What remains is what Lua requires
as literal text: its keywords and standard-library names, plus one deliberate
phrase, **"Protected by XenonSec"**.

That phrase is not an inert comment that could be deleted for free. An
encrypted second copy lives in the constant pool, is decoded with the same key
as the program's strings, and is checked with `gsub` at runtime. If it doesn't
decode to the exact text, it's treated as a tamper signal. Reading a script's
own comment text at runtime isn't reliable in standard Lua, so this avoids
depending on it.

## Optimization passes

| Pass | File | What it does |
|---|---|---|
| Capture analysis | `capture.lua` | Finds which locals a closure captures. Runs before SSA and again after renaming, for register decisions. |
| Constant folding | `fold.lua` | Folds literal arithmetic at build time. Runs before and after SSA. |
| SSA-style propagation | `ssa.lua` | Value numbering: copy and constant propagation, plus dead-store elimination. |
| Global localization | `localize.lua` | Caches read-only globals in locals. Anything reassigned while global is left alone. |
| Renamer | `renamer.lua` | Static scope resolution and identifier renaming. |
| Junk injection | `junk.lua` | Injects `JUNK` writes outside variable-length windows, with exact jump remapping. |
| Flattening | `passes.lua` | Control-flow flattening, described above. |

### SSA, and what "cross-branch" means

The SSA pass merges values across branches, the way a phi-function would for a
simple case:

- After `if c then x = 1 else x = 1 end`, a later `print(x)` sees the literal
  `1`. When branches disagree, the merge drops the value.
- A branch that always returns, breaks, or continues doesn't contribute to the
  merge. An `if` with no `else` counts as an else that changes nothing.
- A condition that is a literal after propagation (for example `if DEBUG then`
  with `DEBUG = false`) is collapsed to the branch that runs.
- Values flow into `if`, `do`, and loop bodies.
- Dead stores are removed only when the name is never read or reassigned later.
  Without the reassignment check, `local x = 1; x = 2` would lose its
  declaration and write a global.

Loops get a phi at the header. A value survives into the loop only if every
route back to the header (the end of the body, each `continue`, and each `break`)
still carries the same value. The pass finds this by a fixed point: it optimizes
a trial copy of the body, drops every name whose value disagrees on some route,
and repeats until nothing changes. The header environment is also the
environment after the loop, so a value can't leak out of a loop along a route
that wasn't checked. Loops nested more than three deep use the plainer rule
that drops everything the loop assigns, which keeps compile time bounded.

This is still not a complete CFG-based SSA. There are no general phi-functions
for values that merge through a `break` with different values, and there is
no alias analysis.

Operations that can run Lua code invalidate captured names they might change.
That includes calls, indexing, and operators that can reach a metamethod (for
example `a + 1` with an `__add` that assigns a captured local). Only `and`,
`or`, and `not` are known to run no code, and a store through an index (`t.a = v`) always counts, since `__newindex` can run. Here is why any of this matters. A
function call can mutate a variable through a closure that captured it, even
with no visible assignment in between:

```lua
local calls = 0
local function getTable()
  calls = calls + 1
  return { x = 10 }
end
local t = getTable()
print(t.x, calls)   -- an unguarded SSA would propagate calls=0 here
```

The differential suite caught this as a wrong answer, not a crash. The fix:
`capture.lua` runs once on the untransformed AST so SSA knows which names any
closure can reach. A statement that can run code invalidates those names, and
so does the end of a loop whose body does. Names never captured stay trackable
across calls.

Two bugs found by a randomized differential test after the loop phi went in:
a call inside a loop body didn't invalidate a captured local after the loop
(`local x = 1; local function set() x = 2 end; while flag do set(); break end;
local y = x` printed `1`), and a metamethod that assigns a captured local went
unseen by the pass entirely. Both are fixed and have regression tests.

## Luau support

`--luau` covers a tested subset of Luau. It is not complete. Syntax that is
parsed and then discarded has no runtime effect, by design, because this tool
replaces the original code with its own VM.

| Feature | Notes |
|---|---|
| Compound assignment | `+= -= *= /= //= %= ^= ..=`. Index targets evaluate the object and key exactly once, using synthesized temporaries. |
| `continue` | In `while`, `repeat`, and both `for` forms. Unwinds through nested `if` and `do` blocks, lands before `until` in a `repeat` (where the body's locals are still visible), and gives fresh closure capture per iteration. |
| Floor division | `//` and `//=`, compiled to `math.floor(a/b)` so the output still runs on Lua 5.1. |
| Type annotations | Local, parameter, and return types, generic `<T>` parameters, and `type X = ...` aliases. Skipped by a balanced-bracket heuristic and discarded. |
| If-expressions | `if C then A else B` and `elseif`. Compiled to an immediately-invoked function around a real `if`, not the `cond and a or b` trick, which breaks when `a` is falsy. |
| String interpolation | `` `hello {name}, {1+1}` ``, with nesting. Desugared at parse time into a concatenation chain, so later passes see ordinary nodes. |
| Generalized iteration | `for k, v in t do` on a plain table, without `pairs`. At runtime, a table first value is walked with `next`, and a function first value is called as an iterator, so existing `pairs` loops are unchanged. |
| Attributes | `@native`, `@checked`, and similar before a function declaration. Parsed and discarded. |
| Numeric literals | Binary (`0b1010`) and `_` digit separators (`1_000_000`, `0xFF_FF`). |
| `\u{...}` escapes | In plain and interpolated strings. Encoded to UTF-8 by hand, so no `utf8` library is needed. |

**Known gaps:** `__iter`-metamethod iteration (tables with `__iter` use the
`next`-based default), attributes on anonymous function expressions (only
statement-level `function` and `local function` are handled), and the `buffer`
type, which has no special syntax, so `buffer.create` and similar calls work as
ordinary library calls but are not specifically tested. If one of these blocks a
real script, that is a reason to prioritize it.

## Architecture

```
input.lua
   |  lexer.lua / parser.lua     tokens -> AST (luau flag gates Luau syntax)
   v
  AST
   |  capture.lua (early)        closure-captured names, used by SSA
   |  fold.lua                   constant folding
   |  ssa.lua                    value numbering, propagation, dead stores
   |  fold.lua (again)
   |  localize.lua               cache read-only globals in locals
   |  renamer.lua                scope resolution and identifier renaming
   |  capture.lua (again)        register decisions for the compiler
   v
  AST (optimized, localized, renamed)
   |  compiler.lua               AST -> register bytecode + constant pool
   v
  module { consts, protos }
   |  junk.lua                   JUNK injection, jump remapping
   |  passes.lua                 control-flow flattening
   |  src/obfuscator/*          opcode shuffle, predicates, decoys, constant
   |                             cipher, anti-tamper, template render, minify
   v
  single self-contained .lua file
```

### Project layout

```text
XenonSec/
├── xenonsec.lua              # CLI entrypoint
├── obfuscate.lua             # Stable public API entrypoint
├── src/
│   ├── obfuscator.lua        # Pipeline: AST passes, then bundle and render
│   ├── obfuscator/           # Output generation, one responsibility per file
│   │   ├── loader.lua        # Memoized dofile() so each module loads once
│   │   ├── util.lua          # Random identifiers, shuffles, XOR, minify
│   │   ├── crypto.lua        # Constant cipher and its per-build parameters
│   │   ├── opcodes.lua       # Opcode list, operator symbols, constant fields
│   │   ├── bundle.lua        # Constant pool, opcode renumbering, key vault, checksums
│   │   ├── predicates.lua    # Opaque predicates
│   │   ├── handlers.lua      # Decoy and real operator handlers
│   │   ├── render.lua        # Renders the VM engine template
│   │   ├── stdlib.lua        # Standard-library call renaming
│   │   └── templates/        # Lua source templates, returned as strings
│   │       ├── vm.lua        # VM engine
│   │       ├── header.lua    # Key vault, constants, protos
│   │       └── footer.lua    # Integrity check, engine call
│   ├── lexer.lua             # Lexer
│   ├── parser.lua            # Lua and Luau parser
│   ├── compiler.lua          # AST -> register bytecode
│   ├── interpreter.lua       # Reference register VM used by tests
│   ├── passes.lua            # Control-flow flattening
│   ├── fold.lua              # Constant folding
│   ├── ssa.lua               # SSA-style propagation
│   ├── localize.lua          # Global localization
│   ├── renamer.lua           # Scope-aware renaming
│   ├── capture.lua           # Closure capture analysis
│   └── junk.lua              # JUNK injection
├── tests/                    # See Testing below
├── assets/
│   └── xenonsec-logo.svg
└── README.md
```

## Testing

| Suite | Command | Result |
|---|---|---|
| Differential tests (reference VM vs. native Lua) | `run_tests.lua` | 38 / 38 |
| End-to-end, every pass on | `e2e_test.lua` | 20 / 20 |
| SSA pass, including regression, cross-branch, and loop phi cases | `ssa_test.lua` | 58 / 58 |
| Luau features, against plain-Lua oracles | `luau_test.lua` | 12 / 12 |
| Pass-level, including junk inside `f(g(h()))` windows | `passes_test.lua` | 12 / 12 |
| Standard-library lookups, cache flush, cipher constants | `mutate_test.lua` | 16 / 16 |
| ProxifyLocal, with and without other options, plus tamper checks | `proxify_test.lua` | 31 / 31 |
| Anti-tamper, anti-debug, no plaintext operator tables | `protection_test.lua` | 19 / 19 |
| Lune and Lute differential suite (10 programs x 7 option sets, plus an env-logger check) | `sh tests/run_runtime.sh <runtime> texlua` | 72 / 72 on Lune |

`difftest.lua` is a helper module loaded by `run_tests.lua`, not a standalone
suite.

The suites have also been run repeatedly across randomized builds to catch
randomization-dependent failures. Test counts are from the most recent run and
will change as tests are added.

The host-side suites above were run with `texlua` (Lua 5.3), since no Lua 5.1
binary was available. The runtime suite runs the same kind of programs under
Lune.

## Limitations

**Not protection, by design:**

- The decode key and the ciphertext are both in the output, so anyone with the
  file can decrypt the constant pool. The cache flush shortens how long plaintext
  stays in memory. It is not secrecy.
- Handler bodies are ordinary Lua. A reader who knows the VM design can find the
  dispatch, the register table, and the instruction pointer, whatever they are
  named. Per-build numbering, seeds, and decoys make each build a separate
  analysis job. They don't remove the semantics from the code.
- The field-decoding arithmetic is visible in the dispatcher. Hiding it further
  would need a different encoding scheme.
- The env-logger checks, live getters, and metamethod keys such as `__index`
  use literal names, because Lua and the runtimes require them.
- The cipher is a custom construction, not a standard or reviewed one. Per-build
  constants remove fixed values, but no cryptographic strength is claimed.
- This is identifier, control-flow, and constant obfuscation with junk and
  opaque predicates. It is not a full anti-tamper, anti-debugger, or VM-detection
  suite. Checksums and anti-debug checks exist, but there is no self-modifying
  code. The goal is to raise the cost of casual copy-paste theft.

**Performance:**

- Interpreted, not compiled. Expect noticeably slower execution than plain Lua.
  Suitable for game scripts and plugins, not hot numeric loops.
- `--proxify` makes register-heavy code 1.4x to 3.4x slower.

**Scope:**

- Input must be valid Lua 5.1 or Luau source. Compiled `.luac` bytecode is not
  supported.
- Error messages point at the bundled VM file and line, not your original source.
- SSA's loop phi covers loops nested up to three deep. Deeper loops use the plainer rule that drops every value the loop assigns.
- Luau `__iter` iteration and function-expression attributes are not handled.
  See [Luau support](#luau-support).
- Global writes under Lute stay private to the program, as described in
  [Running on Luau runtimes](#running-on-luau-runtimes).

## Files

Module-level summary: see [Project layout](#project-layout) above. The entry
points are `xenonsec.lua` (CLI) and `obfuscate.lua`, which forwards to
`src/obfuscator.lua` for the public `obfuscate(src, name, opts)` API.
