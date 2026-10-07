import { inputMethod, inputMethodEngine, InputMethodExtensionContext } from '@kit.IMEKit';
import { display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipboardStore } from '../../model/ClipboardStore';
import { Logger } from '../../model/Logger';
import { ImeSettings } from '../../model/ImeSettings';
import { ThemeStore } from '../../model/Theme';

/** 输入法面板要加载的页面（路径相对 ets 目录，与 main_pages.json 保持一致） */
const PANEL_PAGE: string = 'InputMethodExtensionAbility/pages/Keyboard';

/** 键盘面板高度 = 屏幕高度 × ImeSettings.heightRate()（0.38 偏高，实测默认 0.30；面板内「高度−/+」可调） */
const PANEL_HEIGHT_RATE: number = 0.30;

/** 本应用包名（轮转切换时跳过自己） */
const OWN_BUNDLE: string = 'com.example.clipboardmerger';

/** 界面订阅键：是否正在跟编辑框绑定 */
export const STATE_IME_ACTIVE: string = 'imeActive';

/**
 * 输入法面板控制器（对齐 Android 版 ClipboardInputMethodService 的职责）
 *
 * 生命周期：InputMethodService.onCreate → 本类 onCreate(扩展上下文)
 * 面板创建用 IME Kit 的 createPanel；键盘页面通过 AppStorage 读历史、
 * 通过本类（单例）往编辑框里插文本。
 */
export class KeyboardController {
  private panel: inputMethodEngine.Panel | undefined = undefined;
  private client: inputMethodEngine.InputClient | undefined = undefined;
  private ctx: InputMethodExtensionContext | undefined = undefined;
  private active: boolean = false;

  onCreate(context: InputMethodExtensionContext): void {
    this.ctx = context;
    // 输入法进程也要初始化 Logger：否则 IME 侧日志只进 hilog、不落文件，
    // 排查键盘问题（切换/toast/面板高度）时从文件里什么都看不到（本轮就吃了这个亏）
    Logger.init(context);
    ClipboardStore.init(context);
    // 键盘侧自检：写进偏好 ⇒ App 的「切换目标」弹层直接显示（跨进程最可靠的回读通道）
    ImeSettings.setLastSwitch('IME 进程已创建 · ' + new Date().toTimeString().substring(0, 8));
    ThemeStore.init(context);
    ImeSettings.init(context);
    Logger.d('KeyboardController.onCreate: start');

    const ability: inputMethodEngine.InputMethodAbility = inputMethodEngine.getInputMethodAbility();
    ability.on('inputStart', (kbController: inputMethodEngine.KeyboardController,
      client: inputMethodEngine.InputClient) => {
      this.client = client;
      this.active = true;
      AppStorage.setOrCreate<boolean>(STATE_IME_ACTIVE, true);
      Logger.d('inputStart: edit box attached');
      // 输入法进程与 UI 进程不共享 AppStorage ⇒ 这里再重读一次皮肤
      ThemeStore.reload();
      // 拉起键盘时补采一次剪贴板（刚复制完就切过来打字的场景）
      ClipboardStore.capture();
      // 高度设置可能在 App 侧改过 ⇒ 每次输入开始都重新应用一次
      if (this.panel !== undefined) {
        this.resizePanel(this.panel);
      }
    });
    ability.on('inputStop', () => {
      this.client = undefined;
      this.active = false;
      AppStorage.setOrCreate<boolean>(STATE_IME_ACTIVE, false);
      Logger.d('inputStop: edit box detached');
    });
    // 键盘显示/隐藏（API 26 的 InputMethodAbility 事件）：显示时刷新一次历史
    ability.on('keyboardShow', () => {
      Logger.d('keyboardShow: refresh clipboard history');
      // 皮肤可能在 UI 进程被切换过（AppStorage 不跨进程）⇒ 每次显示重读一次
      ThemeStore.reload();
      ClipboardStore.capture();
      // 键盘高度设置改过之后必须在这里重新 resize 一次：
      // 面板只在 onCreate 里 resize 过，而设置页在另一个进程，改不动这里的 panel（PIT-042）
      if (this.panel !== undefined) {
        this.resizePanel(this.panel);
      }
    });
    ability.on('keyboardHide', () => {
      Logger.d('keyboardHide');
    });

    // API 26：面板由 InputMethodAbility.createPanel(ctx, info) 创建（返回 Promise<Panel>）
    // flag 可省略（默认 FLG_FIXED 固定态），用 inputMethodEngine 自己的 PanelInfo/PanelType
    const info: inputMethodEngine.PanelInfo = { type: inputMethodEngine.PanelType.SOFT_KEYBOARD };
    ability.createPanel(context, info).then((panel: inputMethodEngine.Panel) => {
      this.panel = panel;
      this.resizePanel(panel);
      panel.setUiContent(PANEL_PAGE).then(() => {
        Logger.d('setUiContent: ok');
        // 关键：面板尺寸要在**设置 UI 内容之后**再设一次 —— 之前只在 setUiContent 之前
        // resize 过，实测高度设置不生效（面板内容决定尺寸）
        this.resizePanel(panel);
      }).catch((err: BusinessError) => {
        Logger.w(`setUiContent failed: code=${err.code}, message=${err.message}`);
      });
    }).catch((err: BusinessError) => {
      Logger.w(`createPanel failed: code=${err.code}, message=${err.message}`);
    });

    ClipboardStore.startWatch();
    Logger.d('KeyboardController.onCreate: done');
  }

  onDestroy(): void {
    ClipboardStore.stopWatch();
    this.client = undefined;
    this.active = false;
    Logger.d('KeyboardController.onDestroy');
  }

  /**
   * 给面板设置可见尺寸（宽=屏宽，高=屏高×0.38）。
   * 不调用它的话，面板可能以 0/极小高度创建 ⇒ 表现成"输入法弹不出来"。
   */
  private resizePanel(panel: inputMethodEngine.Panel): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      // 高度比例来自设置（「键盘设置」里可调），默认 0.30
      const rate: number = ImeSettings.heightRate();
      const h: number = Math.round(d.height * rate);
      panel.resize(d.width, h).then(() => {
        Logger.d(`panel.resize ok: ${d.width}x${h} (rate=${rate}, screen ${d.width}x${d.height})`);
        ImeSettings.setLastSwitch(`面板 resize 成功 ${d.width}x${h}px · rate=${rate} · 屏 ${d.width}x${d.height}`);
      }).catch((err: BusinessError) => {
        Logger.w(`panel.resize failed: code=${err.code}, message=${err.message}`);
        ImeSettings.setLastSwitch(`面板 resize 失败 code=${err.code} ${err.message} · rate=${rate}`);
      });
    } catch (err) {
      Logger.w('resizePanel: getDefaultDisplaySync failed');
      ImeSettings.setLastSwitch('面板 resize 前置失败：取屏幕尺寸异常');
    }
  }

  /** 运行时改键盘高度（面板内「高度−/+」调完立即生效，不用重启输入法） */
  applyHeightRate(rate: number): void {
    ImeSettings.setHeightRate(rate);
    if (this.panel === undefined) {
      Logger.w('applyHeightRate: panel undefined');
      return;
    }
    this.resizePanel(this.panel);
  }

  /** 键盘进程自己的日志开关（键盘进程是独立沙箱，App 侧那个开关管不到它） */
  setLogEnabled(on: boolean): void {
    if (this.ctx === undefined) {
      return;
    }
    Logger.setEnabled(this.ctx, on);
    Logger.d(`KeyboardController.setLogEnabled: ${on}`);
  }

  logEnabled(): boolean {
    return Logger.isEnabled();
  }

  /** 系统全部输入法（面板内选择目标用；键盘进程自己枚举，不依赖 App 侧配置） */
  listIme(): Array<inputMethod.InputMethodProperty> {
    try {
      return inputMethod.getSetting().getAllInputMethodsSync();
    } catch (err) {
      Logger.w('listIme failed');
      return [];
    }
  }

  /** 当前输入法包名（用于"轮转下一个"） */
  currentImeName(): string {
    try {
      return inputMethod.getCurrentInputMethod().name;
    } catch (err) {
      return '';
    }
  }

  private labelOf(p: inputMethod.InputMethodProperty): string {
    return p.label === undefined || p.label === '' ? p.name : p.label;
  }

  /**
   * 切换输入法。target 为空 = 轮转到系统列表里的下一个（跳过自己）；
   * target 非空 = 切到指定包名。**不再依赖 App 侧 preferences**（跨沙箱读不到，这是
   * "设了小艺却切到百度"的根因：effectiveTarget 回退到列表第一个 = 百度）。
   */
  switchIme(target: string, onDone?: (msg: string) => void): void {
    const done = (m: string): void => {
      if (onDone !== undefined) {
        onDone(m);
      }
    };
    const all: Array<inputMethod.InputMethodProperty> = this.listIme();
    if (all.length === 0) {
      done('切换失败：系统返回的输入法列表为空');
      return;
    }
    let hit: inputMethod.InputMethodProperty | undefined = undefined;
    if (target !== '') {
      for (let i = 0; i < all.length; i++) {
        if (all[i].name === target) {
          hit = all[i];
        }
      }
    } else {
      const cur: string = this.currentImeName();
      let idx: number = -1;
      for (let i = 0; i < all.length; i++) {
        if (all[i].name === cur) {
          idx = i;
        }
      }
      for (let k = 1; k <= all.length; k++) {
        const p: inputMethod.InputMethodProperty = all[(idx + k + all.length) % all.length];
        if (p.name !== OWN_BUNDLE) {
          hit = p;
          break;
        }
      }
    }
    if (hit === undefined) {
      done(`切换失败：列表里没有 ${target === '' ? '其它' : target} 输入法`);
      return;
    }
    const lbl: string = this.labelOf(hit);
    const nm: string = hit.name;
    const id: string = hit.id;
    inputMethod.switchInputMethod(hit).then((ok: boolean) => {
      const r: string = `切到 ${lbl} → ${ok ? '成功' : '系统返回 false'}`;
      Logger.d(`ime switch ${r} (${nm}/${id})`);
      ImeSettings.setLastSwitch(r);
      done(r);
    }).catch((err: BusinessError) => {
      const r: string = `切到 ${lbl} 异常 code=${err.code}`;
      Logger.w(`ime switch ${r} (${nm}/${id}) ${err.message}`);
      ImeSettings.setLastSwitch(`${r} ${err.message}`);
      done(r);
    });
  }

  isActive(): boolean {
    return this.active;
  }

  /** 把文本插到当前编辑框（多选合并时传拼好的整串） */
  insertText(text: string): void {
    if (this.client === undefined) {
      Logger.w('insertText: no active edit box');
      return;
    }
    this.client.insertText(text).then(() => {
      Logger.d(`insertText: ok, len=${text.length}`);
    }).catch((err: BusinessError) => {
      Logger.w(`insertText failed: code=${err.code}, message=${err.message}`);
    });
  }

  /** 退格（IME Kit 里 KEYCODE_DEL 对应 deleteForward） */
  deleteForward(length: number): void {
    if (this.client === undefined) {
      return;
    }
    this.client.deleteForward(length).then(() => {
      Logger.d('deleteForward: ok');
    }).catch((err: BusinessError) => {
      Logger.w(`deleteForward failed: code=${err.code}, message=${err.message}`);
    });
  }

  /** 发送功能键：1 = 确认键（回车 / 搜索 / 发送，跟随编辑框类型） */
  sendKeyFunction(action: number): void {
    if (this.client === undefined) {
      return;
    }
    this.client.sendKeyFunction(action).then(() => {
      Logger.d('sendKeyFunction: ok');
    }).catch((err: BusinessError) => {
      Logger.w(`sendKeyFunction failed: code=${err.code}, message=${err.message}`);
    });
  }

  /**
   * 收起键盘（面板）：点键盘顶栏「▼ 收起」时调用。
   * Panel.hide() 是 IME Kit 提供的收起面板接口（不销毁，下次输入再 show）。
   */
  hidePanel(): void {
    if (this.panel === undefined) {
      Logger.w('hidePanel: panel is undefined');
      return;
    }
    this.panel.hide().then(() => {
      Logger.d('hidePanel: ok');
    }).catch((err: BusinessError) => {
      Logger.w(`hidePanel failed: code=${err.code}, message=${err.message}`);
    });
  }
}

/** 单例：扩展生命周期内复用 */
export const keyboardController: KeyboardController = new KeyboardController();
