# XenonSec

![XenonSec](assets/xenonsec-logo.svg)

XenonSec is a virtual-machine obfuscator for Lua 5.1 and Luau. It does not
just rename identifiers and scramble strings. It compiles your script to a
custom register bytecode and ships a randomized bytecode interpreter in the
same file, wrapped in a single closure.

The output is one ordinary `.lua` file with no dependencies. It contains no
identifiers from your source, no plaintext strings, no fixed opcode numbers,
and nothing at the top level except one expression.

> **Status.** Obfuscation raises the cost of reading and copying a script. It
> is not secrecy and not a security boundary. See [Limitations](#limitations).

## Quick start

```
lua xenonsec.lua myscript.lua                  # writes myscript.xenon.lua
lua xenonsec.lua myscript.lua -o out.lua
lua xenonsec.lua game.luau --luau              # parse input as Luau
lua xenonsec.lua myscript.lua --antidebug      # opt-in debugger detection
lua xenonsec.lua myscript.lua --proxify        # opt-in proxy-object locals
```

Build with any standard Lua interpreter. The output runs like the original:

```
lua out.lua
```

The build was tested on Lua 5.4 and Lua 5.1 (checked with `luac5.1 -p`, and run
with `lua5.1`).

## Options

Run `lua xenonsec.lua -h` for the full help text.

| Flag | Effect |
|---|---|
| `-o <file>` | Output path (default: `<input>.xenon.lua`). |
| `--luau` | Parse the input as Luau (see [Luau support](#luau-support)). |
| `--antidebug` | Enable debug-hook, native-hook, coroutine-hook, and env-logger detection. Off by default because profilers and IDEs can trigger false positives. |
| `--proxify` | Store registers and captured locals in proxy objects. Harder to read statically, slower (see [ProxifyLocal](#proxifylocal---proxify)). |
| `--junk <0..1>` | Junk-instruction rate. Default is auto-scaled to input size (about 0.20 to 0.55). `0` disables it. |
| `--decoys <n>` | Number of decoy constants. Default is auto-scaled. |
| `--strength <1-4>` | Decoy and clutter level (default 2). Adds bulk, not secrecy. |
| `--min-size <n>` | Grow the output to at least `n` bytes by raising the strength (padding is dead code; off by default). |
| `--no-flush` | Keep decoded constants cached for the whole run. |
| `--no-antitamper` | Disable the build-time checksum and runtime integrity check. |
| `--no-fold` | Disable constant folding of literal arithmetic. |
| `--no-ssa` | Disable value propagation and dead-store elimination. |
| `--no-localize` | Disable global localization. |
| `--no-minify` | Keep the generated VM and header readable (debugging). |

Explicit `--junk` and `--decoys` values override auto-scaling.

## Running on Luau runtimes

The output runs on [Lune](https://lune-org.github.io/docs) 0.10.5 and on
[Lute](https://github.com/luau-lang/lute). The build tool needs a standard Lua
interpreter, because it uses `dofile` and `io`, which these runtimes lack:

```
lua xenonsec.lua game.luau -o game.xenon.luau --luau
lune run game.xenon.luau        # or: lute run game.xenon.luau
```

Runtime notes:

- Global names are encrypted constants in the output. Global reads and writes
  go through an accessor chosen at startup:
  - If the real global environment is writable (Lua 5.1 via `getfenv(0)`, Lua
    5.3+ via `_G`, Lune), globals go straight to it. Semantics match the raw
    program, including `_G.x` after `x = 1`.
  - If it isn't (Lute: `_G` is read-only and doesn't track assignments), writes
    go to a private table. Reads check the standard builtins live, so a host
    replacement of `print` is seen, and then fall back to a snapshot of host
    globals.
- Known limit on Lute only: a global the program writes is private to the
  program. Modules or host code that read globals through the real environment
  won't see it. Single-file scripts behave identically.
- Lune has no `debug` library, so hook-based anti-debug checks are inert there.
  The env-logger check still runs.

## What gets obfuscated

| Layer | What happens |
|---|---|
| **Identifiers** | A scope resolver renames every local, parameter, and loop variable to an opaque token. Genuine globals keep their names internally and are encrypted at rest like every other string. |
| **Control flow** | Compiled to register bytecode and run by a handler-table state machine. Control-flow flattening shuffles basic blocks and adds dead decoy blocks. No `if`/`while` or linear dispatch chain is left to read. |
| **Opcodes and operands** | Each instruction carries its own random seed. Its opcode and operands are stored masked with a value derived from that seed and the field's slot. The VM decodes each instruction just before running it and never holds a decoded program. |
| **Numeric keys and indexes** | Table keys and indexes in the generated code (handler tables, opcode alias tables, stdlib slots, escaped-constant entries) are written as `((n+k)-k)` with a fresh key per literal, so the numbers do not appear directly. |
| **Operators** | Binary and unary operators dispatch through per-build randomized integers. No operator symbol appears in the output, not even as a table key. |
| **Bytecode per proto** | Each function's instructions are packed and encrypted with its own key, derived from the build key and a per-proto nonce. A proto is decrypted the first time it is called. Protos that never run stay encrypted. |
| **Runtime decoder** | The LZMA-style decoder that unpacks the proto records is itself compiled by this VM, so it ships as encrypted bytecode, not readable Lua. Its own protos are stored uncompressed, because they are what decompresses the rest. The range-coder adaptation rate (16 or 32) is chosen per build, and the compressor uses the same value. This costs about 40 KB per output. |
| **State-dependent decoding** | Each instruction's decode masks depend on a running state that advances with every executed opcode and resets at jumps and returns. The stored tuples can only be decoded by replaying the program's control flow. |
| **MBA arithmetic** | `+` and `-` on non-negative integers below 2^52 (default) use bitwise identities (`a+b = (a^b) + 2(a&b)`), so the dispatcher has no plain integer `+` or `-` in that range. Other operands use the real operator. Options: `mba = false` disables it; `mbaLimit = 67108864` (2^26) trades coverage for speed (about 2x on large-operand arithmetic). |
| **Strings and constants** | One shared constant pool, shuffled and encrypted with a per-build cipher and key. Constants are decrypted lazily on first use and cached. Constants the program never reaches are never decrypted. |
| **Standard-library names** | Functions such as `string.format`, `pcall`, and `table.concat` are looked up through one table filled at startup, not named in the code. Each name is stored under its own keystream (a per-name seed run through a multiplicative generator), so the encoded bytes differ for every build. The bootstrap finds `string.char` and `string.byte` by behavior, not by name. |
| **Decoys** | Unreferenced decoy constants, decoy opcode handlers, decoy dispatch branches, and dead blocks, all in the same format as real code. |
| **Junk instructions** | `JUNK` writes into a scratch register no real instruction uses. Junk never lands inside a variable-length result window, and jump targets are remapped exactly. |
| **Single closure** | The whole file is `return (function(...) ... end)(...)`. Nothing from the program sits at the chunk's top level. |
| **Anti-tamper** | On by default. See [Anti-tamper](#anti-tamper). |
| **Anti-debug** | Opt-in with `--antidebug`. See [Anti-debug](#anti-debug---antidebug). |
| **Minification** | The VM and header scaffolding is minified with a token-aware, parser-based minifier. Comments are dropped (the watermark comment stays), statements are separated only where needed, and integer literals of 1000 or more are masked as arithmetic with a per-build key. |

Everything above is on by default, except anti-debug and proxify. Each layer
can be turned off through the flags above or the `opts` table on
`Obf.obfuscate(src, name, opts)`.

## How the VM works

**Machine.** Every function runs on a register file with no value stack. Each
instruction names the registers it reads and writes. Variable-length results
(`f(...)`, `...`, multiple returns) go into consecutive registers, and a `top`
count on the frame tells the consumer how many there are (`CALLM`, `RETM`,
`SETLISTM`). `and`, `or`, and conditionals test a register directly (`JF`,
`JT`, `JNIL`).

**Dispatch.** A method-based state machine with one handler per opcode, looked
up by a per-build key. Operators are one instruction per operator (`BIN<k>`),
with a constant right-hand form (`BINK<k>`), and one per unary operator
(`UN<k>`).

**Captured locals** (locals a nested closure refers to) use a scope-cell
mechanism, so closures still capture them by reference. Uncaptured locals live
in registers.

**Handler gates.** Every handler starts with an opaque predicate over the
frame's probe counter, built from number-theoretic identities that hold for
every integer. They add analysis noise only.

**Metamorphic handlers.** Several core handlers have more than one body. A
build picks one at random, so two builds of the same script expose different
handler code. The alternatives (`templates/core_variants.lua`) change statement
order, local aliases, and expression shape, but compute the same thing. The
handler self-test runs the chosen bodies at startup, so a variant that changed
behavior stops the build instead of passing quietly.

## Protection details

### Anti-tamper

On by default. The build computes a checksum over the ciphertext, the opcodes,
and the operands, and the runtime recomputes it. A periodic check runs during
execution. Editing the output stops the program. Disable with
`--no-antitamper`.

### Anti-debug (`--antidebug`)

Opt-in. It checks for debug hooks, native hooks, coroutine hooks, and
env-loggers (a logger installed before the protected code). On Lune the hook
checks are inert, since there is no `debug` library. Off by default because
profilers and IDEs can trigger false positives.

### ProxifyLocal (`--proxify`)

Registers and captured locals live in proxy objects, so the register file no
longer looks like a plain Lua table to a static reader. Measured slowdown:
1.4x to 3.4x on register-heavy code.

### Constant cipher and cache

The constant pool is stored as base85 text, with escape-form entries only where
the decoder needs a constant at load time. Constants are decrypted on first use
and cached per decode site. The cache is flushed on a schedule (every 65536
steps by default; `--no-flush` keeps it). The flush shortens how long plaintext
stays in memory. It is not secrecy.

## Optimization passes

- **Constant folding** (`fold.lua`): literal arithmetic is evaluated at build
  time. Disable with `--no-fold`.
- **Value propagation and dead stores** (`ssa.lua`): an SSA-style pass that
  propagates values across branches and removes dead stores. Its loop phi covers
  loops nested up to three deep; deeper loops fall back to a plainer rule that
  drops every value the loop assigns. Disable with `--no-ssa`.
- **Global localization** (`localize.lua`): read-only globals are cached in
  locals. Disable with `--no-localize`.

## Luau support

`--luau` covers a tested subset of Luau. Syntax that is parsed and then
discarded has no runtime effect, by design, because this tool replaces the
original code with its own VM.

| Feature | Notes |
|---|---|
| Compound assignment | `+= -= *= /= //= %= ^= ..=`. Index targets evaluate the object and key exactly once, using synthesized temporaries. |
| `continue` | In `while`, `repeat`, and both `for` forms. Lands before `until` in a `repeat` (where the body's locals are still visible), and gives fresh closure capture per iteration. |
| Floor division | `//` and `//=`, compiled to `math.floor(a/b)` so the output still runs on Lua 5.1. |
| Type annotations | Local, parameter, and return types; generic `<T>` parameters; function types, including inside table types; `type X = ...` aliases, including several in a row. Skipped by a balanced-bracket scanner and discarded. |
| Type assertions | `e :: T` is accepted and discarded. |
| If-expressions | `if C then A else B` and `elseif`. Compiled to an immediately-invoked function around a real `if`, not the `cond and a or b` trick, which breaks when `a` is falsy. |
| String interpolation | `` `hello {name}, {1+1}` ``, with nesting. Desugared at parse time into a concatenation chain. |
| Generalized iteration | `for k, v in t do` on a plain table, without `pairs`. A table is walked with `next`; a function is called as an iterator, so existing `pairs` loops are unchanged. |
| Attributes | `@native`, `@checked`, and similar before a function declaration. Parsed and discarded. |
| Numeric literals | Binary (`0b1010`) and `_` digit separators (`1_000_000`, `0xFF_FF`). |
| `\u{...}` escapes | In plain and interpolated strings, encoded to UTF-8 by hand. |

**Known gaps:** `__iter`-metamethod iteration (tables with `__iter` use the
`next`-based default), attributes on anonymous function expressions (only
statement-level `function` and `local function` are handled), and the `buffer`
type, which has no special syntax. `buffer.create` and similar calls work as
ordinary library calls but are not specifically tested.

## Architecture

```
input.lua
   |  lexer.lua / parser.lua     tokens -> AST (luau flag gates Luau syntax)
   v
  AST
   |  capture.lua                closure-captured names
   |  fold.lua, ssa.lua          constant folding, value propagation
   |  localize.lua               cache read-only globals in locals
   |  renamer.lua                scope resolution and identifier renaming
   v
  AST (optimized, renamed)
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
├── obfuscate.lua             # Public API entrypoint
├── src/
│   ├── obfuscator.lua        # Pipeline: AST passes, then bundle and render
│   ├── obfuscator/           # Output generation, one responsibility per file
│   │   ├── loader.lua        # Memoized dofile() so each module loads once
│   │   ├── util.lua          # Random identifiers, shuffles, XOR, numeric masks, minify
│   │   ├── crypto.lua        # Constant cipher and its per-build parameters
│   │   ├── opcodes.lua       # Opcode list, operator symbols, constant fields
│   │   ├── bundle.lua        # Constant pool, opcode renumbering, key vault, checksums
│   │   ├── predicates.lua    # Opaque predicates
│   │   ├── handlers.lua      # Decoy and real operator handlers
│   │   ├── render.lua        # Renders the VM engine template
│   │   ├── stdlib.lua        # Standard-library name encoding and slot table
│   │   ├── minify.lua        # Parser-based token-aware minifier
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
└── assets/
    └── xenonsec-logo.svg
```

## Testing

| Suite | Command | Result |
|---|---|---|
| Differential tests (reference VM vs. native Lua) | `lua tests/run_tests.lua` | 38 / 38 |
| End-to-end, every pass on | `lua tests/e2e_test.lua` | 20 / 20 |
| SSA pass, including regression and loop cases | `lua tests/ssa_test.lua` | 58 / 58 |
| Luau features, against plain-Lua oracles | `lua tests/luau_test.lua` | 12 / 12 |
| Pass-level, including minifier and literal masking | `lua tests/passes_test.lua` | 39 / 39 |
| Metamorphic builds, standard-library lookups, key masking | `lua tests/mutate_test.lua` | 21 / 21 |
| ProxifyLocal, with and without other options | `lua tests/proxify_test.lua` | 31 / 31 |
| Anti-tamper and anti-debug | `lua tests/protection_test.lua` | 31 / 33 |
| Lune differential suite (10 programs x option sets, plus an env-logger check) | `sh tests/run_runtime.sh <runtime> lua` | 86 / 86 on Lune |

`protection_test.lua` has two known failing checks, "bytecode-check prefix found
in the output" and "anti-debug build has the bytecode-hash prefix". They are
open issues, not regressions in the current build. The mid-run debugger-attach
check is timing-sensitive and can fail intermittently.

`difftest.lua` is a helper module loaded by `run_tests.lua`, not a standalone
suite.

## Limitations

**What the obfuscation does not protect against:**

- The decode key and the ciphertext are both in the output, so anyone with the
  file can decrypt the constant pool.
- Handler bodies are ordinary Lua. A reader who knows the VM design can find the
  dispatch, the register table, and the instruction pointer, whatever they are
  named. Per-build numbering, seeds, and decoys make each build a separate
  analysis job; they do not remove the semantics from the code.
- The numeric masks are arithmetic, so constant folding by a deobfuscator can
  undo them. The field-decoding arithmetic is visible in the dispatcher.
- The cipher is a custom construction, not a standard or reviewed one. Per-build
  constants remove fixed values, but no cryptographic strength is claimed.
- Anything the program needs to run can be observed by dynamic analysis. Process
  memory cannot be fully protected in pure Lua, and the cache flush only
  shortens how long decoded constants stay in memory.
- This is not a full anti-tamper, anti-debugger, or VM-detection suite. There is
  no self-modifying code. The goal is to raise the cost of casual copy-paste theft.
- Some names must stay literal because Lua or the runtimes require them: metamethod
  keys such as `__index`, the env-logger checks, and the live getters.

**Known open issues:**

- `protection_test.lua` fails two checks, "bytecode-check prefix found in the
  output" and "anti-debug build has the bytecode-hash prefix". These are open
  issues, not regressions in the current build.
- The mid-run debugger-attach check is timing-sensitive and can fail
  intermittently.

**Runtime and Luau gaps:**

- On Lute only, a global the program writes stays private to the program.
  Modules or host code that read globals through the real environment won't see
  it. Lune and Lua keep full global semantics.
- Lune has no `debug` library, so the hook-based anti-debug checks do nothing
  there. The env-logger check still runs.
- Luau `__iter` iteration is not handled; tables with `__iter` use the `next`-based
  default. Attributes on anonymous function expressions are not handled. The
  `buffer` type is not specifically tested.

**Performance:**

- Interpreted, not compiled. Expect noticeably slower execution than plain Lua.
  Suitable for game scripts and plugins, not hot numeric loops.
- `--proxify` makes register-heavy code 1.4x to 3.4x slower.

**Scope:**

- Input must be valid Lua 5.1 or Luau source. Compiled `.luac` bytecode is not
  supported.
- Error messages point at the bundled VM file and line, not at your source.
- A small script builds to about 165 KB at the default settings, mostly the VM
  engine, the decoder, and the stdlib table. Use `--no-minify` to inspect the
  scaffolding.

## Files

The entry points are `xenonsec.lua` (CLI) and `obfuscate.lua`, which forwards to
`src/obfuscator.lua` for the public `obfuscate(src, name, opts)` API. See
[Project layout](#project-layout) for the modules.
