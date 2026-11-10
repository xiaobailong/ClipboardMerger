/** 构建信息注入：写入 harmony/entry/src/main/ets/model/BuildInfo.ets（对齐 Android 的 BuildConfig） */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// __dirname = <repo>/scripts/tools ⇒ 仓库根要上两级（原来只上到 scripts/，导致写文件 ENOENT、构建信息一直没注入）
const root = path.resolve(__dirname, '..', '..');
const out = path.join(root, 'harmony', 'entry', 'src', 'main', 'ets', 'model', 'BuildInfo.ets');
// 可选参数：release / debug（build-harmony.bat 不带参数 ⇒ debug）
const buildMode = process.argv[2] === 'release' ? 'release' : 'debug';

let commit = 'unknown';
try {
  commit = execSync('git rev-parse --short HEAD', { cwd: root }).toString().trim();
} catch (err) {
  commit = 'unknown';
}

const now = new Date();
const pad = (n) => (n < 10 ? '0' + n : '' + n);
const time = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
  `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;

const content = `/**
 * 构建信息（由 tools/build-info.js 生成，勿手工维护）
 */
export const BUILD_TIME: string = '${time}';
export const GIT_COMMIT: string = '${commit}';
export const BUILD_TYPE: string = 'HarmonyOS · ${buildMode === 'release' ? 'release 签名' : 'debug 签名'}';
`;

fs.writeFileSync(out, content.replace(/\n/g, '\r\n'), 'utf8');
console.log(`BuildInfo injected: ${time} / ${commit}`);
