// App configuration via @ohos.data.preferences
import { preferences } from '@kit.ArkData'
import { common } from '@kit.AbilityKit'
import { Logger } from '../utils/Logger'

const PREF_NAME = 'nanoclaw_config'

const KEY_API_KEY = 'api_key'
const KEY_BASE_URL = 'base_url'
const KEY_MODEL = 'model'
const KEY_MAX_TOKENS = 'max_tokens'
const KEY_TEMPERATURE = 'temperature'
const KEY_ASSISTANT_NAME = 'assistant_name'
const KEY_SILICONFLOW_API_KEY = 'siliconflow_api_key'
const KEY_SILICONFLOW_API_URL = 'siliconflow_api_url'
const KEY_EMBEDDING_MODEL = 'embedding_model'
const KEY_MCP_SERVERS = 'mcp_servers'

const DEFAULT_API_KEY = ''
const DEFAULT_BASE_URL = 'https://api.deepseek.com/v1'
const DEFAULT_MODEL = 'deepseek-chat'
const DEFAULT_MAX_TOKENS = 8192
const DEFAULT_TEMPERATURE = 0.7
const DEFAULT_ASSISTANT_NAME = 'Andy'
const DEFAULT_SILICONFLOW_API_KEY = 'sk-pznryirahmchscwxodgwxhrhhyyumzsodtkfgdhgzqenyzlp'
const DEFAULT_SILICONFLOW_API_URL = 'https://api.siliconflow.cn/v1/embeddings'
const DEFAULT_EMBEDDING_MODEL = 'BAAI/bge-m3'
const DEFAULT_MCP_SERVERS = '[{"name":"高德地图","url":"https://mcp.amap.com/mcp?key=4229156b6896fd12fd1629d7e4e79861"}]'

export class ConfigService {
  private pref: preferences.Preferences | null = null

  async init(context: common.UIAbilityContext): Promise<void> {
    this.pref = await preferences.getPreferences(context, PREF_NAME)
    Logger.info('ConfigService initialized')
  }

  async saveApiKey(key: string): Promise<void> {
    await this.pref!.put(KEY_API_KEY, key)
    await this.pref!.flush()
  }

  async getApiKey(): Promise<string> {
    const val = await this.pref!.get(KEY_API_KEY, DEFAULT_API_KEY)
    return val as string
  }

  async getBaseUrl(): Promise<string> {
    const val = await this.pref!.get(KEY_BASE_URL, DEFAULT_BASE_URL)
    return val as string
  }

  async setBaseUrl(url: string): Promise<void> {
    await this.pref!.put(KEY_BASE_URL, url)
    await this.pref!.flush()
  }

  async getModel(): Promise<string> {
    const val = await this.pref!.get(KEY_MODEL, DEFAULT_MODEL)
    return val as string
  }

  async setModel(model: string): Promise<void> {
    await this.pref!.put(KEY_MODEL, model)
    await this.pref!.flush()
  }

  async getMaxTokens(): Promise<number> {
    const val = await this.pref!.get(KEY_MAX_TOKENS, DEFAULT_MAX_TOKENS)
    return val as number
  }

  async getTemperature(): Promise<number> {
    const val = await this.pref!.get(KEY_TEMPERATURE, DEFAULT_TEMPERATURE)
    return val as number
  }

  async getAssistantName(): Promise<string> {
    const val = await this.pref!.get(KEY_ASSISTANT_NAME, DEFAULT_ASSISTANT_NAME)
    return val as string
  }

  async hasApiKey(): Promise<boolean> {
    const key = await this.getApiKey()
    return key.length > 0
  }

  // --- SiliconFlow / RAG ---

  async getSiliconFlowApiKey(): Promise<string> {
    const val = await this.pref!.get(KEY_SILICONFLOW_API_KEY, DEFAULT_SILICONFLOW_API_KEY)
    return val as string
  }

  async setSiliconFlowApiKey(key: string): Promise<void> {
    await this.pref!.put(KEY_SILICONFLOW_API_KEY, key)
    await this.pref!.flush()
  }

  async getSiliconFlowApiUrl(): Promise<string> {
    const val = await this.pref!.get(KEY_SILICONFLOW_API_URL, DEFAULT_SILICONFLOW_API_URL)
    return val as string
  }

  async setSiliconFlowApiUrl(url: string): Promise<void> {
    await this.pref!.put(KEY_SILICONFLOW_API_URL, url)
    await this.pref!.flush()
  }

  async getEmbeddingModel(): Promise<string> {
    const val = await this.pref!.get(KEY_EMBEDDING_MODEL, DEFAULT_EMBEDDING_MODEL)
    return val as string
  }

  async setEmbeddingModel(model: string): Promise<void> {
    await this.pref!.put(KEY_EMBEDDING_MODEL, model)
    await this.pref!.flush()
  }

  // --- MCP Servers ---

  async getMcpServers(): Promise<string> {
    // Stored as JSON string: [{"name":"xxx","url":"xxx"}, ...]
    const val = await this.pref!.get(KEY_MCP_SERVERS, DEFAULT_MCP_SERVERS)
    return val as string
  }

  async setMcpServers(json: string): Promise<void> {
    await this.pref!.put(KEY_MCP_SERVERS, json)
    await this.pref!.flush()
  }
}

// Singleton
export const configService = new ConfigService()
