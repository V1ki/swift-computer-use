import { sky } from '../src/index.mjs';

try {
  const apps = await sky.list_apps({ includeWindows: true });
  console.log(JSON.stringify(apps, null, 2));
  const app = apps.find(item => item.isRunning && item.windows.length) ?? apps.find(item => item.isRunning);
  if (app) {
    const state = await sky.get_app_state({ app: app.id, includeScreenshot: false, includeText: true });
    console.log(state.text.split('\n').slice(0, 40).join('\n'));
  } else console.log('当前没有可读取状态的运行中应用。');
} catch (error) {
  console.error(`SwiftCUA 示例无法完成: ${error.message}`);
  process.exitCode = 1;
} finally {
  sky.close();
}
