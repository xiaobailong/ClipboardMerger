import { inputMethod } from '@kit.IMEKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const PREF_STORE: string = 'clipboard_merger_settings';
const K_TARGET_BUNDLE: string = 'target_ime_bundle';
const K_TARGET_ID: string = 'target_ime_id';
const K_TARGET_LABEL: string = 'target_ime_label';
const K_LAST_SWITCH: string = 'ime_last_switch_report';
const K_HEIGHT_RATE: string = 'ime_panel_height_rate';
/** 上次在键盘里粘贴的时间戳（用于算"有几条新内容待粘贴"） */
const K_LAST_PASTE_TS: string = 'ime_last_paste_ts';
/** 键盘面板默认高度比例（屏幕高度 × 该值） */
const DEFAULT_HEIGHT_RATE: number = 0.30;
const OWN_BUNDLE: string = 'com.example.clipboardmerger';

/** 输入法条目（label=中文显示名，bundle/id=唯一标识） */
export interface ImeItem {
  label: string;
  bundle: string;
  id: string;
}

/**
 * 输入法列表 / 切换目标（对齐 Android 的 dialog_ime_settings：选一个"切换"按钮的目标输入法）
 * 列表一律显示系统给的 label（中文名），label 为空才退回包名。
 */
export class ImeSettings {
  private static ctx: common.Context | undefined = undefined;
  private static target: ImeItem | undefined = undefined;
  private static lastSwitchText: string = '';
  private static heightRateValue: number = 0;
  private static lastPaste: number = 0;

  static init(context: common.Context): void {
    ImeSettings.ctx = context;
    ImeSettings.reload();
  }

  static reload(): void {
    if (ImeSettings.ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
      const bundle: preferences.ValueType = store.getSync(K_TARGET_BUNDLE, '');
      const id: preferences.ValueType = store.getSync(K_TARGET_ID, '');
      const label: preferences.ValueType = store.getSync(K_TARGET_LABEL, '');
      if (typeof bundle === 'string' && bundle !== '' && typeof id === 'string') {
        ImeSettings.target = {
          label: typeof label === 'string' && label !== '' ? label : bundle,
          bundle: bundle,
          id: id
        };
      } else {
        ImeSettings.target = undefined;
      }
    } catch (err) {
      Logger.w('ImeSettings.reload failed');
    }
  }

  /** 系统里全部输入法（含本应用），label 为空时用包名兜底 */
  static listAll(): ImeItem[] {
    const out: ImeItem[] = [];
    try {
      const all: Array<inputMethod.InputMethodProperty> = inputMethod.getSetting().getAllInputMethodsSync();
      for (let i = 0; i < all.length; i++) {
        const p: inputMethod.InputMethodProperty = all[i];
        const label: string = p.label === undefined || p.label === '' ? p.name : p.label;
        out.push({ label: label, bundle: p.name, id: p.id });
      }
    } catch (err) {
      Logger.w('ImeSettings.listAll failed');
    }
    return out;
  }

  /** 当前输入法（label 化了的中文名） */
  static current(): ImeItem | undefined {
    try {
      const p: inputMethod.InputMethodProperty = inputMethod.getCurrentInputMethod();
      const label: string = p.label === undefined || p.label === '' ? p.name : p.label;
      return { label: label, bundle: p.name, id: p.id };
    } catch (err) {
      return undefined;
    }
  }

  /** 本应用的输入法是否已注册进系统 */
  static ownRegistered(): boolean {
    const all: ImeItem[] = ImeSettings.listAll();
    for (let i = 0; i < all.length; i++) {
      if (all[i].bundle === OWN_BUNDLE) {
        return true;
      }
    }
    return false;
  }

  static getTarget(): ImeItem | undefined {
    return ImeSettings.target;
  }

  static setTarget(item: ImeItem): void {
    ImeSettings.target = item;
    ImeSettings.persist(item.bundle, item.id, item.label);
    Logger.d(`ImeSettings.setTarget: ${item.label} (${item.bundle}/${item.id})`);
  }

  /** 不限（默认切换到系统列表里的另一个输入法） */
  static clearTarget(): void {
    ImeSettings.target = undefined;
    ImeSettings.persist('', '', '');
    Logger.d('ImeSettings.clearTarget');
  }

  /** 键盘「切换」按钮的实际目标：优先配置的目标，没配则取第一个非本应用的输入法 */
  static effectiveTarget(): ImeItem | undefined {
    if (ImeSettings.target !== undefined) {
      return ImeSettings.target;
    }
    const all: ImeItem[] = ImeSettings.listAll();
    for (let i = 0; i < all.length; i++) {
      if (all[i].bundle !== OWN_BUNDLE) {
        return all[i];
      }
    }
    return undefined;
  }

  /**
   * 最近一次「切换」的结果报告。
   * 键盘跑在输入法进程里、主界面在 UI 进程里 ⇒ 跨进程只能走 preferences。
   * 排查"设了小艺却切到百度"这类问题时，主界面的「切换目标」弹层直接显示它。
   */
  static setLastSwitch(report: string): void {
    ImeSettings.lastSwitchText = report;
    if (ImeSettings.ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
      store.putSync(K_LAST_SWITCH, report);
      store.flushSync();
    } catch (err) {
      Logger.w('ImeSettings.setLastSwitch failed');
    }
  }

  /** 上次在键盘里粘贴的时间戳（0 = 从没粘过） */
  static setLastPasteTs(ts: number): void {
    ImeSettings.lastPaste = ts;
    if (ImeSettings.ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
      store.putSync(K_LAST_PASTE_TS, ts);
      store.flushSync();
    } catch (err) {
      Logger.w('ImeSettings.setLastPasteTs failed');
    }
  }

  static lastPasteTs(): number {
    if (ImeSettings.lastPaste > 0) {
      return ImeSettings.lastPaste;
    }
    if (ImeSettings.ctx === undefined) {
      return 0;
    }
    try {
      const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
      const v: preferences.ValueType = store.getSync(K_LAST_PASTE_TS, 0);
      ImeSettings.lastPaste = typeof v === 'number' ? v : 0;
    } catch (err) {
      Logger.w('ImeSettings.lastPasteTs read failed');
    }
    return ImeSettings.lastPaste;
  }

  static lastSwitch(): string {
    if (ImeSettings.lastSwitchText !== '') {
      return ImeSettings.lastSwitchText;
    }
    if (ImeSettings.ctx === undefined) {
      return '';
    }
    try {
      const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
      const v: preferences.ValueType = store.getSync(K_LAST_SWITCH, '');
      ImeSettings.lastSwitchText = typeof v === 'string' ? v : '';
    } catch (err) {
      Logger.w('ImeSettings.lastSwitch read failed');
    }
    return ImeSettings.lastSwitchText;
  }

  /** 键盘面板高度比例（屏高 × rate），可在「键盘设置」里调 */
  static setHeightRate(rate: number): void {
    ImeSettings.heightRateValue = rate;
    if (ImeSettings.ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
      store.putSync(K_HEIGHT_RATE, rate);
      store.flushSync();
    } catch (err) {
      Logger.w('ImeSettings.setHeightRate failed');
    }
    Logger.d(`ImeSettings.setHeightRate: ${rate}`);
  }

  static heightRate(): number {
    if (ImeSettings.heightRateValue > 0) {
      return ImeSettings.heightRateValue;
    }
    let v: number = DEFAULT_HEIGHT_RATE;
    if (ImeSettings.ctx !== undefined) {
      try {
        const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
        const raw: preferences.ValueType = store.getSync(K_HEIGHT_RATE, DEFAULT_HEIGHT_RATE);
        v = typeof raw === 'number' ? raw : DEFAULT_HEIGHT_RATE;
      } catch (err) {
        v = DEFAULT_HEIGHT_RATE;
      }
    }
    ImeSettings.heightRateValue = v;
    return v;
  }

  private static persist(bundle: string, id: string, label: string): void {
    if (ImeSettings.ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ImeSettings.ctx, { name: PREF_STORE });
      store.putSync(K_TARGET_BUNDLE, bundle);
      store.putSync(K_TARGET_ID, id);
      store.putSync(K_TARGET_LABEL, label);
      store.flushSync();
    } catch (err) {
      Logger.w('ImeSettings.persist failed');
    }
  }
}
