// Settings page - API key, model, base URL, MCP, RAG configuration
import { router } from '@kit.ArkUI'
import { configService } from '../services/ConfigService'
import { ApiClient } from '../services/ApiClient'
import { ApiConfig, ApiMessage } from '../models/Types'

@Entry
@Component
struct SettingsPage {
  @State apiKey: string = ''
  @State baseUrl: string = 'https://api.deepseek.com/v1'
  @State model: string = 'deepseek-chat'
  @State siliconFlowApiKey: string = ''
  @State mcpServerUrl: string = ''
  @State mcpServerName: string = ''
  @State statusMessage: string = ''
  @State isTesting: boolean = false
  @State isSaving: boolean = false

  async aboutToAppear(): Promise<void> {
    this.apiKey = await configService.getApiKey()
    this.baseUrl = await configService.getBaseUrl()
    this.model = await configService.getModel()
    this.siliconFlowApiKey = await configService.getSiliconFlowApiKey()

    // Load first MCP server if exists
    const mcpJson = await configService.getMcpServers()
    try {
      const servers = JSON.parse(mcpJson) as McpServerEntry[]
      if (servers.length > 0) {
        this.mcpServerName = servers[0].name
        this.mcpServerUrl = servers[0].url
      }
    } catch (e) {
      // ignore
    }
  }

  async saveSettings(): Promise<void> {
    this.isSaving = true
    await configService.saveApiKey(this.apiKey)
    await configService.setBaseUrl(this.baseUrl)
    await configService.setModel(this.model)
    await configService.setSiliconFlowApiKey(this.siliconFlowApiKey)

    // Save MCP servers
    if (this.mcpServerUrl.length > 0) {
      const name = this.mcpServerName.length > 0 ? this.mcpServerName : 'MCP Server'
      const servers: McpServerEntry[] = [{ name, url: this.mcpServerUrl }]
      await configService.setMcpServers(JSON.stringify(servers))
    } else {
      await configService.setMcpServers('[]')
    }

    this.statusMessage = 'Settings saved! Restart app for MCP/RAG changes to take effect.'
    this.isSaving = false
    setTimeout(() => {
      router.back({ url: 'pages/Index' })
    }, 800)
  }

  async testConnection(): Promise<void> {
    if (!this.apiKey) {
      this.statusMessage = 'Please enter an API key first'
      return
    }

    this.isTesting = true
    this.statusMessage = 'Testing connection...'

    try {
      const config: ApiConfig = {
        apiKey: this.apiKey,
        baseUrl: this.baseUrl,
        model: this.model,
        maxTokens: 50,
        temperature: 0.7
      }

      const client = new ApiClient(config)
      const testMsg: ApiMessage = { role: 'user', content: 'Say "hello" in one word.' }
      const messages: ApiMessage[] = [testMsg]
      const response = await client.sendMessage(messages)
      const reply = response.choices[0].message.content || '(empty)'
      this.statusMessage = `Connection OK! Response: "${reply}" (${response.usage.totalTokens} tokens)`
    } catch (e) {
      this.statusMessage = `Connection failed: ${(e as Error).message}`
    }

    this.isTesting = false
  }

  build() {
    Column() {
      // Title bar
      Row() {
        Button('< Back')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor('#FFFFFF')
          .onClick(() => {
            router.back({ url: 'pages/Index' })
          })

        Text('Settings')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Text('')
          .width(60)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 12, bottom: 12 })
      .backgroundColor('#1a1a2e')

      // Settings form
      Scroll() {
        Column() {
          // === LLM Section ===
          Text('LLM Configuration')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ top: 20, bottom: 4 })
            .width('100%')

          // API Key
          Text('API Key')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 12, bottom: 8 })
            .width('100%')

          TextInput({ text: this.apiKey, placeholder: 'sk-...' })
            .type(InputType.Password)
            .height(44)
            .width('100%')
            .borderRadius(8)
            .backgroundColor('#F0F0F0')
            .onChange((value: string) => {
              this.apiKey = value
            })

          // Base URL
          Text('API Base URL')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 12, bottom: 8 })
            .width('100%')

          TextInput({ text: this.baseUrl, placeholder: 'https://api.deepseek.com/v1' })
            .height(44)
            .width('100%')
            .borderRadius(8)
            .backgroundColor('#F0F0F0')
            .onChange((value: string) => {
              this.baseUrl = value
            })

          // Model
          Text('Model')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 12, bottom: 8 })
            .width('100%')

          TextInput({ text: this.model, placeholder: 'deepseek-chat' })
            .height(44)
            .width('100%')
            .borderRadius(8)
            .backgroundColor('#F0F0F0')
            .onChange((value: string) => {
              this.model = value
            })

          // Test + Save buttons
          Row() {
            Button('Test Connection')
              .fontSize(14)
              .backgroundColor('#666666')
              .layoutWeight(1)
              .margin({ right: 8 })
              .enabled(!this.isTesting)
              .onClick(() => {
                this.testConnection()
              })

            Button('Save')
              .fontSize(14)
              .backgroundColor('#4A90D9')
              .layoutWeight(1)
              .margin({ left: 8 })
              .enabled(!this.isSaving)
              .onClick(() => {
                this.saveSettings()
              })
          }
          .width('100%')
          .margin({ top: 16 })

          // === RAG Section ===
          Text('RAG (Vector Retrieval)')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ top: 28, bottom: 4 })
            .width('100%')

          Text('SiliconFlow API Key (free, for BGE-M3 embeddings)')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 12, bottom: 8 })
            .width('100%')

          TextInput({ text: this.siliconFlowApiKey, placeholder: 'sk-... (optional)' })
            .type(InputType.Password)
            .height(44)
            .width('100%')
            .borderRadius(8)
            .backgroundColor('#F0F0F0')
            .onChange((value: string) => {
              this.siliconFlowApiKey = value
            })

          Text('Leave empty to use keyword-based retrieval instead of vector search.')
            .fontSize(12)
            .fontColor('#999999')
            .margin({ top: 4 })
            .width('100%')

          // === MCP Section ===
          Text('MCP Server')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ top: 28, bottom: 4 })
            .width('100%')

          Text('Server Name')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 12, bottom: 8 })
            .width('100%')

          TextInput({ text: this.mcpServerName, placeholder: 'e.g. Amap Maps' })
            .height(44)
            .width('100%')
            .borderRadius(8)
            .backgroundColor('#F0F0F0')
            .onChange((value: string) => {
              this.mcpServerName = value
            })

          Text('Server URL')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 12, bottom: 8 })
            .width('100%')

          TextInput({ text: this.mcpServerUrl, placeholder: 'https://mcp.example.com/mcp?key=...' })
            .height(44)
            .width('100%')
            .borderRadius(8)
            .backgroundColor('#F0F0F0')
            .onChange((value: string) => {
              this.mcpServerUrl = value
            })

          Text('Streamable HTTP MCP servers only. Leave empty to disable.')
            .fontSize(12)
            .fontColor('#999999')
            .margin({ top: 4 })
            .width('100%')

          // Status message
          if (this.statusMessage) {
            Text(this.statusMessage)
              .fontSize(13)
              .fontColor(this.statusMessage.includes('failed') || this.statusMessage.includes('Please') ? '#CC0000' : '#009900')
              .margin({ top: 16 })
              .width('100%')
              .textAlign(TextAlign.Center)
          }

          // Info
          Text('OHClaw')
            .fontSize(12)
            .fontColor('#AAAAAA')
            .margin({ top: 40 })

          Text('AI Agent with ReAct loop, tool use, memory, task scheduling, MCP, and RAG.\nBased on NanoClaw, rewritten in pure ArkTS for HarmonyOS.')
            .fontSize(12)
            .fontColor('#CCCCCC')
            .margin({ top: 8 })
            .textAlign(TextAlign.Center)
        }
        .padding({ left: 24, right: 24, bottom: 40 })
        .width('100%')
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}

interface McpServerEntry {
  name: string
  url: string
}
