import { InputMethodExtensionAbility } from '@kit.IMEKit';
import { Want } from '@kit.AbilityKit';
import { keyboardController } from './model/KeyboardController';
import { Logger } from '../model/Logger';

const TAG: string = 'InputMethodService';

/**
 * 剪集输入法（对齐 Android 版 ClipboardInputMethodService）
 *
 * 注意：输入法 Extension 受「基础访问模式」约束 ——
 * 只做基础打字能力，不要在这里做网络请求（GitHub 同步请放在设置页的 UIAbility 里）。
 */
export default class InputMethodService extends InputMethodExtensionAbility {
  onCreate(want: Want): void {
    keyboardController.onCreate(this.context);
    Logger.d(`${TAG}.onCreate: want=${want.abilityName}`);
  }

  onDestroy(): void {
    keyboardController.onDestroy();
    Logger.d(`${TAG}.onDestroy`);
  }
}
