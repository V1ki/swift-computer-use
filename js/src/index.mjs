import { createSky } from './sky.mjs';
export { createSky } from './sky.mjs';
export { Transport } from './transport.mjs';

// 导入模块不会连接服务；首次方法调用才进行连接和版本握手。
export const sky = createSky();
export default sky;
