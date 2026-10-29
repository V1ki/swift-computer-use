import { Worker } from 'node:worker_threads';
import readline from 'node:readline';
import { createSky } from './sky.mjs';

export const TOOLS = [
  { name: 'js', description: '在持久 SwiftCUA 上下文执行 JavaScript；提供 sky、cua、console、sleep 和 json。', inputSchema: {
    type: 'object', properties: {
      code: { type: 'string', description: 'JavaScript 代码，支持 await、末尾表达式或显式 return。' },
      title: { type: 'string', minLength: 1, maxLength: 80, description: '操作的简短标题。' },
      timeout_ms: { type: 'integer', minimum: 1, description: '执行截止时间（毫秒），默认 30000。' },
    }, required: ['code'], additionalProperties: false,
  } },
  { name: 'js_reset', description: '重建 JavaScript 上下文，清除用户全局变量。', inputSchema: {
    type: 'object', properties: {}, additionalProperties: false,
  } },
  { name: 'turn_ended', description: '记录 Stop、Interrupt 或 SubagentStop 等回合结束事件。', inputSchema: {
    type: 'object', properties: {
      hook_event_name: { type: 'string', minLength: 1 }, session_id: { type: 'string', minLength: 1 }, turn_id: { type: 'string', minLength: 1 },
    }, required: ['hook_event_name', 'session_id', 'turn_id'], additionalProperties: false,
  } },
];

const MAX_OUTPUT = 25_000;
const ALLOWED_METHODS = new Set(['list_apps', 'list_windows', 'get_app_state', 'click', 'press_key', 'type_text', 'scroll', 'set_value', 'drag', 'paste', 'select_text', 'perform_secondary_action', 'capture_screenshot', 'ping', 'permissions', 'end_session']);
const protocolError = (code, message) => Object.assign(new Error(message), { code });
const textResult = (text, isError = false) => ({ content: [{ type: 'text', text: String(text).slice(0, MAX_OUTPUT) }], ...(isError ? { isError: true } : {}) });

function validate(name, args) {
  const tool = TOOLS.find(item => item.name === name);
  if (!tool) throw protocolError(-32602, `未知工具: ${name}`);
  if (!args || typeof args !== 'object' || Array.isArray(args)) throw protocolError(-32602, 'arguments 必须是对象');
  const schema = tool.inputSchema;
  for (const field of Object.keys(args)) if (!Object.hasOwn(schema.properties, field)) throw protocolError(-32602, `未知参数: ${field}`);
  for (const field of schema.required ?? []) if (!Object.hasOwn(args, field)) throw protocolError(-32602, `缺少参数: ${field}`);
  for (const [field, value] of Object.entries(args)) {
    const rule = schema.properties[field];
    if (rule.type === 'string' && (typeof value !== 'string' || (rule.minLength && !value.trim()) || value.length < (rule.minLength ?? 0) || value.length > (rule.maxLength ?? Infinity))) throw protocolError(-32602, `无效字符串参数: ${field}`);
    if (rule.type === 'integer' && (!Number.isSafeInteger(value) || value < rule.minimum)) throw protocolError(-32602, `无效整数参数: ${field}`);
  }
}

export class MCPServer {
  constructor({ socketPath, home, sky, logger = message => process.stderr.write(`[swiftcua-mcp] ${message}\n`) } = {}) {
    this.sky = sky ?? createSky({ socketPath, home });
    this.logger = logger;
    this.worker = null;
    this.active = null;
    this.nextRun = 1;
    this.queue = Promise.resolve();
    this.closed = false;
  }

  #startWorker() {
    if (this.worker) return;
    const worker = new Worker(new URL('./repl-worker.mjs', import.meta.url), {
      resourceLimits: { maxOldGenerationSizeMb: 64, maxYoungGenerationSizeMb: 16, stackSizeMb: 4 },
    });
    this.worker = worker;
    worker.on('message', message => this.#onWorkerMessage(worker, message));
    worker.on('error', error => { if (this.worker === worker) this.#finish(null, error.message, true); });
    worker.on('exit', code => {
      if (this.worker !== worker) return;
      this.worker = null;
      if (this.active) this.#finish(null, `执行器退出 (${code})`, true);
    });
  }

  async #onWorkerMessage(worker, message) {
    const active = this.active;
    if (!active || worker !== this.worker || message.run !== active.run) return;
    if (message.kind === 'log') {
      active.logs = (active.logs + String(message.text) + '\n').slice(0, MAX_OUTPUT);
    } else if (message.kind === 'done') {
      this.#finish(message.result, message.error?.message, Boolean(message.error));
    } else if (message.kind === 'call') {
      try {
        let result;
        if (message.method === '__sleep') {
          const ms = message.args?.[0];
          if (typeof ms !== 'number' || !Number.isFinite(ms) || ms < 0 || ms > 2_147_483_647) throw new Error('sleep 参数必须是 0..2147483647 的毫秒数');
          await new Promise(resolve => {
            const timer = setTimeout(() => { active.sleepTimers.delete(timer); resolve(); }, ms);
            active.sleepTimers.add(timer);
          });
          result = null;
        } else {
          if (!ALLOWED_METHODS.has(message.method) || !Array.isArray(message.args)) throw new Error('禁止调用该方法');
          result = await this.sky[message.method](...message.args);
        }
        if (this.active === active && this.worker === worker) worker.postMessage({ kind: 'reply', id: message.id, generation: message.generation, result });
      } catch (error) {
        if (this.active === active && this.worker === worker) worker.postMessage({ kind: 'reply', id: message.id, generation: message.generation, error: { message: error.message, code: error.code, data: error.data } });
      }
    }
  }

  #finish(result, error, isError) {
    const active = this.active;
    if (!active) return;
    this.active = null;
    clearTimeout(active.timer);
    for (const timer of active.sleepTimers) clearTimeout(timer);
    const suffix = isError ? `Error: ${error}` : result ?? 'undefined';
    active.resolve(textResult(active.logs + suffix, isError));
  }

  async #resetWorker() {
    const old = this.worker;
    this.worker = null;
    if (old) await old.terminate();
  }

  async #execute(args) {
    if (this.closed) return textResult('MCP server 已关闭', true);
    this.#startWorker();
    const run = this.nextRun++;
    // Node 定时器上限是 32 位整数；更大预算安全地收敛到该上限。
    const timeoutMs = Math.min(args.timeout_ms ?? 30_000, 2_147_483_647);
    return new Promise(resolve => {
      this.active = { run, resolve, logs: '', sleepTimers: new Set(), timer: setTimeout(() => {
        this.#finish(null, `JavaScript 执行在 ${timeoutMs}ms 后超时；上下文已重置`, true);
        void this.#resetWorker();
      }, timeoutMs) };
      this.worker.postMessage({ kind: 'run', run, code: args.code, timeoutMs });
    });
  }

  async callTool(name, args = {}) {
    validate(name, args);
    if (name === 'turn_ended') {
      this.logger(`turn_ended ${JSON.stringify(args)}`);
      return textResult('{}');
    }
    const task = this.queue.then(async () => {
      if (name === 'js_reset') { await this.#resetWorker(); return textResult('{}'); }
      return this.#execute(args);
    });
    this.queue = task.catch(() => {});
    return task;
  }

  async handle(message) {
    const id = message?.id ?? null;
    if (!message || typeof message !== 'object' || Array.isArray(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string' || (Object.hasOwn(message, 'id') && message.id !== null && typeof message.id !== 'string' && !Number.isFinite(message.id))) {
      return { jsonrpc: '2.0', id, error: { code: -32600, message: 'Invalid Request' } };
    }
    // 通知不返回响应；初始化完成通知无需副作用。
    if (!Object.hasOwn(message, 'id')) return null;
    try {
      let result;
      switch (message.method) {
        case 'initialize': result = { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'swiftcua-mcp', version: '0.1.0' } }; break;
        case 'ping': result = {}; break;
        case 'tools/list': result = { tools: TOOLS }; break;
        case 'tools/call': {
          const params = message.params;
          if (!params || typeof params.name !== 'string') throw protocolError(-32602, 'tools/call 需要 name 和 arguments');
          result = await this.callTool(params.name, params.arguments === undefined ? {} : params.arguments);
          break;
        }
        default: throw protocolError(-32601, `Method not found: ${message.method}`);
      }
      return { jsonrpc: '2.0', id, result };
    } catch (error) {
      return { jsonrpc: '2.0', id, error: { code: Number.isInteger(error.code) ? error.code : -32603, message: error.message } };
    }
  }

  async close() {
    this.closed = true;
    this.#finish(null, 'MCP server 已关闭', true);
    await this.#resetWorker();
    this.sky.close();
  }
}

export function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (flag === '--help' || flag === '-h') { options.help = true; continue; }
    if (!['--socket', '--home'].includes(flag) || !argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error(`无效参数: ${flag}；用法: swiftcua-mcp [--socket <path>] [--home <dir>]`);
    options[flag === '--socket' ? 'socketPath' : 'home'] = argv[++i];
  }
  return options;
}

export async function runStdio(options = {}) {
  const server = new MCPServer(options);
  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  const tasks = new Set();
  const send = message => { if (message) process.stdout.write(JSON.stringify(message) + '\n'); };
  input.on('line', line => {
    if (!line.trim()) return;
    let message;
    try { message = JSON.parse(line); }
    catch { send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }); return; }
    const task = server.handle(message).then(send);
    tasks.add(task);
    task.finally(() => tasks.delete(task));
  });
  const stop = () => { input.close(); void server.close(); };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  await new Promise(resolve => input.once('close', resolve));
  await Promise.allSettled([...tasks]);
  await server.close();
  process.removeListener('SIGINT', stop);
  process.removeListener('SIGTERM', stop);
}
