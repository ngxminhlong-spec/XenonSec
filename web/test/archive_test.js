"use strict";
// Run with: node --test web/test/
// Builds real .zip files with the system zip/python, then checks the reader,
// the linker, and that the linked code really runs (under texlua, Lua 5.3).
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");
const { readZip } = require("../lib/zip");
const { linkArchive } = require("../lib/link");

const LIMITS = { maxEntries: 256, maxUnpackedBytes: 512 * 1024 };
const TEXLUA = process.env.TEXLUA || "texlua";

function tmpdir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "xs-test-"));
}

// Writes the given files with python's zipfile. `entries` is
// [{ name, data, mode? }]; mode sets the unix mode (e.g. symlink 0o120777).
function makeZip(entries, { stored = false } = {}) {
  const dir = tmpdir();
  const spec = path.join(dir, "spec.json");
  const out = path.join(dir, "a.zip");
  const items = entries.map((e) => ({
    name: e.name,
    data: Buffer.from(e.data).toString("base64"),
    mode: e.mode || 0o100644,
  }));
  fs.writeFileSync(spec, JSON.stringify(items));
  const py = `
import base64, json, sys, zipfile
items = json.load(open(sys.argv[1]))
method = zipfile.ZIP_STORED if sys.argv[3] == "1" else zipfile.ZIP_DEFLATED
with zipfile.ZipFile(sys.argv[2], "w", method) as z:
    for it in items:
        info = zipfile.ZipInfo(it["name"])
        info.external_attr = it["mode"] << 16
        info.compress_type = method
        z.writestr(info, base64.b64decode(it["data"]))
`;
  execFileSync("python3", ["-c", py, spec, out, stored ? "1" : "0"]);
  return fs.readFileSync(out);
}

function runLua(source) {
  const dir = tmpdir();
  const file = path.join(dir, "linked.lua");
  fs.writeFileSync(file, source);
  return execFileSync(TEXLUA, [file], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

test("reads deflated and stored entries and skips non-Lua files", () => {
  for (const stored of [false, true]) {
    const zip = makeZip(
      [
        { name: "main.lua", data: 'print("hi")\n' },
        { name: "lib/util.lua", data: "return 1\n" },
        { name: "README.md", data: "notes" },
      ],
      { stored }
    );
    const { files, skipped } = readZip(zip, LIMITS);
    assert.deepEqual(files.map((f) => f.name).sort(), ["lib/util.lua", "main.lua"]);
    assert.equal(skipped, 1);
    assert.equal(files.find((f) => f.name === "main.lua").data.toString(), 'print("hi")\n');
  }
});

test("linked project runs: modules, dotted and slash require, caching", () => {
  const zip = makeZip([
    { name: "lib/counter.lua", data: 'print("loading counter")\nlocal n = 0\nreturn { bump = function() n = n + 1; return n end }\n' },
    { name: "lib/greet.lua", data: 'local c = require("lib.counter")\nreturn function(name) return "hello " .. name .. " #" .. c.bump() end\n' },
    { name: "main.lua", data: 'local greet = require("lib/greet")\nlocal c = require("lib.counter")\nprint(greet("a"))\nprint(greet("b"))\nprint(c.bump())\n' },
  ]);
  const { files } = readZip(zip, LIMITS);
  const linked = linkArchive(files, "main.lua");
  assert.equal(runLua(linked), "loading counter\nhello a #1\nhello b #2\n3\n");
});

test("a require of a missing module fails at run time with a clear message", () => {
  const zip = makeZip([{ name: "main.lua", data: 'require("nope")\n' }]);
  const linked = linkArchive(readZip(zip, LIMITS).files, "main.lua");
  const file = path.join(tmpdir(), "missing.lua");
  fs.writeFileSync(file, linked);
  const r = spawnSync(TEXLUA, [file], { encoding: "utf8" });
  assert.notEqual(r.status, 0, "expected a failure");
  // texlua writes runtime errors to stdout when piped, so check both streams.
  assert.match(r.stdout + r.stderr, /module 'nope' is not in the archive/);
});

test("rejects path traversal and absolute names", () => {
  for (const name of ["../evil.lua", "lib/../../evil.lua", "/abs.lua", "a\\b.lua"]) {
    const zip = makeZip([{ name, data: "x" }, { name: "main.lua", data: "print(1)" }]);
    assert.throws(() => readZip(zip, LIMITS), /Unsafe file name|file name/, name);
  }
});

test("rejects symbolic links", () => {
  const zip = makeZip([
    { name: "link.lua", data: "main.lua", mode: 0o120777 },
    { name: "main.lua", data: "print(1)" },
  ]);
  assert.throws(() => readZip(zip, LIMITS), /Symbolic links/);
});

test("rejects archives over the unpacked size limit", () => {
  const big = "-- " + "x".repeat(300 * 1024) + "\n";
  const zip = makeZip([
    { name: "a.lua", data: big },
    { name: "b.lua", data: big },
    { name: "main.lua", data: "print(1)" },
  ]);
  assert.throws(() => readZip(zip, LIMITS), /over 512 KB/);
});

test("rejects archives with too many entries", () => {
  const entries = [];
  for (let i = 0; i < 5; i++) entries.push({ name: `m${i}.lua`, data: "x" });
  const zip = makeZip(entries);
  assert.throws(() => readZip(zip, { maxEntries: 4, maxUnpackedBytes: LIMITS.maxUnpackedBytes }), /more than 4 entries/);
});

test("rejects non-zip data and archives without Lua files", () => {
  assert.throws(() => readZip(Buffer.from("not a zip at all"), LIMITS), /not a valid .zip/);
  const onlyText = makeZip([{ name: "readme.txt", data: "hi" }]);
  assert.throws(() => readZip(onlyText, LIMITS), /no .lua or .luau files/);
});

test("rejects a missing entry file and invalid module names", () => {
  const zip = makeZip([{ name: "lib/util.lua", data: "return 1" }]);
  const { files } = readZip(zip, LIMITS);
  assert.throws(() => linkArchive(files, "main.lua"), /entry file "main.lua" is not in the archive/);

  const bad = makeZip([{ name: "my-lib.lua", data: "return 1" }, { name: "main.lua", data: "print(1)" }]);
  assert.throws(() => linkArchive(readZip(bad, LIMITS).files, "main.lua"), /can't be used as a module name/);
});

test("a shebang line and a BOM are removed from modules", () => {
  const zip = makeZip([
    { name: "lib/x.lua", data: "﻿#!/usr/bin/env lua\nreturn 42\n" },
    { name: "main.lua", data: 'print(require("lib.x"))\n' },
  ]);
  const linked = linkArchive(readZip(zip, LIMITS).files, "main.lua");
  assert.equal(runLua(linked), "42\n");
});
