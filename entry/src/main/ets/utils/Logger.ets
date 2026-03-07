// Thin wrapper around hilog
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000
const TAG = 'NanoClaw'

export class Logger {
  static debug(msg: string): void {
    hilog.debug(DOMAIN, TAG, msg)
  }

  static info(msg: string): void {
    hilog.info(DOMAIN, TAG, msg)
  }

  static warn(msg: string): void {
    hilog.warn(DOMAIN, TAG, msg)
  }

  static error(msg: string): void {
    hilog.error(DOMAIN, TAG, msg)
  }
}
