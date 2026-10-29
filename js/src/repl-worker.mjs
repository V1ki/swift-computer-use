import vm from 'node:vm';
import { parentPort } from 'node:worker_threads';

const METHODS = ['list_apps', 'list_windows', 'get_app_state', 'click', 'press_key', 'type_text', 'scroll', 'set_value', 'drag', 'paste', 'select_text', 'perform_secondary_action', 'capture_screenshot', 'ping', 'permissions', 'end_session'];
let context;
let activeRun = null;
let generation = 0;
let logCharacters = 0;

function reset() {
  generation++;
  const sandbox = Object.create(null);
  // 只跨边界传递 JSON 字符串。宿主对象、函数返回值和错误不进入用户上下文。
  sandbox.__bridge = Object.setPrototypeOf((serialized) => {
    try {
      if (typeof serialized !== 'string' || serialized.length > 8 * 1024 * 1024 || activeRun === null) return;
      const message = JSON.parse(serialized);
      if (message.kind === 'log') {
        if (logCharacters >= 25000) return;
        const text = String(message.text).slice(0, 25000 - logCharacters);
        logCharacters += text.length + 1;
        parentPort.postMessage({ kind: 'log', text, run: activeRun });
      } else if (message.kind === 'done') {
        parentPort.postMessage({ ...message, run: activeRun });
        activeRun = null;
      } else if (message.kind === 'call') parentPort.postMessage({ ...message, run: activeRun, generation });
    } catch { /* 桥接层不向沙箱抛出宿主错误。 */ }
  }, null);
  context = vm.createContext(sandbox, { name: 'SwiftCUA REPL', codeGeneration: { strings: false, wasm: false } });
  new vm.Script(`(() => {
    const bridge = globalThis.__bridge;
    delete globalThis.__bridge;
    const pending = new Map();
    let nextId = 1;
    const stringify = JSON.stringify;
    const parse = JSON.parse;
    const render = value => {
      if (typeof value === 'string') return value;
      if (value === undefined) return 'undefined';
      try { return stringify(value, null, 2) ?? String(value); }
      catch { return '[无法序列化的结果]'; }
    };
    const send = value => bridge(stringify(value));
    const invoke = (method, args) => new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, {resolve, reject});
      try { send({kind: 'call', id, method, args}); }
      catch (error) { pending.delete(id); reject(error); }
    });
    const sky = Object.create(null);
    for (const name of ${JSON.stringify(METHODS)}) sky[name] = (...args) => invoke(name, args);
    sky.target = 'mac';
    globalThis.sky = Object.freeze(sky);
    globalThis.cua = sky;
    globalThis.sleep = ms => invoke('__sleep', [ms]);
    globalThis.json = value => stringify(value, null, 2);
    globalThis.console = Object.freeze(Object.fromEntries(['log', 'info', 'warn', 'error', 'debug', 'dir'].map(name => [name, (...args) => send({kind: 'log', text: args.map(render).join(' ')})])));
    Object.defineProperty(globalThis, '__deliver', {value: serialized => {
      const message = parse(serialized);
      const item = pending.get(message.id);
      if (!item) return;
      pending.delete(message.id);
      if (message.error) {
        const error = new Error(message.error.message);
        error.code = message.error.code;
        error.data = message.error.data;
        item.reject(error);
      } else item.resolve(message.result);
    }});
    const then = Function.prototype.call.bind(Promise.prototype.then);
    Object.defineProperty(globalThis, '__complete', {value: promise => {
      then(promise, value => send({kind: 'done', result: render(value).slice(0, 25000)}), error => {
        send({kind: 'done', error: {message: String(error?.message ?? error), code: error?.code}});
      });
    }});
  })()`).runInContext(context, { timeout: 1000 });
}

function compile(code) {
  // Node 缺省的动态 import 错误来自宿主 Realm，捕获它会泄漏宿主构造器。
  // 无 AST 依赖时采用保守词元拒绝；字符串或注释中的 import 也会被拒绝。
  if (/\bimport\b/u.test(code)) throw new Error('沙箱禁止 import（含字符串或注释中的独立词元）');
  // 优先表达式，随后尝试最后一行/语句，最后退回支持显式 return 的函数体。
  const expression = code.trim().replace(/;\s*$/, '');
  try { return new vm.Script(`__complete((async () => (\n${expression}\n))())`, { filename: 'cua-repl.js' }); }
  catch { /* 代码块不是单个表达式。 */ }
  const boundaries = [...code.matchAll(/[;\n]/g)].map(match => match.index + 1).reverse();
  for (const offset of boundaries.slice(0, 200)) {
    const tail = code.slice(offset).trim().replace(/;\s*$/, '');
    if (!tail) continue;
    try {
      return new vm.Script(`__complete((async () => {\n${code.slice(0, offset)}\nreturn (\n${tail}\n);\n})())`, { filename: 'cua-repl.js' });
    } catch { /* 只接受语法完整的末尾表达式。 */ }
  }
  return new vm.Script(`__complete((async () => {\n${code}\n})())`, { filename: 'cua-repl.js' });
}

reset();
parentPort.on('message', message => {
  if (message.kind === 'reply') {
    if (message.generation !== generation) return;
    try {
      new vm.Script(`__deliver(${JSON.stringify(JSON.stringify(message))})`).runInContext(context, { timeout: 1000 });
    } catch (error) {
      parentPort.postMessage({ kind: 'done', run: activeRun, error: { message: String(error.message) } });
    }
    return;
  }
  if (message.kind === 'reset') { reset(); parentPort.postMessage({ kind: 'reset', run: message.run }); return; }
  if (message.kind !== 'run') return;
  activeRun = message.run;
  logCharacters = 0;
  try {
    compile(message.code).runInContext(context, { timeout: message.timeoutMs });
  } catch (error) {
    // 错误的属性读取也可能执行用户 getter，外层 Worker 截止时间仍然生效。
    parentPort.postMessage({ kind: 'done', run: message.run, error: { message: String(error?.message ?? error), code: error?.code } });
  }
});
