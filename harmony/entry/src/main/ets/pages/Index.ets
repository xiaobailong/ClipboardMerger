import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ClipItem, ClipboardStore } from '../model/ClipboardStore';
import { Logger } from '../model/Logger';

const APP_VERSION: string = '1.88.0 (鸿蒙版)';
const PERM_READ_PASTEBOARD: Permissions = 'ohos.permission.READ_PASTEBOARD';
/** 列表一次最多渲染多少条（历史里可能存了几千条） */
const LIST_LIMIT: number = 200;

/**
 * 剪集设置页（对齐 Android 版 MainActivity 的信息架构）
 *
 * HarmonyOS 与 Android 的职责差异：
 * - Android：输入法就是监听器；这里输入法 Extension 只负责键盘与采集，
 *   设置页负责「权限 / 历史管理 / 日志开关 / 启用引导」。
 * - 输入法 Extension 受基础访问模式约束不能联网，所以 GitHub 同步（若要做）
 *   必须实现本页所在的 UIAbility 侧。
 */
@Entry
@Component
struct Index {
  @StorageLink('clipItems') items: ClipItem[] = [];
  @StorageLink('clipStatus') status: string = '';
  @State notice: string = '';
  @State logOn: boolean = Logger.isEnabled();

  private host(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** 申请剪贴板读取权限（API 12+ 读剪贴板需要它；受限权限可能要 ACL，见 harmony/README.md） */
  private async requestPermission(): Promise<void> {
    try {
      const at: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = [PERM_READ_PASTEBOARD];
      const result = await at.requestPermissionsFromUser(this.host(), perms);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
      this.notice = granted ? '已获得剪贴板读取权限' : '未授权：剪贴板采集会失败';
      Logger.d(`requestPermission: granted=${granted}`);
    } catch (err) {
      const e = err as BusinessError;
      this.notice = `申请权限失败（${e.code}）：权限可能未在签名里声明（ACL）`;
      Logger.w(`requestPermission failed: code=${e.code}, message=${e.message}`);
    }
  }

  private shownItems(): ClipItem[] {
    return this.items.length > LIST_LIMIT ? this.items.slice(0, LIST_LIMIT) : this.items;
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor('#5A6472')
      .width('100%')
      .margin({ top: 14, bottom: 6 })
  }

  @Builder
  actionButton(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(Color.White)
      .textAlign(TextAlign.Center)
      .padding({ top: 10, bottom: 10 })
      .backgroundColor(color)
      .borderRadius(8)
      .layoutWeight(1)
      .onClick(action)
  }

  build() {
    Column() {
      Row() {
        Text('剪集').fontSize(20).fontWeight(FontWeight.Bold)
        Text(APP_VERSION).fontSize(12).fontColor('#7A828E').margin({ left: 8 }).layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 12, bottom: 4 })

      Scroll() {
        Column() {
          Column() {
            Text(`输入法状态：${this.status}`).fontSize(13).fontColor('#1F2733').width('100%')
            if (this.notice.length > 0) {
              Text(this.notice).fontSize(12).fontColor('#1A6FD4').width('100%').margin({ top: 6 })
            }
            Text(`历史共 ${this.items.length} 条`).fontSize(12).fontColor('#7A828E').width('100%').margin({ top: 6 })
            Row() {
              this.actionButton('申请剪贴板权限', '#1A6FD4', () => {
                this.requestPermission();
              })
              this.actionButton('立即采集', '#2E9E5B', () => {
                ClipboardStore.capture();
              })
            }
            .width('100%')
            .margin({ top: 10 })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Color.White)
          .borderRadius(10)

          this.sectionTitle('怎么启用剪集输入法')
          Column() {
            Text('1. 设置 → 系统和更新 → 输入法（部分版本叫「语言和输入法」）')
              .fontSize(13).fontColor('#1F2733')
            Text('2. 在输入法列表里选中「剪集输入法」')
              .fontSize(13).fontColor('#1F2733').margin({ top: 6 })
            Text('3. 打字时点键盘上的切换按钮，选「剪集输入法」')
              .fontSize(13).fontColor('#1F2733').margin({ top: 6 })
            Text('注意：鸿蒙系统不允许卓易通里跑的安卓应用注册成系统输入法，必须用这个原生版本。')
              .fontSize(11).fontColor('#9AA2AE').margin({ top: 8 })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Color.White)
          .borderRadius(10)
          .alignItems(HorizontalAlign.Start)

          this.sectionTitle(`剪贴板历史（${this.items.length}）`)
          Row() {
            this.actionButton('刷新', '#1A6FD4', () => {
              ClipboardStore.capture();
            })
            this.actionButton('清空历史', '#C0392B', () => {
              ClipboardStore.clear();
            })
          }
          .width('100%')

          if (this.items.length === 0) {
            Text('暂无记录').fontSize(13).fontColor('#7A828E').width('100%').padding({ top: 10 })
          } else {
            Column() {
              ForEach(this.shownItems(), (item: ClipItem) => {
                Row() {
                  Text(item.text)
                    .fontSize(13)
                    .fontColor('#1F2733')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('写回')
                    .fontSize(12)
                    .fontColor('#1A6FD4')
                    .padding({ left: 8 })
                    .onClick(() => {
                      ClipboardStore.copyToPasteboard(item.text);
                    })
                  Text('✕')
                    .fontSize(13)
                    .fontColor('#A0A6B0')
                    .padding({ left: 8 })
                    .onClick(() => {
                      ClipboardStore.removeAt(this.items.indexOf(item));
                    })
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .border({ width: { bottom: 1 }, color: '#EDF0F4' })
              }, (item: ClipItem) => `${item.timestamp}_${item.text.length}`)
            }
            .width('100%')
            .padding({ left: 12, right: 12 })
            .backgroundColor(Color.White)
            .borderRadius(10)
          }

          this.sectionTitle('调试')
          Row() {
            Column() {
              Text('日志输出').fontSize(14).fontColor('#1F2733')
              Text('关闭后不再写日志文件（进程重启也保持关闭）').fontSize(11).fontColor('#9AA2AE')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.logOn })
              .onChange((isOn: boolean) => {
                this.logOn = isOn;
                Logger.setEnabled(this.host(), isOn);
              })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(Color.White)
          .borderRadius(10)

          this.sectionTitle('关于')
          Column() {
            Text(`版本：${APP_VERSION}`).fontSize(13).fontColor('#1F2733')
            Text(`日志文件：${Logger.getLogFile() === '' ? '（未启用）' : Logger.getLogFile()}`)
              .fontSize(11).fontColor('#7A828E').margin({ top: 6 })
            Text('鸿蒙版与 Android 版功能语义一致；鸿蒙的输入法只能由原生 HAP 注册，卓易通里跑的 APK 无法成为系统输入法。')
              .fontSize(11).fontColor('#9AA2AE').margin({ top: 6 })
          }
          .width('100%')
          .padding(12)
          .margin({ bottom: 20 })
          .backgroundColor(Color.White)
          .borderRadius(10)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor('#F2F4F7')
  }
}
