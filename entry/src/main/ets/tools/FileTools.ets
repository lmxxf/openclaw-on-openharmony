// File system tools for the agent
// Restricted to app sandbox (context.filesDir)
import { fileIo } from '@kit.CoreFileKit'
import { ToolRegistry } from '../services/ToolRegistry'
import { Logger } from '../utils/Logger'

let basePath: string = ''

export function initFileTools(filesDir: string): void {
  basePath = filesDir
}

function resolvePath(path: string): string {
  // Security: prevent path traversal
  const normalized = path.replace(/\.\.\//g, '').replace(/\.\./g, '')
  if (normalized.startsWith('/')) {
    return `${basePath}${normalized}`
  }
  return `${basePath}/${normalized}`
}

async function fileRead(input: Record<string, Object>): Promise<string> {
  const path = input['path'] as string
  if (!path) return 'Error: path is required'

  const fullPath = resolvePath(path)
  try {
    const stat = fileIo.statSync(fullPath)
    if (stat.isDirectory()) {
      return `Error: ${path} is a directory, use file_list instead`
    }
    const content = fileIo.readTextSync(fullPath)
    return content
  } catch (e) {
    return `Error reading file: ${(e as Error).message}`
  }
}

async function fileWrite(input: Record<string, Object>): Promise<string> {
  const path = input['path'] as string
  const content = input['content'] as string
  if (!path) return 'Error: path is required'
  if (content === undefined || content === null) return 'Error: content is required'

  const fullPath = resolvePath(path)
  try {
    // Ensure parent directory exists
    const lastSlash = fullPath.lastIndexOf('/')
    if (lastSlash > 0) {
      const dir = fullPath.substring(0, lastSlash)
      try {
        fileIo.mkdirSync(dir, true)
      } catch (_e) {
        // directory may already exist
      }
    }

    const file = fileIo.openSync(fullPath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
    fileIo.writeSync(file.fd, content)
    fileIo.closeSync(file)

    return `File written: ${path} (${content.length} bytes)`
  } catch (e) {
    return `Error writing file: ${(e as Error).message}`
  }
}

async function fileList(input: Record<string, Object>): Promise<string> {
  const directory = (input['directory'] as string) || '/'

  const fullPath = resolvePath(directory)
  try {
    const entries = fileIo.listFileSync(fullPath)
    if (entries.length === 0) {
      return `Directory ${directory} is empty`
    }

    const lines: string[] = []
    for (const entry of entries) {
      const entryPath = `${fullPath}/${entry}`
      try {
        const stat = fileIo.statSync(entryPath)
        const type = stat.isDirectory() ? 'DIR' : 'FILE'
        const size = stat.isDirectory() ? '' : ` (${stat.size} bytes)`
        lines.push(`  ${type}  ${entry}${size}`)
      } catch (_e) {
        lines.push(`  ???  ${entry}`)
      }
    }
    return `Contents of ${directory}:\n${lines.join('\n')}`
  } catch (e) {
    return `Error listing directory: ${(e as Error).message}`
  }
}

export function registerFileTools(registry: ToolRegistry): void {
  const fileReadSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"path":{"type":"string","description":"File path relative to app sandbox root"}},"required":["path"]}')

  registry.registerTool(
    'file_read',
    'Read the contents of a file from the app sandbox. Returns the text content.',
    fileReadSchema,
    fileRead
  )

  const fileWriteSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"path":{"type":"string","description":"File path relative to app sandbox root"},"content":{"type":"string","description":"Content to write"}},"required":["path","content"]}')

  registry.registerTool(
    'file_write',
    'Write content to a file in the app sandbox. Creates parent directories if needed.',
    fileWriteSchema,
    fileWrite
  )

  const fileListSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"directory":{"type":"string","description":"Directory path relative to sandbox root. Default: /"}}}')

  registry.registerTool(
    'file_list',
    'List files and directories in the app sandbox.',
    fileListSchema,
    fileList
  )

  Logger.info('File tools registered')
}
