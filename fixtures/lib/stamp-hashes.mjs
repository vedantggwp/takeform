#!/usr/bin/env node
"use strict";

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const fixtureDir = process.argv[2];
if (!fixtureDir) {
  console.error("usage: stamp-hashes.mjs <fixtureDir>");
  process.exit(2);
}

function walk(dir, acc = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) walk(p, acc);
    else acc.push(p);
  }
  return acc;
}

function sha256(path) {
  const h = createHash("sha256");
  h.update(readFileSync(path));
  return h.digest("hex");
}

const media = join(fixtureDir, "media");
const files = walk(media).sort();
const records = {};
for (const file of files) {
  const rel = relative(fixtureDir, file).split("\\").join("/");
  records[rel] = { sha256: sha256(file) };
}

const hashesPath = join(fixtureDir, "hashes.json");
const payload = {
  hashKind: "container",
  note: "Container sha256 of generated files. If a second generate differs, verify.sh switches this to decoded-av and records framemd5 plus audio md5.",
  files: records
};
writeFileSync(hashesPath, JSON.stringify(payload, null, 2) + "\n");

const manifestPath = join(fixtureDir, "manifest.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
for (const source of manifest.sources) {
  const rec = records[source.path];
  if (rec) source.sha256 = rec.sha256;
}
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
console.log("stamped " + files.length + " files in " + fixtureDir);
