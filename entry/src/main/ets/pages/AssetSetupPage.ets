import { router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { AssetStore } from '../model/AssetStore';

interface SetupTheme {
  name: string;
  bgHover: string;
  borderSubtle: string;
  borderStrong: string;
  textPrimary: string;
  textBody: string;
  textSecondary: string;
  textTertiary: string;
  textQuaternary: string;
  accent: string;
  accentHover: string;
  accentSoft: string;
  accentBorder: string;
}

// 与 PetPage 的天空/酸橙味令牌一致；本页只取用到的字段，避免把整个页面模块引进来。
const SETUP_SKY: SetupTheme = {
  name: 'sky',
  bgHover: '#EFF4FC',
  borderSubtle: '#E6EBF3',
  borderStrong: '#D4DCE8',
  textPrimary: '#1F2329',
  textBody: '#3F454D',
  textSecondary: '#6B7280',
  textTertiary: '#9AA1AD',
  textQuaternary: '#B6BCC7',
  accent: '#6E9BF2',
  accentHover: '#5C8CE8',
  accentSoft: '#EAF2FE',
  accentBorder: '#AEC8F2'
};

const SETUP_LIME: SetupTheme = {
  name: 'lime',
  bgHover: '#FFF4EA',
  borderSubtle: '#F2E8DC',
  borderStrong: '#E4D2BC',
  textPrimary: '#1F2329',
  textBody: '#3F454D',
  textSecondary: '#6B7280',
  textTertiary: '#9AA1AD',
  textQuaternary: '#B6BCC7',
  accent: '#FF8C00',
  accentHover: '#F07D00',
  accentSoft: '#FFF0E0',
  accentBorder: '#FFB066'
};

/**
 * 首启阻断页：素材未安装时只显示这一页，安装完成后进入 PetPage。
 * 素材（Spine/语音）不随 HAP 分发，版权归鹰角网络；本页只负责下载/导入与校验。
 */
@Entry
@Component
struct AssetSetupPage {
  @State busy: boolean = false;
  @State progress: number = 0;
  @State status: string = '';
  @State error: string = '';
  @State downloadUrl: string = '';
  @State petName: string = '予愿安洁莉娜';
  @State downloadMb: string = '0';
  @State installMb: string = '0';
  @State theme: SetupTheme = SETUP_SKY;
  @State themeAnimating: boolean = false;
  private store: AssetStore | null = null;

  private mb(bytes: number): string {
    return (bytes / 1048576).toFixed(1);
  }

  private saveTheme(name: string): void {
    try {
      let prefs = preferences.getPreferencesSync(getContext(this), { name: 'pet_settings' });
      prefs.putSync('pet_theme', name);
      prefs.flush();
    } catch (e) {
    }
  }

  aboutToAppear(): void {
    let ctx = getContext(this) as common.UIAbilityContext;
    try {
      let prefs = preferences.getPreferencesSync(ctx, { name: 'pet_settings' });
      let themeName = prefs.getSync('pet_theme', 'sky') as string;
      this.theme = themeName === 'lime' ? SETUP_LIME : SETUP_SKY;
    } catch (e) {
    }
    try {
      let store = new AssetStore(ctx);
      this.store = store;
      this.petName = store.manifest.pet_name;
      this.downloadMb = this.mb(store.manifest.size);
      this.installMb = this.mb(store.manifest.uncompressed_size);
      let override: string | undefined = AppStorage.get<string>('assetUrlOverride');
      this.downloadUrl = (override !== undefined && override.length > 0) ? override : store.manifest.url;
    } catch (e) {
      let err = e as BusinessError;
      this.error = '素材清单读取失败：' + err.message;
    }
  }

  onBackPress(): boolean {
    return this.busy;
  }

  private enterPet(): void {
    this.status = '安装完成，正在进入桌宠…';
    router.replaceUrl({ url: 'pages/PetPage' }).catch((err: BusinessError) => {
      this.error = '进入桌宠失败：' + err.message;
      this.busy = false;
    });
  }

  private async startDownload(): Promise<void> {
    if (this.busy || this.store === null) {
      return;
    }
    this.busy = true;
    this.progress = 0;
    this.error = '';
    this.status = '正在连接下载源…';
    let ctx = getContext(this) as common.UIAbilityContext;
    let dest = ctx.cacheDir + '/asset_download.zip';
    try {
      await this.store.download(this.downloadUrl, dest, (done: number, total: number) => {
        this.progress = total > 0 ? done / total : 0;
        this.status = '正在下载… ' + this.mb(done) + ' / ' + this.mb(total) + ' MB';
      });
      this.status = '正在校验并安装…';
      await this.store.installFromZip(dest, true, (percent: number) => {
        this.progress = percent / 100;
      });
      try {
        if (fs.accessSync(dest)) {
          fs.unlinkSync(dest);
        }
      } catch (e) {
      }
      this.enterPet();
    } catch (e) {
      let msg = (e as Error).message;
      if (msg === '已取消下载') {
        this.status = '已取消下载。';
      } else {
        this.error = msg;
        this.status = '';
      }
      this.busy = false;
      try {
        if (fs.accessSync(dest)) {
          fs.unlinkSync(dest);
        }
      } catch (e2) {
      }
    }
  }

  private cancelDownload(): void {
    if (this.store !== null) {
      this.status = '正在取消…';
      this.store.cancelDownload();
    }
  }

  private async importZip(): Promise<void> {
    if (this.busy || this.store === null) {
      return;
    }
    try {
      let documentPicker = new picker.DocumentViewPicker(getContext(this));
      let options: picker.DocumentSelectOptions = {
        maxSelectNumber: 1,
        fileSuffixFilters: ['.zip']
      };
      let uris = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      this.busy = true;
      this.progress = 0;
      this.error = '';
      this.status = '正在读取 zip…';
      let ctx = getContext(this) as common.UIAbilityContext;
      let dest = ctx.cacheDir + '/manual_asset.zip';
      let src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(src.fd, dest);
      } finally {
        fs.closeSync(src);
      }
      this.status = '正在校验并安装…';
      await this.store.installFromZip(dest, true, (percent: number) => {
        this.progress = percent / 100;
      });
      try {
        if (fs.accessSync(dest)) {
          fs.unlinkSync(dest);
        }
      } catch (e) {
      }
      this.enterPet();
    } catch (e) {
      let err = e as BusinessError;
      this.error = err.message;
      this.status = '';
      this.busy = false;
    }
  }

  @Builder
  themePill(label: string, option: SetupTheme) {
    Row({ space: 6 }) {
      Column()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(option.accent)
      Text(label)
        .fontSize(11)
        .fontColor(this.theme.name === option.name ? this.theme.textPrimary : this.theme.textTertiary)
    }
    .padding({ left: 9, right: 10, top: 5, bottom: 5 })
    .backgroundColor(this.theme.name === option.name ? this.theme.bgHover : '#00000000')
    .border({ width: this.theme.name === option.name ? 1 : 0, color: this.theme.borderSubtle })
    .borderRadius(12)
    .onClick(() => {
      if (this.themeAnimating || this.busy || this.theme.name === option.name) {
        return;
      }
      this.themeAnimating = true;
      this.saveTheme(option.name);
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
        this.theme = option;
      });
      setTimeout(() => {
        this.themeAnimating = false;
      }, 320);
    })
  }

  build() {
    Scroll() {
      Column() {
        Column() {
          // ── 品牌条：应用图标 + 名字 + 这套素材包含什么 ──
          Row({ space: 16 }) {
            Image($r('app.media.startIcon'))
              .width(64)
              .height(64)
              .borderRadius(16)
              .objectFit(ImageFit.Cover)
            Column({ space: 4 }) {
              Text('酸橙味的信')
                .fontSize(22)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.textPrimary)
              Text(this.petName + ' · 角色素材')
                .fontSize(12)
                .fontColor(this.theme.textSecondary)
              Text('Spine 动画 · 中文/日文语音 · 技能图标')
                .fontSize(11)
                .fontColor(this.theme.textTertiary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 28, right: 28, top: 22, bottom: 22 })
          .backgroundColor(this.theme.accentSoft)

          // ── 内容区 ──
          Column({ space: 14 }) {
            Row({ space: 8 }) {
              Text('界面主题')
                .fontSize(11)
                .fontColor(this.theme.textTertiary)
              Blank()
              this.themePill('天空', SETUP_SKY)
              this.themePill('酸橙味', SETUP_LIME)
            }
            .width('100%')

            Text('给安洁莉娜写封信，\n她会来到你身边的。')
              .fontSize(26)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.textPrimary)
              .width('100%')
            Text('Spine 模型、语音与角色图标不随应用分发。下载一次，之后就能正常陪在你身边。')
              .fontSize(14)
              .fontColor(this.theme.textBody)
              .lineHeight(22)
              .width('100%')

            Row() {
              Column({ space: 2 }) {
                Text('下载')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                Text(this.downloadMb + ' MB')
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.theme.textPrimary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Divider()
                .vertical(true)
                .height(32)
                .color(this.theme.borderSubtle)
              Column({ space: 2 }) {
                Text('安装后')
                  .fontSize(11)
                  .fontColor(this.theme.textTertiary)
                Text(this.installMb + ' MB')
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.theme.textPrimary)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 20 })
            }
            .width('100%')
            .padding(14)
            .backgroundColor(this.theme.bgHover)
            .borderRadius(10)

            Text('来源：GitHub Releases（官方素材库） · 整包 SHA-256 校验')
              .fontSize(11)
              .fontColor(this.theme.textTertiary)
              .width('100%')

            if (this.busy) {
              Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
                .color(this.theme.accent)
                .backgroundColor(this.theme.accentSoft)
                .width('100%')
                .height(6)
              Text(this.status)
                .fontSize(13)
                .fontColor(this.theme.textSecondary)
                .width('100%')
              Row() {
                Blank()
                Text('取消下载')
                  .fontSize(13)
                  .fontColor(this.theme.textTertiary)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.cancelDownload();
                  })
              }
              .width('100%')
            }

            if (this.error.length > 0) {
              Column() {
                Text('安装失败：' + this.error)
                  .fontSize(13)
                  .fontColor('#B3261E')
                  .lineHeight(19)
                  .width('100%')
              }
              .width('100%')
              .padding(10)
              .backgroundColor('#FFF1F0')
              .border({ width: 1, color: '#FAD2CF' })
              .borderRadius(8)
            }

            Button('下载并安装')
              .onClick(() => {
                this.startDownload();
              })
              .enabled(!this.busy)
              .width('100%')
              .height(48)
              .fontSize(16)
              .fontColor('#FFFFFF')
              .backgroundColor(this.theme.accent)
              .borderRadius(10)

            Button('手动导入官方 zip')
              .onClick(() => {
                this.importZip();
              })
              .enabled(!this.busy)
              .width('100%')
              .height(44)
              .fontSize(14)
              .fontColor(this.theme.textBody)
              .backgroundColor('#FFFFFF')
              .border({ width: 1, color: this.theme.borderStrong })
              .borderRadius(10)

            Text('手动导入同样校验整包 SHA-256；不是官方包会被拒绝')
              .fontSize(11)
              .fontColor(this.theme.textTertiary)
              .width('100%')

            Row() {
              Blank()
              Text('退出')
                .fontSize(13)
                .fontColor(this.theme.textTertiary)
                .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                .onClick(() => {
                  if (!this.busy) {
                    (getContext(this) as common.UIAbilityContext).terminateSelf();
                  }
                })
            }
            .width('100%')

            Text('素材版权归上海鹰角网络有限公司所有 · 仅供个人非商业使用')
              .fontSize(11)
              .fontColor(this.theme.textQuaternary)
              .lineHeight(16)
              .width('100%')
          }
          .width('100%')
          .padding({ left: 28, right: 28, top: 24, bottom: 22 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('92%')
        .constraintSize({ maxWidth: 680 })
        .backgroundColor('#FFFFFF')
        .borderRadius(24)
        .clip(true)
        .border({ width: 1, color: this.theme.borderSubtle })
        .shadow({ radius: 24, color: '#14000000', offsetX: 0, offsetY: 10 })
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 24, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bgHover)
    .scrollBar(BarState.Off)
  }
}
