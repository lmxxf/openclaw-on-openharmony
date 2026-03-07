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

const DEFAULT_BASE_URL = 'https://api.deepseek.com/v1'
const DEFAULT_MODEL = 'deepseek-chat'
const DEFAULT_MAX_TOKENS = 8192
const DEFAULT_TEMPERATURE = 0.7
const DEFAULT_ASSISTANT_NAME = 'Andy'

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
    const val = await this.pref!.get(KEY_API_KEY, '')
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
}

// Singleton
export const configService = new ConfigService()
