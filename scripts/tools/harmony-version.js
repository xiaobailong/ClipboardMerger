/**
 * 鸿蒙版版本号查询工具（真源 = harmony/AppScope/app.json5）
 *
 * 用法:
 *   node tools/harmony-version.js          打印 versionName
 *   node tools/harmony-version.js name     同上
 *   node tools/harmony-version.js code     打印 versionCode
 *
 * 注意: 版本递增请用 bump-version-harmony.ps1（-File 方式，不受安全策略拦截）。
 *       bump 命令仅为兼容旧脚本保留，输出警告并返回当前版本信息。
 */
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '..', '..', 'harmony', 'AppScope', 'app.json5');
const mode = (process.argv[2] || 'name').toLowerCase();

let text;
try {
  text = fs.readFileSync(file, 'utf8');
} catch (err) {
  console.error('读不到 ' + file + ' :: ' + err.message);
  process.exit(2);
}

const reCode = /"versionCode"\s*:\s*(\d+)/;
const reName = /"versionName"\s*:\s*"([^"]+)"/;
const mCode = reCode.exec(text);
const mName = reName.exec(text);
if (!mCode || !mName) {
  console.error('app.json5 里找不到 versionCode / versionName');
  process.exit(2);
}

const code = parseInt(mCode[1], 10);
const name = mName[1];

if (mode === 'bump') {
  console.error('[警告] bump 已废弃，请用: powershell -File scripts\\tools\\bump-version-harmony.ps1');
  console.log(name);
} else if (mode === 'code') {
  console.log(String(code));
} else {
  console.log(name);
}