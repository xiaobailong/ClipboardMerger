import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipboardStore } from '../model/ClipboardStore';
import { KeepAlive } from '../model/KeepAlive';
import { Logger } from '../model/Logger';
import { ThemeStore } from '../model/Theme';

/**
 * 入口 UIAbility：剪集的设置页 / 历史页
 *
 * 剪贴板采集在「输入法进程」里做主监听；这里只是让 App 本身也能看历史、
 * 申请剪贴板权限、开关日志。输入法 Extension 不允许联网，
 * 因此将来若要接「GitHub 同步」，实现位置应当在本 Ability 侧。
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.init(this.context);
    ThemeStore.init(this.context);
    KeepAlive.init(this.context);
    ClipboardStore.init(this.context);
    Logger.d('EntryAbility.onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index').then(() => {
      Logger.d('EntryAbility: loadContent pages/Index ok');
    }).catch((err: BusinessError) => {
      Logger.w(`EntryAbility: loadContent failed, code=${err.code}`);
    });
  }

  onDestroy(): void {
    Logger.d('EntryAbility.onDestroy');
  }
}
