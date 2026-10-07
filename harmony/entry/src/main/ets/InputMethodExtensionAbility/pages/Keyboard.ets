import { inputMethod } from '@kit.IMEKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipItem, ClipboardStore } from '../../model/ClipboardStore';
import { EventBus } from '../../model/EventBus';
import { keyboardController } from '../model/KeyboardController';
import { Logger } from '../../model/Logger';
import { ImeItem, ImeSettings } from '../../model/ImeSettings';
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
      Logger.d('ime paste: latest item');
      return;
    }
    keyboardController.insertText(parts.join(SEP));
    this.selectedTexts = [];
    Logger.d(`ime paste: ${parts.length} selected items`);
  }

  /** 「全部粘贴」：把全部记录按顺序合并插入 */
  private pasteAll(): void {
    if (this.items.length === 0) {
      return;
    }
    const parts: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      parts.push(this.items[i].text);
    }
    keyboardController.insertText(parts.join(SEP));
    this.selectedTexts = [];
    Logger.d(`ime pasteAll: ${parts.length} items`);
  }

  /** 「删除」：删除选中的记录（没选中则删除最后一条） */
  private removeSelected(): void {
    if (this.selectedTexts.length === 0) {
      if (this.items.length > 0) {
        ClipboardStore.removeAt(this.items.length - 1);
      }
      return;
    }
    for (let i = this.items.length - 1; i >= 0; i--) {
      const it: ClipItem = this.items[i];
      if (this.selectedTexts.indexOf(it.text) >= 0) {
        // 跨进程同步：App 侧也删掉这条
        EventBus.publish('remove', it.text, it.timestamp);
        ClipboardStore.removeAt(i);
      }
    }
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
      this.refreshLogFiles();
    }
    this.showSettings = !this.showSettings;
    this.imePick = false;
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
      this.publishSnapshot();
      if (n > 0 && this.items.length > 0) {
        // 带上最新一条正文 ⇒ App 侧据此把这条历史也补进它那份（并触发"切到剪集"提醒）
        EventBus.publish('add', this.items[0].text, this.items[0].timestamp);
      }
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
    this.newCount = 0;
    EventBus.publish('paste', this.items[0].text, Date.now());
  }

  /**
   * 广播全量快照（op=snapshot，text=JSON 数组，**旧→新**顺序）。
   * 用途：公共事件只在两侧进程都活着时送达 ⇒ 一方离线期间的事件会丢，
   * 所以两侧一启动就各广播一次全量，另一方把缺的补上（合并，不删，避免误清空）。
   */
  private publishSnapshot(): void {
    try {
      const parts: string[] = [];
      for (let i = this.items.length - 1; i >= 0; i--) {
        parts.push(this.items[i].text);
      }
      EventBus.publish('snapshot', JSON.stringify(parts), Date.now());
      Logger.d(`Keyboard.publishSnapshot: ${parts.length} 条`);
    } catch (err) {
      Logger.w('publishSnapshot failed');
    }
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

  @Builder
  imeKey(label: string, colorIndex: number, action: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(this.p().imeKeyFg)
      .textAlign(TextAlign.Center)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .backgroundColor(this.p().imeKeyColors[colorIndex])
      .borderRadius(8)
      .margin({ right: 6 })
      .onClick(action)
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
          this.removeSelected();
        })
        this.imeKey('清空', 4, () => {
          ClipboardStore.clear();
          this.selectedTexts = [];
          // 跨进程同步：App 侧也清空（否则"一边删了另一边还有"）
          EventBus.publish('clear', '', Date.now());
        })
        this.imeKey('⚙', 3, () => {
          this.toggleSettings();
        })
        this.imeKey('▼', 4, () => {
          keyboardController.hidePanel();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(this.p().imeBarBg)
      .backgroundBlurStyle(this.p().blurBar ? BlurStyle.Thin : BlurStyle.NONE)
      .alignItems(VerticalAlign.Center)

      if (this.showSettings) {
        Text('')
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
              })
            }
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

            Text('提示：键盘进程与 App 是独立沙箱 —— 剪贴板历史、皮肤、日志各存一份。所以「切换目标 / 键盘高度 / 键盘皮肤 / 键盘日志」都只在本页设置才生效。')
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

      Text(this.items.length > 0 ? `📋 ${this.items.length} 条记录` : '📋 剪贴板监听中')
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
