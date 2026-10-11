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

const ROOT = path.join(__dirname, "..");
const RUNNER = path.join(ROOT, "lib", "runner.luau");
const LIB_DIR = path.join(ROOT, "lib", "xenonsec");

const MAX_BODY_BYTES = 160 * 1024;   // request body (source + options)
const MAX_SOURCE_BYTES = 100 * 1024; // Lua source accepted
const MAX_OUTPUT_BYTES = 4 * 1024 * 1024; // keep replies under the platform's limit
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

	const code = data.code;
	if (typeof code !== "string" || code.trim() === "") {
		throw new HttpError(400, "Paste some Lua code first.");
	}
	if (Buffer.byteLength(code, "utf8") > MAX_SOURCE_BYTES) {
		throw new HttpError(413, `Source is over ${MAX_SOURCE_BYTES / 1024} KB. Split the script or remove unused code.`);
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
	return { code, options };
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
		if (Buffer.byteLength(output, "utf8") > MAX_OUTPUT_BYTES) {
			throw new HttpError(413, "The obfuscated output is too large to return. Use a smaller script.");
		}
		return { output, bytes: Buffer.byteLength(output, "utf8"), ms: Date.now() - started };
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
		const job = parseRequest(text);
		const result = await obfuscate(job);
		return send(res, 200, result);
	} catch (err) {
		if (err instanceof HttpError) return send(res, err.status, { error: err.message });
		console.error("obfuscate failed:", err);
		return send(res, 500, { error: "Something went wrong on the server." });
	} finally {
		inFlight--;
	}
};
