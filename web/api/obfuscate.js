"use strict";
// XenonSec web playground: POST /api/obfuscate
//
// Body (JSON):  { "code": "<lua source>", "options": { ...see OPTION_SPEC } }
// Reply (JSON): { "output": "<obfuscated lua>", "bytes": n, "ms": n }
//            or { "error": "<message>" } with a 4xx/5xx status.
//
// The obfuscator runs inside the bundled Lune runtime (bin/lune.gz). The
// user's code is written to a private temp directory as a file and is only
// parsed and transformed, never executed. The temp directory is removed
// after every request.

const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { spawn } = require("child_process");
const { readZip } = require("../lib/zip");
const { linkArchive } = require("../lib/link");

const ROOT = path.join(__dirname, "..");
const RUNNER = path.join(ROOT, "lib", "runner.luau");
const LIB_DIR = path.join(ROOT, "lib", "xenonsec");

const MAX_BODY_BYTES = 1536 * 1024;  // request body (source + options, JSON-escaped)
const MAX_SOURCE_BYTES = 512 * 1024; // Lua source accepted
// Output is about 14x the input (VM engine + ciphertext), so a 512 KB script
// makes ~7.6 MB of text. The reply is therefore gzipped, and the gzipped size
// must stay under Vercel's 4.5 MB response limit. MAX_RAW_OUTPUT_BYTES only
// guards memory.
const MAX_COMPRESSED_BYTES = 4 * 1024 * 1024;
const MAX_RAW_OUTPUT_BYTES = 16 * 1024 * 1024;
// A .zip upload. Sent as base64 inside the JSON body, so about 1.33x its size.
const MAX_ARCHIVE_BYTES = 1024 * 1024;
const MAX_ARCHIVE_ENTRIES = 256;
const MAX_ENTRY_NAME = 256;
const TIMEOUT_MS = 25 * 1000;
const MAX_CONCURRENT = 4;            // per warm instance

// Option name -> validator. Only these keys reach the obfuscator.
const BOOL = (v) => typeof v === "boolean";
const OPTION_SPEC = {
	luau: BOOL,
	antiDebug: BOOL,
	proxify: BOOL,
	minify: BOOL,
	flushConsts: BOOL,
	antiTamper: BOOL,
	fold: BOOL,
	ssa: BOOL,
	localizeGlobals: BOOL,
	strength: (v) => Number.isInteger(v) && v >= 1 && v <= 4,
	junkRate: (v) => v === null || (typeof v === "number" && v >= 0 && v <= 1),
	decoyConstants: (v) => v === null || (Number.isInteger(v) && v >= 0 && v <= 200),
};

let luneBinary = null;
let inFlight = 0;

class HttpError extends Error {
	constructor(status, message) {
		super(message);
		this.status = status;
	}
}

function resolveLune() {
	if (process.env.XENONSEC_LUNE_BIN) return process.env.XENONSEC_LUNE_BIN;
	if (luneBinary && fs.existsSync(luneBinary)) return luneBinary;
	// Vercel's function filesystem is read-only except /tmp, and binaries
	// may lose their execute bit in the bundle, so unpack to /tmp at runtime.
	const dir = path.join(os.tmpdir(), "xenonsec-lune");
	const dest = path.join(dir, "lune");
	fs.mkdirSync(dir, { recursive: true });
	const packed = fs.readFileSync(path.join(ROOT, "bin", "lune.gz"));
	fs.writeFileSync(dest, zlib.gunzipSync(packed), { mode: 0o755 });
	luneBinary = dest;
	return dest;
}

function readBody(req) {
	return new Promise((resolve, reject) => {
		let size = 0;
		const chunks = [];
		req.on("data", (chunk) => {
			size += chunk.length;
			if (size > MAX_BODY_BYTES) {
				reject(new HttpError(413, "Request is too large."));
				req.destroy();
				return;
			}
			chunks.push(chunk);
		});
		req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
		req.on("error", () => reject(new HttpError(400, "Could not read request.")));
	});
}

function parseRequest(text) {
	let data;
	try {
		data = JSON.parse(text);
	} catch (_) {
		throw new HttpError(400, "Request body must be JSON.");
	}
	if (!data || typeof data !== "object") throw new HttpError(400, "Request body must be an object.");

	// Exactly one of `code` (one script) or `archive` (a .zip, base64). With an
	// archive, `entry` names the file that runs last (default main.lua).
	const hasCode = data.code !== undefined;
	const hasArchive = data.archive !== undefined;
	if (hasCode === hasArchive) {
		throw new HttpError(400, "Send either code or archive, not both and not neither.");
	}

	let code = null;
	let archive = null;
	let entry = null;
	if (hasCode) {
		code = data.code;
		if (typeof code !== "string" || code.trim() === "") {
			throw new HttpError(400, "Paste some Lua code first.");
		}
		if (Buffer.byteLength(code, "utf8") > MAX_SOURCE_BYTES) {
			throw new HttpError(413, `Source is over ${MAX_SOURCE_BYTES / 1024} KB. Split the script or remove unused code.`);
		}
	} else {
		const b64 = data.archive;
		if (typeof b64 !== "string" || b64.length === 0) throw new HttpError(400, "The archive is empty.");
		if (!/^[A-Za-z0-9+/=\r\n]*$/.test(b64)) throw new HttpError(400, "The archive is not valid base64.");
		archive = Buffer.from(b64, "base64");
		if (archive.length > MAX_ARCHIVE_BYTES) {
			throw new HttpError(413, `The .zip is over ${MAX_ARCHIVE_BYTES / 1024 / 1024} MB.`);
		}
		entry = data.entry === undefined || data.entry === null ? "main.lua" : data.entry;
		if (typeof entry !== "string" || entry.length === 0 || entry.length > MAX_ENTRY_NAME) {
			throw new HttpError(400, "entry must be the file name of the main script inside the archive.");
		}
	}

	const rawOpts = data.options == null ? {} : data.options;
	if (typeof rawOpts !== "object" || Array.isArray(rawOpts)) {
		throw new HttpError(400, "options must be an object.");
	}
	const options = {};
	for (const key of Object.keys(rawOpts)) {
		const check = OPTION_SPEC[key];
		if (!check) throw new HttpError(400, `Unknown option: ${key}`);
		if (!check(rawOpts[key])) throw new HttpError(400, `Invalid value for ${key}.`);
		options[key] = rawOpts[key];
	}
	return { code, archive, entry, options };
}

// Turns a .zip into one Lua source (lib/link.js). Problems with the archive are
// the user's, so they come back as 400 with the reason.
function linkUpload(archive, entry) {
	let files;
	try {
		files = readZip(archive, { maxEntries: MAX_ARCHIVE_ENTRIES, maxUnpackedBytes: MAX_SOURCE_BYTES }).files;
	} catch (err) {
		throw new HttpError(400, err.message);
	}
	let code;
	try {
		code = linkArchive(files, entry);
	} catch (err) {
		throw new HttpError(400, err.message);
	}
	if (Buffer.byteLength(code, "utf8") > MAX_SOURCE_BYTES) {
		throw new HttpError(413, `The linked source is over ${MAX_SOURCE_BYTES / 1024} KB. Split the project or remove unused code.`);
	}
	return code;
}

function runLune(workDir, optsFile, inFile, outFile) {
	return new Promise((resolve, reject) => {
		const child = spawn(
			resolveLune(),
			["run", RUNNER, "--", LIB_DIR, inFile, outFile, optsFile],
			{ cwd: workDir, env: { PATH: process.env.PATH || "/usr/bin:/bin" }, stdio: ["ignore", "pipe", "pipe"] }
		);
		let stdout = "";
		let stderr = "";
		const timer = setTimeout(() => {
			child.kill("SIGKILL");
			reject(new HttpError(504, "Obfuscation took too long. Try a smaller script or lower strength."));
		}, TIMEOUT_MS);
		child.stdout.on("data", (d) => { if (stdout.length < 16384) stdout += d; });
		child.stderr.on("data", (d) => { if (stderr.length < 16384) stderr += d; });
		child.on("error", (err) => { clearTimeout(timer); reject(err); });
		child.on("close", (code) => {
			clearTimeout(timer);
			if (code === 0) return resolve();
			const line = stdout.split("\n").find((l) => l.startsWith("ERR ")) || "";
			// Keep the first line of the obfuscator's own error message.
			const message = line ? line.slice(4).split("\n")[0] : (stderr.split("\n")[0] || "Unknown failure");
			reject(new HttpError(422, "XenonSec could not obfuscate this script: " + message));
		});
	});
}

async function obfuscate({ code, options }) {
	const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "xs-job-"));
	try {
		const inFile = path.join(workDir, "input.lua");
		const outFile = path.join(workDir, "output.lua");
		const optsFile = path.join(workDir, "opts.json");
		fs.writeFileSync(inFile, code, "utf8");
		fs.writeFileSync(optsFile, JSON.stringify(options), "utf8");

		const started = Date.now();
		await runLune(workDir, optsFile, inFile, outFile);
		const output = fs.readFileSync(outFile, "utf8");
		const bytes = Buffer.byteLength(output, "utf8");
		if (bytes > MAX_RAW_OUTPUT_BYTES) {
			throw new HttpError(413, "The obfuscated output is too large to return. Use a smaller script.");
		}
		return { output, bytes, ms: Date.now() - started };
	} finally {
		fs.rmSync(workDir, { recursive: true, force: true });
	}
}

function send(res, status, payload) {
	res.statusCode = status;
	res.setHeader("content-type", "application/json; charset=utf-8");
	res.setHeader("cache-control", "no-store");
	res.end(JSON.stringify(payload));
}

module.exports = async function handler(req, res) {
	if (req.method !== "POST") {
		res.setHeader("allow", "POST");
		return send(res, 405, { error: "Use POST." });
	}
	if (inFlight >= MAX_CONCURRENT) {
		res.setHeader("retry-after", "2");
		return send(res, 429, { error: "The playground is busy. Try again in a moment." });
	}
	inFlight++;
	try {
		// Vercel may hand over an already-parsed body; otherwise read the stream.
		let text;
		if (typeof req.body === "string") text = req.body;
		else if (req.body && typeof req.body === "object") text = JSON.stringify(req.body);
		else text = await readBody(req);
		const parsed = parseRequest(text);
		const code = parsed.archive ? linkUpload(parsed.archive, parsed.entry) : parsed.code;
		const result = await obfuscate({ code, options: parsed.options });
		const gz = zlib.gzipSync(Buffer.from(result.output, "utf8"), { level: 6 });
		if (gz.length > MAX_COMPRESSED_BYTES) {
			throw new HttpError(413, "The obfuscated output is too large to return. Use a smaller script.");
		}
		// Success: the body is the gzipped Lua text itself. The browser decodes
		// the gzip transparently. Metadata goes in headers.
		res.statusCode = 200;
		res.setHeader("content-type", "text/plain; charset=utf-8");
		res.setHeader("content-encoding", "gzip");
		res.setHeader("cache-control", "no-store");
		res.setHeader("x-xenonsec-bytes", String(result.bytes));
		res.setHeader("x-xenonsec-gzip", String(gz.length));
		res.setHeader("x-xenonsec-ms", String(result.ms));
		res.end(gz);
		return;
	} catch (err) {
		if (err instanceof HttpError) return send(res, err.status, { error: err.message });
		console.error("obfuscate failed:", err);
		return send(res, 500, { error: "Something went wrong on the server." });
	} finally {
		inFlight--;
	}
};
