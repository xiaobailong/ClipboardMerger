import { ClipItem, ClipboardStore } from '../../model/ClipboardStore';
import { keyboardController } from '../model/KeyboardController';

/** 键盘面板高度（vp）。若真机上键盘区域不贴合，先调这个值 */
const PANEL_HEIGHT_VP: number = 300;

/**
 * 剪集输入法键盘
 *
 * 与 Android 版 IME 面板的功能对齐：
 * - 点一条 = 插入到编辑框
 * - 勾选多条 +「合并插入」= 全部拼成一段插入（对齐 Android 的合并粘贴）
 * - 退格 / 回车 / 刷新 / 清空历史 / 单条删除
 */
@Entry
@Component
struct Index {
  @StorageLink('clipItems') items: ClipItem[] = [];
  @StorageLink('clipStatus') status: string = '';
  @StorageLink('imeActive') imeActive: boolean = false;
  @State selected: string[] = [];

  private isPicked(text: string): boolean {
    return this.selected.indexOf(text) >= 0;
  }

  private toggle(text: string): void {
    const i: number = this.selected.indexOf(text);
    if (i >= 0) {
      this.selected.splice(i, 1);
    } else {
      this.selected.push(text);
    }
    this.selected = this.selected.slice();
  }

  /** 按历史顺序拼接已勾选的内容 */
  private mergedText(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const it: ClipItem = this.items[i];
      if (this.selected.indexOf(it.text) >= 0) {
        parts.push(it.text);
      }
    }
    return parts.join('\n');
  }

  private mergeInsert(): void {
    const text: string = this.mergedText();
    if (text.length === 0) {
      return;
    }
    keyboardController.insertText(text);
    this.selected = [];
  }

  @Builder
  tinyButton(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(color)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(6)
      .backgroundColor(Color.White)
      .margin({ left: 6 })
      .onClick(action)
  }

  build() {
    Column() {
      Row() {
        Text(this.imeActive ? `剪集 · 共 ${this.items.length} 条` : '剪集 · 未绑定编辑框')
          .fontSize(12)
          .fontColor('#5A6472')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        this.tinyButton('刷新', '#1A6FD4', () => {
          ClipboardStore.capture();
        })
        this.tinyButton('清空', '#C0392B', () => {
          ClipboardStore.clear();
          this.selected = [];
        })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .alignItems(VerticalAlign.Center)

      if (this.items.length === 0) {
        Column() {
          Text('还没有剪贴板记录')
            .fontSize(14)
            .fontColor('#7A828E')
          Text(this.status)
            .fontSize(11)
            .fontColor('#9AA2AE')
            .margin({ top: 6 })
          Text('复制一段文字后再点「刷新」；若一直为空，请到「剪集」App 里授予剪贴板读取权限')
            .fontSize(11)
            .fontColor('#9AA2AE')
            .margin({ top: 6 })
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding({ left: 20, right: 20 })
      } else {
        List({ space: 4 }) {
          ForEach(this.items, (item: ClipItem) => {
            ListItem() {
              Row() {
                Text(this.isPicked(item.text) ? '☑' : '☐')
                  .fontSize(16)
                  .fontColor('#1A6FD4')
                  .padding({ right: 8 })
                  .onClick(() => {
                    this.toggle(item.text);
                  })
                Column() {
                  Text(item.text)
                    .fontSize(14)
                    .fontColor('#1F2733')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${item.text.length} 字`)
                    .fontSize(10)
                    .fontColor('#9AA2AE')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text('✕')
                  .fontSize(15)
                  .fontColor('#A0A6B0')
                  .padding({ left: 10, right: 4, top: 4, bottom: 4 })
                  .onClick(() => {
                    ClipboardStore.removeAt(this.items.indexOf(item));
                  })
              }
              .width('100%')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(Color.White)
              .borderRadius(6)
              .onClick(() => {
                keyboardController.insertText(item.text);
              })
            }
          }, (item: ClipItem) => `${item.timestamp}_${item.text.length}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 10, right: 10 })
      }

      Row() {
        this.tinyButton('退格', '#333333', () => {
          keyboardController.deleteForward(1);
        })
        this.tinyButton(`合并插入(${this.selected.length})`, this.selected.length > 0 ? '#1A6FD4' : '#B4BAC4', () => {
          this.mergeInsert();
        })
        Blank()
        this.tinyButton('回车', '#333333', () => {
          keyboardController.sendKeyFunction(1);
        })
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 6, bottom: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height(PANEL_HEIGHT_VP)
    .backgroundColor('#EDF0F4')
  }
}
