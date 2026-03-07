// Scheduled task management tools
// Ported from NanoClaw ipc-mcp-stdio.ts
import { ToolRegistry } from '../services/ToolRegistry'
import { dbService } from '../services/DatabaseService'
import { Logger } from '../utils/Logger'
import { generateId } from '../utils/TextFormatter'
import { computeNextRun, getNextCronTime } from '../utils/CronParser'
import { ScheduledTask } from '../models/Types'

let defaultChatId: string = 'default'

export function setTaskChatId(chatId: string): void {
  defaultChatId = chatId
}

async function scheduleTask(input: Record<string, Object>): Promise<string> {
  const prompt = input['prompt'] as string
  const scheduleType = input['schedule_type'] as string
  const scheduleValue = input['schedule_value'] as string

  if (!prompt) return 'Error: prompt is required'
  if (!scheduleType) return 'Error: schedule_type is required (cron, interval, or once)'
  if (!scheduleValue) return 'Error: schedule_value is required'

  if (scheduleType !== 'cron' && scheduleType !== 'interval' && scheduleType !== 'once') {
    return 'Error: schedule_type must be cron, interval, or once'
  }

  // Validate cron expression
  if (scheduleType === 'cron') {
    try {
      getNextCronTime(scheduleValue, new Date())
    } catch (e) {
      return `Error: invalid cron expression "${scheduleValue}": ${(e as Error).message}`
    }
  }

  // Validate interval
  if (scheduleType === 'interval') {
    const ms = parseInt(scheduleValue)
    if (!ms || ms <= 0) {
      return `Error: interval must be a positive number of milliseconds, got "${scheduleValue}"`
    }
  }

  const id = generateId()
  const now = new Date().toISOString()
  const nextRun = computeNextRun(scheduleType, scheduleValue, null)

  const task: ScheduledTask = {
    id,
    chatId: defaultChatId,
    prompt,
    scheduleType: scheduleType as ('cron' | 'interval' | 'once'),
    scheduleValue,
    nextRun,
    lastRun: null,
    lastResult: null,
    status: 'active',
    createdAt: now
  }

  await dbService.createTask(task)
  Logger.info(`Task created: ${id} (${scheduleType}: ${scheduleValue})`)

  return `Task scheduled (id: ${id})\n  Type: ${scheduleType}\n  Value: ${scheduleValue}\n  Next run: ${nextRun}\n  Prompt: ${prompt.substring(0, 100)}`
}

async function listTasks(_input: Record<string, Object>): Promise<string> {
  const tasks = await dbService.getAllTasks()

  if (tasks.length === 0) {
    return 'No scheduled tasks'
  }

  const lines = tasks.map(t => {
    return `- [${t.status}] ${t.id}\n  ${t.scheduleType}: ${t.scheduleValue}\n  Next: ${t.nextRun || 'N/A'}\n  Prompt: ${t.prompt.substring(0, 80)}`
  })

  return `Scheduled tasks (${tasks.length}):\n\n${lines.join('\n\n')}`
}

async function pauseTask(input: Record<string, Object>): Promise<string> {
  const taskId = input['task_id'] as string
  if (!taskId) return 'Error: task_id is required'

  const task = await dbService.getTaskById(taskId)
  if (!task) return `Error: task ${taskId} not found`

  await dbService.updateTaskStatus(taskId, 'paused')
  return `Task ${taskId} paused`
}

async function resumeTask(input: Record<string, Object>): Promise<string> {
  const taskId = input['task_id'] as string
  if (!taskId) return 'Error: task_id is required'

  const task = await dbService.getTaskById(taskId)
  if (!task) return `Error: task ${taskId} not found`

  await dbService.updateTaskStatus(taskId, 'active')
  return `Task ${taskId} resumed`
}

async function cancelTask(input: Record<string, Object>): Promise<string> {
  const taskId = input['task_id'] as string
  if (!taskId) return 'Error: task_id is required'

  const task = await dbService.getTaskById(taskId)
  if (!task) return `Error: task ${taskId} not found`

  await dbService.deleteTask(taskId)
  return `Task ${taskId} cancelled and deleted`
}

export function registerTaskTools(registry: ToolRegistry): void {
  const scheduleSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"prompt":{"type":"string","description":"The prompt to execute when the task runs"},"schedule_type":{"type":"string","enum":["cron","interval","once"],"description":"Type: cron (cron expression), interval (milliseconds), once (ISO datetime)"},"schedule_value":{"type":"string","description":"For cron: 0 9 * * * (9 AM daily). For interval: 3600000 (1 hour in ms). For once: ISO datetime string."}},"required":["prompt","schedule_type","schedule_value"]}')

  registry.registerTool(
    'schedule_task',
    'Schedule a recurring or one-time task. The task will run the given prompt at the specified schedule.',
    scheduleSchema,
    scheduleTask
  )

  const listSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{}}')

  registry.registerTool(
    'list_tasks',
    'List all scheduled tasks with their status, schedule, and next run time.',
    listSchema,
    listTasks
  )

  const pauseSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"task_id":{"type":"string","description":"The task ID to pause"}},"required":["task_id"]}')

  registry.registerTool(
    'pause_task',
    'Pause a scheduled task. It will not run until resumed.',
    pauseSchema,
    pauseTask
  )

  const resumeSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"task_id":{"type":"string","description":"The task ID to resume"}},"required":["task_id"]}')

  registry.registerTool(
    'resume_task',
    'Resume a paused task.',
    resumeSchema,
    resumeTask
  )

  const cancelSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"task_id":{"type":"string","description":"The task ID to cancel"}},"required":["task_id"]}')

  registry.registerTool(
    'cancel_task',
    'Cancel and delete a scheduled task permanently.',
    cancelSchema,
    cancelTask
  )

  Logger.info('Task tools registered')
}
