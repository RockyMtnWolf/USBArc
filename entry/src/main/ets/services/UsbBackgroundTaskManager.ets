import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export type UsbBackgroundTaskMode = 'off' | 'download' | 'taskKeeping';

export interface UsbBackgroundTaskState {
  ok: boolean;
  selectedMode: UsbBackgroundTaskMode;
  taskActive: boolean;
  activeModes: Array<string>;
  suppressedBySystem: boolean;
  message: string;
}

const DOMAIN: number = 0x0000;
const TAG: string = 'UsbArcBackground';
const APP_BUNDLE: string = 'io.github.rockymtnwolf.usbarc';
const ENTRY_ABILITY: string = 'EntryAbility';

export class UsbBackgroundTaskManager {
  private context?: common.UIAbilityContext;
  private task?: backgroundTaskManager.ContinuousTaskNotification;
  private activeModes: Array<string> = [];
  private selectedMode: UsbBackgroundTaskMode = 'off';
  private suppressedBySystem: boolean = false;
  private stopping: boolean = false;
  private listenerRegistered: boolean = false;
  private cancellationRevision: number = 0;
  private operationQueue: Promise<void> = Promise.resolve();
  private lastMessage: string = '后台任务已关闭。';
  private lastOk: boolean = true;
  private readonly listeners: Set<(state: UsbBackgroundTaskState) => void> =
    new Set<(state: UsbBackgroundTaskState) => void>();

  private readonly cancelCallback = (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
    if (this.stopping || (this.task?.continuousTaskId !== undefined &&
      info.id !== this.task.continuousTaskId)) {
      return;
    }
    this.cancellationRevision++;
    this.task = undefined;
    this.activeModes = [];
    this.suppressedBySystem = true;
    this.lastOk = false;
    this.lastMessage = '系统已结束后台任务；USBArc不会自动抢占重启。再次手动开启任务或启动USB/IP服务后可重试。';
    hilog.info(DOMAIN, TAG, 'Background task cancelled. reason=%{public}d', info.reason);
    this.notifyState();
  };

  register(context: common.UIAbilityContext): void {
    this.context = context;
    if (this.listenerRegistered) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback);
      this.listenerRegistered = true;
    } catch (error) {
      this.lastMessage = `系统取消监听不可用，code=${(error as BusinessError).code ?? -1}`;
    }
    this.notifyState();
  }

  subscribe(listener: (state: UsbBackgroundTaskState) => void): () => void {
    this.listeners.add(listener);
    listener(this.getState());
    return (): void => { this.listeners.delete(listener); };
  }

  restoreSelection(mode: UsbBackgroundTaskMode): void {
    this.selectedMode = mode;
    if (mode !== 'off') {
      this.lastMessage = '已保存后台任务模式；本次启动尚未申请系统任务。';
    }
    this.notifyState();
  }

  async setMode(context: common.UIAbilityContext, mode: UsbBackgroundTaskMode): Promise<UsbBackgroundTaskState> {
    return this.serialize(async (): Promise<UsbBackgroundTaskState> => {
      this.context = context;
      if (mode === 'taskKeeping' && deviceInfo.deviceType !== deviceInfo.DeviceTypes.TYPE_2IN1) {
        this.lastMessage = '系统任务维持仅适用于PC/2-in-1设备。';
        this.lastOk = false;
        this.notifyState();
        return this.getState();
      }
      if (mode === 'off') {
        const stopped: boolean = await this.stopInternal(context);
        if (stopped) {
          this.selectedMode = 'off';
          this.suppressedBySystem = false;
          this.lastMessage = '后台任务已关闭。';
          this.lastOk = true;
        } else {
          this.lastOk = false;
        }
        this.notifyState();
        return this.getState();
      }
      this.suppressedBySystem = false;
      this.selectedMode = mode;
      const started: boolean = await this.startOrUpdateInternal(context, mode);
      if (!started) {
        this.lastOk = false;
        this.notifyState();
        return this.getState();
      }
      this.lastOk = true;
      this.lastMessage = mode === 'taskKeeping' ?
        '系统已确认任务维持类别。系统仍可能结束此任务。' :
        '系统已确认数据传输任务。USBArc不会下载文件或显示下载进度，系统可能因此取消任务。';
      this.notifyState();
      return this.getState();
    });
  }

  async onServerStarted(context: common.UIAbilityContext): Promise<UsbBackgroundTaskState> {
    if (this.selectedMode === 'off') {
      return this.getState();
    }
    return this.setMode(context, this.selectedMode);
  }

  async stop(context: common.UIAbilityContext): Promise<UsbBackgroundTaskState> {
    return this.serialize(async (): Promise<UsbBackgroundTaskState> => {
      this.context = context;
      if (await this.stopInternal(context)) {
        this.selectedMode = 'off';
        this.suppressedBySystem = false;
        this.lastMessage = '后台任务已关闭。';
        this.lastOk = true;
      } else {
        this.lastOk = false;
      }
      this.notifyState();
      return this.getState();
    });
  }

  getState(): UsbBackgroundTaskState {
    return {
      ok: this.lastOk,
      selectedMode: this.selectedMode,
      taskActive: this.task !== undefined,
      activeModes: this.activeModes.slice(),
      suppressedBySystem: this.suppressedBySystem,
      message: this.lastMessage
    };
  }

  async dispose(context: common.UIAbilityContext): Promise<void> {
    if (this.listenerRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback);
      } catch (_error) {
        // The system also releases process listeners when the UIAbility ends.
      }
      this.listenerRegistered = false;
    }
    await this.stop(context);
  }

  private async startOrUpdateInternal(context: common.UIAbilityContext,
    mode: UsbBackgroundTaskMode): Promise<boolean> {
    const desiredModes: Array<string> = [mode === 'taskKeeping' ? 'taskKeeping' : 'dataTransfer'];
    try {
      if (this.task !== undefined) {
        if (this.activeModes.length === desiredModes.length &&
          this.activeModes.every((item: string) => desiredModes.includes(item))) {
          return true;
        }
        const revision: number = this.cancellationRevision;
        const updated: backgroundTaskManager.ContinuousTaskNotification =
          await backgroundTaskManager.updateBackgroundRunning(context, desiredModes);
        if (revision !== this.cancellationRevision) {
          this.task = undefined;
          this.activeModes = [];
          this.lastMessage = '系统在更新期间结束了后台任务；USBArc不会自动抢占重启。';
          this.lastOk = false;
          return false;
        }
        this.task = updated;
        this.activeModes = desiredModes;
        return true;
      }
      const revision: number = this.cancellationRevision;
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: APP_BUNDLE, abilityName: ENTRY_ABILITY }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 2048,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      if (revision !== this.cancellationRevision) {
        return false;
      }
      const started: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, desiredModes, agent);
      if (revision !== this.cancellationRevision) {
        return false;
      }
      this.task = started;
      this.activeModes = desiredModes;
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.lastMessage = `系统未确认后台任务，code=${businessError.code ?? -1}`;
      this.lastOk = false;
      hilog.warn(DOMAIN, TAG, 'Background task start or update failed. code=%{public}d', businessError.code ?? -1);
      return false;
    }
  }

  private async stopInternal(context: common.UIAbilityContext): Promise<boolean> {
    if (this.task === undefined) {
      return true;
    }
    this.stopping = true;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      this.task = undefined;
      this.activeModes = [];
      return true;
    } catch (error) {
      const businessError: BusinessError = error as BusinessError;
      this.lastMessage = `系统未确认后台任务已停止，code=${businessError.code ?? -1}`;
      this.lastOk = false;
      hilog.warn(DOMAIN, TAG, 'Background task stop failed. code=%{public}d', businessError.code ?? -1);
      return false;
    } finally {
      this.stopping = false;
    }
  }

  private serialize<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.operationQueue.then(operation, operation);
    this.operationQueue = result.then((): void => {}, (): void => {});
    return result;
  }

  private notifyState(): void {
    const state: UsbBackgroundTaskState = this.getState();
    this.listeners.forEach((listener: (state: UsbBackgroundTaskState) => void): void => {
      try {
        listener(state);
      } catch (_error) {
        // State observers must not break system task transitions.
      }
    });
  }
}

export const sharedUsbBackgroundTaskManager: UsbBackgroundTaskManager = new UsbBackgroundTaskManager();
