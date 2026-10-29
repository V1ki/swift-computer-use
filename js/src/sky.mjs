import { randomUUID } from 'node:crypto';
import { Transport, API_VERSION } from './transport.mjs';

// 字段只做命名归一化，不改写枚举值；同名冲突优先使用 camelCase。
export function normalizeParams(params = {}) {
  if (!params || typeof params !== 'object' || Array.isArray(params)) throw new TypeError('参数必须是对象');
  const output = {};
  for (const [key, value] of Object.entries(params)) {
    const camel = key.replace(/_([a-z])/g, (_, letter) => letter.toUpperCase());
    if (value !== undefined && (camel === key || !(camel in params))) output[camel] = value;
  }
  return output;
}

function windowInfo(window) {
  return {
    id: window.id, app: window.app, title: window.title ?? null,
    bounds: window.bounds, layer: window.layer ?? 0,
    isOnScreen: window.isOnScreen ?? false, isFocused: window.isFocused ?? false,
  };
}

function screenshotInfo(screenshot) {
  if (!screenshot) return null;
  return {
    url: screenshot.url, width: screenshot.width ?? null, height: screenshot.height ?? null,
    id: screenshot.id, zIndex: screenshot.zIndex ?? 0,
  };
}

export function createSky({ socketPath, home, autoConnect = true } = {}) {
  const transport = new Transport({ socketPath, home });
  const sessionId = randomUUID();
  let ready = null;
  transport.on('close', () => { ready = null; });

  async function connect() {
    if (!ready) {
      ready = (async () => {
        await transport.connect();
        const info = await transport.ping();
        if (info.apiVersion && info.apiVersion !== API_VERSION) {
          throw Object.assign(new Error(`SwiftCUA API 版本不兼容: ${info.apiVersion}`), { code: 'EVERSION' });
        }
        return info;
      })();
      ready.catch(() => { ready = null; transport.close(); });
    }
    return ready;
  }

  async function ensureReady() {
    if (!ready && !autoConnect) throw Object.assign(new Error('自动连接已禁用，请先 await sky.connect()'), { code: 'ENOTCONN' });
    return connect();
  }

  async function rpc(method, params = {}) {
    await ensureReady();
    return transport.request(method, { sessionId, ...normalizeParams(params) });
  }

  const sky = {
    target: 'mac',
    connect,
    close() { ready = null; transport.close(); },
    async ping() { await ensureReady(); return transport.ping(); },
    async permissions() { return rpc('getPermissions'); },
    async list_apps(params = {}) {
      const result = await rpc('listApps', params);
      return (result.apps ?? result).map(app => ({
        id: app.id, displayName: app.displayName ?? null, isRunning: app.isRunning ?? false,
        lastUsedDate: app.lastUsedDate ?? null, useCount: app.useCount ?? 0,
        windows: (app.windows ?? []).map(windowInfo),
      }));
    },
    async list_windows() {
      const result = await rpc('listWindows');
      return (result.windows ?? result).map(windowInfo);
    },
    async get_app_state(params) {
      const result = await rpc('getAppState', params);
      const state = result.state ?? result;
      return {
        app: state.app, screenshot: screenshotInfo(state.screenshot),
        text: state.text ?? '', accessibility: state.accessibility ?? null,
      };
    },
    async capture_screenshot(params = {}) {
      const result = await rpc('captureScreenshot', params);
      return (result.screenshots ?? result).map(screenshotInfo);
    },
    async end_session() {
      await ensureReady();
      await transport.notify('endSession', { sessionId });
      return {};
    },
  };
  const actions = {
    click: 'click', press_key: 'pressKey', type_text: 'typeText', scroll: 'scroll',
    set_value: 'setValue', drag: 'drag', paste: 'paste', select_text: 'selectText',
    perform_secondary_action: 'performSecondaryAction',
  };
  for (const [name, method] of Object.entries(actions)) {
    sky[name] = async (params = {}) => { await rpc(method, params); return {}; };
  }
  return sky;
}
