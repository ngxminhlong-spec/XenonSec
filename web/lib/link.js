"use strict";
// Links the .lua/.luau files of an archive into one Lua source string.
//
//   lib/util.lua  becomes a module named "lib.util" (dots, like Lua's require)
//   main.lua      is the entry point: its code runs last, at the top level
//
// Each module is a function. The linked file defines `require` before any
// module runs, so require("lib.util") and require("lib/util") both find the
// module. A module runs once, and its result is cached (like Lua's require).
// A require of a name that isn't in the archive fails at run time with a clear
// error. Names computed at run time can't be checked here.

const MODULE_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/;

function moduleName(path) {
  const dotted = path.replace(/\.(lua|luau)$/i, "").split("/").join(".");
  if (!MODULE_NAME_RE.test(dotted)) {
    throw new Error(
      `The file ${JSON.stringify(path)} can't be used as a module name. ` +
      "Use letters, digits and _ only (folders are joined with dots)."
    );
  }
  return dotted;
}

// Removes a UTF-8 BOM and a leading #! line, which Lua doesn't allow inside a
// module function. The line is replaced by an empty one, so line numbers stay.
function cleanSource(text) {
  let s = text.replace(/^﻿/, "");
  if (s.startsWith("#")) {
    const nl = s.indexOf("\n");
    s = nl < 0 ? "" : s.slice(nl);
  }
  return s;
}

const RUNTIME = [
  "local __xs_mods, __xs_done = {}, {}",
  "local function __xs_require(name)",
  '  name = (name:gsub("/", "."))',
  "  local c = __xs_done[name]",
  "  if c ~= nil then return c end",
  "  local f = __xs_mods[name]",
  '  if not f then error("module \'" .. name .. "\' is not in the archive", 2) end',
  "  local r = f(name)",
  "  if r == nil then r = true end",
  "  __xs_done[name] = r",
  "  return r",
  "end",
  "local require = __xs_require",
].join("\n");

// files: [{ name, data: Buffer }], entry: archive path of the entry file
function linkArchive(files, entry) {
  const entryFile = files.find((f) => f.name === entry);
  if (!entryFile) throw new Error(`The entry file ${JSON.stringify(entry)} is not in the archive.`);

  const parts = [RUNTIME];
  const seen = new Set();
  for (const f of files) {
    if (f === entryFile) continue;
    const name = moduleName(f.name);
    if (seen.has(name)) throw new Error(`Two files would both be the module ${JSON.stringify(name)}.`);
    seen.add(name);
    const body = cleanSource(f.data.toString("utf8"));
    parts.push(`__xs_mods[${JSON.stringify(name)}] = function(...)\n${body}\nend`);
  }
  parts.push(cleanSource(entryFile.data.toString("utf8")));
  return parts.join("\n") + "\n";
}

module.exports = { linkArchive, moduleName };
