import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { Transport, MAX_FRAME_BYTES, resolveSocketPath } from '../src/transport.mjs';
import { fakeServer, frame } from './helpers.mjs';

test('分片、粘包与乱序响应按请求 id 匹配', async t => {
  const received = [];
  const fake = await fakeServer(t, ({ request, socket }) => {
    received.push(request);
    if (received.length !== 3) return;
    const bytes = Buffer.concat([...received].reverse().map(item => frame({ jsonrpc: '2.0', id: item.id, result: item.method })));
    socket.write(bytes.subarray(0, 2));
    setTimeout(() => { socket.write(bytes.subarray(2, 9)); socket.write(bytes.subarray(9)); }, 5);
  });
  const transport = new Transport(fake);
  t.after(() => transport.close());
  assert.deepEqual(await Promise.all(['one', 'two', 'three'].map(method => transport.request(method))), ['one', 'two', 'three']);
  assert.equal(transport.pending.size, 0);
});

test('请求超时带 code 与 timeout 标记', async t => {
  const fake = await fakeServer(t, () => {});
  const transport = new Transport(fake);
  t.after(() => transport.close());
  await assert.rejects(transport.request('slow', {}, { timeoutMs: 20 }), { code: 'ETIMEDOUT', timeout: true });
  assert.equal(transport.pending.size, 0);
});

test('ping 包含版本、客户端身份和 pid', async t => {
  const fake = await fakeServer(t);
  const transport = new Transport(fake);
  t.after(() => transport.close());
  assert.equal((await transport.ping()).apiVersion, 'SwiftCUA-IPC-1');
  assert.deepEqual(fake.requests[0].params, { clientApiVersion: 'SwiftCUA-IPC-1', clientName: '@swiftcua/sky', clientVersion: '0.1.0', pid: process.pid });
});

test('连接中断拒绝所有 pending', async t => {
  const fake = await fakeServer(t, ({ socket }) => socket.destroy());
  const transport = new Transport(fake);
  t.after(() => transport.close());
  const responses = await Promise.allSettled([transport.request('one'), transport.request('two')]);
  assert.ok(responses.every(item => item.status === 'rejected' && item.reason.code === 'ECONNCLOSED'));
});

test('超大入站帧立即拒绝', async t => {
  const fake = await fakeServer(t, ({ socket }) => {
    const header = Buffer.alloc(4); header.writeUInt32LE(MAX_FRAME_BYTES + 1); socket.write(header);
  });
  const transport = new Transport(fake);
  t.after(() => transport.close());
  await assert.rejects(transport.request('large'), { code: 'EMSGSIZE' });
});

test('超大出站帧与无效 JSON 拒绝', async t => {
  const fake = await fakeServer(t, ({ socket }) => socket.write(Buffer.from([1, 0, 0, 0, 123])));
  const transport = new Transport(fake);
  t.after(() => transport.close());
  await assert.rejects(transport.request('large', { text: 'x'.repeat(MAX_FRAME_BYTES) }), { code: 'EMSGSIZE' });
  await assert.rejects(transport.request('bad'), { code: 'EPROTOCOL' });
});

test('路径支持显式参数、环境覆盖与波浪号', () => {
  const originalSocket = process.env.SWIFTCUA_SOCKET;
  const originalHome = process.env.SWIFTCUA_HOME;
  try {
    delete process.env.SWIFTCUA_SOCKET; delete process.env.SWIFTCUA_HOME;
    assert.equal(resolveSocketPath(), path.join(os.homedir(), 'Library/Application Support/SwiftCUA/IPC/computeruse.sock'));
    process.env.SWIFTCUA_HOME = '~/custom';
    assert.equal(resolveSocketPath(), path.join(os.homedir(), 'custom/IPC/computeruse.sock'));
    assert.equal(resolveSocketPath({ home: '/tmp/home' }), '/tmp/home/IPC/computeruse.sock');
    process.env.SWIFTCUA_SOCKET = '/tmp/env.sock';
    assert.equal(resolveSocketPath({ home: '/tmp/home' }), '/tmp/env.sock');
    assert.equal(resolveSocketPath({ socketPath: '/tmp/explicit.sock' }), '/tmp/explicit.sock');
  } finally {
    if (originalSocket === undefined) delete process.env.SWIFTCUA_SOCKET; else process.env.SWIFTCUA_SOCKET = originalSocket;
    if (originalHome === undefined) delete process.env.SWIFTCUA_HOME; else process.env.SWIFTCUA_HOME = originalHome;
  }
});
