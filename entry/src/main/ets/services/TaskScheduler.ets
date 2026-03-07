// Simplified task scheduler - ported from NanoClaw task-scheduler.ts
// Polls DB every 60s for due tasks, runs them through AgentCore
import { Logger } from '../utils/Logger'
import { computeNextRun } from '../utils/CronParser'
import { dbService } from './DatabaseService'
import { agentCore } from './AgentCore'
import { ScheduledTask } from '../models/Types'

const SCHEDULER_POLL_INTERVAL = 60000 // 60 seconds

export class TaskScheduler {
  private running: boolean = false
  private timerId: number = -1

  start(): void {
    if (this.running) return
    this.running = true
    Logger.info('TaskScheduler started')
    this.poll()
  }

  stop(): void {
    this.running = false
    if (this.timerId >= 0) {
      clearTimeout(this.timerId)
      this.timerId = -1
    }
    Logger.info('TaskScheduler stopped')
  }

  private async poll(): Promise<void> {
    if (!this.running) return

    try {
      const dueTasks = await dbService.getDueTasks()
      if (dueTasks.length > 0) {
        Logger.info(`Found ${dueTasks.length} due tasks`)
      }

      for (const task of dueTasks) {
        await this.runTask(task)
      }
    } catch (e) {
      Logger.error(`Scheduler poll error: ${(e as Error).message}`)
    }

    // Schedule next poll
    if (this.running) {
      this.timerId = setTimeout(() => this.poll(), SCHEDULER_POLL_INTERVAL)
    }
  }

  private async runTask(task: ScheduledTask): Promise<void> {
    const startTime = Date.now()
    Logger.info(`Running task: ${task.id}`)

    let result: string | null = null
    let error: string | null = null

    try {
      // Run the task prompt through the agent
      await agentCore.runAgent(task.prompt, task.chatId, (event) => {
        if (event.type === 'text') {
          result = event.content
        } else if (event.type === 'error') {
          error = event.error
        }
      })
    } catch (e) {
      error = (e as Error).message
      Logger.error(`Task ${task.id} failed: ${error}`)
    }

    const durationMs = Date.now() - startTime

    // Log the run
    await dbService.logTaskRun({
      taskId: task.id,
      runAt: new Date().toISOString(),
      durationMs,
      status: error ? 'error' : 'success',
      result,
      error
    })

    // Compute next run
    const nextRun = computeNextRun(task.scheduleType, task.scheduleValue, task.nextRun)
    const resultSummary = error ? `Error: ${error}` : (result ? result.substring(0, 200) : 'Completed')
    await dbService.updateTaskAfterRun(task.id, nextRun, resultSummary)

    Logger.info(`Task ${task.id} completed in ${durationMs}ms`)
  }
}

// Singleton
export const taskScheduler = new TaskScheduler()
