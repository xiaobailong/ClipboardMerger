import { commonEventManager } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

/**
 * 跨进程事件总线（输入法进程 ↔ App 进程）
 *
 * 为什么必须用它：输入法 Extension 跑在**独立沙箱**里（官方「基础访问模式」约束），
 * 它与 App 的 preferences / 文件/ 数据库**都不互通**。鸿蒙本版本又不给普通应用
 * DataShare（服务端类不存在）和无障碍、bundleState（需系统权限）。
 * ⇒ 公共事件（CommonEvent）是唯一可用的跨沙箱通道。
 *
 * 用途：
 *  ① 键盘侧历史变化 → 通知 App（App 收到后发通知横幅 = "自动提醒"，见 Notify.ets）
 *  ② 两边历史保持一致（一边删了 → 另一边也删）
 */
export const EV_HIST_SYNC: string = 'com.example.clipboardmerger.HIST_SYNC';

/** 事件参数：{ op: 'add'|'remove'|'clear'|'snapshot', text?: string, ts?: number, list?: string } */
export interface HistEvent {
  op: string;
  text: string;
  ts: number;
}

export class EventBus {
  /** 发布一条历史变化事件（op: add/remove/clear） */
  static publish(op: string, text: string, ts: number): void {
    if (ts === 0) {
      ts = Date.now();
    }
    const data: commonEventManager.CommonEventPublishData = {
      parameters: {
        op: op,
        text: text,
        ts: ts
      }
    };
    try {
      commonEventManager.publish(EV_HIST_SYNC, data, (err) => {
        if (err) {
          Logger.w(`EventBus.publish err: ${err.code} ${err.message}`);
        }
      });
    } catch (err) {
      Logger.w('EventBus.publish failed');
    }
  }

  /**
   * 订阅历史变化事件。返回订阅者（需要释放时调用 unsubscribe）。
   * ⚠️ 只在进程活着时收得到 ⇒ 两侧启动时各发一次 snapshot 做全量对齐。
   */
  static subscribe(onEvent: (e: HistEvent) => void): commonEventManager.CommonEventSubscriber | undefined {
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = {
        events: [EV_HIST_SYNC]
      };
      const sub: commonEventManager.CommonEventSubscriber = commonEventManager.createSubscriberSync(info);
      commonEventManager.subscribe(sub, (err, data) => {
        if (err) {
          Logger.w(`EventBus.subscribe err: ${err.code} ${err.message}`);
          return;
        }
        const params = data.parameters;
        if (params === undefined) {
          return;
        }
        const op: string = typeof params.op === 'string' ? params.op : '';
        const text: string = typeof params.text === 'string' ? params.text : '';
        const ts: number = typeof params.ts === 'number' ? params.ts : 0;
        Logger.d(`EventBus recv: op=${op} ts=${ts} len=${text.length}`);
        onEvent({ op: op, text: text, ts: ts });
      });
      return sub;
    } catch (err) {
      Logger.w('EventBus.subscribe failed');
      return undefined;
    }
  }

  /** 取消订阅（进程退出/页面销毁时调用） */
  static unsubscribe(sub: commonEventManager.CommonEventSubscriber | undefined): void {
    if (sub === undefined) {
      return;
    }
    try {
      commonEventManager.unsubscribe(sub);
    } catch (err) {
      Logger.w('EventBus.unsubscribe failed');
    }
  }
}
