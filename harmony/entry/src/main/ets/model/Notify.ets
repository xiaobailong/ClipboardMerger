import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

const NOTIFY_ID: number = 1001;

/**
 * 通知提醒（鸿蒙上替代 Android 的「悬浮气泡 + 全屏 Intent」）
 *
 * 取舍：鸿蒙普通应用拿不到 SYSTEM_FLOAT_WINDOW（悬浮窗）权限，通知横幅的展示
 * 又由系统策略决定（静音/勿扰可能不弹）⇒ 提醒可靠性不如 Android，但这是合规路径。
 */
export class Notify {
  /** 申请通知授权（首次弹系统授权框）；已授权直接返回 true */
  static async enable(context: common.UIAbilityContext): Promise<boolean> {
    try {
      await notificationManager.requestEnableNotification(context);
      Logger.d('Notify.enable: granted');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`Notify.enable failed: code=${e.code}, message=${e.message}`);
      return false;
    }
  }

  /** 发一条提醒通知 */
  static async remind(title: string, text: string): Promise<void> {
    const request: notificationManager.NotificationRequest = {
      id: NOTIFY_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      }
    };
    try {
      await notificationManager.publish(request);
      Logger.d(`Notify.remind: ${title} / ${text}`);
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`Notify.remind failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 取消提醒 */
  static async cancel(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFY_ID);
    } catch (err) {
      Logger.w('Notify.cancel failed');
    }
  }
}
