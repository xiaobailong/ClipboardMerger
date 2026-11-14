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

/**
 * 跨进程「删除历史」载荷：删哪些条目 + 这次删除动作的身份（批次 / 动作时间）。
 * 键盘侧建回收站条目时必须原样使用 batchId / opAt，保证 (text, deletedAt) 两边一致（PIT-053）。
 */
export interface HistRemoval {
  items: ClipItem[];
  batchId: string;
  opAt: number;
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
    // 内容唯一（PIT-054）：老数据里可能有同文本多条 ⇒ 启动时一次性收敛（保留最新那条）
    const dropped: number = ClipboardStore.dedupeByText();
    Logger.d(`ClipboardStore.init: loaded ${ClipboardStore.cache.length} items, dedupe dropped ${dropped}`);
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
   * ⚠️ 目前**两侧都不注册**：键盘那份是权威源，App 打开页面时拉全量覆盖即可，
   * 键盘侧的变化不再实时推给 App（`PIT-051`）；两侧都注册会回声（`PIT-050`）。
   * 保留这个钩子只为将来确实需要「变化即推送」的场景。
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

  /**
   * 新增一条（空白跳过）。**历史保持「同内容只有一条」**（PIT-054）：
   * 再次复制同一段文本 = 把那条更新到最前（时间戳刷新），而不是新增重复条目。
   *
   * 为什么要内容唯一：App 那侧按内容勾选/删除（UI 用 text 做键），历史里若存在
   * 同文本多条，镜像按内容去重后就只显示一条 ⇒ 删掉它、旧那条又冒出来（"删不掉"）。
   */
  static addText(text: string): boolean {
    if (text === undefined || text === null || text.trim().length === 0) {
      return false;
    }
    const ts: number = Date.now();
    const dup: number = ClipboardStore.indexOfExact(text, 0);
    if (dup === 0 && ClipboardStore.cache[0].timestamp === ts) {
      // 极端情况：同一毫秒重复触发，视为同一条
      return false;
    }
    if (dup >= 0) {
      // 已存在同内容：删掉旧的，下面按最新时间重新插到最前
      ClipboardStore.cache.splice(dup, 1);
      Logger.d(`addText: moved existing item to top (idx=${dup})`);
    }
    const item: ClipItem = { text: text, timestamp: ts };
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

  /**
   * 精准删除一批（跨进程同步用）：按 `text` + `timestamp` 精确匹配，**不做通配、不做兜底**。
   * 用于 App「清空全部」这类操作 —— 补发时必须只删当时那些条目，不能碰后来新增的内容。
   * 返回实际删掉的条数。
   */
  static removeExact(items: ClipItem[]): number {
    if (items.length === 0) {
      return 0;
    }
    const keys: Set<string> = new Set<string>();
    for (let i = 0; i < items.length; i++) {
      const it: ClipItem = items[i];
      if (it.text === undefined || it.text === null) {
        continue;
      }
      keys.add(`${it.timestamp}|${it.text}`);
    }
    if (keys.size === 0) {
      return 0;
    }
    const kept: ClipItem[] = [];
    let removed: number = 0;
    for (let i = 0; i < ClipboardStore.cache.length; i++) {
      const it: ClipItem = ClipboardStore.cache[i];
      if (keys.has(`${it.timestamp}|${it.text}`)) {
        removed++;
        continue;
      }
      kept.push(it);
    }
    if (removed > 0) {
      ClipboardStore.cache = kept;
      ClipboardStore.persist();
      ClipboardStore.publish();
      Logger.d(`removeExact: removed ${removed}/${items.length}`);
    }
    return removed;
  }

  /** 找出条目在历史里的下标（text 精确，ts>0 时要求时间戳也一致；找不到返回 -1） */
  static indexOfExact(text: string, ts: number): number {
    for (let i = 0; i < ClipboardStore.cache.length; i++) {
      const it: ClipItem = ClipboardStore.cache[i];
      if (it.text === text && (ts === 0 || it.timestamp === ts)) {
        return i;
      }
    }
    return -1;
  }

  static clear(): void {
    // 清空前留一份快照：键盘进程清空时把它塞进 'clear' 事件，App 侧据此把内容移入回收站
    // （两个进程的 preferences 不互通，见 PIT-039；'clear' 的 text 字段以前是空串，这里复用）
    const before: ClipItem[] = ClipboardStore.cache.slice();
    ClipboardStore.cache = [];
    ClipboardStore.persist();
    ClipboardStore.publish();
    Logger.d(`clear: history cleared, snapshot=${before.length}`);
    ClipboardStore.notifyChange('clear', JSON.stringify(before), Date.now());
  }

  /**
   * 恢复回收站条目到历史：**恢复即置顶**（时间戳刷新到现在，而不是沿用原复制时间）。
   *
   * 为什么刷时间戳：历史按时间戳排序，键盘那份是权威源 ⇒ 若只在本机置顶，
   * 一拉全量就又按原时间回到中间。刷成"现在"并让键盘侧按内容 upsert（见 mergeItems），
   * 两边顺序才一致。
   * 同时保持内容唯一：历史里同内容的旧条目会被替换掉。
   * 返回实际恢复条数。
   */
  static restoreItems(items: ClipItem[]): number {
    if (items.length === 0) {
      return 0;
    }
    // 去重 + 保持"列表里的先后顺序"（入参通常已是 newest-first，按时间倒序稳定一下）
    const sorted: ClipItem[] = items.slice();
    sorted.sort((a: ClipItem, b: ClipItem): number => b.timestamp - a.timestamp);
    const texts: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < sorted.length; i++) {
      const text: string = sorted[i].text;
      if (text === undefined || text === null || text.trim().length === 0) {
        continue;
      }
      if (seen.has(text)) {
        continue;
      }
      seen.add(text);
      texts.push(text);
    }
    if (texts.length === 0) {
      return 0;
    }
    // 置顶时间：保证比历史里任何一条都新（同毫秒也不怕），再按顺序递减
    let maxTs: number = 0;
    for (let i = 0; i < ClipboardStore.cache.length; i++) {
      if (ClipboardStore.cache[i].timestamp > maxTs) {
        maxTs = ClipboardStore.cache[i].timestamp;
      }
    }
    const base: number = Math.max(Date.now(), maxTs + 1);
    const restored: ClipItem[] = [];
    for (let i = 0; i < texts.length; i++) {
      restored.push({ text: texts[i], timestamp: base + (texts.length - 1 - i) });
    }
    // 去掉历史里同内容的旧条目（内容唯一），再把恢复的放到最前
    const kept: ClipItem[] = [];
    for (let i = 0; i < ClipboardStore.cache.length; i++) {
      const it: ClipItem = ClipboardStore.cache[i];
      if (!seen.has(it.text)) {
        kept.push(it);
      }
    }
    ClipboardStore.cache = restored.concat(kept);
    if (ClipboardStore.cache.length > MAX_ITEMS) {
      ClipboardStore.cache = ClipboardStore.cache.slice(0, MAX_ITEMS);
    }
    ClipboardStore.persist();
    ClipboardStore.publish();
    Logger.d(`restoreItems: restored ${restored.length}/${items.length}（已置顶，base=${base}）`);
    return restored.length;
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
   * 合并对端快照（App → 键盘，目前只用于「恢复回收站条目」）：
   * **补缺 + 同内容取更新的时间戳**（upsoert 语义），不删本地多余的条。
   *
   * 为什么要刷新已有条目的时间戳：App 侧「恢复即置顶」会把恢复条目的时间戳刷成现在，
   * 键盘这份若还按"内容已存在就跳过"，恢复过来的条目在键盘里就还躺在原位，
   * App 一拉全量又被拉回中间 ⇒ 两边顺序不一致。
   *
   * 返回实际变更（新增 + 更新时间戳）的条数。
   */
  static mergeItems(items: ClipItem[]): number {
    ClipboardStore.dedupeByText();
    if (items.length === 0) {
      return 0;
    }
    let changed: number = 0;
    for (let i = 0; i < items.length; i++) {
      const it: ClipItem = items[i];
      const text: string = it.text;
      if (text === undefined || text === null || text.trim().length === 0) {
        continue;
      }
      const ts: number = it.timestamp > 0 ? it.timestamp : Date.now();
      const idx: number = ClipboardStore.indexOfExact(text, 0);
      if (idx >= 0) {
        // 已有同内容：只在对方更新时刷新时间戳（恢复置顶），否则保持不动
        if (ts > ClipboardStore.cache[idx].timestamp) {
          ClipboardStore.cache[idx] = { text: text, timestamp: ts };
          changed++;
        }
        continue;
      }
      ClipboardStore.cache.push({ text: text, timestamp: ts });
      changed++;
    }
    if (changed > 0) {
      // 更新时间戳后顺序会乱 ⇒ 统一按时间倒序重排（与展示口径一致）
      ClipboardStore.cache.sort((a: ClipItem, b: ClipItem): number => b.timestamp - a.timestamp);
      if (ClipboardStore.cache.length > MAX_ITEMS) {
        ClipboardStore.cache = ClipboardStore.cache.slice(0, MAX_ITEMS);
      }
      ClipboardStore.persist();
      ClipboardStore.publish();
      Logger.d(`mergeItems: 变更 ${changed}/${items.length}, total=${ClipboardStore.cache.length}`);
    }
    return changed;
  }

  /**
   * 全量替换历史（App 拉回键盘快照后调用）：键盘历史是权威源 ⇒ **整份覆盖**，不做合并。
   * 顺带按时间倒序排好、同文案去重（留最新一条），最多留 MAX_ITEMS 条。
   */
  static replaceAll(items: ClipItem[]): void {
    const sorted: ClipItem[] = items.slice();
    sorted.sort((a: ClipItem, b: ClipItem): number => b.timestamp - a.timestamp);
    const seen: Set<string> = new Set<string>();
    const out: ClipItem[] = [];
    for (let i = 0; i < sorted.length; i++) {
      const it: ClipItem = sorted[i];
      const text: string = it.text;
      if (text === undefined || text === null || text.trim().length === 0) {
        continue;
      }
      if (seen.has(text)) {
        continue;
      }
      seen.add(text);
      out.push({ text: text, timestamp: it.timestamp > 0 ? it.timestamp : Date.now() });
      if (out.length >= MAX_ITEMS) {
        break;
      }
    }
    ClipboardStore.cache = out;
    ClipboardStore.persist();
    ClipboardStore.publish();
    Logger.d(`replaceAll: ${out.length} items (mirror of IME)`);
  }

  /**
   * 「删除历史」的跨进程载荷 JSON：**精确到条目** + 这次删除动作的身份（批次 / 动作时间）。
   * 键盘侧必须用同一个 batchId / opAt 建回收站条目，这样两边条目的跨进程身份
   * (text, deletedAt) 才一致（PIT-053）。
   */
  static removalJson(items: ClipItem[], batchId: string, opAt: number): string {
    const payload: HistRemoval = { items: items, batchId: batchId, opAt: opAt };
    return JSON.stringify(payload);
  }

  /** 解析「删除历史」载荷（脏数据直接丢） */
  static parseRemoval(json: string): HistRemoval | undefined {
    if (json === undefined || json === null || json === '') {
      return undefined;
    }
    try {
      const p: HistRemoval = JSON.parse(json) as HistRemoval;
      if (p === undefined || p === null) {
        return undefined;
      }
      const items: ClipItem[] = p.items === undefined || p.items === null ? [] : p.items;
      return {
        items: items,
        batchId: typeof p.batchId === 'string' ? p.batchId : '',
        opAt: typeof p.opAt === 'number' ? p.opAt : 0
      };
    } catch (err) {
      Logger.w('ClipboardStore.parseRemoval: parse failed');
      return undefined;
    }
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
