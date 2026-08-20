/**
 * ChatStore — 设置持久化（preferences）+ 会话历史（JSON 文件）+ 上下文拼装。
 * 人设提示词与拼装逻辑照搬 Windows 版 core.py / pet_window.py。
 */
import { preferences } from '@kit.ArkData'
import { fileIo as fs } from '@kit.CoreFileKit'
import { util } from '@kit.ArkTS'
import { ChatMsg } from './ChatApi'

// ── 默认智能体 = 安洁莉娜（Skill 注入：鹰角官方文本蒸馏，rawfile 运行时加载） ──
// 兜底提示词：rawfile 缺失时使用（中性工具型，合规定案）
export const DEFAULT_AGENT_PROMPT: string =
  '你是一个乐于助人的通用对话助手。你回答问题清晰、准确、条理分明；' +
  '不确定的事情如实说明，不编造事实；复杂问题先理清思路再作答。'

// 智能体：用户自定义（名称 + 系统提示词）
export interface Agent {
  aid: string
  name: string
  prompt: string
  created_at: number
}

// 主动性发言的生成指令（Windows core.py CHATTER_PROMPT 原文）
export const CHATTER_PROMPT: string =
  '你现在在博士的桌面上待机。请用一句自然的自言自语表达你此刻的想法。不要提问，不要超过30字。只要说一句话。'

// 无 API 时的预设台词（Windows 原文）
export const IDLE_PROACTIVE_LINE: string =
  '咖啡的味道和以前一样，我们之间也和以前一样......嗯，这样就好。'
export const FLIGHT_PROACTIVE_LINE: string =
  '看，每送出一封信，我就会折一颗纸星星。对，纸星星无法升上天空，但它们是安洁莉娜的星星——它们仍然可以离开狭小的玻璃瓶，飞翔、环绕、起舞......'

// ── 设置 ─────────────────────────────────────────────────
export interface ChatSettings {
  chat_base_url: string
  chat_api_key: string
  chat_model: string
  player_name: string
  context_window_size: number
  time_awareness: boolean
  extra_prompt: string
  chatter_interval: string // 主动性发言频率：低频/中频/高频（Windows idle_chatter_interval）
  voice_enabled: boolean // 语音开关（Windows voice_enabled；默认开：点击角色有语音）
  voice_language: string // 语音语言：中文/日文（Windows voice_language）
}

export class ChatStore {
  static DEFAULT_SETTINGS: ChatSettings = {
    chat_base_url: 'https://api.deepseek.com',
    chat_api_key: '',
    chat_model: 'deepseek-v4-flash',
    player_name: '博士',
    context_window_size: 20,
    time_awareness: false, // 用户定案（2026-08-20）：新装默认关闭时间感知
    extra_prompt: '',
    chatter_interval: '中频',
    voice_enabled: false, // 用户定案（2026-08-20）：新装默认关闭语音播放
    voice_language: '中文'
  }

  static async loadSettings(context: Context): Promise<ChatSettings> {
    let prefs = preferences.getPreferencesSync(context, { name: 'pet_settings' })
    let s: ChatSettings = {
      chat_base_url: prefs.getSync('chat_base_url', ChatStore.DEFAULT_SETTINGS.chat_base_url) as string,
      chat_api_key: prefs.getSync('chat_api_key', ChatStore.DEFAULT_SETTINGS.chat_api_key) as string,
      chat_model: prefs.getSync('chat_model', ChatStore.DEFAULT_SETTINGS.chat_model) as string,
      player_name: prefs.getSync('player_name', ChatStore.DEFAULT_SETTINGS.player_name) as string,
      context_window_size: prefs.getSync('context_window_size', ChatStore.DEFAULT_SETTINGS.context_window_size) as number,
      time_awareness: prefs.getSync('time_awareness', ChatStore.DEFAULT_SETTINGS.time_awareness) as boolean,
      extra_prompt: prefs.getSync('extra_prompt', ChatStore.DEFAULT_SETTINGS.extra_prompt) as string,
      chatter_interval: prefs.getSync('chatter_interval', ChatStore.DEFAULT_SETTINGS.chatter_interval) as string,
      voice_enabled: prefs.getSync('voice_enabled', ChatStore.DEFAULT_SETTINGS.voice_enabled) as boolean,
      voice_language: prefs.getSync('voice_language', ChatStore.DEFAULT_SETTINGS.voice_language) as string
    }
    return s
  }

  static saveSettings(context: Context, s: ChatSettings): void {
    let prefs = preferences.getPreferencesSync(context, { name: 'pet_settings' })
    prefs.putSync('chat_base_url', s.chat_base_url)
    prefs.putSync('chat_api_key', s.chat_api_key)
    prefs.putSync('chat_model', s.chat_model)
    prefs.putSync('player_name', s.player_name)
    prefs.putSync('context_window_size', s.context_window_size)
    prefs.putSync('time_awareness', s.time_awareness)
    prefs.putSync('extra_prompt', s.extra_prompt)
    prefs.putSync('chatter_interval', s.chatter_interval)
    prefs.putSync('voice_enabled', s.voice_enabled)
    prefs.putSync('voice_language', s.voice_language)
    prefs.flush()
  }

  // ── 会话历史（JSON 文件；对话树：RoundNode 节点 + path 活跃分支） ──
  static async loadHistory(context: Context): Promise<ChatHistory> {
    let path = context.filesDir + '/chat_history.json'
    try {
      let text = fs.readTextSync(path)
      let h = JSON.parse(text) as ChatHistory
      // 迁移旧版线性 messages → 单链树（首次读取后旧字段清空）
      for (let i = 0; i < h.sessions.length; i++) {
        let sess = h.sessions[i]
        if (sess.rounds === undefined || sess.rounds === null) {
          ChatStore.migrateSession(sess)
        }
        if (sess.path === undefined || sess.path === null) {
          sess.path = []
        }
        if (sess.messages !== undefined && sess.messages !== null && sess.messages.length > 0 &&
          (sess.rounds === undefined || sess.rounds.length === 0)) {
          ChatStore.migrateSession(sess)
        }
        if (sess.messages !== undefined) {
          sess.messages = undefined
        }
        if (sess.pid === undefined || sess.pid === null) {
          sess.pid = ''
        }
        if (sess.context_size === undefined || sess.context_size === null) {
          sess.context_size = 0
        }
        if (sess.agent_aid === undefined || sess.agent_aid === null) {
          sess.agent_aid = ''
        }
        for (let k = 0; k < sess.rounds.length; k++) {
          if (sess.rounds[k].reason === undefined || sess.rounds[k].reason === null) {
            sess.rounds[k].reason = ''
          }
        }
      }
      if (h.projects === undefined || h.projects === null) {
        h.projects = []
      }
      if (h.agents === undefined || h.agents === null) {
        h.agents = []
      }
      return h
    } catch (e) {
      // 解析失败：备份原文件后再返回空结构（防止空结构被保存覆写真实数据）
      try {
        let text2 = fs.readTextSync(path)
        if (text2.length > 0) {
          fs.copyFileSync(path, path + '.bak')
        }
      } catch (e2) {
      }
      return { active_session: '', sessions: [], projects: [], agents: [] }
    }
  }

  // 旧版线性消息 → 单链树（用户+紧随助手成一轮；孤立助手单条成轮）
  private static migrateSession(s: Session): void {
    let msgs = s.messages !== undefined && s.messages !== null ? s.messages : []
    let rounds: RoundNode[] = []
    let path: string[] = []
    let prev = ''
    for (let i = 0; i < msgs.length; i++) {
      let m = msgs[i]
      if (m.role === 'user') {
        let nid = 'm' + i.toString() + '-' + Math.floor(Math.random() * 100000).toString()
        rounds.push({ nid: nid, parent: prev, children: [], user: m.content, assistant: '', reason: '', time: m.time })
        path.push(nid)
        prev = nid
      } else if (prev !== '' && rounds.length > 0) {
        rounds[rounds.length - 1].assistant = m.content
      } else {
        let nid = 'm' + i.toString() + '-' + Math.floor(Math.random() * 100000).toString()
        rounds.push({ nid: nid, parent: prev, children: [], user: '', assistant: m.content, reason: '', time: m.time })
        path.push(nid)
        prev = nid
      }
    }
    for (let i = 0; i + 1 < path.length; i++) {
      let node = ChatStore.findRoundIn(rounds, path[i])
      if (node !== null) {
        node.children.push(path[i + 1])
      }
    }
    s.rounds = rounds
    s.path = path
    s.messages = undefined
  }

  private static findRoundIn(rounds: RoundNode[], nid: string): RoundNode | null {
    for (let i = 0; i < rounds.length; i++) {
      if (rounds[i].nid === nid) {
        return rounds[i]
      }
    }
    return null
  }

  static saveHistory(context: Context, h: ChatHistory): void {
    let path = context.filesDir + '/chat_history.json'
    let tmp = path + '.tmp'
    // 写前备份上一版（崩溃/误覆写后可恢复）
    try {
      let old2 = fs.readTextSync(path)
      if (old2.length > 100) {
        fs.copyFileSync(path, path + '.bak')
      }
    } catch (e) {
    }
    let f = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY)
    fs.writeSync(f.fd, JSON.stringify(h))
    fs.closeSync(f)
    fs.renameSync(tmp, path)
  }

  // ── 上下文拼装：所选智能体的系统提示词（+ 额外提示词）+ 活跃分支路径 ──
  // 截 context_window_size 条；时间前缀注入最后一条用户消息；兄弟分支不进上下文
  static buildPathMessages(h: ChatHistory, s: ChatSettings, agentPrompt: string, sessionCtx: number = 0): ChatMsg[] {
    let msgs: ChatMsg[] = []
    if (agentPrompt.length > 0) {
      msgs.push({ role: 'system', content: agentPrompt })
    }
    if (s.extra_prompt.length > 0 && s.extra_prompt !== '你是普瑞赛斯' && s.extra_prompt !== '你是洁尔佩塔' && s.extra_prompt !== '酸橙味的信') {
      msgs.push({ role: 'system', content: s.extra_prompt })
    }
    let session = ChatStore.findSession(h, h.active_session)
    if (session !== null) {
      let all = ChatStore.pathMessages(h, h.active_session)
      // 每对话上下文条数优先（>0），否则用全局设置
      let win = sessionCtx > 0 ? sessionCtx : s.context_window_size
      let start = Math.max(0, all.length - win)
      for (let i = start; i < all.length; i++) {
        msgs.push(all[i])
      }
      if (s.time_awareness && msgs.length > 2 && msgs[msgs.length - 1].role === 'user') {
        let d = new Date()
        let hh = d.getHours().toString().padStart(2, '0')
        let mm = d.getMinutes().toString().padStart(2, '0')
        let last = msgs[msgs.length - 1]
        msgs[msgs.length - 1] = { role: last.role, content: '[' + hh + ':' + mm + '] ' + last.content }
      }
    }
    return msgs
  }

  static findSession(h: ChatHistory, sid: string): Session | null {
    for (let i = 0; i < h.sessions.length; i++) {
      if (h.sessions[i].sid === sid) {
        return h.sessions[i]
      }
    }
    return null
  }

  // 新会话（首条消息生成标题：前 16 字；pid = 所属项目，'' = 无项目）
  static newSession(h: ChatHistory, firstUserText: string, pid: string = '', agentAid: string = ''): string {
    let sid = Date.now().toString()
    let title = firstUserText.length > 16 ? firstUserText.substring(0, 16) : firstUserText
    h.sessions.push({
      sid: sid,
      title: title,
      created_at: Date.now(),
      pid: pid,
      context_size: 0,
      agent_aid: agentAid,
      rounds: [],
      path: []
    })
    h.active_session = sid
    return sid
  }

  // ── 项目操作（文件夹语义：删除项目不删会话，会话变无项目） ──

  static newProject(h: ChatHistory, name: string): string {
    let t = name.trim()
    if (t.length === 0) {
      return ''
    }
    let pid = 'p' + Date.now().toString() + '-' + Math.floor(Math.random() * 10000).toString()
    h.projects.push({ pid: pid, name: t, created_at: Date.now() })
    return pid
  }

  static renameProject(h: ChatHistory, pid: string, name: string): boolean {
    let t = name.trim()
    if (t.length === 0) {
      return false
    }
    for (let i = 0; i < h.projects.length; i++) {
      if (h.projects[i].pid === pid) {
        h.projects[i].name = t
        return true
      }
    }
    return false
  }

  // 删除项目：其会话全部变无项目（不删除会话）
  static deleteProject(h: ChatHistory, pid: string): boolean {
    let found = false
    for (let i = h.projects.length - 1; i >= 0; i--) {
      if (h.projects[i].pid === pid) {
        h.projects.splice(i, 1)
        found = true
      }
    }
    if (!found) {
      return false
    }
    for (let i = 0; i < h.sessions.length; i++) {
      if (h.sessions[i].pid === pid) {
        h.sessions[i].pid = ''
      }
    }
    return true
  }

  // 移动会话到项目（pid='' = 移出到无项目）；每条对话最多属于一个项目
  static moveSession(h: ChatHistory, sid: string, pid: string): boolean {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return false
    }
    session.pid = pid
    return true
  }

  // 项目下的会话（按创建时间正序）
  static projectsOf(h: ChatHistory, pid: string): Session[] {
    let out: Session[] = []
    for (let i = 0; i < h.sessions.length; i++) {
      if (h.sessions[i].pid === pid) {
        out.push(h.sessions[i])
      }
    }
    return out
  }

  // ── 会话内搜索（用户定案：仅在当前对话话题内生效；有对话树则仅搜活跃分支） ──
  // 大小写不敏感子串匹配；命中用户输入/助手回复
  static searchInSession(h: ChatHistory, sid: string, query: string): SearchResult[] {
    let q = query.trim().toLowerCase()
    let out: SearchResult[] = []
    if (q.length === 0) {
      return out
    }
    let sess = ChatStore.findSession(h, sid)
    if (sess === null) {
      return out
    }
    for (let i = 0; i < sess.path.length; i++) {
      let node = ChatStore.findRound(sess, sess.path[i])
      if (node === null) {
        continue
      }
      let uHit = node.user.toLowerCase().indexOf(q) >= 0
      let aHit = node.assistant.toLowerCase().indexOf(q) >= 0
      if (!uHit && !aHit) {
        continue
      }
      let text = uHit ? node.user : node.assistant
      let pos = text.toLowerCase().indexOf(q)
      let from = Math.max(0, pos - 14)
      let to = Math.min(text.length, pos + q.length + 24)
      let snippet = (from > 0 ? '…' : '') + text.substring(from, to) + (to < text.length ? '…' : '')
      out.push({
        sid: sess.sid,
        title: sess.title,
        nid: node.nid,
        snippet: snippet,
        kind: uHit ? 1 : 2 // 1=用户输入命中 2=助手回复命中
      })
    }
    return out
  }

  // ── 智能体操作（名称 + 系统提示词；工具型定位，不预设角色） ──

  static newAgent(h: ChatHistory, name: string, prompt: string): string {
    let n = name.trim()
    let p = prompt.trim()
    if (n.length === 0 || p.length === 0) {
      return ''
    }
    let aid = 'a' + Date.now().toString() + '-' + Math.floor(Math.random() * 10000).toString()
    h.agents.push({ aid: aid, name: n, prompt: p, created_at: Date.now() })
    return aid
  }

  static renameAgent(h: ChatHistory, aid: string, name: string, prompt: string): boolean {
    let n = name.trim()
    let p = prompt.trim()
    if (n.length === 0 || p.length === 0) {
      return false
    }
    for (let i = 0; i < h.agents.length; i++) {
      if (h.agents[i].aid === aid) {
        h.agents[i].name = n
        h.agents[i].prompt = p
        return true
      }
    }
    return false
  }

  static deleteAgent(h: ChatHistory, aid: string): boolean {
    for (let i = h.agents.length - 1; i >= 0; i--) {
      if (h.agents[i].aid === aid) {
        h.agents.splice(i, 1)
        return true
      }
    }
    return false
  }

  static agentOf(h: ChatHistory, aid: string): Agent | null {
    for (let i = 0; i < h.agents.length; i++) {
      if (h.agents[i].aid === aid) {
        return h.agents[i]
      }
    }
    return null
  }

  // 活跃智能体的系统提示词：
  // ''=默认智能体「安洁莉娜」（Skill 注入）；'~raw'=陌生的友人（无提示词，直连大模型）；其余=自定义智能体
  // 彩蛋 Key 开关：额外提示词恰为「你是普瑞赛斯」/「你是洁尔佩塔」时切换对应 Skill
  static activeAgentPrompt(h: ChatHistory, aid: string, extraPrompt: string = ''): string {
    if (aid === '~raw') {
      return ''
    }
    let a = ChatStore.agentOf(h, aid)
    if (a !== null) {
      return a.prompt
    }
    if (extraPrompt === '你是普瑞赛斯' && ChatStore.priestessPrompt.length > 0) {
      return ChatStore.priestessPrompt
    }
    if (extraPrompt === '你是洁尔佩塔' && ChatStore.jieerpeitaPrompt.length > 0) {
      return ChatStore.jieerpeitaPrompt
    }
    if (extraPrompt === '酸橙味的信' && ChatStore.angelinaPastPrompt.length > 0) {
      return ChatStore.angelinaPastPrompt
    }
    return ChatStore.defaultAgentPrompt
  }

  // 默认智能体的提示词：优先用 rawfile 里的安洁莉娜 Skill 包，加载失败用兜底
  static defaultAgentPrompt: string = DEFAULT_AGENT_PROMPT

  // 彩蛋 Key 开关对应的提示词（运行时加载；空=彩蛋未装载）
  static priestessPrompt: string = '' // 「你是普瑞赛斯」：赛博女鬼夺舍安洁莉娜
  static jieerpeitaPrompt: string = '' // 「你是洁尔佩塔」：终末地再旅者
  static angelinaPastPrompt: string = '' // 「酸橙味的信」：与过去的她对话（安洁莉娜本体 Skill）

  static async loadDefaultPrompt(context: Context): Promise<void> {
    let dec = util.TextDecoder.create('utf-8')
    let loadOne = async (file: string): Promise<string> => {
      try {
        let buf = await context.resourceManager.getRawFileContent(file)
        let text = dec.decodeToString(buf)
        return text.trim().length > 0 ? text : ''
      } catch (e) {
        return ''
      }
    }
    let main = await loadOne('skill/angelina_bundle.md')
    if (main.length > 0) {
      ChatStore.defaultAgentPrompt = main
    }
    ChatStore.priestessPrompt = await loadOne('skill/priestess_bundle.md')
    ChatStore.jieerpeitaPrompt = await loadOne('skill/jieerpeita_bundle.md')
    ChatStore.angelinaPastPrompt = await loadOne('skill/angelina_past_bundle.md')
  }

  // 路径重连到指定轮次：根→该节点→沿首子链走到叶（搜索跳转用）
  static pathToRound(h: ChatHistory, sid: string, nid: string): boolean {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return false
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return false
    }
    // 祖先链（根在前）
    let chain: string[] = []
    let cur: RoundNode | null = node
    let guard = 0
    while (cur !== null && guard < 1000) {
      guard++
      chain.push(cur.nid)
      if (cur.parent === '') {
        break
      }
      cur = ChatStore.findRound(session, cur.parent)
    }
    chain.reverse()
    let p: string[] = chain
    // 从目标节点继续沿首子链到叶
    cur = node
    guard = 0
    while (cur !== null && guard < 1000) {
      guard++
      if (cur.children.length > 0) {
        cur = ChatStore.findRound(session, cur.children[0])
      } else {
        break
      }
      if (cur !== null) {
        p.push(cur.nid)
      }
    }
    session.path = p
    return true
  }

  // ── 对话树操作（轮次 = 树节点；path = 活跃分支） ──

  static findRound(session: Session, nid: string): RoundNode | null {
    for (let i = 0; i < session.rounds.length; i++) {
      if (session.rounds[i].nid === nid) {
        return session.rounds[i]
      }
    }
    return null
  }

  // 活跃路径 → 线性消息（喂 UI 与上下文；空侧跳过——孤立助手轮只出一条）
  static pathMessages(h: ChatHistory, sid: string): ChatMsg[] {
    let session = ChatStore.findSession(h, sid)
    let out: ChatMsg[] = []
    if (session === null) {
      return out
    }
    for (let i = 0; i < session.path.length; i++) {
      let node = ChatStore.findRound(session, session.path[i])
      if (node === null) {
        continue
      }
      if (node.user.length > 0) {
        out.push({ role: 'user', content: node.user })
      }
      if (node.assistant.length > 0) {
        out.push({ role: 'assistant', content: node.assistant, reason: node.reason })
      }
    }
    return out
  }

  // 活跃路径末尾追加新轮（用户输入已写入；助手待流式填充），返回 nid
  static appendUserRound(h: ChatHistory, sid: string, text: string): string {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return ''
    }
    let parent = session.path.length > 0 ? session.path[session.path.length - 1] : ''
    let nid = 'r' + Date.now().toString() + '-' + Math.floor(Math.random() * 10000).toString()
    session.rounds.push({ nid: nid, parent: parent, children: [], user: text, assistant: '', reason: '', time: Date.now() })
    if (parent !== '') {
      let p = ChatStore.findRound(session, parent)
      if (p !== null) {
        p.children.push(nid)
      }
    }
    session.path.push(nid)
    return nid
  }

  // 思考过程落盘（仅思维模型非空）
  static setReason(h: ChatHistory, sid: string, nid: string, reason: string): boolean {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return false
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return false
    }
    node.reason = reason
    return true
  }

  // 流式完成：填充该轮助手回复
  static setAssistant(h: ChatHistory, sid: string, nid: string, content: string): boolean {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return false
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return false
    }
    node.assistant = content
    return true
  }

  // 开分支：同一条用户输入重新生成（Chatbox 语义）——在目标轮的父节点下建兄弟节点，
  // 活跃路径切换到新兄弟，返回新 nid
  private static forkBranch(h: ChatHistory, sid: string, nid: string, newUserText: string): string {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return ''
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return ''
    }
    let newNid = 'r' + Date.now().toString() + '-' + Math.floor(Math.random() * 10000).toString()
    session.rounds.push({
      nid: newNid,
      parent: node.parent,
      children: [],
      user: newUserText,
      assistant: '',
      reason: '',
      time: Date.now()
    })
    if (node.parent !== '') {
      let p = ChatStore.findRound(session, node.parent)
      if (p !== null) {
        p.children.push(newNid)
      }
    }
    // 根轮（parent=''）特判：前缀为空——否则循环找不到 '' 永不 break，
    // 路径变成整条旧路径+新节点 = 重复追加一条一模一样的内容
    let p2: string[] = []
    if (node.parent !== '') {
      for (let i = 0; i < session.path.length; i++) {
        p2.push(session.path[i])
        if (session.path[i] === node.parent) {
          break
        }
      }
    }
    p2.push(newNid)
    session.path = p2
    return newNid
  }

  // 重新生成回复（同一条用户输入）
  static regenBranch(h: ChatHistory, sid: string, nid: string): string {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return ''
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return ''
    }
    return ChatStore.forkBranch(h, sid, nid, node.user)
  }

  // 编辑并重发（修改用户输入后开分支）
  static editResendBranch(h: ChatHistory, sid: string, nid: string, newUserText: string): string {
    return ChatStore.forkBranch(h, sid, nid, newUserText)
  }

  // 原地编辑（不开分支——对话自由的优点：编辑即改上下文）
  static editRoundContent(h: ChatHistory, sid: string, nid: string, isUser: boolean, content: string): boolean {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return false
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return false
    }
    if (isUser) {
      node.user = content
    } else {
      node.assistant = content
    }
    return true
  }

  // 该轮是否为对话树锚点（下方有 ≥2 条分支）
  static isAnchor(h: ChatHistory, sid: string, nid: string): boolean {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return false
    }
    let node = ChatStore.findRound(session, nid)
    return node !== null && node.children.length > 1
  }

  // 删除单条消息：只清该侧内容（另一侧保留成孤立消息——每条对话都是独立上下文）；
  // 两侧都空时整节点删除（锚点规则生效：连同全部后续分支）
  static deleteMessageSide(h: ChatHistory, sid: string, nid: string, isUser: boolean): string {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return 'miss'
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return 'miss'
    }
    if (isUser) {
      node.user = ''
    } else {
      node.assistant = ''
    }
    if (node.user === '' && node.assistant === '') {
      return ChatStore.deleteRound(h, sid, nid)
    }
    return 'ok'
  }

  // 删除轮次。锚点：连同全部后续分支一并删除（返回 'anchor'）；
  // 单链/叶：仅删该节点并重连父子（返回 'ok'）；未找到返回 'miss'
  static deleteRound(h: ChatHistory, sid: string, nid: string): string {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return 'miss'
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return 'miss'
    }
    if (node.children.length > 1) {
      // 锚点：整棵子树一并删除
      let kill: string[] = []
      let queue: string[] = node.children.slice()
      while (queue.length > 0) {
        let c = queue[0]
        queue.splice(0, 1)
        kill.push(c)
        let cn = ChatStore.findRound(session, c)
        if (cn !== null) {
          for (let i = 0; i < cn.children.length; i++) {
            queue.push(cn.children[i])
          }
        }
      }
      for (let i = session.rounds.length - 1; i >= 0; i--) {
        if (kill.indexOf(session.rounds[i].nid) >= 0) {
          session.rounds.splice(i, 1)
        }
      }
      let parent = node.parent !== '' ? ChatStore.findRound(session, node.parent) : null
      if (parent !== null) {
        let idx = parent.children.indexOf(nid)
        if (idx >= 0) {
          parent.children.splice(idx, 1)
        }
      }
      for (let i = session.rounds.length - 1; i >= 0; i--) {
        if (session.rounds[i].nid === nid) {
          session.rounds.splice(i, 1)
        }
      }
      let pIdx = session.path.indexOf(nid)
      if (pIdx >= 0) {
        session.path = session.path.slice(0, pIdx)
      }
      return 'anchor'
    }
    // 单链/叶：重连父子
    let parent = node.parent !== '' ? ChatStore.findRound(session, node.parent) : null
    if (parent !== null) {
      let idx = parent.children.indexOf(nid)
      if (idx >= 0) {
        parent.children.splice(idx, 1)
      }
      if (node.children.length === 1) {
        parent.children.push(node.children[0])
        let child = ChatStore.findRound(session, node.children[0])
        if (child !== null) {
          child.parent = parent.nid
        }
      }
    }
    for (let i = session.rounds.length - 1; i >= 0; i--) {
      if (session.rounds[i].nid === nid) {
        session.rounds.splice(i, 1)
      }
    }
    let pIdx = session.path.indexOf(nid)
    if (pIdx >= 0) {
      session.path.splice(pIdx, 1)
    }
    return 'ok'
  }

  // 切换分支：路径前缀到锚点，接选定子节点并沿其首子链走到叶
  static switchBranch(h: ChatHistory, sid: string, anchorNid: string, childNid: string): boolean {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return false
    }
    let p: string[] = []
    for (let i = 0; i < session.path.length; i++) {
      p.push(session.path[i])
      if (session.path[i] === anchorNid) {
        break
      }
    }
    if (p.length === 0 || p[p.length - 1] !== anchorNid) {
      return false
    }
    let cur = childNid
    let guard = 0
    while (cur !== '' && guard < 1000) {
      guard++
      p.push(cur)
      let node = ChatStore.findRound(session, cur)
      if (node !== null && node.children.length > 0) {
        cur = node.children[0]
      } else {
        break
      }
    }
    session.path = p
    return true
  }

  // 锚点下的全部分支（子节点列表，顺序=创建顺序）
  static branchChildren(h: ChatHistory, sid: string, nid: string): RoundNode[] {
    let session = ChatStore.findSession(h, sid)
    let out: RoundNode[] = []
    if (session === null) {
      return out
    }
    let node = ChatStore.findRound(session, nid)
    if (node === null) {
      return out
    }
    for (let i = 0; i < node.children.length; i++) {
      let c = ChatStore.findRound(session, node.children[i])
      if (c !== null) {
        out.push(c)
      }
    }
    return out
  }

  // 锚点在活跃路径上的下一个节点（当前分支的延续；不在路径上返回 ''）
  static activeChildOf(h: ChatHistory, sid: string, nid: string): string {
    let session = ChatStore.findSession(h, sid)
    if (session === null) {
      return ''
    }
    for (let i = 0; i + 1 < session.path.length; i++) {
      if (session.path[i] === nid) {
        return session.path[i + 1]
      }
    }
    return ''
  }

  // 重命名会话（空白标题拒绝）
  static renameSession(h: ChatHistory, sid: string, title: string): boolean {
    let t = title.trim()
    let session = ChatStore.findSession(h, sid)
    if (session === null || t.length === 0) {
      return false
    }
    session.title = t
    return true
  }

  // 删除会话；删除的是当前会话则清空激活标记（下一条消息自动开新会话）
  static deleteSession(h: ChatHistory, sid: string): boolean {
    for (let i = 0; i < h.sessions.length; i++) {
      if (h.sessions[i].sid === sid) {
        h.sessions.splice(i, 1)
        if (h.active_session === sid) {
          h.active_session = ''
        }
        return true
      }
    }
    return false
  }
}

export interface HistoryMessage {
  time: number
  role: string
  content: string
}

// 对话树轮次节点：一轮 = 用户输入 + 助手回复（缺失侧为空串）
export interface RoundNode {
  nid: string
  parent: string // 父节点 nid；根为 ''
  children: string[] // 子节点 nid（≥2 = 对话树锚点）
  user: string
  assistant: string
  reason: string // 思考过程（reasoning_content；非思维模型为空）
  time: number
}

export interface Session {
  sid: string
  title: string
  created_at: number
  pid: string // 所属项目（'' = 无项目）
  context_size: number // 每对话上下文条数（0 = 用全局设置）
  agent_aid: string // 本对话绑定的智能体（创建时烘焙；''=安洁莉娜，'~raw'=陌生的友人）
  rounds: RoundNode[] // 树的全部节点
  path: string[] // 活跃分支路径（根→当前叶）
  messages?: HistoryMessage[] // 旧版线性数据（迁移后删除）
}

// 项目：容纳若干会话的文件夹；删除项目不删会话（会话变无项目）
export interface Project {
  pid: string
  name: string
  created_at: number
}

export interface ChatHistory {
  active_session: string
  sessions: Session[]
  projects: Project[]
  agents: Agent[]
}

// 搜索命中（kind：0=标题 1=用户输入 2=助手回复）
export interface SearchResult {
  sid: string
  title: string
  nid: string
  snippet: string
  kind: number
}
