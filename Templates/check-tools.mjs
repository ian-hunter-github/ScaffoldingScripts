#!/usr/bin/env node
/**
 * Simple toolchain check.
 * Prints versions; does NOT fail if a tool is missing.
 * Provision/scaffold scripts decide what is required.
 */

import { execSync } from "node:child_process";

function run(cmd) {
  try {
    return execSync(cmd, { stdio: ["ignore", "pipe", "ignore"] })
      .toString()
      .trim();
  } catch {
    return "";
  }
}

function print(label, cmd) {
  const out = run(cmd);
  console.log(`${label}: ${out || "(not found)"}`);
}

console.log("=== Tool versions ===");
print("node", "node -v");
print("npm", "npm -v");
print("git", "git --version");
print("netlify", "netlify --version");
print("supabase", "supabase --version");
console.log("=====================");
