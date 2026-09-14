#!/usr/bin/env node
"use strict";

import { readFileSync } from "node:fs";

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function load(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    fail("cannot parse " + path + ": " + err.message);
  }
}

function resolveRef(root, ref) {
  if (!ref.startsWith("#/")) throw new Error("unsupported $ref " + ref);
  let cur = root;
  for (const part of ref.slice(2).split("/")) {
    cur = cur?.[part];
  }
  if (cur == null) throw new Error("unresolved $ref " + ref);
  return cur;
}

function typeOf(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  return typeof v;
}

function matchesType(v, t) {
  if (Array.isArray(t)) return t.some((one) => matchesType(v, one));
  if (t === "integer") return Number.isInteger(v);
  if (t === "number") return typeof v === "number" && Number.isFinite(v);
  if (t === "object") return typeOf(v) === "object";
  return typeOf(v) === t;
}

function validate(rootSchema, schema, value, path, root) {
  const R = root ?? rootSchema;
  if (schema.$ref) {
    validate(rootSchema, resolveRef(R, schema.$ref), value, path, R);
    return;
  }
  if (schema.const !== undefined && value !== schema.const) {
    throw new Error(path + ": expected const " + JSON.stringify(schema.const));
  }
  if (schema.enum && !schema.enum.includes(value)) {
    throw new Error(path + ": " + JSON.stringify(value) + " not in enum");
  }
  if (schema.type && !matchesType(value, schema.type)) {
    throw new Error(path + ": type " + typeOf(value) + " does not match " + schema.type);
  }
  if (typeof value === "number") {
    if (schema.minimum != null && value < schema.minimum) throw new Error(path + ": below minimum");
    if (schema.maximum != null && value > schema.maximum) throw new Error(path + ": above maximum");
  }
  if (typeof value === "string") {
    if (schema.minLength != null && value.length < schema.minLength) throw new Error(path + ": shorter than minLength");
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) {
      throw new Error(path + ": does not match " + schema.pattern);
    }
  }
  if (Array.isArray(value) && schema.items) {
    if (schema.minItems != null && value.length < schema.minItems) throw new Error(path + ": fewer than minItems");
    value.forEach((item, i) => validate(rootSchema, schema.items, item, path + "/" + i, R));
  }
  if (typeOf(value) === "object" && value) {
    for (const key of schema.required ?? []) {
      if (!Object.prototype.hasOwnProperty.call(value, key)) throw new Error(path + ": missing " + key);
    }
    const props = schema.properties ?? {};
    for (const [key, child] of Object.entries(value)) {
      if (props[key]) {
        validate(rootSchema, props[key], child, path + "/" + key, R);
      } else if (schema.additionalProperties === false) {
        throw new Error(path + ": unexpected property " + key);
      } else if (schema.additionalProperties && schema.additionalProperties !== true) {
        validate(rootSchema, schema.additionalProperties, child, path + "/" + key, R);
      }
    }
  }
}

const expectFail = process.argv.includes("--expect-fail");
const args = process.argv.filter((a) => a !== "--expect-fail").slice(2);
if (args.length !== 2) fail("usage: validate-schema.mjs <schema.json> <instance.json> [--expect-fail]");
const schema = load(args[0]);
const instance = load(args[1]);
try {
  validate(schema, schema, instance, "$");
  if (expectFail) fail(args[1] + " validated but a failure was required");
  console.log("ok " + args[1]);
} catch (err) {
  if (expectFail) {
    console.log("expected-fail " + args[1] + ": " + err.message);
    process.exit(0);
  }
  fail(args[1] + ": " + err.message);
}
