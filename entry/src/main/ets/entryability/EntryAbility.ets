import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { dbService } from '../services/DatabaseService';
import { configService } from '../services/ConfigService';
import { agentCore } from '../services/AgentCore';
import { taskScheduler } from '../services/TaskScheduler';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'KienClaw', 'Failed to set colorMode: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'KienClaw', 'NanoClaw starting...');
  }

  onDestroy(): void {
    taskScheduler.stop();
    hilog.info(DOMAIN, 'KienClaw', 'NanoClaw destroyed');
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    hilog.info(DOMAIN, 'KienClaw', 'Initializing services...');

    // Initialize services
    try {
      await dbService.init(this.context);
      await configService.init(this.context);
      await agentCore.init(this.context.filesDir);

      // Start task scheduler
      taskScheduler.start();

      hilog.info(DOMAIN, 'KienClaw', 'All services initialized');
    } catch (err) {
      hilog.error(DOMAIN, 'KienClaw', 'Service init failed: %{public}s', JSON.stringify(err));
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'KienClaw', 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'KienClaw', 'Content loaded successfully');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'KienClaw', 'Window stage destroyed');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'KienClaw', 'App in foreground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'KienClaw', 'App in background');
  }
}
