import { workScheduler } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipboardStore } from './ClipboardStore';
import { Logger } from './Logger';
import { inputMethod } from '@kit.IMEKit';
import { Notify } from './Notify';

const PREF_STORE: string = 'clipboard_merger_settings';
const K_KEEPALIVE: string = 'keepalive_enabled';
const WORK_ID: number = 2001;
const EXT_ABILITY: string = 'KeepAliveAbility';
/** 鸿蒙延迟任务最短周期 20 分钟 */
const CYCLE_MS: number = 20 * 60 * 1000;

/**
 * 定时补活（WorkScheduler 延迟任务）—— 鸿蒙上替代 Android「自拉起闹钟 + 前台服务常驻」
 *
 * 取舍：鸿蒙不允许应用自己把后台服务拉起来，延迟任务只能做"到点跑一小段"；
 * 所以这里的定位是「定时兜底采集 + 心跳日志」，并让用户能看到它是否在跑。
 */
export class KeepAlive {
  private static ctx: common.Context | undefined = undefined;
  private static enabled: boolean = false;
  private static lastTick: string = '';

  static init(context: common.Context): void {
    KeepAlive.ctx = context;
    try {
      const store = preferences.getPreferencesSync(context, { name: PREF_STORE });
      const raw: preferences.ValueType = store.getSync(K_KEEPALIVE, false);
      KeepAlive.enabled = raw === true;
    } catch (err) {
      KeepAlive.enabled = false;
    }
    if (KeepAlive.enabled) {
      KeepAlive.schedule();
    }
    Logger.d(`KeepAlive.init: enabled=${KeepAlive.enabled}`);
  }

  static isEnabled(): boolean {
    return KeepAlive.enabled;
  }

  static setEnabled(context: common.Context, on: boolean): void {
    KeepAlive.enabled = on;
    try {
      const store = preferences.getPreferencesSync(context, { name: PREF_STORE });
      store.putSync(K_KEEPALIVE, on);
      store.flushSync();
    } catch (err) {
      Logger.w('KeepAlive.setEnabled: persist failed');
    }
    if (on) {
      KeepAlive.schedule();
    } else {
      KeepAlive.cancel();
    }
  }

  static lastTickTime(): string {
    return KeepAlive.lastTick;
  }

  /** 注册/刷新延迟任务（重复执行） */
  static schedule(): void {
    const work: workScheduler.WorkInfo = {
      workId: WORK_ID,
      bundleName: 'com.example.clipboardmerger',
      abilityName: EXT_ABILITY,
      isRepeat: true,
      repeatCycleTime: CYCLE_MS,
      isPersisted: true
    };
    try {
      workScheduler.startWork(work);
      Logger.d('KeepAlive.schedule: workScheduler.startWork ok');
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`KeepAlive.schedule failed: code=${e.code}, message=${e.message}`);
    }
  }

  static cancel(): void {
    const work: workScheduler.WorkInfo = {
      workId: WORK_ID,
      bundleName: 'com.example.clipboardmerger',
      abilityName: EXT_ABILITY
    };
    try {
      workScheduler.stopWork(work, true);
      Logger.d('KeepAlive.cancel: workScheduler.stopWork ok');
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`KeepAlive.cancel failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 到点执行：兜底采一次剪贴板 + 打心跳日志 */
  static tick(ctx: common.Context): void {
    ClipboardStore.init(ctx);
    ClipboardStore.capture();
    const d = new Date();
    KeepAlive.lastTick = `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()} ` +
      `${d.getHours()}:${d.getMinutes()}:${d.getSeconds()}`;
    Logger.d(`KeepAlive.tick (heartbeat): ${KeepAlive.lastTick}`);
    // 定时兜底提醒（平台不给"前台应用检测"，见 PIT-053）：
    // 当前输入法不是剪集 → 提醒切换（"进某 App 提醒"的等价可用时机）
    try {
      const cur = inputMethod.getCurrentInputMethod();
      if (cur.name !== 'com.example.clipboardmerger') {
        Notify.remind('剪集', '当前输入法不是「剪集」，切过去就能一键粘贴剪贴板里的内容');
      }
    } catch (err) {
      Logger.w('KeepAlive.tick: remind switch failed');
    }
  }
}
