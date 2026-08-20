import { common } from '@kit.AbilityKit';

@Entry
@Component
struct Index {
  build() {
    Column({ space: 16 }) {
      Text('予愿安洁莉娜 桌宠')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)

      Text('悬浮窗已启动，请回到桌面查看')
        .fontSize(14)
        .fontColor('#888888')

      Text('本页面仅作控制台，可切到后台')
        .fontSize(12)
        .fontColor('#aaaaaa')

      Button('退出桌宠')
        .margin({ top: 16 })
        .onClick(() => {
          (this.getUIContext().getHostContext() as common.UIAbilityContext).terminateSelf();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}
