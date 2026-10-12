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

## Limits

| Limit | Value | Where |
|---|---|---|
| Source size | 512 KB | `MAX_SOURCE_BYTES` |
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
- `400` bad JSON, empty code, unknown or invalid option
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
