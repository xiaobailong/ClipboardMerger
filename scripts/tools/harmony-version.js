/**
 * 鸿蒙版版本号工具（真源 = harmony/AppScope/app.json5）
 *
 * 用法:
 *   node tools/harmony-version.js          打印 versionName
 *   node tools/harmony-version.js name     同上
 *   node tools/harmony-version.js code     打印 versionCode
 *   node tools/harmony-version.js bump     递增（code+1，name 次版本+1，规则同 Android 的 incrementVersion）
 *
 * 注意：Android 与鸿蒙版本号各自独立（version.properties / app.json5），互不影响。
 */
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '..', 'harmony', 'AppScope', 'app.json5');
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
  const parts = String(name).split('.');
  const minor = (parts.length > 1 ? parseInt(parts[1], 10) : 0) + 1;
  const next = parts[0] + '.' + minor;
  const nextText = text
    .replace(reCode, '"versionCode": ' + (code + 1))
    .replace(reName, '"versionName": "' + next + '"');
  fs.writeFileSync(file, nextText, 'utf8');
  console.log('鸿蒙版本: code ' + code + ' -> ' + (code + 1) + ', name ' + name + ' -> ' + next);
} else if (mode === 'code') {
  console.log(String(code));
} else {
  console.log(name);
}
