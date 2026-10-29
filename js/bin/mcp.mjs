#!/usr/bin/env node
import { parseArgs, runStdio } from '../src/mcp-server.mjs';

try {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) process.stderr.write('用法: swiftcua-mcp [--socket <path>] [--home <dir>]\n');
  else await runStdio(options);
} catch (error) {
  process.stderr.write(`SwiftCUA MCP: ${error.message}\n`);
  process.exitCode = 1;
}
