// Memory tools - read/write persistent markdown notes
import { fileIo } from '@kit.CoreFileKit'
import { ToolRegistry } from '../services/ToolRegistry'
import { Logger } from '../utils/Logger'

let memoryDir: string = ''

export function initMemoryTools(filesDir: string): void {
  memoryDir = `${filesDir}/memory`
  try {
    fileIo.mkdirSync(memoryDir, true)
  } catch (_e) {
    // already exists
  }
}

async function memoryRead(input: Record<string, Object>): Promise<string> {
  const name = input['name'] as string
  if (!name) return 'Error: name is required'

  const safeName = name.replace(/[^a-zA-Z0-9_-]/g, '_')
  const path = `${memoryDir}/${safeName}.md`

  try {
    const content = fileIo.readTextSync(path)
    return content
  } catch (_e) {
    return `Memory "${name}" not found`
  }
}

async function memoryWrite(input: Record<string, Object>): Promise<string> {
  const name = input['name'] as string
  const content = input['content'] as string
  if (!name) return 'Error: name is required'
  if (!content) return 'Error: content is required'

  const safeName = name.replace(/[^a-zA-Z0-9_-]/g, '_')
  const path = `${memoryDir}/${safeName}.md`

  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    fileIo.writeSync(file.fd, content)
    fileIo.closeSync(file)
    return `Memory "${name}" saved (${content.length} bytes)`
  } catch (e) {
    return `Error saving memory: ${(e as Error).message}`
  }
}

async function memoryList(_input: Record<string, Object>): Promise<string> {
  try {
    const entries = fileIo.listFileSync(memoryDir)
    const mdFiles = entries.filter(e => e.endsWith('.md'))

    if (mdFiles.length === 0) {
      return 'No memory files found'
    }

    const lines = mdFiles.map(f => {
      const name = f.replace('.md', '')
      try {
        const stat = fileIo.statSync(`${memoryDir}/${f}`)
        return `  - ${name} (${stat.size} bytes)`
      } catch (_e) {
        return `  - ${name}`
      }
    })

    return `Memory files:\n${lines.join('\n')}`
  } catch (_e) {
    return 'No memory files found'
  }
}

export function registerMemoryTools(registry: ToolRegistry): void {
  registry.registerTool(
    'memory_read',
    'Read a persistent memory note by name. Memory files are markdown documents that persist across conversations.',
    {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Memory name (without .md extension)' }
      },
      required: ['name']
    } as Record<string, Object>,
    memoryRead
  )

  registry.registerTool(
    'memory_write',
    'Write or update a persistent memory note. Use this to remember important information across conversations.',
    {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'Memory name (without .md extension)' },
        content: { type: 'string', description: 'Markdown content to save' }
      },
      required: ['name', 'content']
    } as Record<string, Object>,
    memoryWrite
  )

  registry.registerTool(
    'memory_list',
    'List all saved memory files.',
    {
      type: 'object',
      properties: {}
    } as Record<string, Object>,
    memoryList
  )

  Logger.info('Memory tools registered')
}
