import net from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import path from 'node:path';

export function frame(value) {
  const payload = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(payload.length);
  return Buffer.concat([header, payload]);
}

export async function fakeServer(t, handler) {
  // macOS Unix socket 路径长度有限，使用短路径且不接触真实服务。
  const directory = await mkdtemp('/tmp/swiftcua-js-');
  const socketPath = path.join(directory, 'test.sock');
  const sockets = new Set();
  const requests = [];
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on('error', () => {});
    socket.on('close', () => sockets.delete(socket));
    let buffer = Buffer.alloc(0);
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 4 && buffer.length >= buffer.readUInt32LE(0) + 4) {
        const length = buffer.readUInt32LE(0);
        const request = JSON.parse(buffer.subarray(4, 4 + length));
        buffer = buffer.subarray(4 + length);
        requests.push(request);
        const reply = result => socket.write(frame({ jsonrpc: '2.0', id: request.id, result }));
        const error = (code, message, data) => socket.write(frame({ jsonrpc: '2.0', id: request.id, error: { code, message, data } }));
        if (handler) handler({ request, socket, reply, error });
        else reply(request.method === 'ping' ? { apiVersion: 'SwiftCUA-IPC-1' } : {});
      }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    // 删除前验证绝对目标是本测试刚创建的目录。
    if (path.dirname(directory) !== '/tmp' || !path.basename(directory).startsWith('swiftcua-js-')) throw new Error('拒绝清理非测试目录');
    await rm(directory, { recursive: true, force: true });
  });
  return { socketPath, requests };
}
