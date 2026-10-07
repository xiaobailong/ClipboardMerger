import { hilog } from '@kit.PerformanceAnalysisKit';
import { Environment, fileIo as fs } from '@kit.CoreFileKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';

const DOMAIN: number = 0x0A11;
const TAG: string = 'JianJi';
/** 对齐 Android：SharedPreferences 同名同键（clipboard_merger_settings / log_enabled） */
const PREF_STORE: string = 'clipboard_merger_settings';
const KEY_LOG_ENABLED: string = 'log_enabled';
/** 对齐 Android：Download/JianJi/jianji_log_<yyyy-MM-dd>.txt */
const LOG_DIR_NAME: string = 'JianJi';
const LOG_FILE_PREFIX: string = 'jianji_log';
const LOG_RETENTION_DAYS: number = 7;
const DAY_MS: number = 24 * 60 * 60 * 1000;

/**
 * 日志（与 Android 版 Logger 对齐）
 *
 * - 路径：`Download/JianJi/jianji_log_<yyyy-MM-dd>.txt`（鸿蒙用 Environment.getUserDownloadDir()，
 *   API 12+ 无需权限；拿不到时退回应用沙箱，并在头部写明）
 * - 保留：只保留最近 7 天（LOG_RETENTION_DAYS，与 Android 一致）
 * - 开关：持久化在 `clipboard_merger_settings/log_enabled`；关闭时**不建目录、不建文件**，
 *   只算出"将会写到哪里"给设置页展示
 * - 输出：hilog(DEBUG/WARN) + 文件；文件格式 `[yyyy-MM-dd HH:mm:ss.SSS] [LEVEL] message`
 *   （Android 是 `[时间][线程]`，鸿蒙拿不到线程名，用级别代替）
 */
export class Logger {
  private static enabled: boolean = true;
  private static inited: boolean = false;
  /** 实际在写的文件；未启用/创建失败时为空 */
  private static logFile: string = '';
  /** 只算路径，不创建 */
  private static expected: string = '';
  /** 应用沙箱 filesDir（Download 不可写时的退路） */
  private static filesDir: string = '';

  /** 幂等：多次调用只有第一次生效（Activity / 输入法进程各一次） */
  static init(context: common.Context): void {
    if (Logger.inited) {
      return;
    }
    Logger.inited = true;
    Logger.filesDir = context.filesDir;
    try {
      const store = preferences.getPreferencesSync(context, { name: PREF_STORE });
      const raw: preferences.ValueType = store.getSync(KEY_LOG_ENABLED, true);
      Logger.enabled = raw === true;
    } catch (err) {
      Logger.enabled = true;
    }

    Logger.expected = Logger.expectedLogPath();

    let setup: string = 'disabled';
    if (Logger.enabled) {
      setup = Logger.trySetupLog();
    } else {
      Logger.logFile = '';
      setup = `disabled, not created (${Logger.expected})`;
    }

    Logger.write('INFO', `=== 剪集 v${Logger.versionName()} ===`);
    Logger.write('INFO', `=== API: ${deviceInfo.sdkApiVersion} | Device: ${deviceInfo.productModel} ===`);
    Logger.write('INFO', `=== Log: ${setup} ===`);
    Logger.write('INFO', '=== Log started ===');
    Logger.write('INFO', `=== Log enabled: ${Logger.enabled} ===`);
  }

  /** 供设置页切换；true 时若还没有日志文件会补建 */
  static setEnabled(context: common.Context, enabled: boolean): void {
    Logger.enabled = enabled;
    try {
      const store = preferences.getPreferencesSync(context, { name: PREF_STORE });
      store.putSync(KEY_LOG_ENABLED, enabled);
      store.flushSync();
    } catch (err) {
      Logger.w('setEnabled: persist failed');
    }
    if (enabled) {
      if (Logger.logFile === '') {
        const setup: string = Logger.trySetupLog();
        Logger.write('INFO', `Log re-enabled, file setup: ${setup}`);
      }
      Logger.write('INFO', '=== Log enabled ===');
    } else {
      Logger.write('INFO', '=== Log disabled ===');
    }
  }

  static isEnabled(): boolean {
    return Logger.enabled;
  }

  /** 日志路径：启用时=实际文件；关闭时=“将会写到哪里”（对齐 Android getLogPath） */
  static getLogFile(): string {
    return Logger.logFile !== '' ? Logger.logFile : Logger.expected;
  }

  /** 日志文件是否真的已创建 / 正在写（开关关闭时为 false，对齐 Android isLogFileActive） */
  static isLogFileActive(): boolean {
    return Logger.logFile !== '';
  }

  static d(msg: string): void {
    Logger.write('DEBUG', msg);
  }

  static w(msg: string): void {
    Logger.write('WARN', msg);
  }

  static e(msg: string): void {
    Logger.write('ERROR', msg);
  }

  /** 建目录 + 清理 7 天前日志 + 建今天文件；返回 OK/FAILED 描述（对齐 Android trySetupLog） */
  private static trySetupLog(): string {
    const primary: string = Logger.expected;
    const sandbox: string = `${Logger.filesDir}/${LOG_DIR_NAME}/${LOG_FILE_PREFIX}_${Logger.today()}.txt`;
    const first: string = Logger.setupAt(primary);
    if (first !== '') {
      Logger.logFile = first;
      return `OK: ${first}`;
    }
    Logger.write('WARN', `Download 目录不可写，退回沙箱: ${sandbox}`);
    const second: string = Logger.setupAt(sandbox);
    if (second !== '') {
      Logger.logFile = second;
      return `OK(sandbox): ${second}`;
    }
    Logger.logFile = '';
    return 'FAILED: 目录不可写';
  }

  /** 在指定文件路径上准备写入（建父目录 + 清理旧日志 + 验证可写）；失败返回空串 */
  private static setupAt(filePath: string): string {
    try {
      const dir: string = filePath.substring(0, filePath.lastIndexOf('/'));
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      Logger.cleanOldLogs(dir);
      const f = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.closeSync(f);
      return filePath;
    } catch (err) {
      return '';
    }
  }

  /**
   * 清空全部日志文件（日志弹层「清理日志」按钮）
   * 只删 `JianJi/jianji_log_*.txt`，删完若日志开着会立刻重建当前文件（写一行标记），
   * 这样用户点完能立刻看到"新日志已开始"而不是文件不存在。
   * 返回删除的文件数。
   */
  static clearAllLogs(): number {
    let dir: string = '';
    const src: string = Logger.logFile !== '' ? Logger.logFile : Logger.expected;
    const idx: number = src.lastIndexOf('/');
    if (idx > 0) {
      dir = src.substring(0, idx);
    }
    if (dir === '') {
      return 0;
    }
    let n: number = 0;
    try {
      const names: string[] = fs.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (!name.startsWith(LOG_FILE_PREFIX) || !name.endsWith('.txt')) {
          continue;
        }
        try {
          fs.unlinkSync(`${dir}/${name}`);
          n++;
        } catch (inner) {
          // 单个文件失败不影响其它
        }
      }
    } catch (err) {
      Logger.w('clearAllLogs failed');
      return n;
    }
    Logger.write('DEBUG', `clearAllLogs: removed ${n} file(s)`);
    return n;
  }

  /** 只保留最近 7 天（对齐 Android cleanOldLogs） */
  private static cleanOldLogs(dir: string): void {
    try {
      const names: string[] = fs.listFileSync(dir);
      const nowMs: number = Date.now();
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (!name.startsWith(LOG_FILE_PREFIX) || !name.endsWith('.txt')) {
          continue;
        }
        const full: string = `${dir}/${name}`;
        try {
          const st = fs.statSync(full);
          if (nowMs - st.mtime * 1000 > LOG_RETENTION_DAYS * DAY_MS) {
            fs.unlinkSync(full);
            Logger.write('DEBUG', `cleanOldLogs: removed ${name}`);
          }
        } catch (inner) {
          // 单个文件失败不影响其它
        }
      }
    } catch (err) {
      Logger.write('WARN', 'cleanOldLogs failed');
    }
  }

  /** 只算路径，不创建任何目录（对齐 Android expectedLogPath） */
  private static expectedLogPath(): string {
    try {
      return `${Environment.getUserDownloadDir()}/${LOG_DIR_NAME}/${LOG_FILE_PREFIX}_${Logger.today()}.txt`;
    } catch (err) {
      return `${Logger.filesDir}/${LOG_DIR_NAME}/${LOG_FILE_PREFIX}_${Logger.today()}.txt`;
    }
  }

  private static versionName(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return info.versionName;
    } catch (err) {
      return 'unknown';
    }
  }

  private static write(level: string, msg: string): void {
    // 与 Android 一致：关闭后连 hilog 都不再输出
    if (!Logger.enabled) {
      return;
    }
    const line: string = `${Logger.now()} [${level}] ${msg}`;
    hilog.info(DOMAIN, TAG, '%{public}s', line);
    if (Logger.logFile === '') {
      return;
    }
    try {
      const file = fs.openSync(Logger.logFile,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, line + '\n');
      fs.closeSync(file);
    } catch (err) {
      // 写文件失败不能影响主流程（例如磁盘满）
    }
  }

  private static pad(n: number): string {
    return n < 10 ? `0${n}` : `${n}`;
  }

  private static pad3(n: number): string {
    if (n < 10) {
      return `00${n}`;
    }
    if (n < 100) {
      return `0${n}`;
    }
    return `${n}`;
  }

  /** 文件名用 yyyy-MM-dd（对齐 Android） */
  private static today(): string {
    const d = new Date();
    return `${d.getFullYear()}-${Logger.pad(d.getMonth() + 1)}-${Logger.pad(d.getDate())}`;
  }

  /** 行首时间戳 yyyy-MM-dd HH:mm:ss.SSS（对齐 Android） */
  private static now(): string {
    const d = new Date();
    return `${Logger.today()} ${Logger.pad(d.getHours())}:${Logger.pad(d.getMinutes())}:` +
      `${Logger.pad(d.getSeconds())}.${Logger.pad3(d.getMilliseconds())}`;
  }
}
