import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import readline from 'node:readline';
import { MCPServer, parseArgs } from '../src/mcp-server.mjs';
import { fakeServer } from './helpers.mjs';

function request(method, params, id = 1) { return { jsonrpc: '2.0', id, method, params }; }
function content(response) { return response.content[0].text; }

test('MCP 初始化、工具 schema、JS 计算与 await sky.list_apps', async t => {
  const fake = await fakeServer(t, ({ request, reply }) => reply(request.method === 'ping' ? { apiVersion: 'SwiftCUA-IPC-1' } : { apps: [{ id: 'com.test', windows: [] }] }));
  const server = new MCPServer({ ...fake, logger() {} });
  t.after(() => server.close());
  const initialization = await server.handle(request('initialize', { protocolVersion: '2024-11-05' }));
  assert.equal(initialization.result.protocolVersion, '2024-11-05');
  assert.deepEqual(initialization.result.capabilities.tools, {});
  const tools = (await server.handle(request('tools/list'))).result.tools;
  assert.deepEqual(tools.map(tool => tool.name), ['js', 'js_reset', 'turn_ended']);
  assert.ok(tools.every(tool => tool.inputSchema.additionalProperties === false));
  const calculation = await server.handle(request('tools/call', { name: 'js', arguments: { code: 'return 1+1' } }));
  assert.equal(content(calculation.result), '2');
  const apps = await server.handle(request('tools/call', { name: 'js', arguments: { code: 'await sky.list_apps()' } }));
  assert.equal(JSON.parse(content(apps.result))[0].id, 'com.test');
  assert.equal(content(await server.callTool('js', { code: 'console.log("hello");\nconst value = 3;\nvalue + 4' })), 'hello\n7');
  assert.equal(content(await server.callTool('js', { code: 'await sleep(5); return cua === sky' })), 'true');
});

test('turn_ended 校验与 MCP 协议错误', async t => {
  const logs = [];
  const server = new MCPServer({ logger: line => logs.push(line) });
  t.after(() => server.close());
  for (const args of [{}, { hook_event_name: 'Stop', session_id: 's' }, { hook_event_name: ' ', session_id: 's', turn_id: 't' }, { hook_event_name: 'Stop', session_id: 's', turn_id: 't', extra: 1 }]) {
    const result = await server.handle(request('tools/call', { name: 'turn_ended', arguments: args }));
    assert.equal(result.error.code, -32602);
  }
  const args = { hook_event_name: 'SubagentStop', session_id: 's', turn_id: 't' };
  assert.equal(content(await server.callTool('turn_ended', args)), '{}');
  assert.match(logs[0], /SubagentStop/);
  for (const args of [{ code: 1 }, { code: '1', title: '' }, { code: '1', title: 'a'.repeat(81) }, { code: '1', timeout_ms: 0 }, { code: '1', timeout_ms: 1.2 }, { code: '1', extra: true }]) {
    assert.equal((await server.handle(request('tools/call', { name: 'js', arguments: args }))).error.code, -32602);
  }
  assert.equal((await server.handle(request('tools/call', { name: 'js_reset', arguments: null }))).error.code, -32602);
  assert.equal((await server.handle(request('tools/call', { name: 'unknown' }))).error.code, -32602);
  assert.equal((await server.handle(request('unknown'))).error.code, -32601);
  assert.equal((await server.handle({})).error.code, -32600);
  assert.equal(await server.handle({ jsonrpc: '2.0', method: 'notifications/initialized' }), null);
});

test('持久全局状态与 js_reset', async t => {
  const server = new MCPServer();
  t.after(() => server.close());
  await server.callTool('js', { code: 'globalThis.answer = 42; return answer' });
  assert.equal(content(await server.callTool('js', { code: 'answer' })), '42');
  assert.equal(content(await server.callTool('js_reset')), '{}');
  assert.equal(content(await server.callTool('js', { code: 'typeof answer' })), 'undefined');
});

test('VM 不暴露 require/import/process/文件写入能力或宿主构造器', async t => {
  const fake = await fakeServer(t, ({ request, reply, error }) => {
    if (request.method === 'ping') reply({ apiVersion: 'SwiftCUA-IPC-1' });
    else if (request.method === 'getAppState') error(-32001, 'Denied');
    else reply({ apps: [{ id: 'com.test', windows: [] }] });
  });
  const server = new MCPServer(fake);
  t.after(() => server.close());
  assert.deepEqual(JSON.parse(content(await server.callTool('js', { code: '[typeof process, typeof require, typeof Buffer, typeof fetch, typeof __bridge]' }))), Array(5).fill('undefined'));
  for (const code of [
    'require("node:fs")',
    'await import("node:fs")',
    'try { await import("node:fs"); } catch(e) { return e.constructor.constructor("return process")().pid; }',
    'import fs from "node:fs"',
    'process.getBuiltinModule("fs")',
    'globalThis.constructor.constructor("return process")()',
    'console.log.constructor("return process")()',
    'sky.list_apps.constructor("return process")()',
    'sleep.constructor("return process")()',
    '(await sky.list_apps()).constructor.constructor("return process")()',
    'try { await sky.get_app_state({app:"com.test"}); } catch(e) { return e.constructor.constructor("return process")(); }',
    'await sky.list_apps({get app() { return console.log.constructor("return process")(); }})',
  ]) {
    const result = await server.callTool('js', { code });
    assert.equal(result.isError, true, code + ': ' + content(result));
  }
  assert.equal(content(await server.callTool('js', { code: '2 + 2' })), '4');
});

test('同步循环、await 后循环和永不完成的 Promise 都会超时', async t => {
  const server = new MCPServer();
  t.after(() => server.close());
  for (const code of ['while (true) {}', 'await sleep(1); while (true) {}', 'await new Promise(() => {})']) {
    const result = await server.callTool('js', { code, timeout_ms: 150 });
    assert.equal(result.isError, true);
    assert.match(content(result), /超时|timed out/);
    assert.equal(content(await server.callTool('js', { code: 'return 2' })), '2');
  }
});

test('输出截断不超过 25000 字符', async t => {
  const server = new MCPServer();
  t.after(() => server.close());
  const result = await server.callTool('js', { code: 'console.log("x".repeat(40000)); return "y".repeat(40000)' });
  assert.equal(content(result).length, 25000);
});

test('stdio 子进程按行读写，stdout 只有 JSON-RPC', async t => {
  const fake = await fakeServer(t, ({ request, reply }) => reply(request.method === 'ping' ? { apiVersion: 'SwiftCUA-IPC-1' } : { apps: [{ id: 'stdio.test' }] }));
  const child = spawn(process.execPath, [new URL('../bin/mcp.mjs', import.meta.url).pathname, '--socket', fake.socketPath], { stdio: ['pipe', 'pipe', 'pipe'] });
  t.after(() => { if (child.exitCode === null) child.kill(); });
  const exited = once(child, 'exit');
  let stderr = '';
  child.stderr.setEncoding('utf8'); child.stderr.on('data', chunk => { stderr += chunk; });
  const lines = readline.createInterface({ input: child.stdout });
  const responses = new Map();
  lines.on('line', line => {
    const message = JSON.parse(line);
    responses.get(message.id)?.(message);
  });
  function rpc(id, method, params) {
    return new Promise(resolve => { responses.set(id, resolve); child.stdin.write(JSON.stringify(request(method, params, id)) + '\n'); });
  }
  assert.equal((await rpc(1, 'initialize')).result.serverInfo.name, 'swiftcua-mcp');
  assert.equal((await rpc(2, 'tools/list')).result.tools.length, 3);
  assert.equal(content((await rpc(3, 'tools/call', { name: 'js', arguments: { code: 'return 1+1' } })).result), '2');
  assert.equal(JSON.parse(content((await rpc(4, 'tools/call', { name: 'js', arguments: { code: 'await sky.list_apps()' } })).result))[0].id, 'stdio.test');
  await rpc(5, 'tools/call', { name: 'turn_ended', arguments: { hook_event_name: 'Stop', session_id: 's', turn_id: 't' } });
  child.stdin.end();
  assert.equal((await exited)[0], 0);
  assert.match(stderr, /turn_ended/);
});

test('命令行参数拒绝缺值和未知选项', () => {
  assert.deepEqual(parseArgs(['--socket', '/tmp/a.sock', '--home', '/tmp/home']), { socketPath: '/tmp/a.sock', home: '/tmp/home' });
  assert.throws(() => parseArgs(['--socket']));
  assert.throws(() => parseArgs(['--unknown']));
});
