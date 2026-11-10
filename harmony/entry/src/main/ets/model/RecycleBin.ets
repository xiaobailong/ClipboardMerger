import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ClipItem } from './ClipboardStore';
import { Logger } from './Logger';

/** 一条回收站记录（字段对齐 Android 版 RecyclerItem：content → text） */
export interface RecycleItem {
  id: number;
  text: string;
  timestamp: number;
  /** 删除批次（yyyy-MM-dd HH:mm:ss，同一次删除共用一个） */
  batchId: string;
  /** 移入回收站的时间 */
  deletedAt: number;
  /** 来源：app / ime（对齐 Android moveToRecycleBin(items, source)） */
  source: string;
}

/** 供界面订阅的状态键（AppStorage） */
export const STATE_RECYCLE: string = 'recycleItems';

const STORE_NAME: string = 'clipboard_recycle_bin';
const KEY_ITEMS: string = 'items';
const MAX_ITEMS: number = 5000;

/** 保留天数设置（与 App 其它设置同库：clipboard_merger_settings） */
const SETTINGS_STORE: string = 'clipboard_merger_settings';
const KEY_RETENTION_DAYS: string = 'recycle_bin_retention_days';
const DEFAULT_RETENTION_DAYS: number = 30;
/** -1 = 永久保留（对齐 Android RecycleBinRepository.RETENTION_FOREVER） */
export const RETENTION_FOREVER: number = -1;

/**
 * 回收站仓库（对齐 Android 版 RecycleBinRepository）
 *
 * ⚠️ 平台差异：输入法 Extension 与 App 是两个沙箱（PIT-039），数据存在 **App 进程**，
 * 键盘侧的删除/清空通过 EventBus 事件带过来（见 pages/Index.ets 的 histSub）。
 * 键盘进程读不到这里的回收站 ⇒ 回收站页面只在 App 里。
 */
export class RecycleBinStore {
  private static ctx: common.Context | undefined = undefined;
  private static cache: RecycleItem[] = [];

  static init(context: common.Context): void {
    if (RecycleBinStore.ctx !== undefined) {
      return;
    }
    RecycleBinStore.ctx = context;
    const list: RecycleItem[] = RecycleBinStore.load();
    Logger.d(`RecycleBinStore.init: loaded ${list.length} items`);
    RecycleBinStore.publish();
  }

  /** 内存里的回收站记录（最新删除在前） */
  static getItems(): RecycleItem[] {
    return RecycleBinStore.cache;
  }

  /** 从 preferences 读回收站（同步），顺带清理超过保留天数的记录 */
  static load(): RecycleItem[] {
    const p = RecycleBinStore.store();
    let list: RecycleItem[] = [];
    if (p !== undefined) {
      try {
        const raw: preferences.ValueType = p.getSync(KEY_ITEMS, '[]');
        const json: string = typeof raw === 'string' ? raw : '[]';
        const parsed: RecycleItem[] = JSON.parse(json) as RecycleItem[];
        for (let i = 0; i < parsed.length; i++) {
          const it: RecycleItem = parsed[i];
          if (it === undefined || it === null) {
            continue;
          }
          const text: string = it.text;
          if (text === undefined || text === null || text.length === 0) {
            continue;
          }
          const item: RecycleItem = {
            id: it.id > 0 ? it.id : Date.now() + i,
            text: text,
            timestamp: it.timestamp > 0 ? it.timestamp : Date.now(),
            batchId: typeof it.batchId === 'string' && it.batchId !== '' ? it.batchId : '未知批次',
            deletedAt: it.deletedAt > 0 ? it.deletedAt : Date.now(),
            source: typeof it.source === 'string' && it.source !== '' ? it.source : 'app'
          };
          list.push(item);
        }
      } catch (err) {
        Logger.w('RecycleBinStore.load: parse items failed, reset to empty');
        list = [];
      }
    }
    RecycleBinStore.cache = RecycleBinStore.purgeExpired(list);
    RecycleBinStore.publish();
    return RecycleBinStore.cache;
  }

  /** 清理超过保留天数的记录（永久保留时原样返回）；有清理会顺手持久化 */
  private static purgeExpired(items: RecycleItem[]): RecycleItem[] {
    const days: number = RecycleBinStore.retentionDays();
    if (days === RETENTION_FOREVER) {
      return items;
    }
    const cutoff: number = Date.now() - days * 24 * 60 * 60 * 1000;
    const kept: RecycleItem[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].deletedAt >= cutoff) {
        kept.push(items[i]);
      }
    }
    const removed: number = items.length - kept.length;
    if (removed > 0) {
      Logger.d(`RecycleBinStore.purgeExpired: removed ${removed} expired items (retention=${days} days)`);
      RecycleBinStore.cache = kept;
      RecycleBinStore.persist();
    }
    return kept;
  }

  /**
   * 把剪贴板项移入回收站（对齐 Android moveToRecycleBin）。
   * 去重规则：回收站中已存在相同 text 的项不再重复添加。
   * 返回本次删除批次 id（空列表时返回空串）。
   */
  static moveToRecycleBin(items: ClipItem[], source: string): string {
    if (items.length === 0) {
      Logger.d('RecycleBinStore.moveToRecycleBin: empty list, skip');
      return '';
    }
    const batchId: string = RecycleBinStore.fmtBatch(new Date());
    const now: number = Date.now();
    const existing: RecycleItem[] = RecycleBinStore.load();
    const contents: Set<string> = new Set<string>();
    for (let i = 0; i < existing.length; i++) {
      contents.add(existing[i].text);
    }
    const usedIds: Set<number> = new Set<number>();
    let added: number = 0;
    for (let i = 0; i < items.length; i++) {
      const src: ClipItem = items[i];
      const text: string = src.text;
      if (text === undefined || text === null || text.trim().length === 0) {
        continue;
      }
      if (contents.has(text)) {
        Logger.d('RecycleBinStore.moveToRecycleBin: skip duplicate content');
        continue;
      }
      contents.add(text);
      let newId: number = now + (src.timestamp % 1000);
      while (usedIds.has(newId) || RecycleBinStore.hasId(existing, newId)) {
        newId++;
      }
      usedIds.add(newId);
      const item: RecycleItem = {
        id: newId,
        text: text,
        timestamp: src.timestamp > 0 ? src.timestamp : now,
        batchId: batchId,
        deletedAt: now,
        source: source
      };
      existing.unshift(item);
      added++;
    }
    RecycleBinStore.cache = existing.length > MAX_ITEMS ? existing.slice(0, MAX_ITEMS) : existing;
    RecycleBinStore.persist();
    RecycleBinStore.publish();
    Logger.d(`RecycleBinStore.moveToRecycleBin: batchId=${batchId}, added=${added}, total=${RecycleBinStore.cache.length}`);
    return batchId;
  }

  /** 永久删除指定 id（对齐 Android removeItems） */
  static removeIds(ids: number[]): void {
    if (ids.length === 0) {
      return;
    }
    const idSet: Set<number> = new Set<number>();
    for (let i = 0; i < ids.length; i++) {
      idSet.add(ids[i]);
    }
    const existing: RecycleItem[] = RecycleBinStore.load();
    const kept: RecycleItem[] = [];
    for (let i = 0; i < existing.length; i++) {
      if (!idSet.has(existing[i].id)) {
        kept.push(existing[i]);
      }
    }
    RecycleBinStore.cache = kept;
    RecycleBinStore.persist();
    RecycleBinStore.publish();
    Logger.d(`RecycleBinStore.removeIds: removed ${existing.length - kept.length} items`);
  }

  /** 永久删除某个删除批次（对齐 Android removeBatch） */
  static removeBatch(batchId: string): void {
    const existing: RecycleItem[] = RecycleBinStore.load();
    const kept: RecycleItem[] = [];
    for (let i = 0; i < existing.length; i++) {
      if (existing[i].batchId !== batchId) {
        kept.push(existing[i]);
      }
    }
    RecycleBinStore.cache = kept;
    RecycleBinStore.persist();
    RecycleBinStore.publish();
    Logger.d(`RecycleBinStore.removeBatch: batchId=${batchId}, left=${kept.length}`);
  }

  /** 全部删除批次（新→旧；对齐 Android getBatchIds） */
  static batchIds(): string[] {
    const items: RecycleItem[] = RecycleBinStore.load();
    const out: string[] = [];
    for (let i = 0; i < items.length; i++) {
      if (out.indexOf(items[i].batchId) < 0) {
        out.push(items[i].batchId);
      }
    }
    out.sort((a: string, b: string): number => a < b ? 1 : (a > b ? -1 : 0));
    return out;
  }

  /** 某个批次的记录（对齐 Android getItemsByBatch） */
  static itemsByBatch(batchId: string): RecycleItem[] {
    const items: RecycleItem[] = RecycleBinStore.load();
    const out: RecycleItem[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].batchId === batchId) {
        out.push(items[i]);
      }
    }
    return out;
  }

  /** 清空回收站（不可撤销） */
  static clearAll(): void {
    RecycleBinStore.cache = [];
    RecycleBinStore.persist();
    RecycleBinStore.publish();
    Logger.d('RecycleBinStore.clearAll: done');
  }

  /** 保留天数（-1 = 永久保留） */
  static retentionDays(): number {
    const ctx = RecycleBinStore.ctx;
    if (ctx === undefined) {
      return DEFAULT_RETENTION_DAYS;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: SETTINGS_STORE });
      const raw: preferences.ValueType = store.getSync(KEY_RETENTION_DAYS, DEFAULT_RETENTION_DAYS);
      return typeof raw === 'number' ? raw : DEFAULT_RETENTION_DAYS;
    } catch (err) {
      Logger.w('RecycleBinStore.retentionDays read failed');
      return DEFAULT_RETENTION_DAYS;
    }
  }

  /** 设置保留天数（改完立刻按新规则清理一次） */
  static setRetentionDays(days: number): void {
    const ctx = RecycleBinStore.ctx;
    if (ctx !== undefined) {
      try {
        const store = preferences.getPreferencesSync(ctx, { name: SETTINGS_STORE });
        store.putSync(KEY_RETENTION_DAYS, days);
        store.flushSync();
      } catch (err) {
        Logger.w('RecycleBinStore.setRetentionDays: persist failed');
      }
    }
    Logger.d(`RecycleBinStore.setRetentionDays: days=${days}`);
    RecycleBinStore.cache = RecycleBinStore.purgeExpired(RecycleBinStore.cache);
    RecycleBinStore.persist();
    RecycleBinStore.publish();
  }

  private static hasId(items: RecycleItem[], id: number): boolean {
    for (let i = 0; i < items.length; i++) {
      if (items[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /** 批次 id 格式对齐 Android：yyyy-MM-dd HH:mm:ss */
  private static fmtBatch(d: Date): string {
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
      `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }

  private static store(): preferences.Preferences | undefined {
    if (RecycleBinStore.ctx === undefined) {
      return undefined;
    }
    try {
      return preferences.getPreferencesSync(RecycleBinStore.ctx, { name: STORE_NAME });
    } catch (err) {
      Logger.w('RecycleBinStore.store: getPreferencesSync failed');
      return undefined;
    }
  }

  private static persist(): void {
    const p = RecycleBinStore.store();
    if (p === undefined) {
      return;
    }
    try {
      const limit: number =
        RecycleBinStore.cache.length > MAX_ITEMS ? MAX_ITEMS : RecycleBinStore.cache.length;
      const json: string = JSON.stringify(RecycleBinStore.cache.slice(0, limit));
      p.putSync(KEY_ITEMS, json);
      p.flushSync();
    } catch (err) {
      Logger.w('RecycleBinStore.persist: save failed');
    }
  }

  private static publish(): void {
    try {
      AppStorage.setOrCreate<RecycleItem[]>(STATE_RECYCLE, RecycleBinStore.cache.slice());
    } catch (err) {
      Logger.w('RecycleBinStore.publish: AppStorage failed');
    }
  }
}
