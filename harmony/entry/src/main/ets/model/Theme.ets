import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const PREF_STORE: string = 'clipboard_merger_settings';
const KEY_THEME: string = 'theme_id';

/** 皮肤 id */
export const THEME_HARMONY: string = 'harmony';
export const THEME_ANDROID: string = 'android';
/** AppStorage 键（两个进程各自订阅） */
export const STATE_THEME: string = 'themeId';

/** 一套皮肤的全部颜色（主界面 + 输入法面板） */
export interface Palette {
  pageBg: string;
  barBg: string;
  blurBar: boolean;
  barText: string;
  barTextDim: string;
  cardBg: string;
  cardSelBg: string;
  textPrimary: string;
  textSecondary: string;
  accent: string;
  danger: string;
  selMark: string;
  statusOffBg: string;
  statusOffFg: string;
  statusOnBg: string;
  statusOnFg: string;
  bindBg: string;
  bindFg: string;
  imeBg: string;
  imeBarBg: string;
  imeKeyFg: string;
  imeKeyColors: string[];
  imeItemBg: string;
  imeItemSelBg: string;
  imeItemFg: string;
  imeMark: string;
  imeStatusBg: string;
  imeStatusFg: string;
}

/** 鸿蒙风：清淡白 + 略带透明，选中态灰色 */
export const HARMONY_PALETTE: Palette = {
  pageBg: '#F2F2F7',
  barBg: '#F2FFFFFF',
  blurBar: true,
  barText: '#1C1C1E',
  barTextDim: '#8E8E93',
  cardBg: '#E6FFFFFF',
  cardSelBg: '#D9D9D9',
  textPrimary: '#1C1C1E',
  textSecondary: '#8E8E93',
  accent: '#0A59F7',
  danger: '#E84026',
  selMark: '#8C8C8C',
  statusOffBg: '#FFF7E6',
  statusOffFg: '#B26A00',
  statusOnBg: '#EAF7EE',
  statusOnFg: '#1F7A3D',
  bindBg: '#EAF1FF',
  bindFg: '#0A59F7',
  imeBg: '#F2F2F7',
  imeBarBg: '#F2FFFFFF',
  imeKeyFg: '#1C1C1E',
  imeKeyColors: ['#E9E9EB', '#E9E9EB', '#E9E9EB', '#E9E9EB', '#E9E9EB'],
  imeItemBg: '#E6FFFFFF',
  imeItemSelBg: '#D9D9D9',
  imeItemFg: '#1C1C1E',
  imeMark: '#8C8C8C',
  imeStatusBg: '#E5E5EA',
  imeStatusFg: '#6E6E73'
};

/** Android 原版：紫顶栏 + 白卡片 + 深绿键盘（取值来自 app/src/main/res/values/colors.xml 与 layout/ime_view.xml） */
export const ANDROID_PALETTE: Palette = {
  pageBg: '#F5F5F5',
  barBg: '#6200EE',
  blurBar: false,
  barText: '#FFFFFF',
  barTextDim: '#80FFFFFF',
  cardBg: '#FFFFFF',
  cardSelBg: '#FFFFFF',
  textPrimary: '#DE000000',
  textSecondary: '#99000000',
  accent: '#6200EE',
  danger: '#E53935',
  selMark: '#6200EE',
  statusOffBg: '#FFF3E0',
  statusOffFg: '#E65100',
  statusOnBg: '#E8F5E9',
  statusOnFg: '#2E7D32',
  bindBg: '#E3F2FD',
  bindFg: '#1565C0',
  imeBg: '#1B5E20',
  imeBarBg: '#1B5E20',
  imeKeyFg: '#FFFFFF',
  imeKeyColors: ['#388E3C', '#FF9800', '#2E7D32', '#D32F2F', '#B00020'],
  imeItemBg: '#1A3A1A',
  imeItemSelBg: '#264A26',
  imeItemFg: '#E8F5E9',
  imeMark: '#A5D6A7',
  imeStatusBg: '#0D3D13',
  imeStatusFg: '#FFFFFF'
};

/**
 * 皮肤设置（持久化在 clipboard_merger_settings / theme_id）
 *
 * 注意：主界面在 UIAbility 进程、键盘面板在输入法 Extension 进程，AppStorage 不跨进程，
 * 所以输入法侧在每次键盘显示时 reload() 一次，保证切换后立即生效。
 */
export class ThemeStore {
  private static ctx: common.Context | undefined = undefined;
  private static id: string = THEME_HARMONY;

  static init(context: common.Context): void {
    ThemeStore.ctx = context;
    ThemeStore.reload();
  }

  /** 从 preferences 重读（进程内首次 + 输入法每次键盘显示时调用） */
  static reload(): void {
    if (ThemeStore.ctx !== undefined) {
      try {
        const store = preferences.getPreferencesSync(ThemeStore.ctx, { name: PREF_STORE });
        const raw: preferences.ValueType = store.getSync(KEY_THEME, THEME_HARMONY);
        ThemeStore.id = typeof raw === 'string' ? raw : THEME_HARMONY;
      } catch (err) {
        ThemeStore.id = THEME_HARMONY;
      }
    }
    AppStorage.setOrCreate<string>(STATE_THEME, ThemeStore.id);
    Logger.d(`ThemeStore.reload: ${ThemeStore.id}`);
  }

  static current(): string {
    return ThemeStore.id;
  }

  /** 切换并持久化 */
  static set(name: string): void {
    ThemeStore.id = name;
    if (ThemeStore.ctx !== undefined) {
      try {
        const store = preferences.getPreferencesSync(ThemeStore.ctx, { name: PREF_STORE });
        store.putSync(KEY_THEME, name);
        store.flushSync();
      } catch (err) {
        Logger.w('ThemeStore.set: persist failed');
      }
    }
    AppStorage.setOrCreate<string>(STATE_THEME, name);
    Logger.d(`ThemeStore.set: ${name}`);
  }

  static palette(): Palette {
    return ThemeStore.id === THEME_ANDROID ? ANDROID_PALETTE : HARMONY_PALETTE;
  }
}

/** 页面里按 themeId 取调色板（供 @StorageLink 响应式使用） */
export function paletteOf(themeId: string): Palette {
  return themeId === THEME_ANDROID ? ANDROID_PALETTE : HARMONY_PALETTE;
}
