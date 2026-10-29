import test from 'node:test';
import assert from 'node:assert/strict';
import { createSky } from '../src/index.mjs';
import { fakeServer } from './helpers.mjs';

const window = { id: 1, app: 'com.test', bounds: { x: 0, y: 0, width: 800, height: 600 }, layer: 0, isOnScreen: true, isFocused: true };

test('sky 懒连接、应用/窗口/状态形状及 snake_case 归一化', async t => {
  const fake = await fakeServer(t, ({ request, reply }) => {
    if (request.method === 'ping') reply({ apiVersion: 'SwiftCUA-IPC-1' });
    else if (request.method === 'listApps') reply({ apps: [{ id: 'com.test', displayName: 'Test', isRunning: true, windows: [window] }] });
    else if (request.method === 'listWindows') reply({ windows: [window] });
    else if (request.method === 'getAppState') reply({ state: { app: 'com.test', text: '[1] button', accessibility: { tree: '[1] button' } } });
  });
  const sky = createSky(fake);
  t.after(() => sky.close());
  assert.equal(sky.target, 'mac');
  assert.equal(fake.requests.length, 0);
  const apps = await sky.list_apps({ include_windows: true });
  assert.deepEqual(apps, [{ id: 'com.test', displayName: 'Test', isRunning: true, lastUsedDate: null, useCount: 0, windows: [{ ...window, title: null }] }]);
  assert.equal(fake.requests[0].method, 'ping');
  assert.equal(fake.requests[1].params.includeWindows, true);
  assert.ok(fake.requests[1].params.sessionId);
  assert.deepEqual(await sky.list_windows(), [{ ...window, title: null }]);
  assert.deepEqual(await sky.get_app_state({ app: 'com.test', include_screenshot: false, disable_diff: true }), { app: 'com.test', screenshot: null, text: '[1] button', accessibility: { tree: '[1] button' } });
  assert.equal(fake.requests.at(-1).params.includeScreenshot, false);
  assert.equal(fake.requests.at(-1).params.disableDiff, true);
});

test('get_app_state 保留远端错误 code/data', async t => {
  const fake = await fakeServer(t, ({ request, reply, error }) => {
    if (request.method === 'ping') reply({ apiVersion: 'SwiftCUA-IPC-1' });
    else error(-32001, 'Accessibility permission denied', { permission: 'accessibility' });
  });
  const sky = createSky(fake);
  t.after(() => sky.close());
  await assert.rejects(sky.get_app_state({ app: 'com.test' }), { code: -32001, message: 'Accessibility permission denied', data: { permission: 'accessibility' } });
});

test('所有动作映射 camelCase，返回空对象，end_session 是通知', async t => {
  let notifyResolve;
  const notified = new Promise(resolve => { notifyResolve = resolve; });
  const fake = await fakeServer(t, ({ request, reply }) => {
    if (request.method === 'endSession') { notifyResolve(request); return; }
    reply(request.method === 'ping' ? { apiVersion: 'SwiftCUA-IPC-1' } : { success: true });
  });
  const sky = createSky(fake);
  t.after(() => sky.close());
  const actions = { click: 'click', press_key: 'pressKey', type_text: 'typeText', scroll: 'scroll', set_value: 'setValue', drag: 'drag', paste: 'paste', select_text: 'selectText', perform_secondary_action: 'performSecondaryAction' };
  for (const [name, method] of Object.entries(actions)) {
    assert.deepEqual(await sky[name]({ app: 'com.test', element_index: 3, window_id: 4, scroll_x: 5, duration_milliseconds: 50, elementIndex: 7 }), {});
    assert.equal(fake.requests.at(-1).method, method);
    assert.equal(fake.requests.at(-1).params.elementIndex, 7);
    assert.equal(fake.requests.at(-1).params.durationMilliseconds, 50);
    assert.equal(fake.requests.at(-1).params.windowId, 4);
    assert.equal(fake.requests.at(-1).params.scrollX, 5);
    assert.equal(fake.requests.at(-1).params.element_index, undefined);
  }
  assert.deepEqual(await sky.end_session(), {});
  assert.equal((await notified).id, undefined);
});

test('握手拒绝不兼容版本且不会继续动作', async t => {
  const fake = await fakeServer(t, ({ reply }) => reply({ apiVersion: 'future-version' }));
  const sky = createSky(fake);
  t.after(() => sky.close());
  await assert.rejects(sky.list_apps(), { code: 'EVERSION' });
  assert.deepEqual(fake.requests.map(item => item.method), ['ping']);
});

test('状态截图只保留兼容字段', async t => {
  const fake = await fakeServer(t, ({ request, reply }) => reply(request.method === 'ping' ? { apiVersion: 'SwiftCUA-IPC-1' } : { state: { app: 'com.test', text: '', windows: [], screenshot: { id: 'shot', url: 'data:image/jpeg;base64,test', width: 800, height: 600, zIndex: 1, originX: 100 } } }));
  const sky = createSky(fake);
  t.after(() => sky.close());
  assert.deepEqual(await sky.get_app_state({ app: 'com.test' }), { app: 'com.test', text: '', accessibility: null, screenshot: { id: 'shot', url: 'data:image/jpeg;base64,test', width: 800, height: 600, zIndex: 1 } });
});

test('截图数组、权限以及手动连接模式', async t => {
  const fake = await fakeServer(t, ({ request, reply }) => {
    if (request.method === 'ping') reply({ apiVersion: 'SwiftCUA-IPC-1' });
    if (request.method === 'getPermissions') reply({ accessibility: true, screenRecording: false });
    if (request.method === 'captureScreenshot') reply({ screenshots: [{ id: 's', url: 'data:image/jpeg;base64,a', width: 2, height: 3, zIndex: 0 }] });
  });
  const sky = createSky({ ...fake, autoConnect: false });
  t.after(() => sky.close());
  await assert.rejects(sky.permissions(), { code: 'ENOTCONN' });
  await sky.connect();
  assert.deepEqual(await sky.permissions(), { accessibility: true, screenRecording: false });
  assert.equal((await sky.capture_screenshot({ display_id: 1 }))[0].id, 's');
  assert.equal(fake.requests.at(-1).params.displayId, 1);
});
