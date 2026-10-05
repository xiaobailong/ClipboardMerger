import { inputMethodEngine, InputMethodExtensionContext } from '@kit.IMEKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipboardStore } from '../../model/ClipboardStore';
import { Logger } from '../../model/Logger';

/** 输入法面板要加载的页面（路径相对 ets 目录，与 main_pages.json 保持一致） */
const PANEL_PAGE: string = 'InputMethodExtensionAbility/pages/Index';

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
  private active: boolean = false;

  onCreate(context: InputMethodExtensionContext): void {
    ClipboardStore.init(context);
    Logger.d('KeyboardController.onCreate: start');

    const ability: inputMethodEngine.InputMethodAbility = inputMethodEngine.getInputMethodAbility();
    ability.on('inputStart', (kbController: inputMethodEngine.KeyboardController,
      client: inputMethodEngine.InputClient) => {
      this.client = client;
      this.active = true;
      AppStorage.setOrCreate<boolean>(STATE_IME_ACTIVE, true);
      Logger.d('inputStart: edit box attached');
      // 拉起键盘时补采一次剪贴板（刚复制完就切过来打字的场景）
      ClipboardStore.capture();
    });
    ability.on('inputStop', () => {
      this.client = undefined;
      this.active = false;
      AppStorage.setOrCreate<boolean>(STATE_IME_ACTIVE, false);
      Logger.d('inputStop: edit box detached');
    });

    // API 26：面板由 InputMethodAbility.createPanel(ctx, info) 创建（返回 Promise<Panel>）
    // flag 可省略（默认 FLG_FIXED 固定态），用 inputMethodEngine 自己的 PanelInfo/PanelType
    const info: inputMethodEngine.PanelInfo = { type: inputMethodEngine.PanelType.SOFT_KEYBOARD };
    ability.createPanel(context, info).then((panel: inputMethodEngine.Panel) => {
      this.panel = panel;
      panel.setUiContent(PANEL_PAGE).then(() => {
        Logger.d('setUiContent: ok');
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
}

/** 单例：扩展生命周期内复用 */
export const keyboardController: KeyboardController = new KeyboardController();
