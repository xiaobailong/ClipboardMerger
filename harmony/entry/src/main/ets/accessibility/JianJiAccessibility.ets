import { AccessibilityExtensionAbility, AccessibilityEvent } from '@kit.AccessibilityKit';
import { Logger } from '../model/Logger';

/**
 * 剪集无障碍服务：替代 Android 的「使用情况访问权限（UsageStats）」——检测前台应用，
 * 用于「进入绑定的 App 时自动提醒」。
 *
 * 现状（本轮先做"注册 + 打日志验证放行"）：鸿蒙对第三方无障碍服务的开放程度随版本收紧，
 * 先确认系统是否允许启用，再决定要不要把「前台应用变化 → 提醒」接上去。
 *
 * 启用路径：设置 → 辅助功能（或 无障碍）→ 已安装的服务 → 剪集 → 打开开关。
 */
export default class JianJiAccessibility extends AccessibilityExtensionAbility {
  onConnect(): void {
    Logger.d('A11y: onConnect（无障碍服务已启用）');
  }

  onDisconnect(): void {
    Logger.d('A11y: onDisconnect（无障碍服务已停用）');
  }

  /**
   * 无障碍事件回调：先把「事件类型 + 整个事件 JSON」打日志，用来确认：
   * ① 服务是否真的被系统调用；② 能不能拿到前台应用包名（能拿到才谈得上自动提醒）。
   * 用 JSON.stringify 而不是直接读字段：字段名/类型在各版本间有差异（本轮实测 eventType 是
   * string、bundleName 字段名对不上），整串打出来最稳，也便于我据此改提醒逻辑。
   */
  onAccessibilityEvent(event: AccessibilityEvent): void {
    try {
      const t: string = event.eventType;
      let dump: string = '';
      try {
        dump = JSON.stringify(event);
      } catch (inner) {
        dump = '(event 无法序列化)';
      }
      Logger.d(`A11y event: type=${t} ${dump}`);
    } catch (err) {
      Logger.w('A11y onAccessibilityEvent failed');
    }
  }
}
