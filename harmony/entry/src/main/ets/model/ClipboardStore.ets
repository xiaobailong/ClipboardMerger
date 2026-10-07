import { pasteboard } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

/** 一条剪贴板历史（字段名与 Android 版 ClipboardItem 对齐：content → text） */
export interface ClipItem {
  text: string;
  timestamp: number;
}

const STORE_NAME: string = 'clipboard_merger';
const KEY_ITEMS: string = 'items';
const MAX_ITEMS: number = 5000;

/** 供界面订阅的状态键（AppStorage） */
export const STATE_ITEMS: string = 'clipItems';
export const STATE_STATUS: string = 'clipStatus';

/**
 * 剪贴板历史仓库 + 采集器（对齐 Android 版 ClipboardRepository 的语义）
 *
 * 与 Android 版的差异（HarmonyOS 平台约束）：
 * 1) 读取系统剪贴板在 API 12+ 受权限管控（ohos.permission.READ_PASTEBOARD），
 *    没授权时采集会失败 —— 这里只记错误并降级，不影响键盘本身的其它功能；
 * 2) 采集入口有两个：系统剪贴板 'update' 事件 + 输入法 inputStart（拉起键盘时补一次）。
 */
export class ClipboardStore {
  private static ctx: common.Context | undefined = undefined;
  private static cache: ClipItem[] = [];
  private static lastChangeCount: number = -1;
  private static watching: boolean = false;
  private static listener: (() => void) | undefined = undefined;
  private static status: string = '尚未开始监听';
  /** 历史变化回调（键盘进程注册它做「变化即广播」；App 进程不注册，避免回声，见 PIT-050） */
  private static changeCb: ((op: string, text: string, ts: number) => void) | undefined = undefined;

  static init(context: common.Context): void {
    Logger.init(context);
    if (ClipboardStore.ctx !== undefined) {
      return;
    }
    ClipboardStore.ctx = context;
    ClipboardStore.load();
    Logger.d(`ClipboardStore.init: loaded ${ClipboardStore.cache.length} items`);
    ClipboardStore.publish();
  }

  /** 内存里的历史（最新在前） */
  static getItems(): ClipItem[] {
    return ClipboardStore.cache;
  }

  static getStatus(): string {
    return ClipboardStore.status;
  }

  /** 从 preferences 读历史（同步，界面首帧就能拿到数据） */
  static load(): ClipItem[] {
    const p = ClipboardStore.store();
    let list: ClipItem[] = [];
    if (p !== undefined) {
      try {
        const raw: preferences.ValueType = p.getSync(KEY_ITEMS, '[]');
        const json: string = typeof raw === 'string' ? raw : '[]';
        const parsed: ClipItem[] = JSON.parse(json) as ClipItem[];
        for (let i = 0; i < parsed.length; i++) {
          const it: ClipItem = parsed[i];
          if (it === undefined || it === null) {
            continue;
          }
          const text: string = it.text;
          if (text === undefined || text === null || text.length === 0) {
            continue;
          }
          const ts: number = it.timestamp > 0 ? it.timestamp : Date.now();
          const item: ClipItem = { text: text, timestamp: ts };
          list.push(item);
        }
      } catch (err) {
        Logger.w('load: parse items failed, reset to empty');
        list = [];
      }
    }
    ClipboardStore.cache = list;
    return list;
  }

  /**
   * 注册「历史变化」回调：addText / removeAt / clear 成功后会回调它。
   *
   * 用途：**键盘进程**注册它，把每次变化立刻广播给 App（`EventBus`）——
   * 这样「键盘采集到新条目」会**即时**同步到 App，而不是等面板下次重建（本轮修的问题）。
   * App 进程**不要**注册（它应用对方事件时会再改本地存储，注册了就回声，`PIT-050`）。
   */
  static setChangeListener(cb: ((op: string, text: string, ts: number) => void) | undefined): void {
    ClipboardStore.changeCb = cb;
  }

  private static notifyChange(op: string, text: string, ts: number): void {
    const cb = ClipboardStore.changeCb;
    if (cb === undefined) {
      return;
    }
    try {
      cb(op, text, ts);
    } catch (err) {
      Logger.w('notifyChange failed');
    }
  }

  /** 新增一条（空白跳过；与最新一条重复跳过）—— 同 Android 版 addItem */
  static addText(text: string): boolean {
    if (text === undefined || text === null || text.trim().length === 0) {
      return false;
    }
    if (ClipboardStore.cache.length > 0 && ClipboardStore.cache[0].text === text) {
      Logger.d('addText: skip duplicate of latest');
      return false;
    }
    const item: ClipItem = { text: text, timestamp: Date.now() };
    ClipboardStore.cache.unshift(item);
    if (ClipboardStore.cache.length > MAX_ITEMS) {
      ClipboardStore.cache = ClipboardStore.cache.slice(0, MAX_ITEMS);
    }
    ClipboardStore.persist();
    ClipboardStore.publish();
    Logger.d(`addText: done, total=${ClipboardStore.cache.length}`);
    ClipboardStore.notifyChange('add', item.text, item.timestamp);
    return true;
  }

  static removeAt(index: number): void {
    if (index < 0 || index >= ClipboardStore.cache.length) {
      return;
    }
    const removed: ClipItem = ClipboardStore.cache[index];
    ClipboardStore.cache.splice(index, 1);
    ClipboardStore.persist();
    ClipboardStore.publish();
    Logger.d(`removeAt: index=${index}, total=${ClipboardStore.cache.length}`);
    ClipboardStore.notifyChange('remove', removed.text, removed.timestamp);
  }

  static clear(): void {
    ClipboardStore.cache = [];
    ClipboardStore.persist();
    ClipboardStore.publish();
    Logger.d('clear: history cleared');
    ClipboardStore.notifyChange('clear', '', Date.now());
  }

  /**
   * 去掉「正文重复」的条目，保留**最新**那条（返回删掉几条）。
   *
   * 为什么需要：合并对端快照时若只是「循环 `addText`」，已存在的条目会被重复插进来
   * （`addText` 只与最新一条去重）⇒ 历史里出现成片重复（本轮修的 bug）。
   */
  static dedupeByText(): number {
    const seen: Set<string> = new Set<string>();
    const kept: ClipItem[] = [];
    let dropped: number = 0;
    for (let i = 0; i < ClipboardStore.cache.length; i++) {
      const it: ClipItem = ClipboardStore.cache[i];
      if (seen.has(it.text)) {
        dropped++;
        continue;
      }
      seen.add(it.text);
      kept.push(it);
    }
    if (dropped > 0) {
      ClipboardStore.cache = kept;
      ClipboardStore.persist();
      ClipboardStore.publish();
      Logger.d(`dedupeByText: dropped ${dropped}, total=${kept.length}`);
    }
    return dropped;
  }

  /**
   * 合并对端快照：**只补本地没有的**（不删），返回新增条数。
   * `items` 顺序 = 旧→新（对端快照口径）；内部 `unshift` ⇒ 最终仍是最新在前。会先自愈一次本地重复。
   */
  static mergeItems(items: ClipItem[]): number {
    ClipboardStore.dedupeByText();
    if (items.length === 0) {
      return 0;
    }
    const known: Set<string> = new Set<string>();
    for (let i = 0; i < ClipboardStore.cache.length; i++) {
      known.add(ClipboardStore.cache[i].text);
    }
    let added: number = 0;
    for (let i = 0; i < items.length; i++) {
      const it: ClipItem = items[i];
      const text: string = it.text;
      if (text === undefined || text === null || text.trim().length === 0) {
        continue;
      }
      if (known.has(text)) {
        continue;
      }
      known.add(text);
      const ts: number = it.timestamp > 0 ? it.timestamp : Date.now();
      ClipboardStore.cache.unshift({ text: text, timestamp: ts });
      added++;
    }
    if (added > 0) {
      if (ClipboardStore.cache.length > MAX_ITEMS) {
        ClipboardStore.cache = ClipboardStore.cache.slice(0, MAX_ITEMS);
      }
      ClipboardStore.persist();
      ClipboardStore.publish();
      Logger.d(`mergeItems: +${added}, total=${ClipboardStore.cache.length}`);
    }
    return added;
  }

  /** 解析对端快照 JSON：新格式 `[{text,timestamp}]`（旧→新）；兼容老的 `["text"]` */
  static parseSnapshot(json: string): ClipItem[] {
    const out: ClipItem[] = [];
    try {
      const arr: Object[] = JSON.parse(json) as Object[];
      for (let i = 0; i < arr.length; i++) {
        const v: Object = arr[i];
        if (typeof v === 'string') {
          const s: string = v as string;
          if (s.length > 0) {
            out.push({ text: s, timestamp: 0 });
          }
          continue;
        }
        if (v === null || typeof v !== 'object') {
          continue;
        }
        const rec: Record<string, Object> = v as Record<string, Object>;
        const t: Object = rec.text;
        const ts: Object = rec.timestamp;
        if (typeof t === 'string' && (t as string).length > 0) {
          out.push({ text: t as string, timestamp: typeof ts === 'number' ? ts as number : 0 });
        }
      }
    } catch (err) {
      Logger.w('parseSnapshot failed');
    }
    return out;
  }

  /** 订阅系统剪贴板变化（幂等） */
  static startWatch(): void {
    if (ClipboardStore.watching) {
      return;
    }
    try {
      const sp: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      const cb = () => {
        Logger.d('pasteboard update event');
        ClipboardStore.capture();
      };
      ClipboardStore.listener = cb;
      sp.on('update', cb);
      ClipboardStore.watching = true;
      Logger.d('startWatch: subscribed pasteboard update');
    } catch (err) {
      Logger.w('startWatch: subscribe failed');
    }
  }

  static stopWatch(): void {
    if (!ClipboardStore.watching || ClipboardStore.listener === undefined) {
      return;
    }
    try {
      const sp: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      sp.off('update', ClipboardStore.listener);
    } catch (err) {
      Logger.w('stopWatch: unsubscribe failed');
    }
    ClipboardStore.listener = undefined;
    ClipboardStore.watching = false;
  }

  /**
   * 采集当前剪贴板文本。
   * 先做 hasData / hasDataType / getChangeCount 预检，避免无意义的权限弹窗
   * （见官方《申请访问剪贴板权限》的「剪贴板弹窗适配优化」）。
   */
  static async capture(): Promise<void> {
    try {
      const sp: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      if (!sp.hasData()) {
        ClipboardStore.setStatus('剪贴板为空');
        return;
      }
      if (!sp.hasDataType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        ClipboardStore.setStatus('剪贴板里没有文字');
        return;
      }
      const count: number = sp.getChangeCount();
      if (count === ClipboardStore.lastChangeCount) {
        Logger.d('capture: changeCount unchanged, skip');
        return;
      }
      const data: pasteboard.PasteData = await sp.getData();
      ClipboardStore.lastChangeCount = count;
      const n: number = data.getRecordCount();
      let added: boolean = false;
      for (let i = 0; i < n; i++) {
        const record: pasteboard.PasteDataRecord = data.getRecord(i);
        const text: string = record.toPlainText();
        if (text !== undefined && text !== null && text.trim().length > 0) {
          if (ClipboardStore.addText(text)) {
            added = true;
          }
        }
      }
      ClipboardStore.setStatus(added ? '已收集新内容' : '没有新内容');
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`capture failed: code=${e.code}, message=${e.message}`);
      ClipboardStore.setStatus(`读取剪贴板失败（${e.code}）：需要「剪贴板读取」权限`);
    }
  }

  /** 把一条历史写回系统剪贴板（对齐 Android 版「合并到剪贴板 / 点选粘贴」） */
  static async copyToPasteboard(text: string): Promise<void> {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const sp: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      await sp.setData(data);
      ClipboardStore.setStatus('已写回系统剪贴板');
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`copyToPasteboard failed: code=${e.code}, message=${e.message}`);
      ClipboardStore.setStatus(`写回剪贴板失败（${e.code}）`);
    }
  }

  private static store(): preferences.Preferences | undefined {
    if (ClipboardStore.ctx === undefined) {
      return undefined;
    }
    try {
      return preferences.getPreferencesSync(ClipboardStore.ctx, { name: STORE_NAME });
    } catch (err) {
      Logger.w('store: getPreferencesSync failed');
      return undefined;
    }
  }

  private static persist(): void {
    const p = ClipboardStore.store();
    if (p === undefined) {
      return;
    }
    try {
      const limit: number =
        ClipboardStore.cache.length > MAX_ITEMS ? MAX_ITEMS : ClipboardStore.cache.length;
      const json: string = JSON.stringify(ClipboardStore.cache.slice(0, limit));
      p.putSync(KEY_ITEMS, json);
      p.flushSync();
    } catch (err) {
      Logger.w('persist: save failed');
    }
  }

  private static setStatus(text: string): void {
    ClipboardStore.status = text;
    ClipboardStore.publish();
  }

  /** 把最新状态推给界面（AppStorage 订阅） */
  private static publish(): void {
    try {
      AppStorage.setOrCreate<ClipItem[]>(STATE_ITEMS, ClipboardStore.cache.slice());
      AppStorage.setOrCreate<string>(STATE_STATUS, ClipboardStore.status);
    } catch (err) {
      Logger.w('publish: AppStorage failed');
    }
  }
}
