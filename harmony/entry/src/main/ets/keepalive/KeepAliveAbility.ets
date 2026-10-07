import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { KeepAlive } from '../model/KeepAlive';
import { Logger } from '../model/Logger';

/**
 * 延迟任务入口（WorkScheduler）—— 鸿蒙替代 Android 的"自拉起"手段
 * 到点被系统拉起后：初始化日志 → 兜底采集一次剪贴板 → 打心跳日志。
 */
export default class KeepAliveAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    Logger.init(this.context);
    Logger.d(`KeepAliveAbility.onWorkStart: workId=${work.workId}`);
    try {
      KeepAlive.tick(this.context);
    } catch (err) {
      Logger.w('KeepAliveAbility.onWorkStart: tick failed');
    }
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    Logger.d(`KeepAliveAbility.onWorkStop: workId=${work.workId}`);
  }
}
