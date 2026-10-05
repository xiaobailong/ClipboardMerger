import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const DOMAIN: number = 0x0A11;
const TAG: string = 'JianJi';
const PREF_STORE: string = 'jianji_log_settings';
const KEY_LOG_ENABLED: string = 'log_enabled';

/**
 * 日志（对齐 Android 版 Logger 的语义）
 *
 * - hilog：始终输出，DevEco 的 Log 窗口按 TAG=JianJi 过滤
 * - 文件：应用沙箱 filesDir/jianji_log_<yyyyMMdd>.txt（不需要任何权限，真机排查用）
 * - 开关：持久化在 preferences（键 log_enabled），进程重启后仍生效；
 *   关闭后连日志文件都不再创建
 */
export class Logger {
  private static enabled: boolean = true;
  private static inited: boolean = false;
  private static logFile: string = '';

  /** 幂等：多次调用只有第一次生效 */
  static init(context: common.Context): void {
    if (Logger.inited) {
      return;
    }
    Logger.inited = true;
    try {
      const store = preferences.getPreferencesSync(context, { name: PREF_STORE });
      const raw: preferences.ValueType = store.getSync(KEY_LOG_ENABLED, true);
      Logger.enabled = raw === true;
    } catch (err) {
      Logger.enabled = true;
    }
    if (!Logger.enabled) {
      return;
    }
    Logger.setupFile(context);
    Logger.write('INFO', '=== Log started ===');
    Logger.write('INFO', `filesDir=${context.filesDir}`);
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
        Logger.setupFile(context);
      }
      Logger.write('INFO', '=== Log enabled ===');
    } else {
      Logger.write('INFO', '=== Log disabled ===');
    }
  }

  static isEnabled(): boolean {
    return Logger.enabled;
  }

  /** 预期的日志文件路径（未启用时也返回，便于 UI 展示） */
  static getLogFile(): string {
    return Logger.logFile;
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

  private static setupFile(context: common.Context): void {
    try {
      Logger.logFile = `${context.filesDir}/jianji_log_${Logger.today()}.txt`;
    } catch (err) {
      Logger.logFile = '';
    }
  }

  private static write(level: string, msg: string): void {
    const line: string = `${Logger.now()} [${level}] ${msg}`;
    hilog.info(DOMAIN, TAG, '%{public}s', line);
    if (!Logger.enabled || Logger.logFile === '') {
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

  private static today(): string {
    const d = new Date();
    return `${d.getFullYear()}${Logger.pad(d.getMonth() + 1)}${Logger.pad(d.getDate())}`;
  }

  private static now(): string {
    const d = new Date();
    return `${Logger.today()} ${Logger.pad(d.getHours())}:${Logger.pad(d.getMinutes())}:` +
      `${Logger.pad(d.getSeconds())}.${d.getMilliseconds()}`;
  }
}
