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

All of the above are on by default and individually toggleable — see
`xenonsec.lua -h`, or the `opts` table on `Obf.obfuscate(src, name, opts)`.

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
