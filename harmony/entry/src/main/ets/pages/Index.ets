import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { inputMethod, InputMethodSubtype } from '@kit.IMEKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import {
  EventBus,
  HistEvent,
  OP_ACK,
  OP_HIST_REMOVE_MANY,
  OP_RECYCLE_PULL,
  OP_RECYCLE_REMOVE,
  OP_RECYCLE_SNAPSHOT,
  OP_SETTINGS_PULL,
  OP_SETTINGS_SET,
  OP_SETTINGS_SNAPSHOT,
  SRC_APP
} from '../model/EventBus';
import settings from '@ohos.settings';
import { ClipItem, ClipboardStore } from '../model/ClipboardStore';
import {
  RecycleBinStore,
  RecycleItem,
  RecycleOpMeta,
  RETENTION_FOREVER,
  STATE_RECYCLE
} from '../model/RecycleBin';
import { BUILD_TIME, BUILD_TYPE, GIT_COMMIT } from '../model/BuildInfo';
import { GhConfig, GitHubStore } from '../model/GitHub';
import { ImeItem, ImeSettings } from '../model/ImeSettings';
import {
  SET_KEY_RETENTION,
  SET_KEY_TARGET,
  SET_KEY_THEME,
  SettingChange,
  SettingsSnapshot,
  SettingsSync
} from '../model/SettingsSync';
import {
  ChunkAssembler,
  ChunkPayload,
  SNAP_HIST,
  SNAP_RECYCLE,
  SyncChunk
} from '../model/SyncChunk';
import { Logger } from '../model/Logger';
import {
  Palette,
  paletteOf,
  STATE_THEME,
  THEME_ANDROID,
  THEME_HARMONY,
  ThemeStore
} from '../model/Theme';

const APP_BUNDLE: string = 'com.example.clipboardmerger';
const PERM_READ_PASTEBOARD: Permissions = 'ohos.permission.READ_PASTEBOARD';
const LIST_LIMIT: number = 200;
const MERGE_SEP: string = '\n';
/** 顶栏图标说明（设置里的「按键」用；name 写**全量名称**，按钮上的简写放在 hint 里） */
interface ImeKeyHint {
  icon: Resource;
  name: string;
  hint: string;
}

/** 简化名称说明：name = 全量名称，hint = 按钮上显示什么 + 作用 */
interface NameHint {
  name: string;
  hint: string;
}

/** 待补发操作队列上限（溢出丢最早的；每条操作都是有作用域的，丢只影响"那次同步"） */
const PENDING_MAX: number = 200;
/** 待补发队列落盘（App 进程被杀也不丢；键盘下次 hello 时补发 + ack 出队） */
const PENDING_STORE: string = 'clipboard_merger_sync';
const K_PENDING: string = 'pending_ops';

/**
 * 主界面：对齐 Android 版 activity_main.xml
 * Toolbar(剪集 + 更多) → Tab[剪切板 / 回收站 / GitHub] → 按钮栏[全选/取消全选/合并选中/清空全部]
 * → 输入法状态条 → 绑定App状态条 → 卡片列表(勾选 + 序号时间 + 内容3行 + 左滑删除)
 */
@Entry
@Component
struct Index {
  @StorageLink('clipItems') items: ClipItem[] = [];
  @StorageLink('clipStatus') status: string = '';
  @StorageLink('imeActive') imeActive: boolean = false;
  @State selectedTexts: string[] = [];
  @State curTab: number = 0;
  @State imeInfo: string = '输入法检测中…';
  @State notice: string = '';
  @State logOn: boolean = Logger.isEnabled();
  @State dialog: string = '';
  @State ghContent: string = '';
  @State ghStatus: string = '';
  @State aboutVersion: string = '';
  @State aboutBuild: string = '';
  @State aboutModel: string = '';
  @State bindLabel: string = '绑定App: 未设置';
  @State imeItems: ImeItem[] = [];
  @State targetLabel: string = '不限（默认切换）';
  /** 当前输入法显示名（状态条「当前：xxx」用） */
  @State curImeLabel: string = '';
  /** 系统「输入法已切换」事件回调（App 侧自己订阅；AppStorage 不跨进程，键盘进程写的 imeActive 到不了这里） */
  private imeChangeCb: ((p: inputMethod.InputMethodProperty, s: InputMethodSubtype) => void) | undefined = undefined;

  @State bindName: string = '抖音';
  @State permPaste: boolean = false;
  @State permNotify: boolean = false;
  @State swReport: string = '';
  @State kbRate: number = 0.30;
  /** 键盘侧事件订阅者（跨进程：键盘采集到新内容 → 提醒切换输入法） */
  private histSub: commonEventManager.CommonEventSubscriber | undefined = undefined;
  /** App 侧最近的删除/清空操作（键盘进程不在时先攒着，等它发 `hello` 时补发一次） */
  private pendingOps: HistEvent[] = [];
  /** 操作编号发号器（ack 用；进程内自增即可，不需要全局唯一） */
  private pendingSeq: number = 0;
  /** 全量快照拼片器：历史 / 回收站各一个（快照分片发送，见 SyncChunk） */
  private histAssembler: ChunkAssembler = new ChunkAssembler();
  private recycleAssembler: ChunkAssembler = new ChunkAssembler();
  @State ghOwner: string = '';
  @State ghRepo: string = '';
  @State ghPath: string = '';
  @State ghBranch: string = 'main';
  @State ghToken: string = '';
  @StorageLink(STATE_THEME) themeId: string = 'harmony';
  /** 回收站列表（App 进程独有；键盘侧删除/清空通过事件带过来） */
  @StorageLink(STATE_RECYCLE) recycleItems: RecycleItem[] = [];
  /** 回收站里勾选的记录 id（对应 Android RecyclerItem.isSelected） */
  @State recycleSelIds: number[] = [];
  /** 回收站保留天数（-1 = 永久保留） */
  @State retentionDays: number = 30;
  /** 「按批次恢复」弹层里的批次列表 */
  @State batchIds: string[] = [];
  /** 与 batchIds 一一对应的条数（不在 build 里反复读存储） */
  @State batchCounts: number[] = [];
  /** 正在等键盘回「回收站全量」（键盘回收站是权威源，App 这份只是镜像） */
  @State recycleSyncing: boolean = false;
  /** 拉全量的超时定时器（键盘进程没起来时不能把镜像清空） */
  private recyclePullTimer: number = -1;
  /** 拉剪切板全量的超时定时器（键盘进程没起来时不能把本机列表清空） */
  private clipPullTimer: number = -1;

  private p(): Palette {
    return paletteOf(this.themeId);
  }

  private host(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private isSelected(text: string): boolean {
    return this.selectedTexts.indexOf(text) >= 0;
  }

  private toggleSelect(text: string): void {
    const i: number = this.selectedTexts.indexOf(text);
    if (i >= 0) {
      this.selectedTexts.splice(i, 1);
    } else {
      this.selectedTexts.push(text);
    }
    this.selectedTexts = this.selectedTexts.slice();
  }

  private selectAll(): void {
    const all: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      all.push(this.items[i].text);
    }
    this.selectedTexts = all;
    this.notice = `已全选 ${all.length} 条`;
  }

  private deselectAll(): void {
    this.selectedTexts = [];
    this.notice = '已取消全选';
  }

  /** 「合并选中」：按列表顺序拼接后写回系统剪贴板（对齐 Android 的合并到剪贴板） */
  private mergeSelected(): void {
    if (this.selectedTexts.length === 0) {
      this.notice = '请至少选择一项';
      return;
    }
    const parts: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const it: ClipItem = this.items[i];
      if (this.selectedTexts.indexOf(it.text) >= 0) {
        parts.push(it.text);
      }
    }
    ClipboardStore.copyToPasteboard(parts.join(MERGE_SEP));
    this.notice = `合并内容已复制到剪贴板（${parts.length} 条）`;
    Logger.d(`mergeSelected: ${parts.length} items, ${parts.join(MERGE_SEP).length} chars`);
  }

  private clearAll(): void {
    const before: ClipItem[] = this.items.slice();
    let meta: RecycleOpMeta | undefined = undefined;
    if (before.length > 0) {
      meta = RecycleBinStore.moveToRecycleBin(before, 'app');
      Logger.d(`clearAll: moved ${before.length} items to recycle bin, batch=${meta.batchId}, opAt=${meta.opAt}`);
    }
    ClipboardStore.clear();
    this.selectedTexts = [];
    // 关键：带「被清空的条目清单 + 这次删除动作的身份」而不是发无作用域的 clear ——
    // 这条事件可能进 pendingOps 延迟补发，若无作用域会把键盘后来新采集的内容一起清掉（PIT-053）
    if (meta !== undefined && before.length > 0) {
      this.publishHist(OP_HIST_REMOVE_MANY,
        ClipboardStore.removalJson(before, meta.batchId, meta.opAt), Date.now());
    }
    this.notice = before.length > 0 ? `已清空 ${before.length} 条（已移入回收站）` : '剪贴板已清空';
  }

  /** 左滑删除：先移入回收站再删（对齐 Android ViewModel.deleteItem），并同步给键盘进程 */
  private deleteItem(item: ClipItem): void {
    const idx: number = this.items.indexOf(item);
    if (idx < 0) {
      return;
    }
    const meta: RecycleOpMeta = RecycleBinStore.moveToRecycleBin([item], 'app');
    ClipboardStore.removeAt(idx);
    // 键盘侧要用同一份 batchId / opAt 建回收站条目，跨进程身份才对得上
    this.publishHist(OP_HIST_REMOVE_MANY,
      ClipboardStore.removalJson([item], meta.batchId, meta.opAt), Date.now());
    this.notice = '已移入回收站';
    Logger.d(`deleteItem: index=${idx}, batch=${meta.batchId}, total=${RecycleBinStore.getItems().length}`);
  }

  // ==================== 回收站（对齐 Android 回收站 Tab） ====================

  private isRecycleSelected(id: number): boolean {
    return this.recycleSelIds.indexOf(id) >= 0;
  }

  private toggleRecycleSelect(id: number): void {
    const i: number = this.recycleSelIds.indexOf(id);
    if (i >= 0) {
      this.recycleSelIds.splice(i, 1);
    } else {
      this.recycleSelIds.push(id);
    }
    this.recycleSelIds = this.recycleSelIds.slice();
  }

  private selectAllRecycle(): void {
    const ids: number[] = [];
    for (let i = 0; i < this.recycleItems.length; i++) {
      ids.push(this.recycleItems[i].id);
    }
    this.recycleSelIds = ids;
    this.notice = `回收站已全选 ${ids.length} 条`;
  }

  private deselectAllRecycle(): void {
    this.recycleSelIds = [];
    this.notice = '已取消全选';
  }

  private selectedRecycleItems(): RecycleItem[] {
    const out: RecycleItem[] = [];
    for (let i = 0; i < this.recycleItems.length; i++) {
      if (this.recycleSelIds.indexOf(this.recycleItems[i].id) >= 0) {
        out.push(this.recycleItems[i]);
      }
    }
    return out;
  }

  private sourceLabel(src: string): string {
    return src === 'ime' ? '键盘' : '应用';
  }

  private retentionText(): string {
    return this.retentionDays === RETENTION_FOREVER ? '永久保留' : `${this.retentionDays} 天`;
  }

  private recycleBarText(): string {
    const sync: string = this.recycleSyncing ? '　同步中…' : '';
    return `🧹 回收站 ${this.recycleItems.length} 条　已选 ${this.recycleSelIds.length} 条　保留：${this.retentionText()}${sync}`;
  }

  /**
   * 打开回收站时向键盘要一次**全量**（键盘回收站是权威源），
   * 键盘回 `recycleSnapshot` 后由本机整份覆盖镜像（见 histSub）。
   * 键盘进程没起来（1.5s 无回应）⇒ 保留本机缓存，只提示，绝不清空。
   */
  private syncRecycleFromIme(): void {
    this.cancelRecyclePullTimer();
    this.recycleSyncing = true;
    EventBus.publish(OP_RECYCLE_PULL, '', Date.now(), SRC_APP);
    Logger.d('recyclePull → IME');
    this.recyclePullTimer = setTimeout(() => {
      this.recyclePullTimer = -1;
      this.recycleSyncing = false;
      this.notice = '键盘进程未运行，暂显示本机缓存';
      Logger.w('recyclePull: no reply from IME (timeout)');
    }, 1500);
  }

  private cancelRecyclePullTimer(): void {
    if (this.recyclePullTimer >= 0) {
      clearTimeout(this.recyclePullTimer);
      this.recyclePullTimer = -1;
    }
  }

  /**
   * 打开剪切板时向键盘要一次**全量**历史（键盘历史是权威源），
   * 键盘回 `snapshot` 后由本机整份覆盖（见 histSub），不合并。
   * 键盘进程没起来（1.5s 无回应）⇒ 保留本机缓存，只提示，绝不清空。
   */
  private syncClipboardFromIme(): void {
    this.cancelClipPullTimer();
    this.notice = '正在从键盘同步剪贴板…';
    EventBus.publish('pull', '', Date.now(), SRC_APP);
    Logger.d('clipPull → IME');
    this.clipPullTimer = setTimeout(() => {
      this.clipPullTimer = -1;
      this.notice = '键盘进程未运行，暂显示本机缓存';
      Logger.w('clipPull: no reply from IME (timeout)');
    }, 1500);
  }

  private cancelClipPullTimer(): void {
    if (this.clipPullTimer >= 0) {
      clearTimeout(this.clipPullTimer);
      this.clipPullTimer = -1;
    }
  }

  /**
   * 把 App 回收站里「不再存在于回收站」的记录回写给键盘（永久删除 / 恢复 / 清空都走这条）。
   * 下发的是**操作记录列表**：每条 = 动作类型 + 内容 + 动作时间（= 该条目的 deletedAt），
   * 键盘侧按 (text, at) 精确命中 —— 同一段文本被删/恢复/再删也不会被旧操作误伤（PIT-053）。
   */
  private notifyImeRecycleRemove(items: RecycleItem[], type: string): void {
    if (items.length === 0) {
      return;
    }
    this.publishHist(OP_RECYCLE_REMOVE, RecycleBinStore.opsJson(items, type), Date.now());
    Logger.d(`recycleRemove → IME: ${items.length} 条（${type}）`);
  }

  /** 恢复一组回收站记录到剪贴板历史（并顺带同步给键盘进程），返回实际恢复条数 */
  private restoreItems(items: RecycleItem[]): number {
    if (items.length === 0) {
      return 0;
    }
    const clipItems: ClipItem[] = [];
    for (let i = 0; i < items.length; i++) {
      clipItems.push({ text: items[i].text, timestamp: items[i].timestamp });
    }
    const n: number = ClipboardStore.restoreItems(clipItems);
    if (n <= 0) {
      return 0;
    }
    // 键盘那份也要跟上：发一条快照（键盘侧 mergeItems 会补缺 + 用更新的时间戳刷新顺序）。
    // 用**恢复后置顶的真实条目**（时间戳已被刷成"现在"），否则键盘按旧时间戳 upsert，顺序又回到中间。
    const top: ClipItem[] = ClipboardStore.getItems().slice(0, n);
    const asc: ClipItem[] = top.slice();
    asc.sort((a: ClipItem, b: ClipItem): number => a.timestamp - b.timestamp);
    this.publishHist('snapshot', JSON.stringify(asc), Date.now());
    Logger.d(`restoreItems: ${n}/${items.length} → history（已置顶）, snapshot → IME (${asc.length})`);
    return n;
  }

  private restoreSelected(): void {
    const sel: RecycleItem[] = this.selectedRecycleItems();
    if (sel.length === 0) {
      this.notice = '请先勾选要恢复的记录';
      return;
    }
    const ids: number[] = [];
    for (let i = 0; i < sel.length; i++) {
      ids.push(sel[i].id);
    }
    const n: number = this.restoreItems(sel);
    RecycleBinStore.removeIds(ids);
    // 键盘那份回收站里也要消失（它才是权威源，App 只是镜像）
    this.notifyImeRecycleRemove(sel, 'restore');
    this.recycleSelIds = [];
    this.notice = `已恢复选中 ${n} 条到剪贴板`;
  }

  private restoreAll(): void {
    if (this.recycleItems.length === 0) {
      this.notice = '回收站为空';
      return;
    }
    const all: RecycleItem[] = this.recycleItems.slice();
    const n: number = this.restoreItems(all);
    RecycleBinStore.clearAll();
    // 只删「恢复掉的这些内容」，不发无作用域的"清空"（延迟补发时不能误删后来的新记录）
    this.notifyImeRecycleRemove(all, 'restoreAll');
    this.recycleSelIds = [];
    this.notice = `已恢复全部 ${n}/${all.length} 条`;
  }

  private restoreRecent(): void {
    const batches: string[] = RecycleBinStore.batchIds();
    if (batches.length === 0) {
      this.notice = '回收站为空';
      return;
    }
    this.restoreBatch(batches[0]);
  }

  private restoreBatch(batchId: string): void {
    const items: RecycleItem[] = RecycleBinStore.itemsByBatch(batchId);
    if (items.length === 0) {
      this.notice = '该批次已无可恢复记录';
      return;
    }
    const n: number = this.restoreItems(items);
    RecycleBinStore.removeBatch(batchId);
    this.notifyImeRecycleRemove(items, 'restoreBatch');
    this.recycleSelIds = [];
    this.notice = `已恢复批次 ${batchId}（${n} 条）`;
  }

  /** 打开「按批次恢复」弹层（对齐 Android showRestoreBatchDialog） */
  private openBatchDialog(): void {
    this.batchIds = RecycleBinStore.batchIds();
    if (this.batchIds.length === 0) {
      this.notice = '回收站为空，没有可恢复的批次';
      return;
    }
    const counts: number[] = [];
    for (let i = 0; i < this.batchIds.length; i++) {
      counts.push(RecycleBinStore.itemsByBatch(this.batchIds[i]).length);
    }
    this.batchCounts = counts;
    this.dialog = 'batch';
  }

  /** 清空回收站（先弹确认，对齐 Android「此操作不可撤销」） */
  private confirmClearRecycle(): void {
    if (this.recycleItems.length === 0) {
      this.notice = '回收站为空';
      return;
    }
    this.dialog = 'recycleClear';
  }

  private doClearRecycle(): void {
    const doomed: RecycleItem[] = this.recycleItems.slice();
    const n: number = doomed.length;
    RecycleBinStore.clearAll();
    // 只删「这次清掉的那些内容」（延迟补发时不会误删键盘之后新入回收站的记录）
    this.notifyImeRecycleRemove(doomed, 'clear');
    this.recycleSelIds = [];
    this.notice = `已清空回收站（${n} 条已永久删除）`;
    Logger.d(`clearRecycleBin: removed ${n} items permanently`);
  }

  /**
   * 把 App 侧的操作发到**键盘进程**（App → IME 同步），并留一条待补发记录：
   * 公共事件只在两侧进程都活着时送达 ⇒ 键盘进程当时不在，就先攒着，等它发 `hello`（刚起来）时补发。
   *
   * 队列卫生（PIT-057）：
   *  ① 设置类改动**每个 key 只留最新一条**（同一项反复改不该把队列塞满）；
   *  ② 上限 200 条，溢出丢最早的（只丢"没送到"，且操作本身是有作用域的，不会放大影响）；
   *  ③ 快照回来时会把「已经被键盘应用过」的删除操作出队（见 pruneSatisfiedPending）。
   */
  private publishHist(op: string, text: string, ts: number): void {
    if (op === OP_SETTINGS_SET) {
      const ch: SettingChange | undefined = SettingsSync.parseChange(text);
      if (ch !== undefined) {
        for (let i = this.pendingOps.length - 1; i >= 0; i--) {
          const o: HistEvent = this.pendingOps[i];
          if (o.op !== OP_SETTINGS_SET) {
            continue;
          }
          const old: SettingChange | undefined = SettingsSync.parseChange(o.text);
          if (old !== undefined && old.key === ch.key) {
            this.pendingOps.splice(i, 1);
          }
        }
      }
    }
    if (this.pendingOps.length >= PENDING_MAX) {
      this.pendingOps.shift();
    }
    const id: number = ++this.pendingSeq;
    this.pendingOps.push({ op: op, text: text, ts: ts, src: SRC_APP, id: id });
    this.savePending();
    EventBus.publish(op, text, ts, SRC_APP, id);
    Logger.d(`publishHist: ${op} → IME #${id} (pending=${this.pendingOps.length})`);
  }

  /** 键盘顶栏图标 → 操作（设置里的「按键」说明；这里用**全量名称**，简写放 hint） */
  private keyHints(): ImeKeyHint[] {
    return [
      { icon: $r('sys.symbol.text_clipboard'), name: '粘贴', hint: '贴勾选的几条；没勾选贴最新一条' },
      { icon: $r('sys.symbol.list_bullet_square'), name: '全部粘贴', hint: '全部记录按顺序合并贴出' },
      { icon: $r('sys.symbol.keyboard_badge_globe'), name: '切换输入法', hint: '按钮名「切换」：切下一个；长按弹系统选择器' },
      { icon: $r('sys.symbol.delete_left'), name: '删除选中文字', hint: '按钮名「删除」：删编辑框选中的字；长按删勾选的历史' },
      { icon: $r('sys.symbol.eraser_line'), name: '清空剪贴板', hint: '按钮名「清空」：清空历史，内容进回收站' },
      { icon: $r('sys.symbol.gearshape'), name: '键盘设置', hint: '按钮名「设置」：切换目标 / 高度 / 皮肤 / 日志' },
      { icon: $r('sys.symbol.chevron_down'), name: '收起键盘', hint: '按钮名「收起」：收起键盘面板' },
      { icon: $r('sys.symbol.trash'), name: '键盘回收站', hint: '按钮名「回收站」：键盘侧回收站，可恢复 / 清空' }
    ];
  }

  /** 页面上被简化的文字按钮（全量名称 + 按钮上显示什么） */
  private shortHints(): NameHint[] {
    return [
      { name: '取消全选', hint: '按钮名「取消」' },
      { name: '合并选中', hint: '按钮名「合并」：把勾选的内容合并后复制到剪贴板' },
      { name: '恢复选中', hint: '按钮名「恢复」：把勾选的记录恢复到剪贴板（恢复到最前）' },
      { name: '恢复全部', hint: '按钮名「全恢复」：回收站里所有记录恢复（恢复到最前）' },
      { name: '恢复最近', hint: '按钮名「最近」：只恢复最近一次删除的那一批' },
      { name: '恢复批次', hint: '按钮名「批次」：按删除批次挑一批恢复' },
      { name: '清空全部 / 清空回收站', hint: '按钮名「清空」：清空历史（入回收站）或永久清空回收站' },
      { name: '清理日志', hint: '按钮名「清日志」：删掉已有日志文件' }
    ];
  }

  /** 待补发队列落盘：App 进程被杀后下次启动还能补发（ack 出队时也落盘） */
  private savePending(): void {
    try {
      const store = preferences.getPreferencesSync(this.host(), { name: PENDING_STORE });
      store.putSync(K_PENDING, JSON.stringify(this.pendingOps));
      store.flushSync();
    } catch (err) {
      Logger.w('savePending failed');
    }
  }

  /** 启动时恢复待补发队列（id 序列一起恢复，避免与既有条目撞号） */
  private loadPending(): void {
    try {
      const store = preferences.getPreferencesSync(this.host(), { name: PENDING_STORE });
      const raw: preferences.ValueType = store.getSync(K_PENDING, '[]');
      const json: string = typeof raw === 'string' ? raw : '[]';
      const arr: HistEvent[] = JSON.parse(json) as HistEvent[];
      const list: HistEvent[] = [];
      let maxId: number = 0;
      for (let i = 0; i < arr.length; i++) {
        const o: HistEvent = arr[i];
        if (o === undefined || o === null || typeof o.op !== 'string') {
          continue;
        }
        const id: number = typeof o.id === 'number' ? o.id : 0;
        if (id > maxId) {
          maxId = id;
        }
        list.push({
          op: o.op,
          text: typeof o.text === 'string' ? o.text : '',
          ts: typeof o.ts === 'number' ? o.ts : 0,
          src: SRC_APP,
          id: id
        });
      }
      this.pendingOps = list;
      this.pendingSeq = maxId;
      if (list.length > 0) {
        Logger.d(`loadPending: 恢复 ${list.length} 条待补发操作（maxId=${maxId}）`);
      }
    } catch (err) {
      Logger.w('loadPending failed');
      this.pendingOps = [];
    }
  }

  /** 收到键盘回执：把对应操作出队（不再需要补发） */
  private ackPending(id: number): void {
    if (id <= 0) {
      return;
    }
    let changed: boolean = false;
    for (let i = this.pendingOps.length - 1; i >= 0; i--) {
      if (this.pendingOps[i].id === id) {
        this.pendingOps.splice(i, 1);
        changed = true;
        Logger.d(`ack ← IME: 出队 #${id}（剩 ${this.pendingOps.length}）`);
      }
    }
    if (changed) {
      this.savePending();
    }
  }

  /** 还没送到键盘的「删除历史」影响面：`ts|text`（用于抵消快照回拉） */
  private pendingHistKeys(): Set<string> {
    const out: Set<string> = new Set<string>();
    for (let i = 0; i < this.pendingOps.length; i++) {
      const o: HistEvent = this.pendingOps[i];
      if (o.op !== OP_HIST_REMOVE_MANY) {
        continue;
      }
      const p = ClipboardStore.parseRemoval(o.text);
      if (p === undefined) {
        continue;
      }
      for (let k = 0; k < p.items.length; k++) {
        out.add(`${p.items[k].timestamp}|${p.items[k].text}`);
      }
    }
    return out;
  }

  /** 还没送到键盘的「回收站删除」影响面：`at|text` */
  private pendingRecycleKeys(): Set<string> {
    const out: Set<string> = new Set<string>();
    for (let i = 0; i < this.pendingOps.length; i++) {
      const o: HistEvent = this.pendingOps[i];
      if (o.op !== OP_RECYCLE_REMOVE) {
        continue;
      }
      const ops = RecycleBinStore.parseOps(o.text);
      for (let k = 0; k < ops.length; k++) {
        out.add(`${ops[k].at}|${ops[k].text}`);
      }
    }
    return out;
  }

  /**
   * 出队「已经被键盘应用过」的删除操作：快照里根本没有这些条目 ⇒ 键盘已处理（或本来就没有），
   * 不用再补发。顺带防止队列无限重放（PIT-057）。
   */
  private pruneSatisfiedPending(presentKeys: Set<string>): void {
    const kept: HistEvent[] = [];
    let dropped: number = 0;
    for (let i = 0; i < this.pendingOps.length; i++) {
      const o: HistEvent = this.pendingOps[i];
      let satisfied: boolean = false;
      if (o.op === OP_HIST_REMOVE_MANY) {
        const p = ClipboardStore.parseRemoval(o.text);
        if (p !== undefined && p.items.length > 0) {
          satisfied = true;
          for (let k = 0; k < p.items.length; k++) {
            if (presentKeys.has(`${p.items[k].timestamp}|${p.items[k].text}`)) {
              satisfied = false;
              break;
            }
          }
        }
      } else if (o.op === OP_RECYCLE_REMOVE) {
        const ops = RecycleBinStore.parseOps(o.text);
        if (ops.length > 0) {
          satisfied = true;
          for (let k = 0; k < ops.length; k++) {
            if (presentKeys.has(`${ops[k].at}|${ops[k].text}`)) {
              satisfied = false;
              break;
            }
          }
        }
      }
      if (satisfied) {
        dropped++;
        continue;
      }
      kept.push(o);
    }
    if (dropped > 0) {
      this.pendingOps = kept;
      this.savePending();
      Logger.d(`pruneSatisfiedPending: 出队 ${dropped} 条已生效操作（剩 ${kept.length}）`);
    }
  }

  /**
   * 应用键盘历史全量快照：
   * ① 先滤掉「本机已删、但还没送到键盘」的条目（否则刚删的会被快照拉回来，PIT-057）；
   * ② 再把已生效的删除操作出队；
   * ③ 最后整份覆盖。
   */
  private applyHistSnapshot(raw: ClipItem[]): void {
    const pending: Set<string> = this.pendingHistKeys();
    const present: Set<string> = new Set<string>();
    const kept: ClipItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      const it: ClipItem = raw[i];
      present.add(`${it.timestamp}|${it.text}`);
      if (pending.has(`${it.timestamp}|${it.text}`)) {
        continue;
      }
      kept.push(it);
    }
    this.pruneSatisfiedPending(present);
    this.cancelClipPullTimer();
    ClipboardStore.replaceAll(kept);
    this.selectedTexts = [];
    this.notice = `已从键盘侧同步剪贴板 ${kept.length} 条`;
    Logger.d(`snapshot ← IME: replace ${kept.length} 条（快照 ${raw.length}，本地待删 ${pending.size}）`);
  }

  /** 应用键盘回收站全量快照（同上：先滤掉本地待删的，再出队，最后覆盖） */
  private applyRecycleSnapshot(raw: RecycleItem[]): void {
    const pending: Set<string> = this.pendingRecycleKeys();
    const present: Set<string> = new Set<string>();
    const kept: RecycleItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      const it: RecycleItem = raw[i];
      present.add(`${it.deletedAt}|${it.text}`);
      if (pending.has(`${it.deletedAt}|${it.text}`)) {
        continue;
      }
      kept.push(it);
    }
    this.pruneSatisfiedPending(present);
    this.cancelRecyclePullTimer();
    this.recycleSyncing = false;
    RecycleBinStore.replaceAll(kept);
    this.recycleSelIds = [];
    this.notice = `已从键盘侧同步回收站 ${kept.length} 条`;
    Logger.d(`recycleSnapshot ← IME: replace ${kept.length} 条（快照 ${raw.length}，本地待删 ${pending.size}）`);
  }

  /** 向键盘要一次设置快照（皮肤 / 日志 / 键盘高度 / 切换目标 / 回收站保留天数 都以键盘为准） */
  private syncSettingsFromIme(): void {
    EventBus.publish(OP_SETTINGS_PULL, '', Date.now(), SRC_APP);
    Logger.d('settingsPull → IME');
  }

  /** 收键盘设置快照 ⇒ 写进本机各 store，再回读刷新界面状态（皮肤靠 @StorageLink 自动刷） */
  private applyImeSettings(json: string): void {
    const s: SettingsSnapshot | undefined = SettingsSync.parse(json);
    if (s === undefined) {
      return;
    }
    SettingsSync.applySnapshot(s);
    // 日志开关不参与同步（两端各管各的），所以这里不碰 this.logOn
    this.kbRate = ImeSettings.heightRate();
    this.retentionDays = RecycleBinStore.retentionDays();
    this.refreshIme();
    Logger.d(`settingsSnapshot ← IME: theme=${s.theme}, ` +
      `height=${s.heightRate}, retention=${s.retentionDays}`);
  }

  /**
   * App 里改了一条设置 ⇒ 回写键盘（键盘是权威源；不回写的话下次拉快照会被覆盖回去）。
   * 只发改动的那个 key，避免用 App 的其它旧值覆盖键盘侧设置。
   */
  private publishSetting(key: string, value: string): void {
    this.publishHist(OP_SETTINGS_SET, SettingsSync.changeJson(key, value), Date.now());
    Logger.d(`settingsSet → IME: ${key}=${value}`);
  }

  private shownItems(): ClipItem[] {
    return this.items.length > LIST_LIMIT ? this.items.slice(0, LIST_LIMIT) : this.items;
  }

  private fmtTime(ts: number): string {
    const d = new Date(ts);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
  }

  // ---------- 输入法状态 ----------
  private checkIme(): void {
    try {
      const all: Array<inputMethod.InputMethodProperty> = inputMethod.getSetting().getAllInputMethodsSync();
      let ours: boolean = false;
      let list: string = '';
      for (let i = 0; i < all.length; i++) {
        const p: inputMethod.InputMethodProperty = all[i];
        if (p.name === APP_BUNDLE) {
          ours = true;
        }
        list += `[${p.name}/${p.id}]`;
      }
      const cur: inputMethod.InputMethodProperty = inputMethod.getCurrentInputMethod();
      this.imeInfo = ours ? '剪集输入法已注册 ✓' : '剪集输入法未出现在系统列表 ✗';
      Logger.d(`IME check: ours=${ours}, current=${cur.name}/${cur.id}, total=${all.length}, list=${list}`);
    } catch (err) {
      const e = err as BusinessError;
      this.imeInfo = `输入法检测失败（${e.code}）`;
    }
  }

  /** 清理日志（日志弹层按钮）：删掉已有全部日志文件 */
  private clearLogs(): void {
    const n: number = Logger.clearAllLogs();
    this.logOn = Logger.isEnabled();
    this.notice = n > 0 ? `已清理 ${n} 个日志文件` : '没有可清理的日志文件';
    Logger.d(`clearLogs: removed ${n}`);
  }

  /**
   * 导出日志到用户选定的位置（鸿蒙无法直接写系统 Download 目录：属主是 file_manager，
   * 且 getUserDownloadDir 在本机 syscap 不支持）⇒ 用系统文件选择器让用户存到 Download/JianJi。
   */
  private async exportLog(): Promise<void> {
    if (!Logger.isLogFileActive()) {
      this.notice = '当前没有日志文件（日志输出已关闭）';
      return;
    }
    try {
      const src: string = Logger.getLogFile();
      const content: string = fs.readTextSync(src);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [src.substring(src.lastIndexOf('/') + 1)];
      const viewPicker = new picker.DocumentViewPicker(this.host());
      const uris: string[] = await viewPicker.save(options);
      if (uris.length === 0) {
        this.notice = '已取消导出';
        return;
      }
      const out = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, content);
      fs.closeSync(out);
      this.notice = `日志已导出（${content.length} 字符）`;
      Logger.d(`exportLog: ${src} -> ${uris[0]}`);
    } catch (err) {
      const e = err as BusinessError;
      this.notice = `导出失败（${e.code}）`;
      Logger.w(`exportLog failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 打开系统「应用详情」页（自启动 / 权限 / 电池等都在这里） */
  private openAppDetail(): void {
    try {
      settings.openAppDetailSettingsPage(this.host(), APP_BUNDLE);
      this.notice = '已跳转「应用详情」页';
    } catch (err) {
      const e = err as BusinessError;
      this.notice = `跳转失败（${e.code}）：请手动到 设置 → 应用 里找剪集`;
      Logger.w(`openAppDetail failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 打开系统「输入法设置」页 */
  private openImeSettings(): void {
    try {
      settings.openInputMethodSettings(this.host());
      this.notice = '已跳转「输入法」设置页';
    } catch (err) {
      const e = err as BusinessError;
      this.notice = `跳转失败（${e.code}）`;
      Logger.w(`openImeSettings failed: code=${e.code}, message=${e.message}`);
    }
  }

  private async requestPermission(): Promise<void> {
    try {
      const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result = await at.requestPermissionsFromUser(this.host(), [PERM_READ_PASTEBOARD]);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      this.refreshPerms();
      this.notice = granted ? '已获得剪贴板读取权限' : '未授权：剪贴板采集会失败';
      Logger.d(`requestPermission: granted=${granted}`);
    } catch (err) {
      const e = err as BusinessError;
      this.notice = `申请权限失败（${e.code}）：权限可能未在签名里声明（ACL）`;
      Logger.w(`requestPermission failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** GitHub 自诊断（点「诊断 404」）：三级 URL 各探一次，结果直接显示在状态条 */
  private async runGhDiagnose(): Promise<void> {
    this.ghStatus = '诊断中…';
    try {
      const rep: string = await GitHubStore.diagnose();
      this.ghStatus = rep;
    } catch (err) {
      const e = err as BusinessError;
      this.ghStatus = `诊断失败（${e.code}）：${e.message}`;
    }
  }

  /** 「关于」信息（对齐 Android：版本 / 构建类型 / 运行环境 / 包名 / 日志文件） */
  private loadAbout(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.aboutVersion = `v${info.versionName} (build ${info.versionCode})`;
      this.aboutBuild = 'HarmonyOS · debug 签名';
      this.aboutModel = `${deviceInfo.productModel} · API ${deviceInfo.sdkApiVersion}`;
    } catch (err) {
      this.aboutVersion = '未知';
      this.aboutBuild = '未知';
      this.aboutModel = '未知';
    }
    Logger.d(`about: ${this.aboutVersion}, ${this.aboutModel}`);
  }

  /**
   * 「进绑定 App 时提醒切换到剪集输入法」——平台不给前台应用检测
   * （无障碍不可用、bundleState/usageStatistics 需系统权限、DataShare 不存在），
   * 所以用两个可观测信号触发：
   *  ① 用户**刚复制了内容**（他下一步就是要粘贴 = 最需要剪集输入法的时刻）⇒ 键盘侧广播 add 事件；
   *  ② WorkScheduler 定时兜底（见 KeepAliveAbility.tick）。
   * 判定条件：`inputMethod.getCurrentInputMethod()` 不是剪集 ⇒ 发通知提醒去切换（点通知进本页）。
   */
  aboutToAppear(): void {
    ImeSettings.init(this.host());
    this.refreshIme();
    this.registerImeChange();
    this.refreshPerms();
    // 上次进程被杀前没送到键盘的操作（删除/清空/设置改动）在这里恢复，等键盘 hello 补发
    this.loadPending();
    this.swReport = ImeSettings.lastSwitch();
    // 订阅键盘侧事件：① 键盘刚起（hello）→ 补发 App 离线期间的删除/清空；
    // ② 键盘回的全量快照（剪切板 / 回收站）→ 整份覆盖本机镜像
    if (this.histSub === undefined) {
      this.histSub = EventBus.subscribe((e) => {
        if (e.src === SRC_APP) {
          // 自己发的事件（同进程的订阅者也会收到）⇒ 直接忽略，避免回声
          Logger.d('histSub: skip own event');
          return;
        }
        if (e.op === OP_ACK) {
          // 键盘已应用该操作 ⇒ 出队（PIT-058）
          this.ackPending(e.id);
          return;
        }
        if (e.op === 'hello') {
          // 键盘进程刚起来：把 App 攒下的操作补发一次（否则键盘那份会留下已删条目）。
          // 不在这里清队列 —— 靠 ack 出队，收不到 ack 就下次 hello 再重放（幂等）。
          if (this.pendingOps.length > 0) {
            const n: number = this.pendingOps.length;
            for (let i = 0; i < n; i++) {
              const o: HistEvent = this.pendingOps[i];
              EventBus.publish(o.op, o.text, o.ts, SRC_APP, o.id);
            }
            Logger.d(`hello ← IME: 补发 ${n} 条待同步操作`);
          }
          return;
        }
        if (e.op === OP_SETTINGS_SNAPSHOT) {
          // 键盘设置全量（权威源）⇒ 本机设置整份对齐
          this.applyImeSettings(e.text);
        } else if (e.op === OP_RECYCLE_SNAPSHOT) {
          // 键盘回收站全量（权威源）⇒ 整份覆盖本机镜像（分片到达，拼齐后才应用）
          const p: ChunkPayload | undefined = SyncChunk.parse(e.text);
          if (p === undefined) {
            this.applyRecycleSnapshot(RecycleBinStore.parseSnapshot(e.text));
          } else if (p.kind === SNAP_RECYCLE && this.recycleAssembler.push(p)) {
            const items: RecycleItem[] =
              RecycleBinStore.parseSnapshot(JSON.stringify(this.recycleAssembler.take()));
            this.applyRecycleSnapshot(items);
          }
        } else if (e.op === 'snapshot') {
          // 键盘历史全量（权威源，旧→新）⇒ 整份覆盖本机（分片到达，拼齐后才应用）
          const p: ChunkPayload | undefined = SyncChunk.parse(e.text);
          if (p === undefined) {
            this.applyHistSnapshot(ClipboardStore.parseSnapshot(e.text));
          } else if (p.kind === SNAP_HIST && this.histAssembler.push(p)) {
            const items: ClipItem[] =
              ClipboardStore.parseSnapshot(JSON.stringify(this.histAssembler.take()));
            this.applyHistSnapshot(items);
          }
        }
        // 注意：键盘端主动推的 add / remove / clear 已废弃（键盘操作用不着同步回 App，
        // App 打开剪切板时拉全量即可）⇒ 这几个分支不再处理，避免「键盘一操作 App 列表就变」。
      });
    }
    // 上次进程被杀前排队的操作：页面重建后直接补发一次
    // （键盘在 ⇒ 应用并 ack 出队；键盘不在 ⇒ 事件丢掉，队列照旧留着等 hello）
    if (this.pendingOps.length > 0) {
      const n: number = this.pendingOps.length;
      for (let i = 0; i < n; i++) {
        const o: HistEvent = this.pendingOps[i];
        EventBus.publish(o.op, o.text, o.ts, SRC_APP, o.id);
      }
      Logger.d(`aboutToAppear: 补发 ${n} 条持久化操作`);
    }
    // 自愈：旧版本把「快照合并」写成循环 addText，已往列表里插过重复条目 ⇒ 每次打开 App 先去重一次
    const dropped: number = ClipboardStore.dedupeByText();
    if (dropped > 0) {
      this.notice = `已自动去掉 ${dropped} 条重复记录`;
    }
    this.kbRate = ImeSettings.heightRate();
    // 回收站：EntryAbility 已 init 过；这里再调一次是幂等的兜底（App 侧非权威，只做镜像）
    RecycleBinStore.init(this.host(), false);
    this.retentionDays = RecycleBinStore.retentionDays();
    // 皮肤 / 日志开关 / 键盘高度 / 切换目标 / 保留天数：一律以键盘那份为准，拉快照对齐
    this.syncSettingsFromIme();
    this.loadAbout();
    GitHubStore.init(this.host());
    this.syncGhFields();
  }

  /** 页面每次显示（含从系统「输入法设置」/其它应用切回来）：重判输入法状态 + 按当前 tab 拉一次全量 */
  onPageShow(): void {
    this.refreshIme();
    // 键盘那份（历史 / 回收站）都是权威源：回到前台就按当前页拉一次全量，整份覆盖本机镜像。
    // 键盘端不再主动推 add/remove/clear ⇒ 这里不拉的话 App 会一直显示旧数据。
    if (this.curTab === 1) {
      this.syncRecycleFromIme();
    } else if (this.curTab === 0) {
      this.syncClipboardFromIme();
    }
    // 设置也以键盘为准：每次回前台对齐一次（键盘不可能在 App 前台时被操作，所以这一次足够）
    this.syncSettingsFromIme();
    Logger.d('onPageShow: refreshIme + pull from IME');
  }

  /** 页面销毁时退订系统输入法事件 */
  aboutToDisappear(): void {
    const cb = this.imeChangeCb;
    if (cb === undefined) {
      return;
    }
    try {
      inputMethod.getSetting().off('imeChange', cb);
      Logger.d('aboutToDisappear: off(imeChange) ok');
    } catch (err) {
      Logger.w('aboutToDisappear: off(imeChange) failed');
    }
  }

  /**
   * 读权限的当前状态（对齐用户要求：已获得的权限按钮直接显示绿色「已授权」）。
   * 剪贴板：checkAccessTokenSync；通知：isNotificationEnabledSync。
   */
  private refreshPerms(): void {
    try {
      const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const st: abilityAccessCtrl.GrantStatus =
        at.checkAccessTokenSync(info.appInfo.accessTokenId, PERM_READ_PASTEBOARD);
      this.permPaste = st === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (err) {
      this.permPaste = false;
    }
    this.permNotify = false;
    Logger.d(`perms: pasteboard=${this.permPaste}, notify=${this.permNotify}`);
  }

  /** 刷新输入法列表（中文名）+ 当前输入法 + 切换目标 */
  private refreshIme(): void {
    this.imeItems = ImeSettings.listAll();
    const cur: ImeItem | undefined = ImeSettings.current();
    this.curImeLabel = cur === undefined ? '' : cur.label;
    // 「已激活」= 剪集就是系统当前输入法：必须在 App 进程里自己问系统
    // （键盘进程写入的 AppStorage 与本进程隔离，App 侧 @StorageLink('imeActive') 永远是默认 false）
    this.imeActive = this.computeImeActive();
    const own: string = ImeSettings.ownRegistered() ? '剪集输入法已注册 ✓' : '剪集输入法未出现在系统列表 ✗';
    this.imeInfo = cur === undefined ? own : `${own}　当前：${cur.label}`;
    const t: ImeItem | undefined = ImeSettings.getTarget();
    this.targetLabel = t === undefined ? '不限（默认切换）' : t.label;
    let names: string = '';
    for (let i = 0; i < this.imeItems.length; i++) {
      names += `[${this.imeItems[i].label}]`;
    }
    Logger.d(`imeList: ${names}`);
  }

  /**
   * 「剪集输入法是否已生效」：App 进程必须自己问系统 ——
   * 键盘进程（输入法 Extension）写的 `AppStorage['imeActive']` 与本进程隔离（PIT-039），读到的永远是默认 false。
   * ①当前输入法就是剪集 ⇒ 已激活；②`getCurrentInputMethod()` 异常时退回「默认输入法是不是剪集」。
   */
  private computeImeActive(): boolean {
    try {
      const cur: inputMethod.InputMethodProperty = inputMethod.getCurrentInputMethod();
      const mine: boolean = cur.name === APP_BUNDLE;
      Logger.d(`computeImeActive: current=${cur.name}, active=${mine}`);
      return mine;
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`computeImeActive: getCurrentInputMethod failed code=${e.code}`);
    }
    try {
      const def: inputMethod.InputMethodProperty = inputMethod.getDefaultInputMethod();
      Logger.d(`computeImeActive: fallback default=${def.name}`);
      return def.name === APP_BUNDLE;
    } catch (err2) {
      return false;
    }
  }

  /** 合并状态条左侧：历史条数 + 已选条数（多选时补一句操作提示） */
  private countText(): string {
    const sel: number = this.selectedTexts.length;
    const more: string = sel > 1 ? '　点「合并选中」按顺序拼接' : '';
    return `📋 共 ${this.items.length} 条　已选 ${sel} 条${more}`;
  }

  /** 合并状态条右侧：输入法状态（只读展示；未激活时带上「当前是谁」） */
  private imeBarText(): string {
    if (this.imeActive) {
      return '输入法: 已激活 ✅';
    }
    return this.curImeLabel === ''
      ? '输入法: 未激活 ⚠️'
      : `输入法: 未激活 ⚠️ 当前：${this.curImeLabel}`;
  }

  /** 订阅系统「输入法变了」事件：切输入法后状态条立即跟着变，不用等用户手动刷新 */
  private registerImeChange(): void {
    if (this.imeChangeCb !== undefined) {
      return;
    }
    const cb = (p: inputMethod.InputMethodProperty, s: InputMethodSubtype): void => {
      Logger.d(`imeChange: now=${p.name}`);
      this.refreshIme();
    };
    this.imeChangeCb = cb;
    try {
      inputMethod.getSetting().on('imeChange', cb);
      Logger.d('registerImeChange: ok');
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(`registerImeChange failed: code=${e.code}`);
    }
  }

  /** 选择「切换」按钮的目标输入法 */
  private pickTarget(item: ImeItem | undefined): void {
    if (item === undefined) {
      ImeSettings.clearTarget();
      this.notice = '切换目标：不限（默认切到另一个输入法）';
      // 键盘才是真正执行切换的一方 ⇒ 目标必须写进键盘那份
      this.publishSetting(SET_KEY_TARGET, '');
    } else {
      ImeSettings.setTarget(item);
      this.notice = `切换目标已设为「${item.label}」`;
      this.publishSetting(SET_KEY_TARGET, JSON.stringify(item));
    }
    this.refreshIme();
  }

  /** 把已保存的 GitHub 配置回填到输入框 */
  private syncGhFields(): void {
    const c: GhConfig = GitHubStore.current();
    this.ghOwner = c.owner;
    this.ghRepo = c.repo;
    this.ghPath = c.path;
    this.ghBranch = c.branch;
    this.ghToken = c.token;
  }

  /** 保存仓库设置（对齐 Android github_settings_saved） */
  private saveGhSettings(): void {
    const cfg: GhConfig = {
      owner: this.ghOwner.trim(),
      repo: this.ghRepo.trim(),
      path: this.ghPath.trim(),
      branch: this.ghBranch.trim() === '' ? 'main' : this.ghBranch.trim(),
      token: this.ghToken.trim()
    };
    GitHubStore.save(cfg);
    this.ghStatus = '设置已保存';
    this.notice = 'GitHub 仓库设置已保存';
  }

  /** 从 GitHub 拉取文件（对齐 Android github_fetching / fetch_success / fetch_failed） */
  private async doFetch(): Promise<void> {
    if (!GitHubStore.configured()) {
      this.ghStatus = '请先设置GitHub仓库信息';
      return;
    }
    this.ghStatus = '正在从GitHub拉取文件…';
    try {
      const text: string = await GitHubStore.fetch();
      this.ghContent = text;
      this.ghStatus = `文件加载成功 (${text.length} 字符)`;
      Logger.d(`gh fetch ok: ${text.length} chars`);
    } catch (err) {
      const e = err as BusinessError;
      this.ghStatus = `加载失败: ${e.message}`;
      Logger.w(`gh fetch failed: code=${e.code}, message=${e.message}`);
    }
  }

  /** 保存内容到 GitHub（对齐 Android github_saving / save_success / save_failed） */
  private async doSave(): Promise<void> {
    if (!GitHubStore.configured()) {
      this.ghStatus = '请先设置GitHub仓库信息';
      return;
    }
    // 空内容也允许保存：GitHub 支持 0 字节文件（真机日志里 tmp.txt 就是 size:0）
    this.ghStatus = '正在保存到GitHub…';
    try {
      await GitHubStore.saveContent(this.ghContent);
      this.ghStatus = `保存成功 (${this.ghContent.length} 字符)`;
    } catch (err) {
      const e = err as BusinessError;
      this.ghStatus = `保存失败: ${e.message}`;
      Logger.w(`gh save failed: code=${e.code}, message=${e.message}`);
    }
  }

  // ---------- 小组件（对齐 Android 的按钮样式：普通=文字按钮，合并=填充按钮） ----------
  @Builder
  textButton(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(color)
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .layoutWeight(1)
      .onClick(action)
  }

  @Builder
  filledButton(label: string, bg: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 8 })
      .backgroundColor(bg)
      .borderRadius(6)
      .margin({ left: 6, right: 6 })
      .layoutWeight(1)
      .onClick(action)
  }

  /**
   * 顶部合并状态条（原「共 N 条 / 已选 M 条」提示行 + 「输入法: …」状态条二合一）：
   * 左 = 历史条数，右 = 输入法状态；**只读展示**（按需求去掉点击动作，切换输入法请走「更多 → 权限设置 → 输入法设置」）。
   * 底色跟随输入法状态（绿=已激活 / 黄=未激活），一条就够，不再占两行。
   */
  @Builder
  topBar() {
    Row() {
      Text(this.countText())
        .fontSize(11)
        .fontColor(this.imeActive ? this.p().statusOnFg : this.p().statusOffFg)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.imeBarText())
        .fontSize(11)
        .fontColor(this.imeActive ? this.p().statusOnFg : this.p().statusOffFg)
        .maxLines(1)
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .backgroundColor(this.imeActive ? this.p().statusOnBg : this.p().statusOffBg)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  swipeDelete(item: ClipItem) {
    Text('删除')
      .fontSize(15)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
      .textAlign(TextAlign.Center)
      .width(84)
      .height('100%')
      .backgroundColor(this.p().danger)
      .borderRadius(8)
      .onClick(() => {
        this.deleteItem(item);
      })
  }

  /** 回收站列表左滑 = 永久删除（对齐 Android RecycleBin 的 ItemTouchHelper） */
  @Builder
  swipePurge(item: RecycleItem) {
    Text('永久删除')
      .fontSize(14)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
      .textAlign(TextAlign.Center)
      .width(84)
      .height('100%')
      .backgroundColor(this.p().danger)
      .borderRadius(8)
      .onClick(() => {
        RecycleBinStore.removeIds([item.id]);
        this.notifyImeRecycleRemove([item], 'purge');
        const si: number = this.recycleSelIds.indexOf(item.id);
        if (si >= 0) {
          this.recycleSelIds.splice(si, 1);
          this.recycleSelIds = this.recycleSelIds.slice();
        }
        this.notice = '已永久删除 1 条';
      })
  }

  /** 回收站页（对齐 Android content_recycle_bin.xml：两行按钮栏 + 状态行 + 列表 + 空态） */
  @Builder
  recyclePage() {
    Column() {
      Row() {
        this.textButton('全选', this.p().accent, () => {
          this.selectAllRecycle();
        })
        this.textButton('取消', this.p().textSecondary, () => {
          this.deselectAllRecycle();
        })
        this.filledButton('恢复', this.p().accent, () => {
          this.restoreSelected();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 2 })
      .backgroundColor(this.p().cardBg)
      .alignItems(VerticalAlign.Center)

      Row() {
        this.textButton('全恢复', this.p().accent, () => {
          this.restoreAll();
        })
        this.textButton('最近', this.p().accent, () => {
          this.restoreRecent();
        })
        this.textButton('批次', this.p().accent, () => {
          this.openBatchDialog();
        })
        this.textButton('清空', this.p().danger, () => {
          this.confirmClearRecycle();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 2, bottom: 4 })
      .backgroundColor(this.p().cardBg)
      .alignItems(VerticalAlign.Center)

      Text(this.recycleBarText())
        .fontSize(11)
        .fontColor(this.p().textSecondary)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })

      if (this.notice.length > 0) {
        Text(this.notice)
          .fontSize(12)
          .fontColor(this.p().accent)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(4)
      }

      if (this.recycleItems.length === 0) {
        Text('回收站为空')
          .fontSize(16)
          .fontColor(this.p().textSecondary)
          .margin({ top: 48 })
      } else {
        List({ space: 8 }) {
          ForEach(this.recycleItems, (item: RecycleItem) => {
            ListItem() {
              Row() {
                Text(this.isRecycleSelected(item.id) ? '☑' : '☐')
                  .fontSize(18)
                  .fontColor(this.p().selMark)
                  .padding({ right: 8 })
                Column() {
                  Text(`${this.sourceLabel(item.source)} · ${item.batchId}`)
                    .fontSize(11)
                    .fontColor(this.p().textSecondary)
                  Text(item.text)
                    .fontSize(14)
                    .fontColor(this.p().textPrimary)
                    .maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                  Text(`删除于 ${this.fmtTime(item.deletedAt)}`)
                    .fontSize(10)
                    .fontColor(this.p().textSecondary)
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.isRecycleSelected(item.id) ? this.p().cardSelBg : this.p().cardBg)
              .borderRadius(8)
              .onClick(() => {
                this.toggleRecycleSelect(item.id);
              })
            }
            .swipeAction({ end: { builder: () => { this.swipePurge(item); } } })
          }, (item: RecycleItem) => `${item.id}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 8, right: 8, top: 4 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 回收站设置里的一行（单选：保留天数） */
  @Builder
  retentionRow(days: number, label: string) {
    Row() {
      Text(this.retentionDays === days ? '◉' : '○')
        .fontSize(16)
        .fontColor(this.p().accent)
      Text(label)
        .fontSize(14)
        .margin({ left: 8 })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      RecycleBinStore.setRetentionDays(days);
      this.retentionDays = days;
      this.publishSetting(SET_KEY_RETENTION, `${days}`);
      this.notice = days === RETENTION_FOREVER ? '回收站已设为永久保留' : `回收站保留 ${days} 天`;
      Logger.d(`recycle retention: set to ${days}`);
    })
  }

  /** 「按批次恢复」弹层里的一行（点一下就恢复该批次） */
  @Builder
  batchRow(batchId: string, count: number) {
    Row() {
      Column() {
        Text(batchId)
          .fontSize(13)
          .fontColor(this.p().textPrimary)
        Text(`${count} 条`)
          .fontSize(11)
          .fontColor(this.p().textSecondary)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text('恢复')
        .fontSize(13)
        .fontColor(this.p().accent)
        .padding({ left: 12, right: 4 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      this.dialog = '';
      this.restoreBatch(batchId);
    })
  }

  // ---------- GitHub 页（UI 先对齐，联网在 P2 接） ----------
  @Builder
  githubPage() {
    Column() {
      Row() {
        Text('GitHub 内容').fontSize(13).fontColor('#5A6472').layoutWeight(1)
        Text('设置')
          .fontSize(13)
          .fontColor('#1A6FD4')
          .padding(8)
          .onClick(() => {
            this.dialog = 'github';
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8 })
      .alignItems(VerticalAlign.Center)

      TextArea({ text: $$this.ghContent, placeholder: '这里的内容会保存到 GitHub 仓库的指定文件' })
        .width('100%')
        .layoutWeight(1)
        .fontSize(13)
        .margin({ left: 12, right: 12, top: 4 })

      Row() {
        this.textButton('拉取', this.p().accent, () => {
          this.doFetch();
        })
        this.filledButton('保存', this.p().statusOnFg, () => {
          this.doSave();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 8 })

      if (this.ghStatus.length > 0) {
        Text(this.ghStatus)
          .fontSize(12)
          .fontColor('#5A6472')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(4)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ---------- 弹层（对齐 Android 的各个 dialog_*.xml） ----------
  @Builder
  dialogLayer() {
    Column() {
      Column() {
        if (this.dialog === 'about') {
          Text('状态汇总').fontSize(14).fontWeight(FontWeight.Bold).margin({ top: 4, bottom: 4 })
          Text(`皮肤：${this.themeId === THEME_HARMONY ? '鸿蒙风' : 'Android 原版'}　|　输入法：${this.imeActive ? '已激活' : '未激活'}`)
            .fontSize(12)
            .fontColor(this.p().textPrimary)
            .width('100%')
          Text(`剪贴板权限：${this.permPaste ? '已授权' : '未授权'}`)
            .fontSize(12)
            .fontColor(this.p().textPrimary)
            .width('100%')
            .margin({ top: 2 })
          Text(`历史条数：${this.items.length}`)
            .fontSize(12)
            .fontColor(this.p().textPrimary)
            .width('100%')
            .margin({ top: 2 })
          Text('操作：列表里左滑某条 = 删除（移入回收站「回收站」Tab，可恢复）。' +
            '剪贴板与回收站都以键盘那份为准：键盘里改过的内容，回到本页/切到该 Tab 时会自动对齐。')
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ top: 2, bottom: 6 })
          Text('关于').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 10 })
          Text(`版本：${this.aboutVersion}`).fontSize(13).width('100%')
          Text(`构建类型：${BUILD_TYPE}`).fontSize(13).width('100%').margin({ top: 6 })
          Text(`构建时间：${BUILD_TIME}`).fontSize(13).width('100%').margin({ top: 6 })
          Text(`Git 提交：${GIT_COMMIT}`).fontSize(13).width('100%').margin({ top: 6 })
          Text(`运行环境：${this.aboutModel}`).fontSize(13).width('100%').margin({ top: 6 })
          Text(`包名：${APP_BUNDLE}`).fontSize(13).width('100%').margin({ top: 6 })
          Text(`日志文件：${Logger.isLogFileActive() ? Logger.getLogFile() : Logger.getLogFile() + '（当前未创建）'}`)
            .fontSize(12)
            .fontColor('#7A828E')
            .width('100%')
            .margin({ top: 6 })
        } else if (this.dialog === 'log') {
          Text('注意：键盘进程是独立沙箱，它自己那份日志不在这个文件里；这里导出/显示的都是「剪集 App」进程的日志。键盘进程的日志开关在键盘内 ⚙ →「键盘进程日志」。')
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ bottom: 6 })
          Row() {
            this.textButton('清日志', this.p().danger, () => {
              this.clearLogs();
            })
            this.textButton('导出', this.p().accent, () => {
              this.exportLog();
            })
          }
          .width('100%')
          .margin({ top: 4, bottom: 4 })
          Text('日志设置').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 10 })
          Row() {
            Text('日志输出（仅 App 进程）').fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.logOn })
              .onChange((isOn: boolean) => {
                // 只改 App 进程自己的日志开关；键盘进程的日志开关在键盘 ⚙ 里单独管理（互不影响）
                this.logOn = isOn;
                Logger.setEnabled(this.host(), isOn);
                this.notice = isOn ? '日志输出已开启（仅 App）' : '日志输出已关闭（仅 App）';
              })
          }
          .width('100%')
          Text('只控制 App 进程自己的日志（文件日志 + hilog，关闭后一条都不写）。键盘进程是独立沙箱，' +
            '它的日志开关在键盘 ⚙ →「键盘进程日志」里单独设置，两边互不影响。')
            .fontSize(12)
            .fontColor('#7A828E')
            .width('100%')
            .margin({ top: 8 })
          Text(`日志文件：${Logger.isLogFileActive() ? Logger.getLogFile() : Logger.getLogFile() + '（当前未创建）'}`)
            .fontSize(12)
            .fontColor('#7A828E')
            .width('100%')
            .margin({ top: 8 })
        } else if (this.dialog === 'perm') {
          Text('权限设置').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 4 })
          Text('鸿蒙把权限分散在系统设置里，这里集中入口 + 说明')
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ bottom: 8 })

          Column() {
            Row() {
              Column() {
                Text('剪贴板读取权限').fontSize(14).fontColor(this.p().textPrimary)
                Text('采集剪贴板历史必需；未授权时历史会为空').fontSize(11).fontColor(this.p().textSecondary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              if (this.permPaste) {
                Text('已授权 ✓').fontSize(13).fontColor(this.p().statusOnFg)
              } else {
                this.filledButton('申请', this.p().accent, () => {
                  this.requestPermission();
                })
              }
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })

            Row() {
              Column() {
                Text('输入法设置（启用/切换剪集）').fontSize(14).fontColor(this.p().textPrimary)
                Text('剪集必须在这里被勾选为可用输入法').fontSize(11).fontColor(this.p().textSecondary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              this.filledButton('去设置', this.p().accent, () => {
                this.openImeSettings();
              })
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .border({ width: { top: 1 }, color: '#1F000000' })
          }
          .width('100%')
          if (this.notice.length > 0) {
            Text(this.notice)
              .fontSize(12)
              .fontColor(this.p().accent)
              .width('100%')
              .margin({ top: 10 })
          }
        } else if (this.dialog === 'theme') {
          Text('皮肤设置').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 10 })
          Text('⚠️ 这里只影响「剪集 App 的界面」。键盘的皮肤请在键盘内点 ⚙ →「键盘皮肤」里设（输入法进程是独立沙箱，读不到 App 侧的选择）。')
            .fontSize(11)
            .fontColor(this.p().danger)
            .width('100%')
            .margin({ bottom: 6 })
          Row() {
            Text(this.themeId === THEME_HARMONY ? '◉' : '○').fontSize(16).fontColor(this.p().accent)
            Text('鸿蒙风（清淡白 · 略带透明 · 选中灰）').fontSize(14).margin({ left: 8 }).layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            ThemeStore.set(THEME_HARMONY);
            // 键盘面板读的是它自己那份皮肤 ⇒ 回写键盘
            this.publishSetting(SET_KEY_THEME, THEME_HARMONY);
            this.notice = '已切换到鸿蒙风皮肤';
          })
          Row() {
            Text(this.themeId === THEME_ANDROID ? '◉' : '○').fontSize(16).fontColor(this.p().accent)
            Text('Android 原版（紫顶栏 · 深绿键盘）').fontSize(14).margin({ left: 8 }).layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            ThemeStore.set(THEME_ANDROID);
            this.publishSetting(SET_KEY_THEME, THEME_ANDROID);
            this.notice = '已切换到 Android 原版皮肤';
          })
          Text(`当前皮肤：${this.themeId === THEME_HARMONY ? '鸿蒙风' : 'Android 原版'}（切换后立即生效）`)
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ top: 6 })

        } else if (this.dialog === 'github') {
          Text('GitHub 仓库设置').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 10 })
          TextInput({ text: $$this.ghOwner, placeholder: '仓库所有者（owner / 用户名）' })
            .fontSize(13).margin({ bottom: 6 })
          TextInput({ text: $$this.ghRepo, placeholder: '仓库名（repo）' })
            .fontSize(13).margin({ bottom: 6 })
          TextInput({ text: $$this.ghPath, placeholder: '文件路径（如 notes/clip.txt）' })
            .fontSize(13).margin({ bottom: 6 })
          TextInput({ text: $$this.ghBranch, placeholder: '分支（默认 main）' })
            .fontSize(13).margin({ bottom: 6 })
          TextInput({ text: $$this.ghToken, placeholder: 'Personal Access Token（私有仓库才需要）' })
            .fontSize(13).margin({ bottom: 6 })
          Row() {
            this.filledButton('保存', this.p().accent, () => {
              this.saveGhSettings();
            })
            this.textButton('诊断', this.p().textSecondary, () => {
              this.runGhDiagnose();
            })
          }
          .width('100%')
          .margin({ top: 4 })
          if (this.ghStatus.length > 0) {
            Text(this.ghStatus)
              .fontSize(12)
              .fontColor(this.p().textSecondary)
              .width('100%')
              .margin({ top: 6 })
          }
        } else if (this.dialog === 'recycle') {
          Text('回收站设置').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 6 })
          Text('删除的剪贴项先放进回收站；超过保留天数后自动清理，永久保留则只能手动清空。')
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ bottom: 6 })
          this.retentionRow(7, '保留 7 天')
          this.retentionRow(15, '保留 15 天')
          this.retentionRow(30, '保留 30 天（默认）')
          this.retentionRow(90, '保留 90 天')
          this.retentionRow(RETENTION_FOREVER, '永久保留（不自动清理）')
          Text(`当前：${this.retentionText()}　回收站共 ${this.recycleItems.length} 条`)
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ top: 6 })
          Text('回收站最多保存 5000 条，超出上限自动丢弃最旧的记录。')
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ top: 4 })
        } else if (this.dialog === 'batch') {
          Text('按批次恢复').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 4 })
          Text('同一次删除的记录共用一个批次；点一行即可恢复该批次。')
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ bottom: 4 })
          Scroll() {
            Column() {
              ForEach(this.batchIds, (b: string, i: number) => {
                this.batchRow(b, this.batchCounts[i]);
              }, (b: string) => b)
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 260 })
          .scrollBar(BarState.Auto)
        } else if (this.dialog === 'imeKeys') {
          Text('按键说明').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 4 })
          Scroll() {
            Column() {
              Text('键盘顶栏（从左到右）')
                .fontSize(11)
                .fontColor(this.p().textSecondary)
                .width('100%')
                .margin({ bottom: 2 })
              ForEach(this.keyHints(), (h: ImeKeyHint) => {
                Row() {
                  SymbolGlyph(h.icon)
                    .fontSize(18)
                    .fontColor([this.p().textPrimary])
                    .width(26)
                  Column() {
                    Text(h.name).fontSize(13).fontColor(this.p().textPrimary)
                    Text(h.hint).fontSize(10).fontColor(this.p().textSecondary).margin({ top: 2 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
              }, (h: ImeKeyHint) => h.name)

              Text('页面上被简写的按钮')
                .fontSize(11)
                .fontColor(this.p().textSecondary)
                .width('100%')
                .margin({ top: 8, bottom: 2 })
              ForEach(this.shortHints(), (h: NameHint) => {
                Column() {
                  Text(h.name).fontSize(13).fontColor(this.p().textPrimary)
                  Text(h.hint).fontSize(10).fontColor(this.p().textSecondary).margin({ top: 2 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ top: 4, bottom: 4 })
              }, (h: NameHint) => h.name)
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 320 })
          .scrollBar(BarState.Auto)
        } else if (this.dialog === 'recycleClear') {
          Text('清空回收站').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 8 })
          Text('确定要清空回收站吗？此操作不可撤销。')
            .fontSize(13)
            .fontColor(this.p().textPrimary)
            .width('100%')
          Row() {
            this.filledButton('确定清空', this.p().danger, () => {
              this.dialog = '';
              this.doClearRecycle();
            })
            this.textButton('取消', this.p().textSecondary, () => {
              this.dialog = '';
            })
          }
          .width('100%')
          .margin({ top: 12 })
        }

        Row() {
          this.textButton('关闭', this.p().accent, () => {
            this.dialog = '';
          })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('86%')
      .padding(16)
      .backgroundColor(Color.White)
      .borderRadius(12)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.Center)
  }

  // ---------- 主结构：Toolbar + Tab + 页面 ----------
  build() {
    Stack() {
      Column() {
        Row() {
          Text('剪集').fontSize(20).fontColor(this.p().barText)
          Blank()
          Text('⋮')
            .fontSize(22)
            .fontColor(this.p().barText)
            .padding({ left: 14, right: 14 })
            .bindMenu([
              {
                value: '日志',
                action: () => {
                  this.dialog = 'log';
                }
              },
              {
                value: '权限',
                action: () => {
                  this.dialog = 'perm';
                }
              },
              {
                value: '回收站',
                action: () => {
                  this.retentionDays = RecycleBinStore.retentionDays();
                  this.dialog = 'recycle';
                }
              },
              {
                value: '皮肤',
                action: () => {
                  this.dialog = 'theme';
                }
              },
              {
                value: '按键',
                action: () => {
                  this.dialog = 'imeKeys';
                }
              },
              {
                value: '关于',
                action: () => {
                  this.dialog = 'about';
                }
              }
            ])
        }
        .width('100%')
        .height(52)
        .padding({ left: 16 })
        .backgroundColor(this.p().barBg)
        .backgroundBlurStyle(this.p().blurBar ? BlurStyle.Thin : BlurStyle.NONE)
        .alignItems(VerticalAlign.Center)

        Row() {
          Text('剪切板')
            .fontSize(15)
            .fontColor(this.curTab === 0 ? this.p().barText : this.p().barTextDim)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.curTab = 0;
              // 打开剪切板 = 从键盘（权威源）拉一次全量，整份覆盖本机
              this.syncClipboardFromIme();
            })
          Text('回收站')
            .fontSize(15)
            .fontColor(this.curTab === 1 ? this.p().barText : this.p().barTextDim)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.curTab = 1;
              this.retentionDays = RecycleBinStore.retentionDays();
              // 打开回收站 = 从键盘（权威源）拉一次全量，覆盖本机镜像
              this.syncRecycleFromIme();
            })
          Text('GitHub')
            .fontSize(15)
            .fontColor(this.curTab === 2 ? this.p().barText : this.p().barTextDim)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.curTab = 2;
            })
        }
        .width('100%')
        .backgroundColor(this.p().barBg)
        .backgroundBlurStyle(this.p().blurBar ? BlurStyle.Thin : BlurStyle.NONE)

        if (this.curTab === 0) {
          this.clipboardPage()
        } else if (this.curTab === 1) {
          this.recyclePage()
        } else {
          this.githubPage()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F2F4F7')

      if (this.dialog !== '') {
        this.dialogLayer()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  clipboardPage() {
    Column() {
      Row() {
        this.textButton('全选', this.p().accent, () => {
          this.selectAll();
        })
        this.textButton('取消', this.p().textSecondary, () => {
          this.deselectAll();
        })
        this.filledButton('合并', this.p().accent, () => {
          this.mergeSelected();
        })
        this.textButton('清空', this.p().danger, () => {
          this.clearAll();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(this.p().cardBg)
      .alignItems(VerticalAlign.Center)

      this.topBar()

      if (this.notice.length > 0) {
        Text(this.notice)
          .fontSize(12)
          .fontColor(this.p().accent)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(4)
      }

      if (this.items.length === 0) {
        Text('暂无剪贴板内容')
          .fontSize(16)
          .fontColor(this.p().textSecondary)
          .margin({ top: 48 })
      } else {
        List({ space: 8 }) {
          ForEach(this.shownItems(), (item: ClipItem) => {
            ListItem() {
              Row() {
                Text(this.isSelected(item.text) ? '☑' : '☐')
                  .fontSize(18)
                  .fontColor(this.p().selMark)
                  .padding({ right: 8 })
                Column() {
                  Text(`#${this.items.indexOf(item) + 1}  ${this.fmtTime(item.timestamp)}`)
                    .fontSize(11)
                    .fontColor(this.p().textSecondary)
                  Text(item.text)
                    .fontSize(14)
                    .fontColor(this.p().textPrimary)
                    .maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(this.isSelected(item.text) ? this.p().cardSelBg : this.p().cardBg)
              .borderRadius(8)
              .onClick(() => {
                this.toggleSelect(item.text);
              })
            }
            .swipeAction({ end: { builder: () => { this.swipeDelete(item); } } })
          }, (item: ClipItem) => `${item.timestamp}_${item.text.length}`)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 8, right: 8, top: 4 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
