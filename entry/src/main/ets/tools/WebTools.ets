// Web tools - fetch URLs and search
import { http } from '@kit.NetworkKit'
import { ToolRegistry } from '../services/ToolRegistry'
import { Logger } from '../utils/Logger'
import { stripHtmlTags, truncateText } from '../utils/TextFormatter'

async function webFetch(input: Record<string, Object>): Promise<string> {
  const url = input['url'] as string
  if (!url) return 'Error: url is required'

  try {
    const httpRequest = http.createHttp()
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'NanoClaw/1.0 (OpenHarmony)',
        'Accept': 'text/html,application/xhtml+xml,text/plain'
      },
      connectTimeout: 15000,
      readTimeout: 30000
    })
    httpRequest.destroy()

    if (response.responseCode !== 200) {
      return `Error: HTTP ${response.responseCode}`
    }

    const body = response.result as string
    const text = stripHtmlTags(body)
    return truncateText(text, 50000)
  } catch (e) {
    return `Error fetching URL: ${(e as Error).message}`
  }
}

async function webSearch(input: Record<string, Object>): Promise<string> {
  const query = input['query'] as string
  if (!query) return 'Error: query is required'

  // Use DuckDuckGo HTML search (no API key needed)
  try {
    const encodedQuery = encodeURIComponent(query)
    const url = `https://html.duckduckgo.com/html/?q=${encodedQuery}`

    const httpRequest = http.createHttp()
    const response = await httpRequest.request(url, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'NanoClaw/1.0 (OpenHarmony)',
        'Accept': 'text/html'
      },
      connectTimeout: 15000,
      readTimeout: 30000
    })
    httpRequest.destroy()

    if (response.responseCode !== 200) {
      return `Search error: HTTP ${response.responseCode}`
    }

    const body = response.result as string
    // Extract search results from DuckDuckGo HTML
    const results = extractDDGResults(body)

    if (results.length === 0) {
      return `No results found for: ${query}`
    }

    return `Search results for "${query}":\n\n${results.join('\n\n')}`
  } catch (e) {
    return `Search error: ${(e as Error).message}`
  }
}

function extractDDGResults(html: string): string[] {
  const results: string[] = []
  // Extract result snippets from DuckDuckGo HTML
  // Pattern: <a class="result__a" href="...">title</a> ... <a class="result__snippet">snippet</a>
  const resultBlocks = html.split('result__body')

  for (let i = 1; i < resultBlocks.length && results.length < 8; i++) {
    const block = resultBlocks[i]

    // Extract title
    const titleMatch = block.match(/result__a[^>]*href="([^"]*)"[^>]*>([^<]*)</)
    // Extract snippet
    const snippetMatch = block.match(/result__snippet[^>]*>([^<]*)/)

    if (titleMatch) {
      const url = titleMatch[1]
      const title = titleMatch[2].trim()
      const snippet = snippetMatch ? snippetMatch[1].trim() : ''
      results.push(`${results.length + 1}. ${title}\n   ${url}\n   ${snippet}`)
    }
  }

  return results
}

export function registerWebTools(registry: ToolRegistry): void {
  const fetchSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"url":{"type":"string","description":"The URL to fetch"}},"required":["url"]}')

  registry.registerTool(
    'web_fetch',
    'Fetch the content of a web page. Returns the text content with HTML tags stripped.',
    fetchSchema,
    webFetch
  )

  const searchSchema: Record<string, Object> = JSON.parse('{"type":"object","properties":{"query":{"type":"string","description":"Search query"}},"required":["query"]}')

  registry.registerTool(
    'web_search',
    'Search the web using DuckDuckGo. Returns search results with titles, URLs, and snippets.',
    searchSchema,
    webSearch
  )

  Logger.info('Web tools registered')
}
