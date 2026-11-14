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
 * 同步方向（PIT-051）：**键盘（IME）那份是权威源**，App 只是镜像 + 操作台。
 *  ① App → 键盘：App 里的操作（删历史 / 清空 / 恢复 / 回收站增删清空）全部回写键盘；
 *  ② 键盘 → App：**只回快照**（App 打开剪切板 / 回收站时 `pull`，键盘回 `snapshot` 整份覆盖），
 *     键盘侧自己的操作不主动推给 App；
 *  ③ 键盘进程启动时发 `hello`，App 据此补发离线期间攒下的操作（pendingOps）。
 */
export const EV_HIST_SYNC: string = 'com.example.clipboardmerger.HIST_SYNC';

/**
 * 事件来源标记（**防回声**）：App 与输入法 Extension 是同包名的两个进程，
 * 公共事件发出去后本进程的订阅者也会收到 ⇒ 各侧只处理对方发的事件。
 */
export const SRC_APP: string = 'app';
export const SRC_IME: string = 'ime';

/**
 * 回收站同步 op（同样走 EV_HIST_SYNC 通道，payload 都塞在 text 里）：
 *   键盘回收站是**权威源**，App 回收站只是镜像 ⇒
 *   ① App 打开回收站：`recyclePull` → 键盘回 `recycleSnapshot`（全量 JSON）→ App 整份覆盖；
 *   ② App 侧改回收站（永久删除/恢复/清空）：**一律** `recycleRemove` 带上**操作记录列表**
 *      `RecycleOp[] = [{type, text, at}]`，`at` = 目标条目的 deletedAt；
 *   ③ 键盘侧自己的操作只动键盘那份，不回写 App（下次拉全量时自然对齐）。
 *
 * ⚠️ 为什么要"操作记录"而不是"内容清单"：App 的操作可能因键盘进程不在而进 pendingOps，
 * 等键盘下次 `hello` 才补发。若只带内容（或干脆是"清空"），补发时会把 App 操作之后
 * 键盘新产生的、或"同文本但更晚删进来"的记录一并干掉（PIT-053）。
 * 所以破坏性操作一律 (动作类型, 内容, 动作时间) 三元组，接收方按 (text, at) 精确命中。
 */
export const OP_RECYCLE_PULL: string = 'recyclePull';
export const OP_RECYCLE_SNAPSHOT: string = 'recycleSnapshot';
export const OP_RECYCLE_REMOVE: string = 'recycleRemove';

/**
 * 剪切板历史的删除（单条 / 清空全部都走这条）：
 * payload = `HistRemoval{items:[{text,timestamp}], batchId, opAt}` ——
 * 既说清"删哪些条目"，又给出"这次删除动作的身份"（批次 + 动作时间）。
 * 键盘侧据此按 (text, timestamp) 精确删除，并用同一个 batchId/opAt 建回收站条目，
 * 让两边条目的跨进程身份 (text, deletedAt) 一致。
 * （以前发 `clear`（无作用域），补发时会把键盘后来新采集的内容一起清掉，PIT-053）
 */
export const OP_HIST_REMOVE_MANY: string = 'removeMany';

/**
 * 设置同步 op（同样走 EV_HIST_SYNC 通道，payload 在 text 里）：
 * 皮肤 / 键盘高度 / 切换目标 / 回收站保留天数这几个「两侧都有」的设置，
 * 一律**以键盘那份为准**：App 打开时 `settingsPull`，键盘回 `settingsSnapshot` 覆盖；
 * App 里改了设置则 `settingsSet`（只带改动的那个 key）回写键盘。
 *
 * ⚠️ **日志开关不在同步范围内**：两个进程各有各的日志文件与开关，由各自界面独立管理。
 */
export const OP_SETTINGS_PULL: string = 'settingsPull';
export const OP_SETTINGS_SNAPSHOT: string = 'settingsSnapshot';
export const OP_SETTINGS_SET: string = 'settingsSet';

/**
 * 操作回执（PIT-058）：接收方**成功应用**一条 App 操作后，用同一个 `id` 回一条 ack，
 * App 据此把该操作从 pendingOps 出队 —— 不再依赖"下次快照里没看到就算生效"的近似判断。
 * ack 丢了也没关系：操作留在队列里，键盘下次 `hello` 会重放（所有操作都是幂等的精确操作）。
 */
export const OP_ACK: string = 'ack';

/** 事件参数：{ op, text?, ts?, src?, id? } */
export interface HistEvent {
  op: string;
  text: string;
  ts: number;
  /** 来源：SRC_APP / SRC_IME（空串 = 老版本事件，按“对方发的”处理） */
  src: string;
  /** 操作编号（App 发起时分配，接收方 ack 时原样带回；0 = 无需回执） */
  id: number;
}

export class EventBus {
  /**
   * 发布一条事件。`src` 声明"谁发的"，`id` 用于操作回执（0 = 不需要回执）。
   */
  static publish(op: string, text: string, ts: number, src: string, id: number = 0): void {
    if (ts === 0) {
      ts = Date.now();
    }
    const data: commonEventManager.CommonEventPublishData = {
      parameters: {
        op: op,
        text: text,
        ts: ts,
        src: src,
        id: id
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
        const src: string = typeof params.src === 'string' ? params.src : '';
        const id: number = typeof params.id === 'number' ? params.id : 0;
        Logger.d(`EventBus recv: op=${op} ts=${ts} src=${src} id=${id} len=${text.length}`);
        onEvent({ op: op, text: text, ts: ts, src: src, id: id });
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
