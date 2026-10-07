import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { inputMethod } from '@kit.IMEKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { EventBus } from '../model/EventBus';
import settings from '@ohos.settings';
import { ClipItem, ClipboardStore } from '../model/ClipboardStore';
import { BUILD_TIME, BUILD_TYPE, GIT_COMMIT } from '../model/BuildInfo';
import { GhConfig, GitHubStore } from '../model/GitHub';
import { ImeItem, ImeSettings } from '../model/ImeSettings';
import { KeepAlive } from '../model/KeepAlive';
import { Logger } from '../model/Logger';
import { Notify } from '../model/Notify';
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

/**
 * 主界面：对齐 Android 版 activity_main.xml
 * Toolbar(剪集 + 更多) → Tab[剪切板 / GitHub] → 按钮栏[全选/取消全选/合并选中/清空全部]
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
  @State keepAliveOn: boolean = KeepAlive.isEnabled();
  @State keepAliveTick: string = '';
  @State bindName: string = '抖音';
  @State permPaste: boolean = false;
  @State permNotify: boolean = false;
  @State swReport: string = '';
  @State kbRate: number = 0.30;
  /** 键盘侧事件订阅者（跨进程：键盘采集到新内容 → 提醒切换输入法） */
  private histSub: commonEventManager.CommonEventSubscriber | undefined = undefined;
  @State ghOwner: string = '';
  @State ghRepo: string = '';
  @State ghPath: string = '';
  @State ghBranch: string = 'main';
  @State ghToken: string = '';
  @StorageLink(STATE_THEME) themeId: string = 'harmony';

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
    ClipboardStore.clear();
    this.selectedTexts = [];
    this.notice = '已清空全部记录（含系统剪贴板内容）';
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

  /** 申请通知授权（鸿蒙：首次会弹系统授权框） */
  private async enableNotify(): Promise<void> {
    const ok: boolean = await Notify.enable(this.host());
    this.refreshPerms();
    this.notice = ok ? '已获得通知授权' : '未获得通知授权（可到系统设置里开启）';
  }

  /** 发一条测试提醒（验证通知通道） */
  private async testNotify(): Promise<void> {
    await Notify.enable(this.host());
    await Notify.remind('剪集', '这是提醒测试：进入绑定的 App 时应该弹这条（鸿蒙替代 Android 悬浮气泡）');
    this.notice = '已发送测试提醒 —— 看通知栏 / 横幅';
  }

  /** 弹出系统输入法选择器（对齐 Android 点状态条切换键盘） */
  private showImePicker(): void {
    try {
      inputMethod.getSetting().showOptionalInputMethods().then((ok: boolean) => {
        this.notice = ok ? '已弹出输入法列表，请选择「剪集输入法」' : '系统未弹出输入法列表';
      }).catch((err: BusinessError) => {
        this.notice = `弹出输入法列表失败（${err.code}）`;
      });
    } catch (err) {
      const e = err as BusinessError;
      this.notice = `调用输入法接口失败（${e.code}）`;
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
  private async maybeRemindSwitchIme(src: string): Promise<void> {
    try {
      const cur = inputMethod.getCurrentInputMethod();
      const mine: boolean = cur.name === APP_BUNDLE;
      Logger.d(`maybeRemindSwitchIme(${src}): current=${cur.name}, mine=${mine}`);
      if (mine) {
        return;
      }
      await Notify.enable(this.host());
      await Notify.remind('剪集',
        '当前输入法不是「剪集」—— 点这里打开输入法设置，切到剪集就能一键粘贴刚复制的内容');
      this.notice = '当前不是剪集输入法，已提醒你去切换';
    } catch (err) {
      Logger.w('maybeRemindSwitchIme failed');
    }
  }

  aboutToAppear(): void {
    ImeSettings.init(this.host());
    this.refreshIme();
    this.refreshPerms();
    this.swReport = ImeSettings.lastSwitch();
    // 订阅键盘侧事件：键盘进程采集到新内容就广播 ⇒ 若当前输入法不是剪集，立刻提醒切换
    if (this.histSub === undefined) {
      this.histSub = EventBus.subscribe((e) => {
        if (e.op === 'add') {
          // 键盘侧采集到的新内容 → 同步进 App 那份历史（两边保持一致）
          if (e.text !== '') {
            ClipboardStore.addText(e.text);
          }
        } else if (e.op === 'clear') {
          ClipboardStore.clear();
          this.notice = '已随键盘侧清空历史';
        } else if (e.op === 'snapshot') {
          // 键盘侧全量快照（旧→新）：把 App 这份里缺的补上（只合并、不删除，避免误清空）
          try {
            const texts: string[] = JSON.parse(e.text) as string[];
            for (let i = 0; i < texts.length; i++) {
              ClipboardStore.addText(texts[i]);
            }
            if (texts.length > 0) {
              this.notice = `已与键盘侧对齐（键盘侧 ${texts.length} 条）`;
            }
          } catch (err) {
            Logger.w('snapshot parse failed');
          }
        } else if (e.op === 'remove') {
          const arr = ClipboardStore.getItems();
          for (let i = 0; i < arr.length; i++) {
            if (arr[i].text === e.text) {
              ClipboardStore.removeAt(i);
              break;
            }
          }
        }
      });
    }
    this.kbRate = ImeSettings.heightRate();
    this.loadAbout();
    GitHubStore.init(this.host());
    this.syncGhFields();
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

  /** 选择「切换」按钮的目标输入法 */
  private pickTarget(item: ImeItem | undefined): void {
    if (item === undefined) {
      ImeSettings.clearTarget();
      this.notice = '切换目标：不限（默认切到另一个输入法）';
    } else {
      ImeSettings.setTarget(item);
      this.notice = `切换目标已设为「${item.label}」`;
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

  @Builder
  statusBar(text: string, bg: string, fg: string, action: () => void) {
    Text(text)
      .fontSize(12)
      .fontColor(fg)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding(6)
      .backgroundColor(bg)
      .onClick(action)
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
        ClipboardStore.removeAt(this.items.indexOf(item));
        this.notice = '项目已删除';
      })
  }

  // ---------- GitHub 页（UI 先对齐，联网在 P2 接） ----------
  @Builder
  githubPage() {
    Column() {
      Row() {
        Text('GitHub 内容').fontSize(13).fontColor('#5A6472').layoutWeight(1)
        Text('仓库设置')
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
            this.textButton('清理日志', this.p().danger, () => {
              this.clearLogs();
            })
            this.textButton('导出到 Download', this.p().accent, () => {
              this.exportLog();
            })
          }
          .width('100%')
          .margin({ top: 4, bottom: 4 })
          Text('日志设置').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 10 })
          Row() {
            Text('日志输出').fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.logOn })
              .onChange((isOn: boolean) => {
                this.logOn = isOn;
                Logger.setEnabled(this.host(), isOn);
                this.notice = isOn ? '日志输出已开启' : '日志输出已关闭';
              })
          }
          .width('100%')
          Text('关闭后立即停止所有日志输出（文件日志与 hilog）；设置会保存，重启应用 / 输入法服务后依然生效')
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
        } else if (this.dialog === 'keepalive') {
          Text('后台保活 / 提醒').fontSize(16).fontWeight(FontWeight.Bold).margin({ bottom: 10 })
          Text('提醒（原「提醒设置」已并入这里）')
            .fontSize(13)
            .fontColor(this.p().textPrimary)
            .width('100%')
            .margin({ top: 4 })
          Text('鸿蒙普通应用拿不到悬浮窗权限（SYSTEM_FLOAT_WINDOW），横幅是否显示由系统策略决定 ⇒ 用『高优先级通知』提醒（合规路径，可靠性不如 Android 的自绘气泡）。')
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ top: 4 })
          Row() {
            if (this.permNotify) {
              Text('通知已授权 ✓').fontSize(13).fontColor(this.p().statusOnFg)
            } else {
              this.textButton('申请通知授权', this.p().accent, () => {
                this.enableNotify();
              })
            }
            this.textButton('发一条测试提醒', this.p().statusOnFg, () => {
              this.testNotify();
            })
          }
          .width('100%')
          .margin({ top: 8, bottom: 6 })
          Row() {
            this.filledButton('打开应用详情页（自启动/电池）', this.p().accent, () => {
              this.openAppDetail();
            })
          }
          .width('100%')
          .margin({ bottom: 6 })
          Text('① 系统侧（入口名各版本不同，照着找最近的）：设置 → 应用（或"应用和服务"）→ 应用管理 → 剪集 → 打开「应用启动管理 / 自启动 / 后台活动」，把「自动管理」关掉、手动允许自启动与后台活动；再把「最近任务」里的剪集卡片下拉加锁。')
            .fontSize(12)
            .fontColor(this.p().textPrimary)
            .width('100%')
            .margin({ top: 6 })
          Text('（如果在设置里找不到「应用启动管理」，就走「应用信息」页：设置 → 应用 → 应用管理 → 剪集 → 更多/详情）')
            .fontSize(11)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ top: 4 })
          Text('② App 侧（已内置）：剪集输入法被系统拉起时顺手补起剪贴板监听 —— 鸿蒙上最可靠的"复活点"（点任何输入框都会拉起输入法）。')
            .fontSize(12)
            .fontColor(this.p().textPrimary)
            .width('100%')
            .margin({ top: 6 })
          Text('③ 定时补活：鸿蒙有 WorkScheduler（延迟任务）可替代 Android 的自拉起闹钟，但要额外申请后台任务权限；"常用前台服务"对应鸿蒙的「长时任务」（必须挂通知）。开关就在下面（开启后约 20 分钟兜底一次，避免被系统判定滥用）。')
            .fontSize(12)
            .fontColor(this.p().textPrimary)
            .width('100%')
            .margin({ top: 6 })
          Text('④ 被系统「强行停止」后，鸿蒙同样不允许任何应用自拉起，只能手动点开一次剪集。')
            .fontSize(12)
            .fontColor(this.p().textSecondary)
            .width('100%')
            .margin({ top: 6 })
          Row() {
            Column() {
              Text('定时补活（延迟任务）').fontSize(14).fontColor(this.p().textPrimary)
              Text('鸿蒙 WorkScheduler：约 20 分钟一次，到点兜底采集剪贴板 + 写心跳日志')
                .fontSize(11)
                .fontColor(this.p().textSecondary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.keepAliveOn })
              .onChange((isOn: boolean) => {
                this.keepAliveOn = isOn;
                KeepAlive.setEnabled(this.host(), isOn);
                this.keepAliveTick = KeepAlive.lastTickTime();
                this.notice = isOn ? '定时补活已开启（首次触发可能要等一会）' : '定时补活已关闭';
              })
          }
          .width('100%')
          .margin({ top: 10 })
          if (this.keepAliveTick !== '') {
            Text(`最近一次心跳：${this.keepAliveTick}`)
              .fontSize(11)
              .fontColor(this.p().textSecondary)
              .width('100%')
              .margin({ top: 6 })
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
            this.notice = '已切换到 Android 原版皮肤';
          })
          Text('提示：键盘面板由输入法进程单独渲染，切换皮肤后下次弹出键盘即生效（已做自动重读）。')
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
            this.filledButton('保存设置', this.p().accent, () => {
              this.saveGhSettings();
            })
            this.textButton('网络诊断', this.p().textSecondary, () => {
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
                value: '权限设置',
                action: () => {
                  this.dialog = 'perm';
                }
              },
              {
                value: '皮肤',
                action: () => {
                  this.dialog = 'theme';
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
            })
          Text('GitHub')
            .fontSize(15)
            .fontColor(this.curTab === 1 ? this.p().barText : this.p().barTextDim)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.curTab = 1;
            })
        }
        .width('100%')
        .backgroundColor(this.p().barBg)
        .backgroundBlurStyle(this.p().blurBar ? BlurStyle.Thin : BlurStyle.NONE)

        if (this.curTab === 0) {
          this.clipboardPage()
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
        this.textButton('取消全选', this.p().textSecondary, () => {
          this.deselectAll();
        })
        this.filledButton('合并选中', this.p().accent, () => {
          this.mergeSelected();
        })
        this.textButton('清空全部', this.p().danger, () => {
          this.clearAll();
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
      .backgroundColor(this.p().cardBg)
      .alignItems(VerticalAlign.Center)

      Text(`共 ${this.items.length} 条　已选 ${this.selectedTexts.length} 条${this.selectedTexts.length > 1 ? '（点「合并选中」按列表顺序拼接）' : ''}`)
        .fontSize(11)
        .fontColor(this.p().textSecondary)
        .width('100%')
        .padding({ left: 10, bottom: 2 })

      this.statusBar(
        this.imeActive ? '输入法: 已激活 ✅ — 后台监听中' : '输入法: 未激活 ⚠️ (点击切换键盘)',
        this.imeActive ? this.p().statusOnBg : this.p().statusOffBg,
        this.imeActive ? this.p().statusOnFg : this.p().statusOffFg,
        () => {
          this.showImePicker();
        })

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
