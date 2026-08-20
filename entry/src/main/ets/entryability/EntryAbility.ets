import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { settings } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;
const TAG = 'AngelinaPet';

export default class EntryAbility extends UIAbility {
  private isLandscapeNow = false; // 当前窗口方向（windowSizeChange 跟踪）
  private rotationPollId = -1; // 旋转锁定状态轮询兜底（观察者在部分机型不可靠）
  private appliedLockState = -1; // 已应用的锁定状态（-1=未知 0=锁定 1=解锁；幂等去重）

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  onDestroy(): void {
    if (this.rotationPollId >= 0) {
      clearInterval(this.rotationPollId);
      this.rotationPollId = -1;
    }
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/PetPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load PetPage: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'PetPage loaded');
      this.applyTransparency(windowStage);
      const mainWindow = windowStage.getMainWindowSync();
      // 全屏沉浸：布局延伸至状态栏/导航栏下，并隐藏两栏（平板上下白边/手机底部黑边的根因）
      try {
        mainWindow.setWindowLayoutFullScreen(true)
        mainWindow.setSpecificSystemBarEnabled('status', false)
        mainWindow.setSpecificSystemBarEnabled('navigation', false)
        hilog.info(DOMAIN, TAG, 'Fullscreen applied')
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'Fullscreen apply failed: %{public}s', JSON.stringify(e))
      }
      // 横屏悬浮窗：让自由多窗保持横屏形状
      mainWindow.enableLandscapeMultiWindow().then(() => {
        hilog.info(DOMAIN, TAG, 'Landscape multi window enabled');
      }).catch((e: Error) => {
        hilog.error(DOMAIN, TAG, 'enableLandscapeMultiWindow failed: %{public}s', JSON.stringify(e));
      });
      // 旋转锁定（用户定案）：跟随系统旋转锁定，锁定瞬间冻结在当前方向（不被拽回竖屏）。
      // 双 domain 注册观察者（键所属 domain 不确定，谁触发都行；applyRotationLock 幂等）
      try {
        const rect = mainWindow.getWindowProperties().windowRect;
        this.isLandscapeNow = rect.width > rect.height;
        const register = (domain: string): void => {
          settings.registerKeyObserver(this.context, settings.general.ACCELEROMETER_ROTATION_STATUS,
            domain, (err: Error) => {
              if (!err) {
                this.applyRotationLock(windowStage);
              }
            });
        };
        register(settings.domainName.USER_PROPERTY);
        register(settings.domainName.DEVICE_SHARED);
        this.applyRotationLock(windowStage);
        // 轮询兜底：观察者不可靠的机型上，锁/解锁状态最多 1.5s 内收敛（幂等，无副作用）
        this.rotationPollId = setInterval(() => {
          this.applyRotationLock(windowStage);
        }, 1500);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'rotation observer setup failed: %{public}s', JSON.stringify(e));
      }
      // 窗口尺寸变化：未锁定=跟踪当前方向；锁定期间被系统强制旋转时拉回冻结方向（观察者未触发的兜底）
      mainWindow.on('windowSizeChange', (size: window.Size) => {
        try {
          const status = parseInt(settings.getValueSync(this.context,
            settings.general.ACCELEROMETER_ROTATION_STATUS, '1'));
          if (status === 1) {
            this.isLandscapeNow = size.width > size.height;
          } else {
            const forcedLandscape = size.width > size.height;
            if (forcedLandscape !== this.isLandscapeNow) {
              this.applyRotationLock(windowStage);
            }
          }
        } catch (e) {
          this.isLandscapeNow = size.width > size.height;
        }
        this.applyTransparency(windowStage);
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }

  private applyTransparency(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor('#00000000');
      hilog.info(DOMAIN, TAG, 'Transparency applied');
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyTransparency failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 系统旋转锁定状态（1=自动旋转，0=锁定）→ 窗口方向：锁定=冻结当前方向，解锁=跟随传感器。幂等。 */
  private applyRotationLock(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      const status = parseInt(settings.getValueSync(this.context,
        settings.general.ACCELEROMETER_ROTATION_STATUS, '1'));
      if (status === 0) {
        if (this.appliedLockState !== 0) {
          mainWindow.setPreferredOrientation(
            this.isLandscapeNow ? window.Orientation.LANDSCAPE : window.Orientation.PORTRAIT);
          this.appliedLockState = 0;
          hilog.info(DOMAIN, TAG, 'Rotation locked: %{public}s', this.isLandscapeNow ? 'landscape' : 'portrait');
        }
      } else {
        if (this.appliedLockState !== 1) {
          mainWindow.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
          this.appliedLockState = 1;
          hilog.info(DOMAIN, TAG, 'Rotation unlocked: follow sensor');
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'applyRotationLock failed: %{public}s', JSON.stringify(e));
    }
  }
}
