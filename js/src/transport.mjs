import { EventEmitter } from 'node:events';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

export const MAX_FRAME_BYTES = 8 * 1024 * 1024;
export const API_VERSION = 'SwiftCUA-IPC-1';

function expandHome(value) {
  return value === '~' ? os.homedir() : value.startsWith('~/') ? path.join(os.homedir(), value.slice(2)) : value;
}

export function resolveSocketPath({ socketPath, home } = {}) {
  const socket = socketPath || process.env.SWIFTCUA_SOCKET;
  if (socket) return path.resolve(expandHome(socket));
  const root = home || process.env.SWIFTCUA_HOME || path.join(os.homedir(), 'Library/Application Support/SwiftCUA');
  return path.resolve(expandHome(root), 'IPC/computeruse.sock');
}

function failure(message, code, extra = {}) {
  return Object.assign(new Error(message), { code, ...extra });
}

export class Transport extends EventEmitter {
  constructor(options = {}) {
    super();
    this.socketPath = resolveSocketPath(options);
    this.timeoutMs = options.timeoutMs ?? 30_000;
    this.pending = new Map();
    this.nextId = 1;
    this.socket = null;
    this.connecting = null;
    this.buffer = Buffer.alloc(0);
  }

  connect() {
    if (this.connecting) return this.connecting;
    if (this.socket && !this.socket.destroyed && !this.socket.connecting) return Promise.resolve(this);
    const socket = net.createConnection({ path: this.socketPath });
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    const connection = new Promise((resolve, reject) => {
      let connected = false;
      socket.once('connect', () => {
        connected = true;
        resolve(this);
        this.emit('connect');
      });
      socket.on('data', chunk => {
        if (this.socket === socket) this.#receive(chunk);
      });
      socket.on('error', cause => {
        const error = failure(`无法连接或读取 SwiftCUA socket ${this.socketPath}: ${cause.message}。请确认 SwiftCUA 服务已启动且 socket 路径正确。`, cause.code || 'ECONNECTION', { cause });
        reject(error);
        if (this.socket === socket) this.#rejectAll(error);
        this.emit('transportError', error);
      });
      socket.once('close', () => {
        const error = failure('SwiftCUA socket 已断开', 'ECONNCLOSED');
        if (!connected) reject(error);
        if (this.socket === socket) {
          this.socket = null;
          this.#rejectAll(error);
          this.emit('close');
        }
      });
    });
    this.connecting = connection;
    connection.then(() => { if (this.connecting === connection) this.connecting = null; }, () => {
      if (this.connecting === connection) this.connecting = null;
    });
    return connection;
  }

  async request(method, params = {}, { timeoutMs = this.timeoutMs } = {}) {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 2_147_483_647) {
      throw failure('timeoutMs 必须是 1..2147483647 的整数', 'EINVAL');
    }
    // 超时包含连接阶段，避免连接等待不计入预算。
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(failure(`SwiftCUA ${method} 在 ${timeoutMs}ms 后超时`, 'ETIMEDOUT', { timeout: true, timeoutMs }));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.connect().then(() => {
        if (!this.pending.has(id)) return;
        try { this.#send({ jsonrpc: '2.0', id, method, params }); }
        catch (error) { this.#settle(id, error); }
      }, error => this.#settle(id, error));
    });
  }

  async notify(method, params = {}) {
    await this.connect();
    await new Promise((resolve, reject) => {
      try { this.#send({ jsonrpc: '2.0', method, params }, error => error ? reject(error) : resolve()); }
      catch (error) { reject(error); }
    });
  }

  ping(options) {
    return this.request('ping', {
      clientApiVersion: API_VERSION,
      clientName: '@swiftcua/sky',
      clientVersion: '0.1.0',
      pid: process.pid,
    }, options);
  }

  close() {
    this.#rejectAll(failure('SwiftCUA 客户端已关闭', 'ECONNCLOSED'));
    this.socket?.destroy();
  }

  #send(message, callback) {
    const payload = Buffer.from(JSON.stringify(message), 'utf8');
    if (payload.length > MAX_FRAME_BYTES) throw failure('SwiftCUA 帧超过 8MiB 限制', 'EMSGSIZE');
    const header = Buffer.allocUnsafe(4);
    header.writeUInt32LE(payload.length);
    if (!this.socket || this.socket.destroyed) throw failure('SwiftCUA socket 未连接', 'ECONNCLOSED');
    this.socket.write(Buffer.concat([header, payload]), callback);
  }

  #receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    try {
      while (this.buffer.length >= 4) {
        const length = this.buffer.readUInt32LE(0);
        if (length > MAX_FRAME_BYTES) throw failure('SwiftCUA 帧超过 8MiB 限制', 'EMSGSIZE');
        if (this.buffer.length < length + 4) return;
        const message = JSON.parse(this.buffer.subarray(4, 4 + length).toString('utf8'));
        this.buffer = this.buffer.subarray(4 + length);
        if (!message || message.jsonrpc !== '2.0') throw failure('无效 JSON-RPC 响应', 'EPROTOCOL');
        if (message.method && message.id === undefined) { this.emit('notification', message); continue; }
        if (!('result' in message) && !message.error) throw failure('JSON-RPC 响应缺少 result/error', 'EPROTOCOL');
        if (message.error) {
          this.#settle(message.id, failure(message.error.message, message.error.code, { data: message.error.data }));
        } else this.#settle(message.id, null, message.result);
      }
    } catch (error) {
      if (!error.code) error.code = 'EPROTOCOL';
      this.#rejectAll(error);
      this.emit('transportError', error);
      this.socket?.destroy();
    }
  }

  #settle(id, error, value) {
    const item = this.pending.get(id);
    if (!item) return;
    clearTimeout(item.timer);
    this.pending.delete(id);
    if (error) item.reject(error); else item.resolve(value);
  }

  #rejectAll(error) {
    for (const id of this.pending.keys()) this.#settle(id, error);
  }
}
