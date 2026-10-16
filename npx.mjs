#!/usr/bin/env node
// npx agent-deck             install or update
// npx agent-deck uninstall   remove it
import { execSync } from "node:child_process";

if (process.platform !== "darwin") {
  console.error("Agent Deck is a macOS app.");
  process.exit(1);
}
const script = process.argv[2] === "uninstall" ? "uninstall.sh" : "install.sh";
try {
  execSync(`curl -fsSL https://raw.githubusercontent.com/aadilkadiwal/agent-deck/main/${script} | bash`,
           { stdio: "inherit", shell: "/bin/bash" });
} catch (err) {
  process.exit(err.status || 1);
}
