/**
 * ChatApi — DeepSeek 兼容的流式聊天客户端（SSE 增量解析）。
 * 参考 Windows 版 core.py chat_api_request（endpoint 自动补全、temperature 0.8），
 * 升级为流式：@ohos.net.http 的 dataReceive 事件逐块解析 SSE。
 */
import { http } from '@kit.NetworkKit'
import { util } from '@kit.ArkTS'

export interface ChatMsg {
  role: string
  content: string
  reason?: string // 思考过程（助手消息；非思维模型为空）
}

export interface ChatCallbacks {
  onDelta: (text: string) => void
  onReason: (text: string) => void // 思考过程（reasoning_content）
  onDone: (fullText: string) => void
  onError: (message: string) => void
}

export class ChatApi {
  private running: boolean = false
  private req: http.HttpRequest | null = null
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8')

  get isRunning(): boolean {
    return this.running
  }

  static buildUrl(baseUrl: string): string {
    let url = baseUrl
    if (!url.endsWith('/chat/completions')) {
      if (!url.endsWith('/')) {
        url += '/'
      }
      url += 'chat/completions'
    }
    return url
  }

  // 解析 SSE 文本中的思考过程增量（reasoning_content）
  static parseSseReason(chunk: string): string[] {
    let deltas: string[] = []
    let lines = chunk.split('\n')
    for (let i = 0; i < lines.length; i++) {
      let t = lines[i].trim()
      if (!t.startsWith('data:')) {
        continue
      }
      let payload = t.substring(5).trim()
      if (payload === '[DONE]' || payload.length === 0) {
        continue
      }
      try {
        let obj: Record<string, Object> = JSON.parse(payload) as Record<string, Object>
        let choices = obj['choices'] as Array<Record<string, Object>>
        if (choices === undefined || choices.length === 0) {
          continue
        }
        let delta = choices[0]['delta'] as Record<string, Object>
        if (delta === undefined) {
          continue
        }
        let rc = delta['reasoning_content'] as string
        if (rc !== undefined && rc.length > 0) {
          deltas.push(rc)
        }
      } catch (e) {
        // 非 JSON 行忽略
      }
    }
    return deltas
  }

  // 解析一段 SSE 文本（可能含多个事件），返回增量内容数组
  static parseSseChunk(chunk: string): string[] {
    let deltas: string[] = []
    let lines = chunk.split('\n')
    for (let i = 0; i < lines.length; i++) {
      let t = lines[i].trim()
      if (!t.startsWith('data:')) {
        continue
      }
      let payload = t.substring(5).trim()
      if (payload === '[DONE]' || payload.length === 0) {
        continue
      }
      try {
        let obj: Record<string, Object> = JSON.parse(payload) as Record<string, Object>
        let choices = obj['choices'] as Array<Record<string, Object>>
        if (choices === undefined || choices.length === 0) {
          continue
        }
        let delta = choices[0]['delta'] as Record<string, Object>
        if (delta === undefined) {
          continue
        }
        let content = delta['content'] as string
        if (content !== undefined && content.length > 0) {
          deltas.push(content)
        }
      } catch (e) {
        // 非 JSON 行（注释/心跳）忽略
      }
    }
    return deltas
  }

  send(baseUrl: string, apiKey: string, model: string, messages: ChatMsg[],
    cb: ChatCallbacks): void {
    if (this.running) {
      return
    }
    this.running = true
    let body = JSON.stringify({
      model: model,
      messages: messages,
      temperature: 0.8,
      stream: true
    })
    let req = http.createHttp()
    this.req = req
    let full = ''
    let lineBuf = ''
    let raw = ''

    req.on('dataReceive', (data: ArrayBuffer) => {
      // stream 模式：跨块被截断的多字节 UTF-8 字符由解码器内部暂存（否则中文乱码）
      let chunk = lineBuf + this.decoder.decodeToString(new Uint8Array(data), { stream: true })
      raw += chunk
      // SSE 事件以空行分隔；保留最后一个可能不完整的行
      let lines = chunk.split('\n')
      lineBuf = lines.length > 0 ? lines[lines.length - 1] : ''
      let complete = chunk.substring(0, chunk.length - lineBuf.length)
      let deltas = ChatApi.parseSseChunk(complete)
      for (let i = 0; i < deltas.length; i++) {
        full += deltas[i]
        cb.onDelta(deltas[i])
      }
      let reasons = ChatApi.parseSseReason(complete)
      for (let i = 0; i < reasons.length; i++) {
        cb.onReason(reasons[i])
      }
    })

    // 流式专用接口：响应体经 dataReceive 逐块派发。普通 request() 聚合缓冲整个响应体，
    // dataReceive 永不触发（真机实证：200 OK 完整回包但 UI 无流式）
    req.requestInStream(ChatApi.buildUrl(baseUrl), {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + apiKey
      },
      extraData: body,
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      usingCache: false,
      readTimeout: 30000,
      connectTimeout: 15000
    }).then((code: number) => {
      // 流结束：解码器冲刷残余字节（跨块多字节字符的尾部）+ 行缓冲残余
      let flush = this.decoder.decodeToString(new Uint8Array(0), { stream: false })
      let chunk = lineBuf + flush
      raw += chunk
      let tail = ChatApi.parseSseChunk(chunk)
      for (let i = 0; i < tail.length; i++) {
        full += tail[i]
        cb.onDelta(tail[i])
      }
      let tailReasons = ChatApi.parseSseReason(chunk)
      for (let i = 0; i < tailReasons.length; i++) {
        cb.onReason(tailReasons[i])
      }
      lineBuf = ''
      this.running = false
      this.req = null
      if (code >= 400) {
        // 错误响应体（API 报错 JSON）已随 dataReceive 收集在 raw 中
        let err = raw.length > 0 ? raw.substring(0, 120) : 'HTTP ' + code
        try {
          let obj: Record<string, Object> = JSON.parse(raw) as Record<string, Object>
          let e = obj['error'] as Record<string, Object>
          if (e !== undefined && e['message'] !== undefined) {
            err = e['message'] as string
          }
        } catch (e2) {
          // 保留原文截断
        }
        cb.onError(err)
        return
      }
      if (full.length === 0) {
        cb.onError('没有收到有效回复')
        return
      }
      cb.onDone(full)
    }).catch((e: Object) => {
      this.running = false
      this.req = null
      cb.onError(JSON.stringify(e))
    })
  }

  // 连通性测试：发一条最小非流式请求（max_tokens 8 最省钱），验证 key/地址/模型是否有效
  test(baseUrl: string, apiKey: string, model: string, cb: ChatCallbacks): void {
    if (this.running) {
      return
    }
    this.running = true
    let testMsgs: ChatMsg[] = [{ role: 'user', content: '你好' }]
    let body = JSON.stringify({
      model: model,
      messages: testMsgs,
      temperature: 0.0,
      max_tokens: 8,
      stream: false
    })
    let req = http.createHttp()
    this.req = req
    req.request(ChatApi.buildUrl(baseUrl), {
      method: http.RequestMethod.POST,
      header: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + apiKey
      },
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      usingCache: false,
      readTimeout: 15000,
      connectTimeout: 10000
    }).then((resp: http.HttpResponse) => {
      this.running = false
      this.req = null
      let code = resp.responseCode
      let bodyText = ''
      if (typeof resp.result === 'string') {
        bodyText = resp.result
      } else if (resp.result instanceof ArrayBuffer) {
        bodyText = this.decoder.decodeToString(new Uint8Array(resp.result))
      }
      if (code >= 200 && code < 300) {
        try {
          let obj: Record<string, Object> = JSON.parse(bodyText) as Record<string, Object>
          let choices = obj['choices'] as Array<Record<string, Object>>
          if (choices !== undefined && choices.length > 0) {
            cb.onDone(bodyText)
            return
          }
        } catch (e) {
          // 落到错误提示
        }
        cb.onError('响应异常：' + bodyText.substring(0, 100))
        return
      }
      // 非 2xx：提取 API 错误信息（error.message）
      let err = 'HTTP ' + code
      try {
        let obj: Record<string, Object> = JSON.parse(bodyText) as Record<string, Object>
        let e = obj['error'] as Record<string, Object>
        if (e !== undefined && e['message'] !== undefined) {
          err = e['message'] as string
        }
      } catch (e2) {
        if (bodyText.length > 0) {
          err = bodyText.substring(0, 120)
        }
      }
      cb.onError(err)
    }).catch((e: Object) => {
      this.running = false
      this.req = null
      cb.onError(JSON.stringify(e).substring(0, 120))
    })
  }

  cancel(): void {
    if (this.req !== null) {
      this.req.destroy()
      this.req = null
    }
    this.running = false
  }
}
