// Main chat page - NanoClaw on OpenHarmony
import { router } from '@kit.ArkUI'
import { agentCore } from '../services/AgentCore'
import { dbService } from '../services/DatabaseService'
import { configService } from '../services/ConfigService'
import { AgentEvent, ChatMessage, ToolCallRecord } from '../models/Types'
import { generateId } from '../utils/TextFormatter'

interface DisplayMessage {
  id: string
  content: string
  isFromMe: boolean
  timestamp: string
  toolCalls?: ToolCallRecord[]
  isThinking?: boolean
}

@Entry
@Component
struct Index {
  @State messages: DisplayMessage[] = []
  @State inputText: string = ''
  @State isRunning: boolean = false
  @State hasApiKey: boolean = false
  @State currentToolInfo: string = ''
  private chatId: string = 'default'
  private scroller: Scroller = new Scroller()

  async aboutToAppear(): Promise<void> {
    await this.refreshState()
  }

  async onPageShow(): Promise<void> {
    await this.refreshState()
  }

  async refreshState(): Promise<void> {
    this.hasApiKey = await configService.hasApiKey()
    if (this.hasApiKey) {
      await this.loadMessages()
    }
  }

  async loadMessages(): Promise<void> {
    const msgs = await dbService.getMessages(this.chatId, 100)
    const displayMsgs: DisplayMessage[] = []
    for (const m of msgs) {
      const dm: DisplayMessage = {
        id: m.id,
        content: m.content,
        isFromMe: m.isFromMe,
        timestamp: m.timestamp,
        toolCalls: m.toolCalls
      }
      displayMsgs.push(dm)
    }
    this.messages = displayMsgs
    this.scrollToBottom()
  }

  scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollToIndex(this.messages.length - 1)
    }, 100)
  }

  async sendMessage(): Promise<void> {
    const text = this.inputText.trim()
    if (!text || this.isRunning) return

    this.inputText = ''
    this.isRunning = true
    this.currentToolInfo = ''

    // Add user message to display
    const userMsg: DisplayMessage = {
      id: generateId(),
      content: text,
      isFromMe: true,
      timestamp: new Date().toISOString()
    }
    this.messages.push(userMsg)

    // Add thinking indicator
    const thinkingId = generateId()
    const thinkingMsg: DisplayMessage = {
      id: thinkingId,
      content: 'Thinking...',
      isFromMe: false,
      timestamp: new Date().toISOString(),
      isThinking: true
    }
    this.messages.push(thinkingMsg)
    this.scrollToBottom()

    // Collect tool calls for this turn
    const toolCalls: ToolCallRecord[] = []

    await agentCore.runAgent(text, this.chatId, (event: AgentEvent) => {
      if (event.type === 'tool_use') {
        const tc: ToolCallRecord = {
          name: event.name,
          input: event.input,
          result: event.result,
          isError: event.isError
        }
        toolCalls.push(tc)
        this.currentToolInfo = `Using: ${event.name}`
        // Update thinking message
        const thinkingIdx = this.messages.findIndex(m => m.id === thinkingId)
        if (thinkingIdx >= 0) {
          const existing = this.messages[thinkingIdx]
          const updated: DisplayMessage = {
            id: existing.id,
            content: `Using tool: ${event.name}...`,
            isFromMe: existing.isFromMe,
            timestamp: existing.timestamp,
            toolCalls: existing.toolCalls,
            isThinking: existing.isThinking
          }
          this.messages[thinkingIdx] = updated
        }
      } else if (event.type === 'text') {
        // Replace thinking message with actual response
        const thinkingIdx = this.messages.findIndex(m => m.id === thinkingId)
        if (thinkingIdx >= 0) {
          const replacement: DisplayMessage = {
            id: generateId(),
            content: event.content,
            isFromMe: false,
            timestamp: new Date().toISOString(),
            toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
            isThinking: false
          }
          this.messages[thinkingIdx] = replacement
        }
      } else if (event.type === 'error') {
        const thinkingIdx = this.messages.findIndex(m => m.id === thinkingId)
        if (thinkingIdx >= 0) {
          const errMsg: DisplayMessage = {
            id: generateId(),
            content: `Error: ${event.error}`,
            isFromMe: false,
            timestamp: new Date().toISOString(),
            isThinking: false
          }
          this.messages[thinkingIdx] = errMsg
        }
      } else if (event.type === 'done') {
        this.isRunning = false
        this.currentToolInfo = ''
      }
      this.scrollToBottom()
    })

    this.isRunning = false
  }

  build() {
    Column() {
      // Title bar
      Row() {
        Text('OHClaw')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)

        Button('Settings')
          .fontSize(14)
          .backgroundColor('#555555')
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' })
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#1a1a2e')

      if (!this.hasApiKey) {
        // No API key configured
        Column() {
          Text('Welcome to OHClaw')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 16 })

          Text('Please configure your DeepSeek API key in Settings to get started.')
            .fontSize(16)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 24 })

          Button('Go to Settings')
            .fontSize(16)
            .width(200)
            .onClick(() => {
              router.pushUrl({ url: 'pages/SettingsPage' })
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .padding(32)
      } else {
        // Message list
        List({ scroller: this.scroller }) {
          ForEach(this.messages, (msg: DisplayMessage) => {
            ListItem() {
              Column() {
                // Tool calls display (if any)
                if (msg.toolCalls && msg.toolCalls.length > 0) {
                  Column() {
                    ForEach(msg.toolCalls, (tc: ToolCallRecord) => {
                      Row() {
                        Text(`🔧 ${tc.name}`)
                          .fontSize(12)
                          .fontColor('#888888')
                      }
                      .width('100%')
                      .padding(4)
                    })
                  }
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 4 })
                }

                // Message bubble
                Row() {
                  if (msg.isFromMe) {
                    Blank()
                  }

                  Text(msg.content)
                    .fontSize(15)
                    .fontColor(msg.isFromMe ? '#FFFFFF' : '#333333')
                    .backgroundColor(msg.isFromMe ? '#4A90D9' : (msg.isThinking ? '#E8E8E8' : '#F0F0F0'))
                    .borderRadius(16)
                    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                    .constraintSize({ maxWidth: '75%' })
                    .wordBreak(WordBreak.BREAK_ALL)

                  if (!msg.isFromMe) {
                    Blank()
                  }
                }
                .width('100%')
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
              }
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#FAFAFA')

        // Tool activity indicator
        if (this.currentToolInfo) {
          Row() {
            Text(this.currentToolInfo)
              .fontSize(12)
              .fontColor('#888888')
              .fontStyle(FontStyle.Italic)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .backgroundColor('#F5F5F5')
        }

        // Input bar
        Row() {
          TextInput({ text: this.inputText, placeholder: 'Message or /command...' })
            .layoutWeight(1)
            .height(44)
            .borderRadius(22)
            .backgroundColor('#F0F0F0')
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.inputText = value
            })
            .onSubmit(() => {
              this.sendMessage()
            })

          Button({ type: ButtonType.Circle }) {
            Text('➤')
              .fontSize(18)
              .fontColor('#FFFFFF')
          }
          .width(44)
          .height(44)
          .backgroundColor(this.isRunning ? '#CCCCCC' : '#4A90D9')
          .margin({ left: 8 })
          .enabled(!this.isRunning)
          .onClick(() => {
            this.sendMessage()
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('#FFFFFF')
      }
    }
    .width('100%')
    .height('100%')
  }
}
