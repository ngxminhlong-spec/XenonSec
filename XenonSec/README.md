# XenonSec

A VM-based obfuscator for Lua 5.1 source code. It doesn't rename
variables and scramble strings on top of your original Lua — it
**compiles your script into a custom bytecode format and ships a
randomized bytecode interpreter (a small virtual machine) alongside
it.** The output file contains no recognizable trace of your original
source: no identifiers, no plaintext strings, no original control-flow
shape, and no fixed opcode numbering (every build gets a fresh random
instruction-set mapping).

Pure Lua, self-contained, no external dependencies. Works with any
Lua 5.1-compatible runtime (also tested against 5.3/5.4 hosts, since
the generated output only ever uses 5.1-safe syntax) — and the
obfuscator tool itself is also plain 5.1-safe Lua (no `goto`, no
bitwise operators), so it runs under a real `lua5.1` too.

## Quick start

```
lua xenonsec.lua myscript.lua                  # writes myscript.xenon.lua
lua xenonsec.lua myscript.lua -o out.lua        # custom output path
lua xenonsec.lua myscript.lua --junk 0.25 --decoys 30
lua xenonsec.lua myscript.lua --no-minify       # keep scaffolding readable, for debugging
lua xenonsec.lua myscript.lua --no-ssa          # disable the SSA optimizer
```

Run `lua xenonsec.lua -h` for the full flag list. The output is a
single, ordinary `.lua` file — run it exactly like you'd run the
original:

```
lua out.lua
```

## What actually gets obfuscated

| Layer | What happens |
|---|---|
| **Identifiers** | A real static-scope resolver (mirrors Lua's own lexical scoping, including closures) renames every local variable, function parameter, and loop variable to an opaque token. Only genuine global references (`print`, `pairs`, your own global tables, etc.) keep their original spelling internally, because changing those would change behavior — and even those go through the same encrypted constant pool as everything else, so the *name itself* is never visible at rest either. |
| **Control flow** | Your `if`/`while`/`for`/functions are compiled into flat bytecode instructions (jumps, conditional jumps, calls) executed by an interpreter loop. There is no `if`/`while` left in the output to read — the whole program is one dispatch loop. |
| **Opcodes** | The ~29 VM instructions are assigned a random numeric ID on every build. The instruction dispatch table is generated fresh per build, so the mapping isn't reusable between builds. |
| **Strings & literals** | Every string and number in your source (including the renamed identifiers) goes through one shared constant pool, which is **shuffled** and then **XOR-encrypted** with a random per-build multi-byte key. Nothing is readable via `strings output.lua`. |
| **Numeric constants** | Every number additionally passes through a per-build reversible affine mask (`v * M + A`) *before* it reaches the string/XOR layer — a "number-expression" style layer underneath the cipher, not instead of it. |
| **Decoy constants** | A random handful of junk strings/numbers that no instruction ever references get shuffled into the constant pool, so pool size no longer tells you how much the program actually does. |
| **Junk instructions** | Stack-neutral no-op sequences (push a throwaway value, pop it right back) are spliced at random points through every proto's bytecode. Real instruction patterns get noise woven through them; jump targets are precisely remapped so correctness never depends on where the junk landed. |
| **Global localization** | Every genuinely-global identifier that's only ever *read* (never reassigned) gets a one-time `local x = x` synthesized at the top of the chunk, so the rest of the program accesses it as an ordinary (renamed, encrypted) local instead of repeatedly falling through the scope chain to `_G`. Anything ever assigned while global (e.g. `counter = counter + 1`) is deliberately *excluded*, so real global mutation always still works correctly. |
| **Constant folding** | Literal arithmetic (`2 + 3 * 4`, `-(-5)`, etc.) is evaluated once at build time so the VM never spends instructions or constant-pool slots on values that were already fully determined in the source. |
| **SSA-style optimization** | A real value-numbering pass, run before renaming/compilation: every `local x = <pure expr>` is treated as x's single static definition, and every subsequent read *within the same straight-line run of statements* is replaced with a copy of that value (copy/constant propagation) — which typically hands constant-folding a second round of arithmetic to reduce. A local whose value is never read again before going out of scope is dead-code-eliminated (its side-effecting RHS, if any, is kept as a bare statement; a side-effect-free RHS is dropped entirely). Scoped honestly — see below. |
| **Runtime signature** | The VM engine embedded in the output is generated from a template with fully randomized local/function names on every build, so two builds of the same script don't share a byte-for-byte identical engine. |
| **Minification** | The VM engine and header scaffolding are stripped of comments/indentation/blank lines before the (already-encrypted) payload is spliced in — smaller output, zero risk to the embedded ciphertext. |

All of the above are on by default and individually toggleable via CLI
flags or the `opts` table passed to `Obf.obfuscate(src, name, opts)`
(`minify`, `fold`, `ssa`, `localizeGlobals`, `junkRate`, `decoyConstants`).

## Architecture

```
input.lua
   |  lexer.lua        tokenizer
   v
 tokens
   |  parser.lua        recursive-descent -> AST
   v
  AST
   |  fold.lua           constant-fold literal arithmetic
   |  ssa.lua             value numbering: copy/constant propagation + dead-store elimination
   |  fold.lua (again)    catch arithmetic the SSA pass just exposed
   |  localize.lua        prepend synthetic `local x = x` for read-only globals
   |  renamer.lua         static scope resolution + identifier renaming
   v
  AST (optimized, localized, renamed)
   |  compiler.lua        AST -> flat stack-machine bytecode + constant pool
   v
  module { consts, protos }
   |  junk.lua            inject stack-neutral junk instructions, remap jumps
   |  obfuscate.lua        opcode shuffle, constant shuffle + decoys + encryption
   |                       (incl. numeric affine mask), template rendering + minify
   v
  single self-contained .lua file (VM engine + encrypted bytecode)
```

The VM is a **closure-compiling bytecode interpreter**: every compiled
Lua function becomes a genuine host Lua function value (a closure over
the interpreter loop), not a re-implemented call-stack of its own. That
means things like `pcall`, `coroutine.wrap`, `table.sort` with a
comparator, and metatables all interoperate transparently with
obfuscated functions, because as far as the host Lua runtime is
concerned they're just functions.

Variable scoping is implemented as a runtime chain of scope tables
(closures capture the chain by reference), which is what gives correct
closure semantics — including the easy-to-get-wrong case of a fresh
binding per iteration of a numeric `for` loop, which this VM gets
right (verified by a dedicated test).

### What the SSA pass is honest about *not* doing

Full, textbook SSA construction builds a control-flow graph for the
whole function and inserts **phi-functions** at every point where
control paths merge (e.g. right after an `if`/`else`, where a
variable's value depends on which branch ran), so that a single
variable version can still be reasoned about even across branches.
That's a materially bigger undertaking — real CFG construction, block
dominance, phi placement — and this project doesn't do it.

What it does instead: value-number and propagate strictly *within* a
straight-line run of statements, and treat every `if`/`while`/`for`/
`repeat`/closure boundary as an opacity wall — nothing is propagated
into one, and anything reassigned inside one is invalidated the moment
control returns to the straight-line code that follows. This is the
same reasoning a full SSA optimizer would apply to its straight-line
basic blocks; it just doesn't attempt to merge information back
together across branches the way phi-functions would. It's also where
the actual, real bug-hunting effort went during development — see the
next section.

### Why not a register-allocated VM with separate block/register/upvalue modules?

That's a legitimate, larger architecture (closer to how real Lua's own
`lopcodes`/register-based VM works, or how production obfuscators
structure their compiler internals into separate
`block.lua`/`register.lua`/`upvalue.lua`/etc. modules). It's a
genuinely different backend — register allocation, explicit upvalue
capture lists per closure — not an incremental change to the current
scope-chain interpreter, and re-deriving closure/upvalue/loop-variable
semantics from scratch is exactly the class of bug this project has
now hit and fixed twice (see below). Deliberately out of scope here
rather than rushed; happy to take it on as a focused follow-up.

## A real bug the test suite caught (kept here on purpose)

While building the SSA pass, an early version substituted a loop's
pre-loop values directly into its `while`/`repeat` condition. That's
wrong: a loop condition re-evaluates on *every* iteration, seeing
whatever the body most recently assigned — so substituting a stale
value in turned `while i < n do i = i + 1 end` into a permanently-true
`while 0 < 3 do i = i + 1 end`, an infinite loop. The differential test
suite (which actually *executes* both the original and the optimized
code and diffs their output, rather than just checking the AST shape)
caught this immediately as a hang. Fixed by invalidating any
loop-body-assigned name from the condition's substitution environment
*before* substituting, for both `while` and `repeat`. It's called out
here because "the tests passed" is only meaningful if the tests would
actually have caught this — and they did.

## Test coverage

- `run_tests.lua` — 31 differential tests (reference interpreter vs. native Lua).
- `e2e_test.lua` — tests against the **actual generated output file**
  with every pass active together (fold/ssa/junk/localize/masking/minify),
  including dedicated SSA-through-the-full-pipeline cases and a
  closure-capture-safety case.
- `ssa_test.lua` — 21 tests specifically against the SSA pass in
  isolation (propagation, dead-store elimination, loop-condition
  safety for `while`/`repeat`/`for`, nested-loop reassignment,
  closure-capture pinning), each one executing both the original and
  optimized code and diffing real output.
- All three suites are also run repeatedly (20–25 builds each) under a
  hard timeout to catch both randomization-dependent edge cases and
  any reintroduction of the infinite-loop class of bug above.

## Known limitations (be upfront with yourself about these)

- **`goto`/labels** are not supported (not part of Lua 5.1 anyway).
- **This is identifier/control-flow/constant obfuscation with junk
  injection, not a full anti-tamper/VM-detection-resistance suite.**
  There's no checksumming, no debugger-detection, no self-modifying
  code. A patient reverse engineer with time can still trace the
  interpreter loop. Treat this as raising the cost of casual
  copy-paste theft, not as a cryptographic guarantee.
- **The SSA pass doesn't optimize across branches** (no phi-functions;
  see above) — it's real, but it's basic-block-scoped, not
  whole-function scoped.
- **Performance**: every variable read/write walks a runtime scope
  chain and every instruction goes through a numeric if/elseif
  dispatch — this is an interpreter, not compiled code. SSA/fold
  reduce instruction count somewhat; junk injection and global
  localization trade a little more/less of this off in opposite
  directions; net effect is still noticeably slower than plain Lua
  (fine for game scripts/plugins, not for hot numeric loops).
- **Error messages** point at the bundled VM file/line, not your
  original source (a side effect of compilation that also incidentally
  hides your original file structure from stack traces).
- Requires a syntactically valid Lua 5.1 source file. It doesn't
  obfuscate already-compiled bytecode (`.luac`).

## Files

- `lexer.lua`, `parser.lua` — Lua 5.1 front end
- `fold.lua` — constant-folding AST pass
- `ssa.lua` — SSA-style value numbering / propagation / dead-store elimination
- `localize.lua` — global-localization AST pass
- `renamer.lua` — static scope resolver / identifier renamer
- `compiler.lua` — AST → bytecode compiler
- `junk.lua` — junk-instruction injection (jump-target-safe)
- `obfuscate.lua` — bundler (opcode/constant randomization, encryption, template rendering, minify)
- `xenonsec.lua` — CLI entry point
