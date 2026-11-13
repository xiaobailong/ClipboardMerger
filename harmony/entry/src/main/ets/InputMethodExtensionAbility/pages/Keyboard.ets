import { inputMethod } from '@kit.IMEKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipItem, ClipboardStore } from '../../model/ClipboardStore';
import { EventBus, SRC_IME } from '../../model/EventBus';
import { KeyboardController, keyboardController } from '../model/KeyboardController';
import { Logger } from '../../model/Logger';
import { ImeItem, ImeSettings } from '../../model/ImeSettings';
import { RecycleBinStore, RecycleItem, RETENTION_FOREVER, STATE_RECYCLE } from '../../model/RecycleBin';
import { Palette, paletteOf, STATE_THEME, THEME_ANDROID, THEME_HARMONY, ThemeStore } from '../../model/Theme';

const APP_BUNDLE: string = 'com.example.clipboardmerger';
const SEP: string = '\n';

/** 面板内「选择切换目标」列表行 */
interface ImeRow {
  label: string;
  bundle: string;
}

/**
 * 剪集输入法键盘面板（两套皮肤：鸿蒙清淡白=默认 / Android 原版深绿）
 * 功能对齐 Android ime_view.xml：[粘贴][全部粘贴][切换][删除][清空] + 历史列表 + 底部状态栏
 */
@Entry
@Component
struct Keyboard {
  @StorageLink('clipItems') items: ClipItem[] = [];
  @StorageLink('imeActive') imeActive: boolean = false;
  @StorageLink(STATE_THEME) themeId: string = 'harmony';
  @State selectedTexts: string[] = [];
  /** 键盘面板高度（vp）。由「键盘设置」的高度比例算出，直接撑住面板根节点 */
  @State kbH: number = 300;
  /** 面板内：是否展开"选择切换目标"列表 */
  @State imePick: boolean = false;
  @State imeRows: ImeRow[] = [];
  @State rateText: string = '0.30';
  /** 面板内：是否展开「⚙ 设置」（键盘设置 / 皮肤 / 切换目标，全部存在键盘自己的沙箱里） */
  @State showSettings: boolean = false;
  @State targetBundle: string = '';
  /** 键盘进程自己的日志开关（独立沙箱，与 App 侧各一份） */
  @State logOn: boolean = true;
  /** 键盘进程自己的日志文件列表（名称 + 大小，最新在前） */
  @State logFiles: string[] = [];
  /** 上次粘贴之后新增的条数（>0 就在键盘里显示「待粘贴」提醒条） */
  @State newCount: number = 0;
  /** 操作状态反馈文字（显示在底部状态栏，优先级高于记录数） */
  @State statusText: string = '';
  /** 回收站列表（键盘进程自己的沙箱；App 进程读不到 ⇒ 在面板里直接看/恢复） */
  @StorageLink(STATE_RECYCLE) recycleItems: RecycleItem[] = [];
  /** 面板内：是否展开「🗑 回收站」 */
  @State showRecycle: boolean = false;
  /** 「清空回收站」二次确认（3 秒内再点一次才真正清空） */
  @State confirmClear: boolean = false;
  /** 回收站里勾选的记录 id（对齐 App 回收站 recycleSelIds） */
  @State recycleSelIds: number[] = [];
  /** 键盘回收站的保留天数（-1 = 永久保留；与 App 各存一份，见 PIT-039） */
  @State retentionDays: number = 30;
  /** 「恢复批次」内嵌列表：是否展开 + 批次与条数（对齐 App 的按批次恢复弹层） */
  @State showBatchPick: boolean = false;
  @State batchIds: string[] = [];
  @State batchCounts: number[] = [];

  /** 按「键盘设置」里的比例算面板高度：面板尺寸跟随页面内容 ⇒ 必须撑根节点才看得出变化 */
  private computePanelHeight(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const rate: number = ImeSettings.heightRate();
      this.kbH = Math.round(px2vp(d.height * rate));
      Logger.d(`Keyboard panel height -> ${this.kbH}vp (rate=${rate}, screen ${d.height}px)`);
    } catch (err) {
      Logger.w('computePanelHeight failed');
    }
  }

  private p(): Palette {
    return paletteOf(this.themeId);
  }

  /** 键盘页面每次创建/显示时都从 preferences 重读皮肤（面板进程独立，切皮肤后立即生效） */
  aboutToAppear(): void {
    ThemeStore.reload();
    ImeSettings.reload();
    this.computePanelHeight();
    ImeSettings.setLastSwitch(`键盘页面已加载 · 高度=${this.kbH}vp · 皮肤=${ThemeStore.current()}`);
    this.retentionDays = RecycleBinStore.retentionDays();
    this.refreshNew();
    Logger.d(`Keyboard.aboutToAppear: theme=${ThemeStore.current()}`);
  }

  private isSel(text: string): boolean {
    return this.selectedTexts.indexOf(text) >= 0;
  }

  private toggle(text: string): void {
    const i: number = this.selectedTexts.indexOf(text);
    if (i >= 0) {
      this.selectedTexts.splice(i, 1);
    } else {
      this.selectedTexts.push(text);
    }
    this.selectedTexts = this.selectedTexts.slice();
  }

  /** 按列表顺序取选中内容 */
  private orderedSelected(): string[] {
    const parts: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const it: ClipItem = this.items[i];
      if (this.selectedTexts.indexOf(it.text) >= 0) {
        parts.push(it.text);
      }
    }
    return parts;
  }

  /** 「粘贴」：有选中→按顺序合并插入；没选中→插入最新一条 */
  private paste(): void {
    const parts: string[] = this.orderedSelected();
    if (parts.length === 0) {
      if (this.items.length === 0) {
        return;
      }
      keyboardController.insertText(this.items[0].text);
      this.setStatus('✅ 已粘贴最新记录');
      Logger.d('ime paste: latest item');
      return;
    }
    keyboardController.insertText(parts.join(SEP));
    this.setStatus(`✅ 已粘贴 ${parts.length} 条`);
    this.selectedTexts = [];
    Logger.d(`ime paste: ${parts.length} selected items`);
  }

  /** 「全部粘贴」：把全部记录按顺序合并插入 */
  private pasteAll(): void {
    if (this.items.length === 0) {
      this.setStatus('📋 无剪贴记录');
      return;
    }
    const parts: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      parts.push(this.items[i].text);
    }
    keyboardController.insertText(parts.join(SEP));
    this.setStatus(`✅ 已粘贴 ${parts.length} 条`);
    this.selectedTexts = [];
    Logger.d(`ime pasteAll: ${parts.length} items`);
  }

  /** 左滑删除单条：先移入键盘回收站再删（同步给 App 由 ClipboardStore 的变化回调统一做） */
  private removeItem(item: ClipItem): void {
    const idx: number = this.items.indexOf(item);
    if (idx < 0) {
      return;
    }
    const it: ClipItem = this.items[idx];
    // 键盘沙箱自己留底：App 进程收不到同步事件时也能从 🗑 回收站找回
    RecycleBinStore.moveToRecycleBin([it], 'ime');
    // 通知 App 由 ClipboardStore 的变化回调统一做（KeyboardController.onCreate 里注册），这里只管本地删除
    ClipboardStore.removeAt(idx);
    // 勾选集合里也要去掉，否则「已选」计数虚高
    const si: number = this.selectedTexts.indexOf(it.text);
    if (si >= 0) {
      this.selectedTexts.splice(si, 1);
      this.selectedTexts = this.selectedTexts.slice();
    }
    this.toast('已删除 1 条（已移入回收站）');
    this.setStatus('已删除 1 条');
    Logger.d(`ime swipeDelete: idx=${idx}, total=${this.items.length}`);
  }

  /** 「删除」：删除选中的记录（没选中则删除最后一条） */
  private removeSelected(): void {
    if (this.selectedTexts.length === 0) {
      if (this.items.length > 0) {
        RecycleBinStore.moveToRecycleBin([this.items[this.items.length - 1]], 'ime');
        ClipboardStore.removeAt(this.items.length - 1);
        this.setStatus('已删除最后 1 条');
      }
      return;
    }
    // 先收集要删的条目移入回收站，再逐条删（moveToRecycleBin 按内容去重，不会重复入库）
    const doomed: ClipItem[] = [];
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it: ClipItem = this.items[i];
      if (this.selectedTexts.indexOf(it.text) >= 0) {
        doomed.push(it);
      }
    }
    if (doomed.length > 0) {
      RecycleBinStore.moveToRecycleBin(doomed, 'ime');
    }
    let count = 0;
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it: ClipItem = this.items[i];
      if (this.selectedTexts.indexOf(it.text) >= 0) {
        ClipboardStore.removeAt(i);
        count++;
      }
    }
    this.setStatus(`已删除 ${count} 条`);
    this.selectedTexts = [];
  }

  /**
   * 「切换」：有目标就切目标，没有就轮转到下一个。
   * 目标存在**键盘自己的沙箱**里（面板内 ⚙ 设置里选），所以一定读得到 ——
   * 这才是"设了小艺却切到百度"的彻底解法（App 侧设置的键值键盘读不到）。
   */
  private switchIme(): void {
    const t = ImeSettings.getTarget();
    const b: string = t === undefined ? '' : t.bundle;
    this.setStatus('切换输入法中…');
    keyboardController.switchIme(b, (msg: string) => {
      this.toast(msg);
    });
  }

  /** 「⚙ 设置」：展开/收起面板内设置（切换目标 + 键盘高度 + 键盘皮肤） */
  private toggleSettings(): void {
    if (!this.showSettings) {
      this.rateText = ImeSettings.heightRate().toFixed(2);
      const t = ImeSettings.getTarget();
      this.targetBundle = t === undefined ? '' : t.bundle;
      this.loadImeRows();
      this.logOn = keyboardController.logEnabled();
      this.retentionDays = RecycleBinStore.retentionDays();
      this.refreshLogFiles();
    }
    this.showSettings = !this.showSettings;
    this.imePick = false;
    this.showRecycle = false;
  }

  /** 「🗑 回收站」：展开/收起面板内回收站（键盘进程自己的沙箱，App 读不到） */
  private toggleRecycle(): void {
    if (!this.showRecycle) {
      this.confirmClear = false;
      this.showBatchPick = false;
      this.recycleSelIds = [];
      this.retentionDays = RecycleBinStore.retentionDays();
      RecycleBinStore.load(); // 顺带按保留天数清一次过期记录并刷新列表
    }
    this.showRecycle = !this.showRecycle;
    this.showSettings = false;
  }

  /**
   * 恢复若干条回收站记录到剪贴板历史。
   * restoreItems 不触发变化回调 ⇒ 用快照通道同步给 App（App 侧合并去重、只加不删）。
   */
  private restoreRecycle(items: RecycleItem[]): number {
    if (items.length === 0) {
      return 0;
    }
    const clips: ClipItem[] = [];
    const ids: number[] = [];
    for (let i = 0; i < items.length; i++) {
      clips.push({ text: items[i].text, timestamp: items[i].timestamp });
      ids.push(items[i].id);
    }
    const n: number = ClipboardStore.restoreItems(clips);
    RecycleBinStore.removeIds(ids);
    if (n > 0) {
      KeyboardController.publishSnapshot();
    }
    return n;
  }

  /** 勾选状态（对齐 App 回收站） */
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
    this.setStatus(`回收站已全选 ${ids.length} 条`);
  }

  private deselectAllRecycle(): void {
    this.recycleSelIds = [];
    this.setStatus('已取消全选');
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

  /** 「恢复选中」（对齐 App restoreSelected） */
  private restoreSelectedRecycle(): void {
    const sel: RecycleItem[] = this.selectedRecycleItems();
    if (sel.length === 0) {
      this.toast('请先勾选要恢复的记录');
      return;
    }
    const n: number = this.restoreRecycle(sel);
    this.recycleSelIds = [];
    this.showBatchPick = false;
    this.toast(`✅ 已恢复选中 ${n}/${sel.length} 条`);
    this.setStatus(`已从回收站恢复 ${n} 条`);
  }

  /** 「恢复全部」（对齐 App restoreAll） */
  private restoreAllRecycle(): void {
    const all: RecycleItem[] = this.recycleItems.slice();
    if (all.length === 0) {
      this.toast('回收站为空');
      return;
    }
    const n: number = this.restoreRecycle(all);
    this.recycleSelIds = [];
    this.showBatchPick = false;
    this.toast(`✅ 已恢复全部 ${n}/${all.length} 条`);
    this.setStatus(`已从回收站恢复 ${n} 条`);
  }

  /** 「恢复最近」（对齐 App restoreRecent：恢复最近一次删除的批次） */
  private restoreRecentRecycle(): void {
    const batches: string[] = RecycleBinStore.batchIds();
    if (batches.length === 0) {
      this.toast('回收站为空');
      return;
    }
    this.restoreBatch(batches[0]);
  }

  /** 恢复某个删除批次（对齐 App restoreBatch） */
  private restoreBatch(batchId: string): void {
    const items: RecycleItem[] = RecycleBinStore.itemsByBatch(batchId);
    if (items.length === 0) {
      this.toast('该批次已无可恢复记录');
      return;
    }
    const n: number = this.restoreRecycle(items);
    this.showBatchPick = false;
    this.recycleSelIds = [];
    this.toast(`✅ 已恢复批次 ${batchId}（${n}/${items.length} 条）`);
    this.setStatus(`已从回收站恢复 ${n} 条`);
  }

  /** 「恢复批次」：面板内展开批次列表（对齐 App 的按批次恢复弹层） */
  private openBatchPick(): void {
    if (this.recycleItems.length === 0) {
      this.toast('回收站为空，没有可恢复的批次');
      return;
    }
    this.batchIds = RecycleBinStore.batchIds();
    const counts: number[] = [];
    for (let i = 0; i < this.batchIds.length; i++) {
      counts.push(RecycleBinStore.itemsByBatch(this.batchIds[i]).length);
    }
    this.batchCounts = counts;
    this.showBatchPick = !this.showBatchPick;
  }

  /** 保留天数文案（对齐 App retentionText） */
  private retentionText(): string {
    return this.retentionDays === RETENTION_FOREVER ? '永久保留' : `${this.retentionDays} 天`;
  }

  /** 回收站状态行（对齐 App recycleBarText） */
  private recycleBarText(): string {
    return `🧹 回收站 ${this.recycleItems.length} 条　已选 ${this.recycleSelIds.length} 条　保留：${this.retentionText()}`;
  }

  /** 改保留天数（写键盘自己的设置库；App 那份在 App 设置里各存一份） */
  private setRetentionDays(days: number): void {
    RecycleBinStore.setRetentionDays(days);
    this.retentionDays = days;
    this.recycleSelIds = [];
    this.toast(days === RETENTION_FOREVER ? '键盘回收站已设为永久保留' : `键盘回收站保留 ${days} 天`);
    Logger.d(`ime recycle retention: set to ${days}`);
  }

  /** 「清空回收站」：面板内没有弹窗，用两段式确认（第一下提示，3 秒内再点才清空） */
  private clearRecycleTap(): void {
    if (this.recycleItems.length === 0) {
      this.toast('回收站为空');
      return;
    }
    if (!this.confirmClear) {
      this.confirmClear = true;
      this.toast('⚠ 再点一次「清空」才会永久删除');
      setTimeout(() => {
        this.confirmClear = false;
      }, 3000);
      return;
    }
    const n: number = this.recycleItems.length;
    this.confirmClear = false;
    this.showBatchPick = false;
    this.recycleSelIds = [];
    RecycleBinStore.clearAll();
    this.toast(`已清空回收站（${n} 条已永久删除）`);
    this.setStatus(`已清空回收站 ${n} 条`);
  }

  /** 删除时间（MM-dd HH:mm） */
  private fmtDeleted(ts: number): string {
    const d: Date = new Date(ts);
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  private loadImeRows(): void {
    const all = keyboardController.listIme();
    const rows: ImeRow[] = [];
    for (let i = 0; i < all.length; i++) {
      const p = all[i];
      if (p.name === APP_BUNDLE) {
        continue;
      }
      rows.push({
        label: p.label === undefined || p.label === '' ? p.name : p.label,
        bundle: p.name
      });
    }
    this.imeRows = rows;
    Logger.d(`ime settings: ${rows.length} 个可选输入法`);
  }

  /** 选「切换目标」（空串=不限，切换按钮就轮转下一个）；写进键盘进程自己的设置 */
  private pickTarget(bundle: string): void {
    this.targetBundle = bundle;
    if (bundle === '') {
      ImeSettings.clearTarget();
      this.toast('切换目标：不限（切下一个）');
      return;
    }
    const all = keyboardController.listIme();
    for (let i = 0; i < all.length; i++) {
      const p = all[i];
      if (p.name === bundle) {
        const lbl: string = p.label === undefined || p.label === '' ? p.name : p.label;
        ImeSettings.setTarget({ label: lbl, bundle: p.name, id: p.id });
        this.toast(`切换目标：${lbl}`);
        return;
      }
    }
  }

  /** 面板内改高度：写进键盘进程自己的设置并立即 resize（跨沙箱，只有面板内改才生效） */
  private bumpHeight(delta: number): void {
    let r: number = ImeSettings.heightRate() + delta;
    if (r < 0.15) {
      r = 0.15;
    }
    if (r > 0.60) {
      r = 0.60;
    }
    r = Math.round(r * 100) / 100;
    this.rateText = r.toFixed(2);
    keyboardController.applyHeightRate(r);
    this.computePanelHeight();
  }

  /**
   * 「进绑定 App 自动提醒」的替代方案（平台不给前台应用检测）：
   * 键盘被拉起的这一刻 = 用户正要在某个 App 里输入 ⇒ 直接在**键盘里**提醒"有几条新内容待粘贴"，
   * 比"进某个 App 才提醒"更准（任何 App 都会提醒），而且键盘侧自持、必然生效。
   */
  private refreshNew(): void {
    try {
      const last: number = ImeSettings.lastPasteTs();
      let n: number = 0;
      for (let i = 0; i < this.items.length; i++) {
        if (last === 0 || this.items[i].timestamp > last) {
          n++;
        }
      }
      this.newCount = n;
      Logger.d(`Keyboard.refreshNew: lastPaste=${last} new=${n} total=${this.items.length}`);
      // 全量推一次（旧→新，App 侧合并去重）；「新增即广播」由 ClipboardStore 的变化回调负责
      KeyboardController.publishSnapshot();
    } catch (err) {
      Logger.w('refreshNew failed');
    }
  }

  /** 点提醒条：粘贴最新一条并记录时间（提醒条随即消失） */
  private pasteNewest(): void {
    if (this.items.length === 0) {
      return;
    }
    keyboardController.insertText(this.items[0].text);
    ImeSettings.setLastPasteTs(Date.now());
    this.setStatus('✅ 已粘贴最新记录');
    this.newCount = 0;
    EventBus.publish('paste', this.items[0].text, Date.now(), SRC_IME);
  }

  /** 刷新「键盘进程日志」文件列表（键盘独立沙箱 ⇒ 列的是它自己那份） */
  private refreshLogFiles(): void {
    try {
      this.logFiles = Logger.listLogs();
      Logger.d(`Keyboard.refreshLogFiles: ${this.logFiles.length} file(s)`);
    } catch (err) {
      this.logFiles = [];
    }
  }

  /** 清理键盘进程的日志文件 */
  private clearImeLogs(): void {
    const n: number = Logger.clearAllLogs();
    this.logOn = keyboardController.logEnabled();
    this.refreshLogFiles();
    this.toast(n > 0 ? `已清理 ${n} 个日志文件` : '没有可清理的日志文件');
  }

  /** 面板里的轻提示：键盘进程没有独立界面，toast 是最直接的结果反馈 */
  private toast(msg: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2500 });
    } catch (err) {
      Logger.w('toast failed');
    }
  }

  /**
   * 设置底部状态栏文字，2.5 秒后自动恢复为记录数。
   * 空串 = 立即恢复为默认记录数。
   */
  private setStatus(text: string): void {
    this.statusText = text;
    if (text !== '') {
      setTimeout(() => {
        this.statusText = '';
      }, 2500);
    }
  }

  /** 左滑出来的「删除」按钮（键盘面板的每一条历史） */
  @Builder
  swipeDeleteItem(item: ClipItem) {
    Text('删除')
      .fontSize(14)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
      .textAlign(TextAlign.Center)
      .width(72)
      .height('100%')
      .backgroundColor(this.p().danger)
      .borderRadius(8)
      .onClick(() => {
        this.removeItem(item);
      })
  }

  /** 回收站条目左滑 = 永久删除（不可恢复） */
  @Builder
  recyclePurge(item: RecycleItem) {
    Text('永久删除')
      .fontSize(14)
      .fontColor(Color.White)
      .fontWeight(FontWeight.Bold)
      .textAlign(TextAlign.Center)
      .width(72)
      .height('100%')
      .backgroundColor(this.p().danger)
      .borderRadius(8)
      .onClick(() => {
        RecycleBinStore.removeIds([item.id]);
        // 勾选集合里也要去掉，否则「已选」计数虚高（对齐 App swipePurge）
        const si: number = this.recycleSelIds.indexOf(item.id);
        if (si >= 0) {
          this.recycleSelIds.splice(si, 1);
          this.recycleSelIds = this.recycleSelIds.slice();
        }
        this.toast('已永久删除 1 条');
      })
  }

  /** 回收站设置里的一行（单选：保留天数，对齐 App retentionRow） */
  @Builder
  retentionRow(days: number, label: string) {
    Row() {
      Text(this.retentionDays === days ? '◉' : '○')
        .fontSize(14)
        .fontColor(this.p().imeMark)
      Text(label)
        .fontSize(12)
        .fontColor(this.p().imeItemFg)
        .margin({ left: 6 })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .onClick(() => {
      this.setRetentionDays(days);
    })
  }

  /** 键：点 = action；可选 onLongPress（如「删除」长按 = 删历史记录） */
  @Builder
  imeKey(label: string, colorIndex: number, action: () => void, onLongPress?: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(this.p().imeKeyFg)
      .textAlign(TextAlign.Center)
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(this.p().imeKeyColors[colorIndex])
      .borderRadius(8)
      .margin({ right: 4 })
      .onClick(action)
      .gesture(LongPressGesture().onAction(() => {
        if (onLongPress !== undefined) {
          onLongPress();
        }
      }))
  }

  build() {
    Column() {
      Row() {
        this.imeKey('粘贴', 0, () => {
          this.paste();
        })
        this.imeKey('全部粘贴', 1, () => {
          this.pasteAll();
        })
        this.imeKey('切换', 2, () => {
          this.switchIme();
        })
        this.imeKey('删除', 3, () => {
          // 对齐 Android btnDelete：删的是**编辑框里**的文字（有选中整段删，否则退格 1 个字符）
          if (!keyboardController.deleteSelected()) {
            this.setStatus('⚠ 当前没有正在编辑的输入框');
          } else {
            this.setStatus('已删除选中内容');
          }
        }, () => {
          // 长按保留原能力：删掉历史列表里勾选的记录
          this.removeSelected();
          this.toast('已删除勾选的历史记录');
        })
        this.imeKey('清空', 4, () => {
          // 先移入键盘进程自己的回收站（App 那份由 'clear' 事件里的快照入 App 回收站），
          // 再清空；跨进程同步由 ClipboardStore 的变化回调统一广播
          if (this.items.length > 0) {
            RecycleBinStore.moveToRecycleBin(this.items.slice(), 'ime');
          }
          ClipboardStore.clear();
          this.selectedTexts = [];
          this.setStatus('剪切板已清空（内容已入回收站）');
        })
        this.imeKey('⚙', 3, () => {
          this.toggleSettings();
        })
        this.imeKey('▼', 4, () => {
          keyboardController.hidePanel();
        })
        this.imeKey('🗑', 4, () => {
          this.toggleRecycle();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(this.p().imeBarBg)
      .backgroundBlurStyle(this.p().blurBar ? BlurStyle.Thin : BlurStyle.NONE)
      .alignItems(VerticalAlign.Center)

      if (this.showSettings) {
        Text('')
      } else if (this.showRecycle) {
        // 面板内回收站：按钮与功能对齐 App 回收站（两行 7 个按钮 + 状态行 + 列表）
        Column() {
          Row() {
            this.imeKey('全选', 0, () => {
              this.selectAllRecycle();
            })
            this.imeKey('取消全选', 1, () => {
              this.deselectAllRecycle();
            })
            this.imeKey('恢复选中', 0, () => {
              this.restoreSelectedRecycle();
            })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 4, bottom: 1 })
          .alignItems(VerticalAlign.Center)

          Row() {
            this.imeKey('恢复全部', 0, () => {
              this.restoreAllRecycle();
            })
            this.imeKey('恢复最近', 0, () => {
              this.restoreRecentRecycle();
            })
            this.imeKey('恢复批次', 0, () => {
              this.openBatchPick();
            })
            this.imeKey(this.confirmClear ? '确认清空' : '清空回收站', 4, () => {
              this.clearRecycleTap();
            })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 1, bottom: 2 })
          .alignItems(VerticalAlign.Center)

          Text(this.recycleBarText())
            .fontSize(11)
            .fontColor(this.p().imeStatusFg)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })

          if (this.showBatchPick) {
            // 按批次恢复：点一行即恢复该批次（对齐 App 的「恢复批次」弹层）
            Column() {
              Row() {
                Text('按批次恢复（点一行即恢复该批次）')
                  .fontSize(11)
                  .fontColor(this.p().imeStatusFg)
                  .layoutWeight(1)
                this.imeKey('返回', 1, () => {
                  this.showBatchPick = false;
                })
              }
              .width('100%')
              .padding({ left: 8, right: 8, bottom: 2 })
              .alignItems(VerticalAlign.Center)
              List({ space: 4 }) {
                ForEach(this.batchIds, (batchId: string, idx: number) => {
                  ListItem() {
                    Row() {
                      Text(batchId)
                        .fontSize(12)
                        .fontColor(this.p().imeItemFg)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${this.batchCounts[idx]} 条`)
                        .fontSize(10)
                        .fontColor(this.p().imeStatusFg)
                    }
                    .width('100%')
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .backgroundColor(this.p().imeItemBg)
                    .borderRadius(8)
                    .onClick(() => {
                      this.restoreBatch(batchId);
                    })
                  }
                }, (batchId: string) => batchId)
              }
              .width('100%')
              .layoutWeight(1)
              .padding({ left: 8, right: 8 })
            }
            .width('100%')
            .layoutWeight(1)
          } else if (this.recycleItems.length === 0) {
            Column() {
              Text('回收站是空的')
                .fontSize(13)
                .fontColor(this.p().imeStatusFg)
              Text('键盘侧删除/清空的内容会留在这里，App 端拿不到数据也能找回')
                .fontSize(11)
                .fontColor(this.p().imeStatusFg)
                .margin({ top: 4 })
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .padding({ left: 20, right: 20 })
          } else {
            List({ space: 4 }) {
              ForEach(this.recycleItems, (item: RecycleItem) => {
                ListItem() {
                  Row() {
                    Text(this.isRecycleSelected(item.id) ? '☑' : '☐')
                      .fontSize(16)
                      .fontColor(this.isRecycleSelected(item.id) ? this.p().imeMark : this.p().imeStatusFg)
                      .padding({ right: 8 })
                    Column() {
                      Text(item.text)
                        .fontSize(13)
                        .fontColor(this.p().imeItemFg)
                        .maxLines(3)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${this.fmtDeleted(item.deletedAt)} 删除 · ${item.batchId}`)
                        .fontSize(10)
                        .fontColor(this.p().imeStatusFg)
                        .margin({ top: 2 })
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                  .backgroundColor(this.isRecycleSelected(item.id) ? this.p().imeItemSelBg : this.p().imeItemBg)
                  .borderRadius(8)
                  .onClick(() => {
                    this.toggleRecycleSelect(item.id);
                  })
                }
                .swipeAction({ end: { builder: () => { this.recyclePurge(item); } } })
              }, (item: RecycleItem) => `${item.id}_${item.deletedAt}`)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 8, right: 8, top: 2 })
          }
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.items.length === 0) {
        Column() {
          Text('暂无剪贴板记录')
            .fontSize(13)
            .fontColor(this.p().imeStatusFg)
          Text('复制文字后回到这里；若一直为空，请到「剪集」App 里授权剪贴板读取权限')
            .fontSize(11)
            .fontColor(this.p().imeStatusFg)
            .margin({ top: 4 })
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20 })
      } else {
        List({ space: 6 }) {
          ForEach(this.items, (item: ClipItem) => {
            ListItem() {
              Row() {
                Text(this.isSel(item.text) ? '☑' : '☐')
                  .fontSize(16)
                  .fontColor(this.isSel(item.text) ? this.p().imeMark : this.p().imeStatusFg)
                  .padding({ right: 8 })
                  .onClick(() => {
                    this.toggle(item.text);
                  })
                Text(item.text)
                  .fontSize(13)
                  .fontColor(this.p().imeItemFg)
                  .maxLines(5)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.isSel(item.text) ? this.p().imeItemSelBg : this.p().imeItemBg)
              .borderRadius(8)
              .onClick(() => {
                keyboardController.insertText(item.text);
                this.setStatus('✅ 已粘贴');
              })
            }
            // 左滑删除这一条（对齐 App 主界面；键盘那份删完会同步给 App 进程）
            .swipeAction({ end: { builder: () => { this.swipeDeleteItem(item); } } })
          }, (item: ClipItem) => `${item.timestamp}_${item.text.length}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 8, right: 8, top: 4 })
      }

      if (this.showSettings) {
        Scroll() {
          Column() {
          Text('切换目标').fontSize(11).fontColor(this.p().imeStatusFg).width('100%')
          Row() {
            Text(this.targetBundle === '' ? '◉' : '○').fontSize(14).fontColor(this.p().imeMark)
            Text('不限（默认切下一个）').fontSize(12).fontColor(this.p().imeItemFg).margin({ left: 6 })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            this.pickTarget('');
          })
          ForEach(this.imeRows, (row: ImeRow) => {
            Row() {
              Text(this.targetBundle === row.bundle ? '◉' : '○').fontSize(14).fontColor(this.p().imeMark)
              Text(row.label).fontSize(12).fontColor(this.p().imeItemFg).margin({ left: 6 })
            }
            .width('100%')
            .padding({ top: 6, bottom: 6 })
            .onClick(() => {
              this.pickTarget(row.bundle);
            })
          }, (row: ImeRow) => row.bundle)

          Text('键盘高度').fontSize(11).fontColor(this.p().imeStatusFg).width('100%').margin({ top: 4 })
          Row() {
            this.imeKey('高度−', 4, () => {
              this.bumpHeight(-0.03);
            })
            Text(this.rateText).fontSize(12).fontColor(this.p().imeStatusFg).padding({ left: 4, right: 4 })
            this.imeKey('高度+', 4, () => {
              this.bumpHeight(0.03);
            })
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })

          Text('键盘皮肤').fontSize(11).fontColor(this.p().imeStatusFg).width('100%').margin({ top: 4 })
          Row() {
            Text(this.themeId === THEME_HARMONY ? '◉' : '○').fontSize(14).fontColor(this.p().imeMark)
            Text('鸿蒙风（清淡白）').fontSize(12).fontColor(this.p().imeItemFg).margin({ left: 6 })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            ThemeStore.set(THEME_HARMONY);
            this.toast('已切换到鸿蒙风皮肤');
          })
          Row() {
            Text(this.themeId === THEME_ANDROID ? '◉' : '○').fontSize(14).fontColor(this.p().imeMark)
            Text('Android 原版（深绿键盘）').fontSize(12).fontColor(this.p().imeItemFg).margin({ left: 6 })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })
          .onClick(() => {
            ThemeStore.set(THEME_ANDROID);
            this.toast('已切换到 Android 原版皮肤');
          })

          Text('回收站').fontSize(11).fontColor(this.p().imeStatusFg).width('100%').margin({ top: 4 })
          Text('删除的剪贴项先放进回收站；超过保留天数后自动清理，永久保留则只能手动清空。（对齐 App 的「回收站设置」）')
            .fontSize(10)
            .fontColor(this.p().imeStatusFg)
            .width('100%')
          this.retentionRow(7, '保留 7 天')
          this.retentionRow(15, '保留 15 天')
          this.retentionRow(30, '保留 30 天（默认）')
          this.retentionRow(90, '保留 90 天')
          this.retentionRow(RETENTION_FOREVER, '永久保留（不自动清理）')
          Text(`当前：${this.retentionText()}　键盘回收站共 ${this.recycleItems.length} 条`)
            .fontSize(10)
            .fontColor(this.p().imeStatusFg)
            .width('100%')
            .margin({ top: 4 })
          Text('回收站最多保存 5000 条，超出上限丢弃最旧的记录。这里的设置只作用于键盘沙箱那份（App 的回收站设置在 App 里）。')
            .fontSize(10)
            .fontColor(this.p().imeStatusFg)
            .width('100%')
            .margin({ top: 2, bottom: 4 })

            Text('键盘进程日志').fontSize(11).fontColor(this.p().imeStatusFg).width('100%').margin({ top: 4 })
            Row() {
              Column() {
                Text('写日志文件').fontSize(13).fontColor(this.p().imeItemFg)
                Text('键盘进程是独立沙箱，App 的日志开关管不到它 ⇒ 这里单独一个').fontSize(10)
                  .fontColor(this.p().imeStatusFg)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.logOn })
                .onChange((isOn: boolean) => {
                  this.logOn = isOn;
                  keyboardController.setLogEnabled(isOn);
                  this.toast(isOn ? '键盘日志已开启' : '键盘日志已关闭');
                })
            }
            .width('100%')
            .padding({ top: 4, bottom: 6 })

            Row() {
              this.imeKey('清理日志', 1, () => {
                this.clearImeLogs();
              })
              Text(`共 ${this.logFiles.length} 个文件`)
                .fontSize(10)
                .fontColor(this.p().imeStatusFg)
                .layoutWeight(1)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ top: 2, bottom: 2 })
            ForEach(this.logFiles, (f: string) => {
              Text(f)
                .fontSize(10)
                .fontColor(this.p().imeStatusFg)
                .width('100%')
                .padding({ left: 4, top: 1, bottom: 1 })
            }, (f: string) => f)

            Text('「删除」= 删编辑框里选中的文字（没选中就退格 1 个字符）；长按「删除」= 删掉列表里勾选的历史记录；列表里左滑某条 = 删掉这一条。删除/清空的内容都会移入键盘回收站（🗑），App 端拿不到数据时也能从那里找回。')
              .fontSize(10)
              .fontColor(this.p().imeItemFg)
              .width('100%')
              .padding({ top: 4 })

            Text('提示：键盘进程与 App 是独立沙箱 —— 剪贴板历史、皮肤、日志、回收站各存一份。所以「切换目标 / 键盘高度 / 键盘皮肤 / 键盘日志」都只在本页设置才生效；回收站也一样：App 的回收站在 App 沙箱、键盘回收站在键盘沙箱（顶栏 🗑）。')
              .fontSize(10)
              .fontColor(this.p().imeStatusFg)
              .width('100%')
              .padding({ top: 4, bottom: 8 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .backgroundColor(this.p().imeItemBg)
      }

      Text(this.statusText !== '' ? this.statusText : (this.items.length > 0 ? `📋 ${this.items.length} 条记录` : '📋 剪贴板监听中'))
        .fontSize(11)
        .fontColor(this.p().imeStatusFg)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 4, bottom: 6 })
        .backgroundColor(this.p().imeStatusBg)
    }
    .width('100%')
    .height(this.kbH)
    .backgroundColor(this.p().imeBg)
  }
}