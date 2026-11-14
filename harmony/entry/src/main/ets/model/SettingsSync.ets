import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Logger } from './Logger';
import { ImeSettings } from './ImeSettings';
import { RecycleBinStore } from './RecycleBin';
import { THEME_ANDROID, THEME_HARMONY, ThemeStore } from './Theme';

const PREF_STORE: string = 'clipboard_merger_settings';
/** 键盘侧「最近一次自己改设置」的时间戳（补发保护用，见 PIT-053） */
const K_LAST_SETTING_TS: string = 'ime_last_setting_ts';

/**
 * 设置同步（PIT-052）
 *
 * 背景：输入法进程与 App 进程是两个沙箱，preferences 各存一份 ⇒ 皮肤 / 日志开关 /
 * 键盘高度 / 切换目标 / 回收站保留天数这些「两边都有」的设置天生会不一致。
 *
 * 规则：**键盘那份是权威源**，App 打开时拉一次快照对齐；App 里改设置则单条回写键盘
 * （只带改动的那一个 key，避免用 App 的旧值把键盘侧的别的设置盖掉）。
 */

/**
 * 需要跨进程对齐的设置。
 *
 * ⚠️ **日志开关不在这里**：App 与键盘是两个进程、两套日志文件，日志开关由各自
 * 的界面独立管理（互不影响），用户明确要求「分开管理，各自设置各自的」。
 */
export interface SettingsSnapshot {
  /** 皮肤 id：harmony / android */
  theme: string;
  /** 键盘面板高度比例（0.15~0.60） */
  heightRate: number;
  /** 切换目标输入法（空串 = 不限，切下一个） */
  targetBundle: string;
  targetId: string;
  targetLabel: string;
  /** 回收站保留天数（-1 = 永久保留） */
  retentionDays: number;
}

/** 单条设置改动的 key */
export const SET_KEY_THEME: string = 'theme';
export const SET_KEY_HEIGHT: string = 'heightRate';
export const SET_KEY_TARGET: string = 'target';
export const SET_KEY_RETENTION: string = 'retentionDays';

/** 单条设置改动（value 一律用字符串承载，数字/布尔由收方解析） */
export interface SettingChange {
  key: string;
  value: string;
}

export class SettingsSync {
  private static ctx: common.Context | undefined = undefined;
  private static lastLocalTs: number = 0;

  /** 键盘进程启动时调用（只有键盘侧需要记「本地改设置的时间」） */
  static init(context: common.Context): void {
    SettingsSync.ctx = context;
  }

  /**
   * 键盘侧自己改了设置：记时间戳（持久化，进程重启后仍能挡住过期的补发）。
   * App 侧改动命令会带自己的 ts，若早于这个时间戳 ⇒ 键盘忽略它，
   * 避免「App 离线期间的旧设置」在键盘重启补发时盖掉键盘后来改过的新值。
   */
  static markLocalChange(ts: number): void {
    const t: number = ts > 0 ? ts : Date.now();
    if (t <= SettingsSync.lastLocalTs) {
      return;
    }
    SettingsSync.lastLocalTs = t;
    const ctx = SettingsSync.ctx;
    if (ctx === undefined) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: PREF_STORE });
      store.putSync(K_LAST_SETTING_TS, t);
      store.flushSync();
    } catch (err) {
      Logger.w('SettingsSync.markLocalChange: persist failed');
    }
  }

  static lastLocalChange(): number {
    if (SettingsSync.lastLocalTs > 0) {
      return SettingsSync.lastLocalTs;
    }
    const ctx = SettingsSync.ctx;
    if (ctx === undefined) {
      return 0;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: PREF_STORE });
      const v: preferences.ValueType = store.getSync(K_LAST_SETTING_TS, 0);
      SettingsSync.lastLocalTs = typeof v === 'number' ? v : 0;
    } catch (err) {
      SettingsSync.lastLocalTs = 0;
    }
    return SettingsSync.lastLocalTs;
  }

  /** 读本进程当前的设置（键盘侧用它生成快照） */
  static snapshot(): SettingsSnapshot {
    const target = ImeSettings.getTarget();
    const brief = target === undefined ? undefined : target;
    const snap: SettingsSnapshot = {
      theme: ThemeStore.current(),
      heightRate: ImeSettings.heightRate(),
      targetBundle: brief === undefined ? '' : brief.bundle,
      targetId: brief === undefined ? '' : brief.id,
      targetLabel: brief === undefined ? '' : brief.label,
      retentionDays: RecycleBinStore.retentionDays()
    };
    return snap;
  }

  static toJson(): string {
    return JSON.stringify(SettingsSync.snapshot());
  }

  static parse(json: string): SettingsSnapshot | undefined {
    if (json === undefined || json === null || json === '') {
      return undefined;
    }
    try {
      const s: SettingsSnapshot = JSON.parse(json) as SettingsSnapshot;
      if (s === undefined || s === null) {
        return undefined;
      }
      return s;
    } catch (err) {
      Logger.w('SettingsSync.parse: failed');
      return undefined;
    }
  }

  /**
   * 把键盘快照写进本进程的各个 store（App 侧对齐用；不动 UI 状态，调用方自己回读刷新）。
   * 值没变就不写，避免每次 onPageShow 都触发持久化 / 回收站清理。
   */
  static applySnapshot(s: SettingsSnapshot): void {
    const theme: string = s.theme === THEME_ANDROID ? THEME_ANDROID : THEME_HARMONY;
    if (ThemeStore.current() !== theme) {
      ThemeStore.set(theme);
    }
    // 日志开关不参与对齐：两端各管各的（见 SettingsSnapshot 注释）
    if (s.heightRate > 0 && ImeSettings.heightRate() !== s.heightRate) {
      ImeSettings.setHeightRate(s.heightRate);
    }
    const cur = ImeSettings.getTarget();
    const curBundle: string = cur === undefined ? '' : cur.bundle;
    if (s.targetBundle !== curBundle) {
      if (s.targetBundle === '') {
        ImeSettings.clearTarget();
      } else {
        ImeSettings.setTarget({
          label: s.targetLabel !== '' ? s.targetLabel : s.targetBundle,
          bundle: s.targetBundle,
          id: s.targetId
        });
      }
    }
    if (RecycleBinStore.retentionDays() !== s.retentionDays) {
      RecycleBinStore.setRetentionDays(s.retentionDays);
    }
    Logger.d(`SettingsSync.applySnapshot: theme=${theme}, height=${s.heightRate}, ` +
      `target=${s.targetBundle}, retention=${s.retentionDays}`);
  }

  /** 单条改动 → JSON（App 回写键盘用） */
  static changeJson(key: string, value: string): string {
    const ch: SettingChange = { key: key, value: value };
    return JSON.stringify(ch);
  }

  static parseChange(json: string): SettingChange | undefined {
    if (json === undefined || json === null || json === '') {
      return undefined;
    }
    try {
      const ch: SettingChange = JSON.parse(json) as SettingChange;
      if (ch === undefined || ch === null || typeof ch.key !== 'string') {
        return undefined;
      }
      return ch;
    } catch (err) {
      Logger.w('SettingsSync.parseChange: failed');
      return undefined;
    }
  }
}
