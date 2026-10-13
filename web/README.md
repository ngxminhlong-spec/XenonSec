# XenonSec Playground

A web page that runs the XenonSec obfuscator on a script you paste or upload.
It works on phones and desktops and is deployed on Vercel.

## How it works

```
browser (public/index.html)
   │  POST /api/obfuscate  { code, options }
   ▼
Vercel function (api/obfuscate.js)
   │  writes the script to a private temp folder
   │  runs  bin/lune  with  lib/runner.luau
   ▼
Lune runtime  ──►  lib/xenonsec/  (the obfuscator, unchanged)
   │
   ▼  gzipped Lua text + size headers → preview in the page, copy / download
```

- **Frontend** (`public/index.html`): one file with inline CSS and JS. No
  framework, no CDN, no build step. Layout is single column under 720 px and
  two columns above that. Inputs use 16 px text so iOS does not zoom.
- **API** (`api/obfuscate.js`): validates the request, runs the obfuscator in a
  per-request temp directory, and deletes that directory afterwards.
- **Runtime**: the obfuscator was written for Lua 5.1/5.3. The playground runs
  it on Lune (a Luau runtime) using `lib/runner.luau`, which supplies `dofile`
  and the source-location lookup the obfuscator uses. The obfuscator's own
  files are not modified.
- **Lune** is bundled as `bin/lune.gz` (gzipped, about 5 MB). On a cold start
  the function unpacks it to `/tmp` and marks it executable.

## Options

| UI control | API key | Notes |
|---|---|---|
| Luau syntax | `luau` | Needed for `+=`, `continue`, `//`, type annotations |
| Minify output | `minify` | Off keeps the VM readable (debugging only) |
| ProxifyLocal | `proxify` | Registers and captured locals in proxy objects; slower |
| Anti-debug | `antiDebug` | Can false-positive with profilers and IDEs |
| Anti-tamper | `antiTamper` | Checksum over the generated file |
| Flush constant cache | `flushConsts` | Clears decoded strings every 65536 steps |
| Constant folding | `fold` | |
| Value propagation | `ssa` | |
| Localize globals | `localizeGlobals` | |
| Strength | `strength` | 1–4 (decoy and clutter level) |
| Junk rate | `junkRate` | 0–1, `null` = auto |
| Decoy constants | `decoyConstants` | 0–200, `null` = auto |

Unknown keys and out-of-range values are rejected with HTTP 400.

## Zip projects

Open a `.zip` of several `.lua` files (up to 1 MB) instead of pasting one
script. The playground links them into one script first, then obfuscates that:

1. The archive is read in memory (`lib/zip.js`). Only stored and deflate
   entries are accepted. Encrypted entries, zip64, symbolic links, names with
   `..`, absolute paths or backslashes, and more than 256 entries are refused.
   Only `.lua` and `.luau` files are used; other files are skipped.
2. The files are linked (`lib/link.js`). Each file becomes a module named after
   its path (`lib/util.lua` is `lib.util`, and `require("lib/util")` also works).
   A module runs once and its result is cached. The entry file (default
   `main.lua`, set in the page) runs last.
3. The linked source must still fit the 512 KB source limit, and then the
   engine runs on it as usual.

A `require` of a name that isn't in the archive fails at run time with a clear
message. File names must use letters, digits and `_` (folders are joined with
dots).

API: send `archive` (the zip, base64) and `entry` (the entry file's path inside
the zip) in place of `code`. Send one or the other, not both.

Tests: `node --test web/test/archive_test.js` (needs `python3`, which builds the
test zips, and `texlua` on PATH). They build real zips, check the reader's refusals, and run
the linked output.

## Limits

| Limit | Value | Where |
|---|---|---|
| Source size (after linking, for zips too) | 512 KB | `MAX_SOURCE_BYTES` |
| Zip file size | 1 MB | `MAX_ARCHIVE_BYTES` |
| Zip entries | 256 | `MAX_ARCHIVE_ENTRIES` |
| Request body | 1.5 MB | `MAX_BODY_BYTES` |
| Reply size (gzipped) | 4 MB | `MAX_COMPRESSED_BYTES` (Vercel's response limit is 4.5 MB) |
| Output size (raw, memory guard) | 16 MB | `MAX_RAW_OUTPUT_BYTES` |
| Run time | 25 s (function limit 30 s) | `TIMEOUT_MS`, `vercel.json` |
| Concurrency | 4 jobs per warm instance | `MAX_CONCURRENT` |

The concurrency limit is per instance. Vercel can run several instances, and
the in-memory counter does not share state between them. There is no
per-user rate limit yet.

## Status codes

- `200` success: the body is the obfuscated Lua text, gzipped
  (`content-encoding: gzip`, `content-type: text/plain`). Browsers decompress it
  automatically. Headers carry the metadata: `x-xenonsec-bytes` (raw size),
  `x-xenonsec-gzip` (size on the wire) and `x-xenonsec-ms` (run time).
  Errors are still JSON: `{ "error": "..." }`.
- `400` bad JSON, empty code, unknown or invalid option, a bad zip (the reason is in `error`)
- `405` not POST
- `413` source or body too large
- `422` the obfuscator rejected the script (syntax error, etc.)
- `429` too many jobs running on this instance
- `504` run exceeded the time limit
- `500` unexpected server error (details go to the function log only)

## Local testing

```bash
# Run the API directly with the system Lune binary
XENONSEC_LUNE_BIN=/path/to/lune node -e '
  const http = require("http");
  const api = require("./api/obfuscate.js");
  http.createServer(api).listen(8787);
'

# In another shell
curl -s -X POST localhost:8787/api/obfuscate \
  -H 'content-type: application/json' \
  -d '{"code":"print(1+1)","options":{"strength":2}}'
```

The page can be previewed with any static server that also routes
`/api/obfuscate` to the handler. Vercel CLI (`vercel dev`) does both.

## Deploy

The project is connected to this repository. Vercel uses:

- root directory: `web`
- output directory: `public`
- no build command (everything is prebuilt)

Pushes to the connected branch create preview deployments; the production
branch creates the production deployment.

## Privacy and safety

- Scripts are sent to the server only to be obfuscated. Each request uses a
  temp folder that is removed afterwards. The playground does not write
  scripts to a database or log their contents.
- The obfuscator parses the script and never executes it.
- Obfuscation makes code harder to read. It does not make it secret. Do not put
  passwords, tokens or API keys in client-side code.
