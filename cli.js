#!/usr/bin/env node
// npm entry point.
//   autodeploy install      -> runs install.sh from this package (needs root)
//   autodeploy <anything>   -> forwards to the installed server CLI
"use strict";

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const HOME = process.env.AUTODEPLOY_HOME || "/opt/autodeploy";
const INSTALLED_CLI = path.join(HOME, "bin", "autodeploy");
const args = process.argv.slice(2);

function run(cmd, cmdArgs) {
  const res = spawnSync(cmd, cmdArgs, { stdio: "inherit" });
  if (res.error) {
    console.error(`autodeploy: ${res.error.message}`);
    process.exit(1);
  }
  process.exit(res.status === null ? 1 : res.status);
}

if (process.platform !== "linux") {
  console.error("autodeploy runs on a Linux server (Ubuntu/Debian).");
  process.exit(1);
}

if (args[0] === "install") {
  const installer = path.join(__dirname, "install.sh");
  const isRoot = typeof process.getuid === "function" && process.getuid() === 0;
  if (isRoot) run("bash", [installer, ...args.slice(1)]);
  run("sudo", ["bash", installer, ...args.slice(1)]);
}

if (args[0] === "--version" || args[0] === "-v") {
  console.log(require("./package.json").version);
  process.exit(0);
}

if (!fs.existsSync(INSTALLED_CLI)) {
  console.log("autodeploy is not installed on this server yet.\n");
  console.log("  sudo npx @ahmadkhatib/autodeploy install\n");
  console.log("Docs: https://github.com/ahmadkhatib1/autodeploy#readme");
  process.exit(args.length ? 1 : 0);
}

run(INSTALLED_CLI, args);
