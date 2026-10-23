/** Builds a user-facing claim error while keeping the SDK result visible. */
export function describeUsbManagerClaimFailure(interfaceId: number, sdkCode: number,
  interfaceClass: number, forceClaim: boolean): string {
  if (interfaceClass === 8 && sdkCode === -1 && !forceClaim) {
    return `存储接口 ${interfaceId} 占用失败（USB SDK -1：驱动异常）。设备可能仍被本机挂载，请先安全弹出卷后重试；需要强制接管时请在设置中手动开启。`;
  }
  return `USB interface ${interfaceId} claim failed (USB SDK code ${sdkCode})`;
}
