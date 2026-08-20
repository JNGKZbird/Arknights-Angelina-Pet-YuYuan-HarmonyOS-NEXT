/**
 * PetPage v2 — spine38 桌宠页面（三模型：基建 build / 战斗背面 back / 战斗正面 front）。
 * 动画循环（VSync 帧回调 + 固定步长）+ 单击互动 + 双击菜单 + 长按拖动转向。
 * 布局架构（v2.0 定论）：缩放按各模型 setup 包围盒（跨模型角色尺寸一致）；
 * 画布按状态包围盒变尺寸 + 每状态居中（悬浮桌宠无地面参照）。
 * 渲染管线（全部真机验证过）：CPU 光栅化(直通) → 转预乘 → writeBufferToPixels → Image。
 */
import { Skeleton } from '../spine38/skeleton'
import { apply_animation } from '../spine38/animation'
import { SkeletonBinary } from '../spine38/loader'
import { TextureAtlas, AtlasAttachmentLoaderImpl } from '../spine38/atlas'
import { collect_triangles, hit_test_point, RenderTransform, Texture } from '../spine38/renderer'
import { render_frame_to_window, render_frame_gl, init_surface } from 'libraster.so'
import { image } from '@kit.ImageKit'
import { util } from '@kit.ArkTS'
import { hilog } from '@kit.PerformanceAnalysisKit'
import { FrameCallback, display, mediaquery } from '@kit.ArkUI'
import { preferences } from '@kit.ArkData'
import { media } from '@kit.MediaKit'
import { camera } from '@kit.CameraKit'
import { abilityAccessCtrl } from '@kit.AbilityKit'
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit'
import { ChatApi, ChatMsg } from '../model/ChatApi'
import { ChatStore, ChatSettings, ChatHistory, Session, Project, Agent, RoundNode, SearchResult, CHATTER_PROMPT, IDLE_PROACTIVE_LINE, FLIGHT_PROACTIVE_LINE } from '../model/ChatStore'
import { VOICE_FILES, VOICE_LINES, BASE_TALK, COMBAT_SELECT, COMBAT_DEPLOY, COMBAT_FIGHT } from '../model/Voice'
import { MarkdownView } from '../components/MarkdownView'

// 基准画布（setup 包围盒缩放的参照；状态画布在此基础上按状态包围盒变尺寸）
const RW = 300
const RH = 480
const MARGIN = 14

interface MenuItem {
  label: string
  anim: string
  once?: boolean // 单次动画（播完回持久状态）
}

// 技能定义（照抄 Windows STATE_CHAIN）
interface SkillDef {
  label: string
  on: string[] // 开启链（依次播一次 → 技能待机）
  idle: string // 开启后待机（循环）
  combat: string // 点击触发的技能攻击（一次 → 回技能待机）
  off: string[] // 关闭链（依次播一次 → 回普通待机）
}

const COMBAT_SKILLS: SkillDef[] = [
  {
    label: '技能1',
    on: ['Start_2'],
    idle: 'Skill_1_Idle',
    combat: 'Skill_1_Loop',
    off: ['Skill_1_End']
  },
  {
    label: '技能2',
    on: ['Skill_2_Begin', 'Skill_2_Takeoff_Begin', 'Skill_2_Takeoff_Loop', 'Skill_2_Takeoff_End'],
    idle: 'Skill_2_Idle',
    combat: 'Skill_2_Loop',
    off: ['Skill_2_End']
  },
  {
    label: '技能3',
    on: ['Skill_3_Begin'],
    idle: 'Skill_3_Idle',
    combat: 'Skill_3_Combat',
    off: ['Skill_3_End']
  }
]

// 状态画布布局：画布尺寸随状态变，缩放恒定（每模型 setup 基准）
class StateLayout {
  w: number = 0
  h: number = 0
  t: RenderTransform = new RenderTransform()
}

async function loadTexture(context: Context, rawfilePath: string): Promise<Texture> {
  let data = await context.resourceManager.getRawFileContent(rawfilePath)
  let imageSource = image.createImageSource(data.buffer)
  let pixelMap = await imageSource.createPixelMap()
  let buffer = new ArrayBuffer(pixelMap.getPixelBytesNumber())
  await pixelMap.readPixelsToBuffer(buffer)
  let bytes = new Uint8Array(buffer)
  // 设备解码输出预乘，读回后反预乘（定律③：不做则腮红变灰）
  for (let i = 0; i < bytes.length; i += 4) {
    let a = bytes[i + 3]
    if (a > 0 && a < 255) {
      bytes[i] = Math.min(255, Math.round(bytes[i] * 255 / a))
      bytes[i + 1] = Math.min(255, Math.round(bytes[i + 1] * 255 / a))
      bytes[i + 2] = Math.min(255, Math.round(bytes[i + 2] * 255 / a))
    }
  }
  let info = pixelMap.getImageInfoSync()
  let tex = new Texture()
  tex.width = info.size.width
  tex.height = info.size.height
  tex.pixels = bytes
  return tex
}

// VSync 对齐的帧回调（替代 setInterval：与屏幕刷新严格同步，v1.0 丝滑感的来源）。
// 用 VSync 时间戳算真实 dt 推进动画：帧率下跌时动画跳帧保实时速度（不掉帧时 ≈ 固定步长）
class PetFrameCallback extends FrameCallback {
  private owner: PetView
  private lastNano: number = 0

  constructor(owner: PetView) {
    super()
    this.owner = owner
  }

  onFrame(frameTimeInNano: number): void {
    let dt = 1.0 / 60.0
    if (this.lastNano > 0 && frameTimeInNano > this.lastNano) {
      dt = (frameTimeInNano - this.lastNano) / 1e9
      // 钳制：切后台回来等长间隔不产生跳变
      if (dt > 0.25) {
        dt = 0.25
      }
    }
    this.lastNano = frameTimeInNano
    this.owner.onVsyncFrame(dt)
  }

  onIdle(timeLeftInNano: number): void {
  }
}

// ── 设计令牌（Kimi K3 Skill：DeepSeek 极简设计系统） ──
// 唯一事实来源：单一强调色/五级灰阶/圆角四档/唯一阴影（仅输入卡片）。禁止自由发挥。
interface ThemeTokens {
  name: string
  bgMain: string
  bgSidebar: string
  bgHover: string
  bgActive: string
  bubbleUser: string
  borderSubtle: string
  borderStrong: string
  textPrimary: string
  textBody: string
  textSecondary: string
  textTertiary: string
  textQuaternary: string
  accent: string
  accentHover: string
  accentSoft: string
  accentBorder: string
  sendIdle: string
}

// 天空主题：淡蓝强调色（用户要求：突出少女飞行时天空与云朵的浪漫感）
const THEME_SKY: ThemeTokens = {
  name: '天空',
  bgMain: '#FFFFFF',
  bgSidebar: '#FFFFFF',
  bgHover: '#EFF4FC',
  bgActive: '#E4EDFA',
  bubbleUser: '#EFF4FC',
  borderSubtle: '#E6EBF3',
  borderStrong: '#D4DCE8',
  textPrimary: '#1F2329',
  textBody: '#3F454D',
  textSecondary: '#6B7280',
  textTertiary: '#9AA1AD',
  textQuaternary: '#B6BCC7',
  accent: '#6E9BF2',
  accentHover: '#5C8CE8',
  accentSoft: '#EAF2FE',
  accentBorder: '#AEC8F2', // 未选中圆点：可见的淡蓝（100% 不透明）
  sendIdle: '#D6E3FB'
}

// 酸橙味主题：纯白打底（用户定案），强调色=明亮亮橙（非米黄），
// 主题个性收敛在强调色 + 边缘/气泡的细微暖调
const THEME_LIME: ThemeTokens = {
  name: '酸橙味',
  bgMain: '#FFFFFF',
  bgSidebar: '#FFFFFF',
  bgHover: '#FFF4EA',
  bgActive: '#FFE9D6',
  bubbleUser: '#FFF3E6',
  borderSubtle: '#F2E8DC',
  borderStrong: '#E4D2BC',
  textPrimary: '#1F2329',
  textBody: '#3F454D',
  textSecondary: '#6B7280',
  textTertiary: '#9AA1AD',
  textQuaternary: '#B6BCC7',
  accent: '#FF8C00',
  accentHover: '#F07D00',
  accentSoft: '#FFF0E0',
  accentBorder: '#FFB066', // 未选中圆点：可见的淡橙（100% 不透明）
  sendIdle: '#FFD9AE'
}

// 会话列表项（扁平结构：1=会话 2=项目文件夹 3=无项目固定分类）
class SidebarItem {
  kind: number = 1
  label: string = ''
  sid: string = ''
  pid: string = ''
  indent: boolean = false
}

// 文件夹图标（自绘：标签+主体，无 emoji 依赖）；全局复用（侧边栏/项目胶囊）
@Builder
function FolderGlyph(color: string, w: number) {
  Column() {
    Row()
      .width(w * 0.45)
      .height(w * 0.22)
      .borderRadius({ topLeft: w * 0.08, topRight: w * 0.08 })
      .backgroundColor(color)
    Row()
      .width(w)
      .height(w * 0.62)
      .borderRadius(w * 0.1)
      .backgroundColor(color)
  }
  .alignItems(HorizontalAlign.Start)
}

// 智能体图标：主星 = 十字胶囊交叉（四角星轮廓，仿 Gemini 星形神韵），中心空心圆环；
// 右上角实体小十字星（差异化设计，防侵权）；hole=背景色（挖空用）
@Builder
function StarGlyph(color: string, hole: string, w: number) {
  Stack({ alignContent: Alignment.TopStart }) {
    // 主星：细竖胶囊 + 细横胶囊交叉（纤细星形）
    Row()
      .width(w * 0.22)
      .height(w * 0.72)
      .borderRadius(w * 0.11)
      .backgroundColor(color)
      .position({ x: w * 0.39, y: w * 0.14 })
    Row()
      .width(w * 0.72)
      .height(w * 0.22)
      .borderRadius(w * 0.11)
      .backgroundColor(color)
      .position({ x: w * 0.14, y: w * 0.39 })
    // 中心空心圆（背景色描边圆环——视觉挖空）
    Circle({ width: w * 0.3, height: w * 0.3 })
      .fillOpacity(0)
      .stroke(hole)
      .strokeWidth(w * 0.09)
      .position({ x: w * 0.35, y: w * 0.35 })
    // 卫星：实体小十字星（右上角）
    Row()
      .width(w * 0.12)
      .height(w * 0.26)
      .borderRadius(w * 0.06)
      .backgroundColor(color)
      .position({ x: w * 0.64, y: w * 0.07 })
    Row()
      .width(w * 0.26)
      .height(w * 0.12)
      .borderRadius(w * 0.06)
      .backgroundColor(color)
      .position({ x: w * 0.57, y: w * 0.14 })
  }
  .width(w)
  .height(w)
}

// 齿轮/设置图标（自绘：三条滑块线 + 错落圆钮）
@Builder
function GearGlyph(color: string, w: number) {
  Column({ space: 3 }) {
    Row({ space: 3 }) {
      Circle({ width: 3, height: 3 })
        .fill(color)
      Row()
        .width(w * 0.68)
        .height(1.5)
        .borderRadius(1)
        .backgroundColor(color)
    }
    Row({ space: 3 }) {
      Row()
        .width(w * 0.4)
        .height(1.5)
        .borderRadius(1)
        .backgroundColor(color)
      Circle({ width: 3, height: 3 })
        .fill(color)
    }
    Row({ space: 3 }) {
      Circle({ width: 3, height: 3 })
        .fill(color)
      Row()
        .width(w * 0.56)
        .height(1.5)
        .borderRadius(1)
        .backgroundColor(color)
    }
  }
  .width(w)
  .height(w)
  .justifyContent(FlexAlign.Center)
  .alignItems(HorizontalAlign.Start)
}

// 智能体图标（芯片 + 白点；颜色参数化——侧边栏入口用灰色，胶囊用绿 #2E8B57）
@Builder
function AgentGlyph(color: string, w: number) {
  Stack() {
    Row()
      .width(w * 0.72)
      .height(w * 0.72)
      .borderRadius(w * 0.2)
      .backgroundColor(color)
    Circle({ width: w * 0.3, height: w * 0.3 })
      .fill(Color.White)
  }
  .width(w)
  .height(w)
}

// 项目箭头（双线简约，主题色）：展开=向下 ⌄，收起=向右 ›；两条细杆 ±45° 绕交点旋转拼出
@Builder
function ProjectArrow(open: boolean, color: string) {
  Stack() {
    Row()
      .width(2)
      .height(7)
      .borderRadius(1)
      .backgroundColor(color)
      .position({ x: 3, y: 4 })
      .rotate({ angle: 45, centerX: '50%', centerY: '100%' })
    Row()
      .width(2)
      .height(7)
      .borderRadius(1)
      .backgroundColor(color)
      .position({ x: 3, y: 4 })
      .rotate({ angle: -45, centerX: '50%', centerY: '100%' })
  }
  .width(8) // 与圆点同轴（x=4..12）
  .height(14)
  .rotate({ angle: open ? 0 : -90 }) // 收起态整体旋转为右箭头（动画由父级 animateTo 驱动）
}

// ── 侧边栏（用户极简定案：纯白打底、话题项无背景只文字+圆点、可折叠为竖条轨） ──
// 圆点：选中=强调色（鲜艳）、未选中=淡色，均 100% 不透明；折叠后话题变 50% 不透明竖条
@Component
struct ChatSidebar {
  @Prop sessions: Session[] = []
  @Prop projects: Project[] = []
  @Prop activeSid: string = ''
  @Prop theme: ThemeTokens = THEME_SKY
  @Prop collapsed: boolean = false
  @Prop isLandscape: boolean = true // 竖屏展开宽度收窄 20%（220→176）
  @Prop expandedPids: string = '' // 展开的项目（逗号分隔，持久化）
  @State peekSid: string = '' // 收起态第一步点击：仅展开该话题标题（气泡）；再点同一条才切换
  onToggleCollapse: () => void = () => {
  }
  onNewSession: () => void = () => {
  }
  onNewProject: () => void = () => {
  }
  onSelectSession: (sid: string) => void = () => {
  }
  onToggleProject: (pid: string) => void = () => {
  }
  onLongPressProject: (pid: string) => void = () => {
  }
  onOpenSettings: () => void = () => {
  }
  onOpenAgents: () => void = () => {
  }
  onToggleTheme: () => void = () => {
  }
  onLongPressSession: (sid: string) => void = () => {
  }

  private isExpanded(pid: string): boolean {
    return (',' + this.expandedPids + ',').indexOf(',' + pid + ',') >= 0
  }

  // 扁平列表：项目文件夹（+展开时其下会话缩进）→ 无项目固定分类（灰点，不可收起）
  private buildItems(): SidebarItem[] {
    let items: SidebarItem[] = []
    for (let i = 0; i < this.projects.length; i++) {
      let p = this.projects[i]
      let folder = new SidebarItem()
      folder.kind = 2
      folder.label = p.name
      folder.pid = p.pid
      items.push(folder)
      if (this.isExpanded(p.pid)) {
        for (let j = 0; j < this.sessions.length; j++) {
          if (this.sessions[j].pid === p.pid) {
            let it = new SidebarItem()
            it.kind = 1
            it.label = this.sessions[j].title
            it.sid = this.sessions[j].sid
            it.indent = true
            items.push(it)
          }
        }
      }
    }
    // 无项目分类：有归属为空的话题才显示；固定展开不可收起
    let hasNone = false
    for (let j = 0; j < this.sessions.length; j++) {
      if (this.sessions[j].pid === '') {
        hasNone = true
        break
      }
    }
    if (hasNone) {
      let head = new SidebarItem()
      head.kind = 3
      head.label = '无项目'
      items.push(head)
      for (let j = 0; j < this.sessions.length; j++) {
        if (this.sessions[j].pid === '') {
          let it = new SidebarItem()
          it.kind = 1
          it.label = this.sessions[j].title
          it.sid = this.sessions[j].sid
          it.indent = true
          items.push(it)
        }
      }
    }
    return items
  }

  build() {
    Column() {
      // 顶行：真 logo（avatar.png，两态保留，36×36）+ "酸橙味的信"（仅展开）+
      // 折叠箭头（仅横屏可见；竖屏窄侧边栏会被挤出——整行点击即可展开/收起）
      Row({ space: 8 }) {
        Image($rawfile('avatar.png'))
          .width(36)
          .height(36)
          .borderRadius(10)
        if (!this.collapsed) {
          Text('酸橙味的信')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
        }
        if (this.isLandscape) {
          Text(this.collapsed ? '›' : '‹')
            .fontSize(22)
            .fontColor(this.theme.textSecondary)
            .width(32)
            .height(36)
            .textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .height(40)
      .onClick(() => {
        this.peekSid = ''
        this.onToggleCollapse()
      })
      // 新对话：展开=整行按钮（"+ 新对话"，白底 1px 边框圆角 10，Skill §4.1），
      // 内容左对齐 + 与 logo 同轴；收起=边框与底色渐隐为透明，只剩 +（动画过渡，同轴）
      Row({ space: 6 }) {
        Text('+')
          .fontSize(16)
          .fontColor(this.theme.textSecondary)
        if (!this.collapsed) {
          Text('新对话')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textBody)
        }
      }
      .width(this.collapsed ? 36 : '100%') // 折叠时与 logo 同宽（36），同一中心轴
      .height(36)
      .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
      .padding({ left: this.collapsed ? 0 : 10, right: 0 }) // 展开：+ 在 x=20..36，中心 28 = logo 轴
      .backgroundColor(this.collapsed ? Color.Transparent : Color.White)
      .border({ width: 1, color: this.collapsed ? Color.Transparent : this.theme.borderSubtle })
      .borderRadius(10)
      .margin({ top: 2 })
      .animation({ duration: 200, curve: Curve.EaseOut })
      .onClick(() => {
        this.onNewSession()
      })
      // 新建项目（仅展开态可操作；展开="+"紫色符号，收起=紫色竖条）
      Row({ space: 8 }) {
        if (this.collapsed) {
          Text('')
            .width(4)
            .height(24)
            .borderRadius(2)
            .backgroundColor('#8B5CF6')
            .opacity(0.5)
        } else {
          Text('+')
            .fontSize(16) // 与新对话的 + 同字号
            .fontColor('#8B5CF6') // 紫色 = 项目域颜色（与文件夹分色条下半一致）
            .width(8) // 与圆点同轴（x=4..12，中心 8）
            .textAlign(TextAlign.Center)
        }
        if (!this.collapsed) {
          Text('新建项目')
            .fontSize(14)
            .fontColor(this.theme.textBody)
        }
      }
      .width(this.collapsed ? 36 : '100%')
      .height(32)
      .padding(this.collapsed ? { left: 0, right: 0 } : { left: 4, right: 12 }) // 与会话行同轴
      .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
      .margin({ top: 4 })
      .onClick(() => {
        if (!this.collapsed) {
          this.onNewProject()
        }
      })
      // 话题列表：项目文件夹（分色条）与无项目会话平铺
      List({ space: 2 }) {
        ForEach(this.buildItems(), (item: SidebarItem) => {
          ListItem() {
            if (item.kind === 3) {
              // 无项目固定分类：灰色圆点；不可收起、无点击行为
              Row({ space: 8 }) {
                Text('')
                  .width(this.collapsed ? 4 : 8)
                  .height(this.collapsed ? 24 : 8)
                  .borderRadius(this.collapsed ? 2 : 4)
                  .backgroundColor('#999999')
                  .opacity(this.collapsed ? 0.5 : 1)
                if (!this.collapsed) {
                  Text(item.label)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.theme.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
              }
              .width(this.collapsed ? 36 : '100%')
              .height(32)
              .padding(this.collapsed ? { left: 0, right: 0 } : { left: 4, right: 12 })
              .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
            } else if (item.kind === 2) {
              // 项目文件夹：主题色双线箭头（展开向下/收起向右）+ 名称；点击展开收起
              Row({ space: 8 }) {
                ProjectArrow(this.isExpanded(item.pid), this.theme.accent)
                if (!this.collapsed) {
                  Text(item.label)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.theme.textPrimary)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
              }
              .width(this.collapsed ? 36 : '100%')
              .height(32)
              .padding(this.collapsed ? { left: 0, right: 0 } : { left: 4, right: 12 })
              .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
              .onClick(() => {
                this.onToggleProject(item.pid) // 收起态也可交互：箭头行使展开/收起职能
              })
              .gesture(
                LongPressGesture()
                  .onAction(() => {
                    if (!this.collapsed) {
                      this.onLongPressProject(item.pid)
                    }
                  })
              )
            } else {
              Row({ space: 8 }) {
                Text('')
                  .width(this.collapsed ? 4 : 8)
                  .height(this.collapsed ? 24 : 8)
                  .borderRadius(this.collapsed ? 2 : 4)
                  .backgroundColor(item.sid === this.activeSid ? this.theme.accent : this.theme.accentBorder)
                  .opacity(this.collapsed ? 0.5 : 1)
                  .animation({ duration: 200, curve: Curve.EaseOut })
                if (!this.collapsed) {
                  Text(item.label)
                    .fontSize(14)
                    .fontColor(item.sid === this.activeSid ? this.theme.textPrimary : this.theme.textBody)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
              }
              .width(this.collapsed ? 36 : '100%') // 折叠时与 logo 同轴
              .height(32)
              .padding(this.collapsed ? { left: 0, right: 0 } :
                (item.indent ? { left: 20, right: 12 } : { left: 4, right: 12 })) // 项目内会话缩进
              .justifyContent(this.collapsed ? FlexAlign.Center : FlexAlign.Start)
              .onClick(() => {
                if (this.collapsed) {
                  // 两步交互：第一步点击「丨」仅弹出标题气泡；再点同一条才切换会话
                  if (this.peekSid === item.sid) {
                    this.peekSid = ''
                    this.onSelectSession(item.sid)
                  } else {
                    this.peekSid = item.sid
                  }
                } else {
                  this.onSelectSession(item.sid)
                }
              })
              .bindPopup(this.collapsed && this.peekSid === item.sid, {
                message: item.label,
                placement: Placement.Right,
                targetSpace: 10,
                messageOptions: {
                  textColor: '#1A1A1A',
                  font: { size: 12 }
                }
              })
              .gesture(
                LongPressGesture()
                  .onAction(() => {
                    this.onLongPressSession(item.sid)
                  })
              )
            }
          }
        }, (item: SidebarItem) => item.kind === 2 ?
          'p-' + item.pid + '-' + item.label + '-' + (this.isExpanded(item.pid) ? '1' : '0') :
          (item.kind === 3 ? 'u-none' : 's-' + item.sid + '-' + item.label))
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .margin({ top: 4 })
      // 底行：主题点（左下）+ 智能体/设置（右下，间距紧凑），两态同相对位置
      Row({ space: 2 }) {
        Row({ space: 6 }) {
          Text('')
            .width(10)
            .height(10)
            .borderRadius(5)
            .backgroundColor(this.theme.accent)
          if (!this.collapsed) {
            Text(this.theme.name)
              .fontSize(13)
              .fontColor(this.theme.textSecondary)
          }
        }
        .height(28)
        .onClick(() => {
          this.onToggleTheme()
        })
        Blank()
        // 智能体入口（四角星 + 中心空心 + 卫星小十字；收起侧边栏时隐藏）
        if (!this.collapsed) {
          Row() {
            StarGlyph(this.theme.textSecondary, this.theme.bgSidebar, 18)
          }
          .width(32)
          .height(28)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.onOpenAgents()
          })
        }
        // 设置入口（齿轮：与智能体入口区分）
        Row() {
          GearGlyph(this.theme.textSecondary, 14)
        }
        .width(28)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onOpenSettings()
        })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width(this.collapsed ? 80 : (this.isLandscape ? 220 : 140)) // 展开 220；竖屏(手机) 140
    .height('100%')
    .padding({
      left: 10,
      top: 10,
      bottom: 10,
      right: this.collapsed ? 2 : 10 // 收起时箭头贴交界线
    })
    .alignItems(HorizontalAlign.Start) // 关键：Column 默认居中子项，窄元素会被推离左缘导致轴错位
    .backgroundColor(this.theme.bgSidebar)
    .animation({ duration: 200, curve: Curve.EaseOut })
  }
}

// ── 会话操作对话框（长按会话项弹出：重命名/移动到项目/删除/取消） ──
@CustomDialog
struct SessionActionDialog {
  controller?: CustomDialogController
  title: string = ''
  onRename: () => void = () => {
  }
  onMoveToProject: () => void = () => {
  }
  onDelete: () => void = () => {
  }

  build() {
    Column() {
      Text(this.title.length > 0 ? this.title : '会话操作')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 16 })
      Divider().color('#EEEEEE')
      Text('重命名')
        .fontSize(15)
        .fontColor('#1A1A1A')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onRename()
        })
      Divider().color('#EEEEEE')
      Text('移动到项目')
        .fontSize(15)
        .fontColor('#1A1A1A')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onMoveToProject()
        })
      Divider().color('#EEEEEE')
      Text('删除')
        .fontSize(15)
        .fontColor('#E5484D')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onDelete()
        })
      Divider().color('#EEEEEE')
      Text('取消')
        .fontSize(15)
        .fontColor('#666666')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.controller?.close()
        })
    }
    .width(280)
    .padding({ top: 20, bottom: 8 })
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 项目名称对话框（新建/重命名共用） ──
@CustomDialog
struct ProjectNameDialog {
  controller?: CustomDialogController
  title: string = '新建项目'
  draft: string = ''
  onConfirm: (text: string) => void = () => {
  }
  @State input: string = ''

  aboutToAppear(): void {
    this.input = this.draft
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
        .margin({ bottom: 16 })
      TextInput({ text: this.input, placeholder: '项目名称' })
        .fontSize(15)
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .onChange((v: string) => {
          this.input = v
        })
        .margin({ bottom: 16 })
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor('#666666')
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close()
          })
        Text('确定')
          .fontSize(15)
          .fontColor(Color.White)
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .backgroundColor('#6E9BF2')
          .borderRadius(10)
          .onClick(() => {
            this.onConfirm(this.input.trim())
            this.controller?.close()
          })
      }
      .width('100%')
    }
    .width(280)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 项目操作对话框（长按文件夹：重命名/删除/取消） ──
@CustomDialog
struct ProjectActionDialog {
  controller?: CustomDialogController
  title: string = ''
  onRename: () => void = () => {
  }
  onDelete: () => void = () => {
  }

  build() {
    Column() {
      Text(this.title.length > 0 ? this.title : '项目')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 16 })
      Divider().color('#EEEEEE')
      Text('重命名')
        .fontSize(15)
        .fontColor('#1A1A1A')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onRename()
        })
      Divider().color('#EEEEEE')
      Text('删除项目')
        .fontSize(15)
        .fontColor('#E5484D')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onDelete()
        })
      Divider().color('#EEEEEE')
      Text('取消')
        .fontSize(15)
        .fontColor('#666666')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.controller?.close()
        })
    }
    .width(280)
    .padding({ top: 20, bottom: 8 })
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 对话参数对话框（每对话上下文条数 + 当前智能体人设；安洁莉娜人设锁定只读） ──
@CustomDialog
struct ConvParamDialog {
  controller?: CustomDialogController
  @Prop theme: ThemeTokens = THEME_SKY
  ctxDraft: string = '' // 当前上下文条数（'' = 用全局设置）
  agentName: string = ''
  agentPrompt: string = ''
  locked: boolean = false // 安洁莉娜：人设不可修改
  onSaveCtx: (text: string) => void = () => {
  }
  onSavePrompt: (text: string) => void = () => {
  }
  @State inputCtx: string = ''
  @State inputPrompt: string = ''

  aboutToAppear(): void {
    this.inputCtx = this.ctxDraft
    this.inputPrompt = this.agentPrompt
  }

  build() {
    Column({ space: 12 }) {
      Text('对话参数')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
      Column({ space: 6 }) {
        Text('上下文条数（0 = 用全局设置）').fontSize(12).fontColor('#999999')
        TextInput({ text: this.inputCtx, placeholder: '0' })
          .type(InputType.Number)
          .fontSize(14)
          .height(40)
          .backgroundColor('#F5F5F5')
          .borderRadius(10)
          .onChange((v: string) => {
            this.inputCtx = v
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      Column({ space: 6 }) {
        Row() {
          Text(this.agentName + ' · 人设')
            .fontSize(12)
            .fontColor('#999999')
          Blank()
          if (this.locked) {
            Text('固定不可修改')
              .fontSize(11)
              .fontColor('#999999')
          }
        }
        .width('100%')
        if (this.locked) {
          // 锁定态（安洁莉娜 Skill 包）：只读可滚动完整浏览
          Scroll() {
            Text(this.inputPrompt)
              .fontSize(13)
              .fontColor('#1A1A1A')
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .width('100%')
          .height(220)
          .backgroundColor('#F5F5F5')
          .borderRadius(10)
          .padding(10)
          .scrollBar(BarState.Off)
        } else {
          TextArea({ text: this.inputPrompt })
            .fontSize(13)
            .backgroundColor('#F5F5F5')
            .borderRadius(10)
            .constraintSize({ minHeight: 100, maxHeight: 220 })
            .onChange((v: string) => {
              this.inputPrompt = v
            })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      Row({ space: 10 }) {
        Text('取消')
          .fontSize(15)
          .fontColor('#666666')
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close()
          })
        Text('确定')
          .fontSize(15)
          .fontColor(Color.White)
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .backgroundColor(this.theme.accent)
          .borderRadius(10)
          .onClick(() => {
            this.onSaveCtx(this.inputCtx.trim())
            if (!this.locked) {
              this.onSavePrompt(this.inputPrompt.trim())
            }
            this.controller?.close()
          })
      }
      .width('100%')
    }
    .width(420)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 智能体编辑对话框（新建/编辑共用；编辑态带删除） ──
@CustomDialog
struct AgentEditDialog {
  controller?: CustomDialogController
  @Prop theme: ThemeTokens = THEME_SKY
  @Prop isLandscape: boolean = true
  title: string = '新建智能体'
  draftName: string = ''
  draftPrompt: string = ''
  canDelete: boolean = false
  onConfirm: (name: string, prompt: string) => void = () => {
  }
  onDelete: () => void = () => {
  }
  @State inputName: string = ''
  @State inputPrompt: string = ''

  aboutToAppear(): void {
    this.inputName = this.draftName
    this.inputPrompt = this.draftPrompt
  }

  build() {
    Column({ space: 12 }) {
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
      TextInput({ text: this.inputName, placeholder: '智能体名称' })
        .fontSize(15)
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .onChange((v: string) => {
          this.inputName = v
        })
      TextArea({ text: this.inputPrompt, placeholder: '系统提示词：这个智能体擅长什么、如何回答' })
        .fontSize(14)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .constraintSize(this.isLandscape ?
          { minHeight: 64, maxHeight: 100 } : // 横屏屏幕矮：提示词区收紧，删除/取消/确定按钮必须可见可点
          { minHeight: 100, maxHeight: 260 })
        .onChange((v: string) => {
          this.inputPrompt = v
        })
      Row({ space: 10 }) {
        if (this.canDelete) {
          Text('删除')
            .fontSize(15)
            .fontColor('#E5484D')
            .height(40)
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .onClick(() => {
              this.onDelete()
              this.controller?.close()
            })
        }
        Text('取消')
          .fontSize(15)
          .fontColor('#666666')
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close()
          })
        Text('确定')
          .fontSize(15)
          .fontColor(Color.White)
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .backgroundColor(this.theme.accent)
          .borderRadius(10)
          .onClick(() => {
            this.onConfirm(this.inputName.trim(), this.inputPrompt.trim())
            this.controller?.close()
          })
      }
      .width('100%')
    }
    .width(420)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 智能体管理面板（独立入口：预设/管理智能体，与设置交互逻辑分离） ──
@Component
struct AgentPanel {
  @Prop agents: Agent[] = [] // @Prop：父组件更新后必须同步（普通字段只初始化一次——新建智能体不刷新的根因）
  @Prop activeAid: string = ''
  @Prop theme: ThemeTokens = THEME_SKY
  onClose: () => void = () => {
  }
  onNew: () => void = () => {
  }
  onEdit: (aid: string) => void = () => {
  }
  onSelect: (aid: string) => void = () => {
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.onClose()
        })
      Column({ space: 10 }) {
        Row() {
          Text('智能体')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
          Blank()
          Text('关闭')
            .fontSize(14)
            .fontColor('#666666')
            .onClick(() => {
              this.onClose()
            })
        }
        .width('100%')
        List({ space: 4 }) {
          ForEach(this.agents, (a: Agent) => {
            ListItem() {
              Row({ space: 8 }) {
                Text('')
                  .width(8)
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(this.theme.accent)
                Text(a.name)
                  .fontSize(14)
                  .fontColor(a.aid === this.activeAid ? this.theme.accent : '#1A1A1A')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Text(a.aid === this.activeAid ? '使用中' : '启用')
                  .fontSize(11)
                  .fontColor(this.theme.accent)
                  .padding({ left: 6, right: 6, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.onSelect(a.aid)
                  })
              }
              .width('100%')
              .height(40)
              .padding({ left: 6, right: 6 })
              .onClick(() => {
                this.onEdit(a.aid) // 点击 = 查看/修改名称与提示词
              })
              .gesture(
                LongPressGesture()
                  .onAction(() => {
                    this.onEdit(a.aid)
                  })
              )
            }
          }, (a: Agent) => a.aid)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        Row({ space: 6 }) {
          Text('+')
            .fontSize(16)
            .fontColor(this.theme.accent)
          Text('新建智能体')
            .fontSize(14)
            .fontColor('#1A1A1A')
        }
        .width('100%')
        .height(40)
        .padding({ left: 6 })
        .onClick(() => {
          this.onNew()
        })
      }
      .width('92%')
      .constraintSize({ maxWidth: 460 })
      .height('70%')
      .padding(20)
      .backgroundColor(Color.White)
      .borderRadius(20)
      .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }
}

// ── 项目选择对话框（移动会话用：项目列表 + 无项目 + 取消） ──
@CustomDialog
struct ProjectPickDialog {
  controller?: CustomDialogController
  current: string = ''
  projects: Project[] = []
  onPick: (pid: string) => void = () => {
  }

  build() {
    Column() {
      Text('移动到项目')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
        .margin({ bottom: 12 })
      Divider().color('#EEEEEE')
      Text('无项目')
        .fontSize(14)
        .fontColor(this.current === '' ? '#6E9BF2' : '#1A1A1A')
        .width('100%')
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onPick('')
          this.controller?.close()
        })
      Divider().color('#EEEEEE')
      ForEach(this.projects, (p: Project) => {
        Text(p.name)
          .fontSize(14)
          .fontColor(this.current === p.pid ? '#6E9BF2' : '#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .height(40)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onPick(p.pid)
            this.controller?.close()
          })
      }, (p: Project) => p.pid)
      Divider().color('#EEEEEE')
      Text('取消')
        .fontSize(14)
        .fontColor('#666666')
        .width('100%')
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.controller?.close()
        })
    }
    .width(260)
    .padding({ top: 16, bottom: 8 })
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 会话重命名对话框 ──
@CustomDialog
struct SessionRenameDialog {
  controller?: CustomDialogController
  draft: string = ''
  onConfirm: (text: string) => void = () => {
  }
  @State input: string = ''

  aboutToAppear(): void {
    this.input = this.draft
  }

  build() {
    Column() {
      Text('重命名会话')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
        .margin({ bottom: 16 })
      TextInput({ text: this.input })
        .fontSize(15)
        .height(44)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .onChange((v: string) => {
          this.input = v
        })
        .margin({ bottom: 16 })
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor('#666666')
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close()
          })
        Text('确定')
          .fontSize(15)
          .fontColor(Color.White)
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .backgroundColor('#6E9BF2')
          .borderRadius(10)
          .onClick(() => {
            this.onConfirm(this.input.trim())
            this.controller?.close()
          })
      }
      .width('100%')
    }
    .width(280)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 消息操作对话框（长按消息气泡弹出）：用户=[编辑][编辑并重发][删除]，助手=[编辑][重新生成][删除] ──
@CustomDialog
struct MessageActionDialog {
  controller?: CustomDialogController
  preview: string = ''
  role: string = 'user'
  onEdit: () => void = () => {
  }
  onEditResend: () => void = () => {
  }
  onRegen: () => void = () => {
  }
  onDelete: () => void = () => {
  }
  onCopy: () => void = () => {
  }

  build() {
    Column() {
      Text(this.preview)
        .fontSize(13)
        .fontColor('#666666')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ bottom: 16 })
      Divider().color('#EEEEEE')
      Text('复制')
        .fontSize(15)
        .fontColor('#1A1A1A')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onCopy()
        })
      Divider().color('#EEEEEE')
      Text('编辑')
        .fontSize(15)
        .fontColor('#1A1A1A')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onEdit()
        })
      if (this.role === 'user') {
        Divider().color('#EEEEEE')
        Text('编辑并重发')
          .fontSize(15)
          .fontColor('#1A1A1A')
          .width('100%')
          .height(44)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onEditResend()
          })
      } else {
        Divider().color('#EEEEEE')
        Text('重新生成')
          .fontSize(15)
          .fontColor('#1A1A1A')
          .width('100%')
          .height(44)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.onRegen()
          })
      }
      Divider().color('#EEEEEE')
      Text('删除')
        .fontSize(15)
        .fontColor('#E5484D')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.onDelete()
        })
      Divider().color('#EEEEEE')
      Text('取消')
        .fontSize(15)
        .fontColor('#666666')
        .width('100%')
        .height(44)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.controller?.close()
        })
    }
    .width(280)
    .padding({ top: 20, bottom: 8 })
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 消息编辑对话框（多行输入） ──
@CustomDialog
struct MessageEditDialog {
  controller?: CustomDialogController
  draft: string = ''
  onConfirm: (text: string) => void = () => {
  }
  @State input: string = ''

  aboutToAppear(): void {
    this.input = this.draft
  }

  build() {
    Column() {
      Text('编辑消息')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#1A1A1A')
        .margin({ bottom: 16 })
      TextArea({ text: this.input })
        .fontSize(15)
        .backgroundColor('#F5F5F5')
        .borderRadius(10)
        .constraintSize({ minHeight: 100, maxHeight: 320 })
        .onChange((v: string) => {
          this.input = v
        })
        .margin({ bottom: 16 })
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor('#666666')
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close()
          })
        Text('确定')
          .fontSize(15)
          .fontColor(Color.White)
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .backgroundColor('#6E9BF2')
          .borderRadius(10)
          .onClick(() => {
            this.onConfirm(this.input.trim())
            this.controller?.close()
          })
      }
      .width('100%')
    }
    .width(420)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 删除确认对话框（消息/会话共用：防误触的二级询问） ──
@CustomDialog
struct ConfirmDeleteDialog {
  controller?: CustomDialogController
  title: string = ''
  onConfirm: () => void = () => {
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(15)
        .fontColor('#1A1A1A')
        .lineHeight(22)
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 20 })
      Row() {
        Text('取消')
          .fontSize(15)
          .fontColor('#666666')
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.controller?.close()
          })
        Text('删除')
          .fontSize(15)
          .fontColor(Color.White)
          .height(40)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .backgroundColor('#E5484D')
          .borderRadius(10)
          .onClick(() => {
            this.onConfirm()
          })
      }
      .width('100%')
    }
    .width(300)
    .padding(20)
    .backgroundColor(Color.White)
    .borderRadius(16)
  }
}

// ── 主区域（Skill §4.2-4.4：Hero 偏上 38-42%、消息列表 max-w 768、Composer 唯一阴影） ──
@Component
struct ChatMain {
  @Link chatInput: string
  @Prop messages: ChatMsg[] = []
  private isPhone: boolean = deviceInfo.deviceType === 'phone' // 手机/平板差异化
  @Prop @Watch('onMsgVersion') msgVersion: number = 0 // 消息列表整体替换时变化：ForEach key 带上它，杜绝跨会话复用旧组件
  @Prop @Watch('onStream') streamingText: string = ''
  @Prop streamingReason: string = '' // 思考过程（流式显示）
  @Prop @Watch('onMessages') isStreaming: boolean = false
  @Prop theme: ThemeTokens = THEME_SKY
  @State atBottom: boolean = true // 置底跟随（Chatbox 式：用户上滑打破后不跟随）
  @State streamReasonOpen: boolean = true // 流式思考默认展开
  @State histReasonIdx: number = -1 // 历史消息中展开思考的那条（-1=全折叠）
  @Prop collapsed: boolean = false
  @Prop isLandscape: boolean = true // 竖屏时内容列自适应填满（768 定宽仅限横屏收起态）
  onSend: () => void = () => {
  }
  onStop: () => void = () => {
  }
  onLongPressMsg: (idx: number) => void = () => {
  }
  @Prop branches: RailBranch[][] = [] // 每轮分支信息（与活跃路径轮次对齐）
  onSwitchBranch: (anchorRound: number, childNid: string) => void = () => {
  }
  @Prop projects: Project[] = []
  @Prop projectPid: string = '' // 新建会话归属项目（''=无项目）
  onSelectProject: (pid: string) => void = () => {
  }
  @State projectPickerShow: boolean = false
  @State agentPickerShow: boolean = false
  @Prop agents: Agent[] = [] // 智能体列表
  @Prop agentAid: string = '' // 活跃智能体（''=默认智能体「安洁莉娜」）
  @Prop agentName: string = '安洁莉娜'
  @Prop composerPlaceholder: string = '与安洁莉娜对话…'
  @Prop sessionTitle: string = '' // 当前话题标题（点击可直接重命名）
  onRenameTopic: () => void = () => {
  }
  onSelectAgent: (aid: string) => void = () => {
  }
  onManageAgents: () => void = () => {
  }
  onConvParams: () => void = () => {
  }
  // ── 搜索模式（输入框内切换；结果从输入框上方拉起） ──
  @State searchMode: boolean = false
  @Prop searchResults: SearchResult[] = []
  @Prop playerName: string = '博士' // 用户消息发送者名（设置里的称呼）
  onSearchQuery: (text: string) => void = () => {
  }
  onPickSearchResult: (r: SearchResult) => void = () => {
  }

  // 命中内容的发送者：用户消息=自定义称呼，LLM 消息=智能体名
  private senderOf(r: SearchResult): string {
    return r.kind === 1 ? this.playerName : this.agentName
  }
  @Prop @Watch('onScrollCmd') scrollCmd: number = 0
  @Prop scrollRound: number = 0

  onScrollCmd(): void {
    if (this.scrollCmd > 0) {
      this.jumpToRound(this.scrollRound)
    }
  }

  // 新内容/流式增量到达：置底状态跟随滚动
  onStream(): void {
    this.followBottom()
  }

  onMessages(): void {
    this.followBottom()
  }

  private followBottom(): void {
    if (!this.atBottom) {
      return
    }
    // 延迟出渲染阶段（@Watch 回调里直接滚会崩）+ 兜底保护
    setTimeout(() => {
      try {
        this.listCtl.scrollEdge(Edge.Bottom)
      } catch (e) {
      }
    }, 0)
  }

  private projectLabel(): string {
    if (this.projectPid === '') {
      return '无项目'
    }
    for (let i = 0; i < this.projects.length; i++) {
      if (this.projects[i].pid === this.projectPid) {
        return this.projects[i].name
      }
    }
    return '无项目'
  }

  // 智能体选择弹窗：默认智能体（安洁莉娜）+ 各智能体 + 管理入口
  @Builder
  agentPicker() {
    Column({ space: 0 }) {
      Text('安洁莉娜')
        .fontSize(13)
        .fontColor(this.agentAid === '' ? this.theme.accent : '#1A1A1A')
        .width('100%')
        .height(36)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.agentPickerShow = false
          this.onSelectAgent('')
        })
      Divider().color('#EEEEEE')
      Text('陌生的友人')
        .fontSize(13)
        .fontColor(this.agentAid === '~raw' ? this.theme.accent : '#1A1A1A')
        .width('100%')
        .height(36)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.agentPickerShow = false
          this.onSelectAgent('~raw')
        })
      Divider().color('#EEEEEE')
      Text('管理智能体')
        .fontSize(13)
        .fontColor('#666666')
        .width('100%')
        .height(36)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.agentPickerShow = false
          this.onManageAgents()
        })
    }
    .width(180)
    .padding({ top: 6, bottom: 6 })
    .backgroundColor(Color.White)
    .borderRadius(10)
    .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 4 })
  }

  @Builder
  projectPicker() {
    Column({ space: 0 }) {
      Text('无项目')
        .fontSize(13)
        .fontColor(this.projectPid === '' ? this.theme.accent : '#1A1A1A')
        .width('100%')
        .height(36)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.projectPickerShow = false
          this.onSelectProject('')
        })
      Divider().color('#EEEEEE')
      ForEach(this.projects, (p: Project) => {
        Text(p.name)
          .fontSize(13)
          .fontColor(this.projectPid === p.pid ? this.theme.accent : '#1A1A1A')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.projectPickerShow = false
            this.onSelectProject(p.pid)
          })
      }, (p: Project) => p.pid)
    }
    .width(180)
    .padding({ top: 6, bottom: 6 })
    .backgroundColor(Color.White)
    .borderRadius(10)
    .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 4 })
  }
  // ── 导航轨可见性追踪：列表项 onAreaChange 汇报位置，集合变化才刷新（不随滚动逐帧重建） ──
  @State visSet: string = '' // 当前视口内可见的轮次下标（逗号分隔）
  @State visMin: number = 0 // 可见轮次最小值（导航轨窗口锚点）
  @State visMax: number = 0 // 可见轮次最大值（窗口居中锚定用）
  @State visVersion: number = 0
  private visRoundSet: Set<number> = new Set()
  private listCtl: Scroller = new Scroller()

  // 一轮 = 用户输入 + 紧跟其后的助手回复；缺失一侧则单条成轮（含孤立助手消息）
  private buildRounds(): ChatMsg[][] {
    let out: ChatMsg[][] = []
    for (let i = 0; i < this.messages.length; i++) {
      let m = this.messages[i]
      if (m.role === 'user') {
        let pair: ChatMsg[] = [m]
        if (i + 1 < this.messages.length && this.messages[i + 1].role === 'assistant') {
          pair.push(this.messages[i + 1])
          i++
        }
        out.push(pair)
      } else {
        out.push([m])
      }
    }
    return out
  }

  // 消息下标 → 轮次下标（与 buildRounds 同一配对规则）
  private roundIndexOf(msgIdx: number): number {
    // 越界防护：列表重建后旧可见性回调带着旧下标触发（否则访问 undefined.role → TypeError 闪退）
    if (msgIdx < 0 || msgIdx >= this.messages.length) {
      return -1
    }
    let r = -1
    for (let i = 0; i <= msgIdx; i++) {
      if (this.messages[i].role === 'user') {
        r++
        if (i + 1 <= msgIdx && i + 1 < this.messages.length && this.messages[i + 1].role === 'assistant') {
          i++
        }
      } else {
        r++
      }
    }
    return r
  }

  // 轮次下标 → 该轮首条消息下标（悬浮窗跳转用）
  private firstMsgOfRound(r: number): number {
    let cur = -1
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].role === 'user') {
        cur++
        if (cur === r) {
          return i
        }
        if (i + 1 < this.messages.length && this.messages[i + 1].role === 'assistant') {
          i++
        }
      } else {
        cur++
        if (cur === r) {
          return i
        }
      }
    }
    return -1
  }

  // 悬浮窗点击：滚动到该轮对话
  private jumpToRound(r: number): void {
    let idx = this.firstMsgOfRound(r)
    if (idx >= 0) {
      this.listCtl.scrollToIndex(idx, true, ScrollAlign.START)
    }
  }

  private pushVisState(): void {
    let arr: number[] = []
    this.visRoundSet.forEach((v: number) => {
      arr.push(v)
    })
    arr.sort((a: number, b: number) => a - b)
    this.visSet = arr.join(',')
    this.visMin = arr.length > 0 ? arr[0] : 0
    this.visMax = arr.length > 0 ? arr[arr.length - 1] : 0
    this.visVersion++
  }

  // onVisibleAreaChange 回调：滚动时可靠触发（onAreaChange 在 List 滚动中不更新——高亮不稳定的根因）
  private trackVis(msgIdx: number, isVisible: boolean): void {
    let r = this.roundIndexOf(msgIdx)
    if (r < 0) {
      return
    }
    let had = this.visRoundSet.has(r)
    if (isVisible && !had) {
      this.visRoundSet.add(r)
      this.pushVisState()
    } else if (!isVisible && had) {
      this.visRoundSet.delete(r)
      this.pushVisState()
    }
  }

  onMsgVersion(): void {
    // 会话切换：清空可见性（消息整体替换，旧轮次下标作废）
    this.visRoundSet.clear()
    this.visSet = ''
    this.visMin = 0
    this.visMax = 0
    this.visVersion++
  }

  build() {
    Column() {
      // 居中包装：内容列限宽 768（仅横屏收起态）——其余情况自适应填满主区（竖屏不再溢出）
      Row() {
        if (!this.isPhone && this.collapsed && this.isLandscape) {
          Blank().width(52) // 补偿右侧导航轨宽度：内容列保持精确居中（仅平板）
        }
        Column() {
      // 话题标题（点击直接在对话界面重命名）
      if (this.sessionTitle.length > 0) {
        Row() {
          Text(this.sessionTitle)
            .fontSize(13)
            .fontColor(this.theme.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 2, bottom: 6 })
        .onClick(() => {
          this.onRenameTopic()
        })
      }
      if (this.messages.length === 0 && !this.isStreaming) {
        // Hero 空状态：垂直偏上（上垫 0.72 / 下垫 1.28 ≈ 36% 处）
        Column() {
          Blank().layoutWeight(0.72)
          Column({ space: 24 }) {
            Row({ space: 10 }) {
              Text('予')
                .width(36)
                .height(36)
                .fontSize(17)
                .fontColor(Color.White)
                .backgroundColor(this.theme.accent)
                .borderRadius(10)
                .textAlign(TextAlign.Center)
              Text('安洁莉娜的来信')
                .fontSize(24)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.textPrimary)
            }
            Text('给芋圆写一封信吧，她会认真读完的')
              .fontSize(14)
              .fontColor(this.theme.textSecondary)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          Blank().layoutWeight(1.28)
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        // 消息列表（Skill §4.4：间距 24、用户气泡 max 75%、助手无气泡配 logo 前缀）
        List({ space: 24, scroller: this.listCtl }) {
          ForEach(this.messages, (m: ChatMsg, idx: number) => {
            ListItem() {
              if (m.role === 'user') {
                Row() {
                  Text(m.content)
                    .fontSize(15)
                    .fontColor(this.theme.textBody)
                    .lineHeight(24)
                    .backgroundColor(this.theme.bubbleUser)
                    .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 6 })
                    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                    .constraintSize({ maxWidth: '75%' })
                }
                .width('100%')
                .justifyContent(FlexAlign.End)
                .gesture(
                  LongPressGesture()
                    .onAction(() => {
                      this.onLongPressMsg(idx)
                    })
                )
              } else {
                Row() {
                  Text('予')
                    .width(16)
                    .height(16)
                    .fontSize(9)
                    .fontColor(this.theme.accent)
                    .backgroundColor(this.theme.accentSoft)
                    .borderRadius(4)
                    .textAlign(TextAlign.Center)
                    .margin({ right: 8, top: 4 })
                  Column({ space: 4 }) {
                    if (m.reason !== undefined && m.reason.length > 0) {
                      Row({ space: 4 }) {
                        Text(this.histReasonIdx === idx ? '▾' : '▸')
                          .fontSize(11)
                          .fontColor(this.theme.textTertiary)
                        Text('思考过程')
                          .fontSize(11)
                          .fontColor(this.theme.textTertiary)
                      }
                      .onClick(() => {
                        this.histReasonIdx = this.histReasonIdx === idx ? -1 : idx
                      })
                      if (this.histReasonIdx === idx) {
                        Text(m.reason)
                          .fontSize(12)
                          .fontColor(this.theme.textTertiary)
                          .lineHeight(18)
                          .width('100%')
                      }
                    }
                    MarkdownView({
                      text: m.content,
                      fontColor: this.theme.textBody,
                      baseSize: 15
                    })
                  }
                    .layoutWeight(1) // 占 logo 外的剩余宽度：不加则按整行宽换行，右缘被裁 ~24vp（1.5 字）
                    .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .gesture(
                  LongPressGesture()
                    .onAction(() => {
                      this.onLongPressMsg(idx)
                    })
                )
              }
            }
            .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
              try {
                if (idx < this.messages.length) {
                  this.trackVis(idx, isVisible)
                  if (idx === this.messages.length - 1) {
                    this.atBottom = currentRatio >= 0.98
                  }
                }
              } catch (e) {
              }
            })
          }, (m: ChatMsg, idx: number) => this.msgVersion.toString() + '-' + idx.toString() + '-' + m.role)
          if (this.isStreaming) {
            ListItem() {
              Row() {
                Text('予')
                  .width(16)
                  .height(16)
                  .fontSize(9)
                  .fontColor(this.theme.accent)
                  .backgroundColor(this.theme.accentSoft)
                  .borderRadius(4)
                  .textAlign(TextAlign.Center)
                  .margin({ right: 8, top: 4 })
                Column({ space: 6 }) {
                  if (this.streamingReason.length > 0) {
                    Row({ space: 4 }) {
                      Text(this.streamReasonOpen ? '▾' : '▸')
                        .fontSize(11)
                        .fontColor(this.theme.textTertiary)
                      Text('思考过程')
                        .fontSize(11)
                        .fontColor(this.theme.textTertiary)
                    }
                    .onClick(() => {
                      this.streamReasonOpen = !this.streamReasonOpen
                    })
                    if (this.streamReasonOpen) {
                      Text(this.streamingReason)
                        .fontSize(12)
                        .fontColor(this.theme.textTertiary)
                        .lineHeight(18)
                        .width('100%')
                    }
                  }
                  Text(this.streamingText.length > 0 ? this.streamingText : '···')
                    .fontSize(15)
                    .fontColor(this.theme.textBody)
                    .lineHeight(24)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }
            .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
              try {
                this.atBottom = currentRatio >= 0.98
              } catch (e) {
              }
            })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      // 搜索结果（搜索模式下从输入框上方拉起）
      if (this.searchMode) {
        Column() {
          if (this.chatInput.trim().length > 0 && this.searchResults.length === 0) {
            Text('无匹配结果')
              .fontSize(13)
              .fontColor(this.theme.textTertiary)
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 12, bottom: 12 })
          }
          List({ space: 0 }) {
            ForEach(this.searchResults, (r: SearchResult, idx: number) => {
              ListItem() {
                Row() {
                  Text(this.senderOf(r) + '：')
                    .fontSize(11)
                    .fontColor(r.kind === 1 ? this.theme.accent : this.theme.textTertiary)
                  Text(r.snippet)
                    .fontSize(13)
                    .fontColor(this.theme.textBody)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .padding({ top: 8, bottom: 8, left: 4, right: 4 })
                .onClick(() => {
                  this.chatInput = ''
                  this.searchMode = false
                  this.onPickSearchResult(r)
                })
              }
            }, (r: SearchResult, idx: number) => r.sid + '-' + r.nid + '-' + r.kind.toString() + '-' + idx.toString())
          }
          .width('100%')
          .constraintSize({ maxHeight: 220 })
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .padding({ left: 6, right: 6, top: 6, bottom: 6 })
        .backgroundColor(Color.White)
        .borderRadius(12)
        .shadow({ radius: 16, color: '#22000000', offsetX: 0, offsetY: 4 })
        .margin({ bottom: 10 })
      }
      // 输入卡片 Composer（横屏高度收窄 50%，竖屏全宽全高）+ 左上角外侧智能体圆点
      Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // 项目胶囊：显示当前归属；点击弹出项目列表（手机横屏空间紧张时隐藏）
        if (!(this.isPhone && this.isLandscape)) {
        Row({ space: 4 }) {
          FolderGlyph(this.theme.accent, 14)
          Text(this.projectLabel())
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Blank()
        }
        .width('100%')
        .bindPopup(this.projectPickerShow, {
          builder: () => {
            this.projectPicker()
          },
          placement: Placement.Top,
          targetSpace: 8
        })
        .onClick(() => {
          this.projectPickerShow = !this.projectPickerShow
          this.agentPickerShow = false
        })
        .padding({ bottom: 6 })
        }
        TextArea({ text: this.chatInput, placeholder: this.searchMode ? '搜索对话…' : this.composerPlaceholder })
          .fontSize(15)
          .fontColor(this.theme.textPrimary)
          .backgroundColor(Color.Transparent)
          .constraintSize(this.isPhone && this.isLandscape ?
            { minHeight: 26, maxHeight: 70 } : // 手机横屏 -50%
            (this.isLandscape ?
              { minHeight: 52, maxHeight: 140 } : // 平板横屏正常
              { minHeight: 40, maxHeight: 105 })) // 竖屏 -25%
          .onChange((v: string) => {
            this.chatInput = v
            if (this.searchMode) {
              this.onSearchQuery(v)
            }
          })
          .onSubmit(() => {
            if (!this.searchMode) {
              this.onSend()
            }
          })
        Row({ space: 4 }) {
          Blank()
          // 放大镜：搜索模式开关（点击展开为搜索输入框；位于发送按钮左侧）
          Row() {
            // 放大镜（内联绘制：颜色直接绑状态表达式——@Builder 参数在部分更新下不刷新）
            Stack({ alignContent: Alignment.TopStart }) {
              Circle({ width: 10, height: 10 })
                .fillOpacity(0)
                .stroke(this.searchMode ? this.theme.accent : this.theme.textSecondary)
                .strokeWidth(1.6)
                .position({ x: 1, y: 1 })
              Row()
                .width(1.6)
                .height(5.5)
                .borderRadius(1)
                .backgroundColor(this.searchMode ? this.theme.accent : this.theme.textSecondary)
                .rotate({ angle: 45 })
                .position({ x: 9, y: 9 })
            }
            .width(16)
            .height(16)
          }
          .width(32)
          .height(32)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.searchMode = !this.searchMode
            if (!this.searchMode) {
              this.chatInput = ''
              this.onSearchQuery('')
            } else {
              this.onSearchQuery(this.chatInput)
            }
          })
          if (!this.searchMode && !this.isStreaming) {
            // 发送按钮（Skill §4.3：32px 圆形；空输入浅色禁态、有输入实色）
            Text('↑')
              .width(32)
              .height(32)
              .fontSize(16)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .borderRadius(999)
              .backgroundColor(this.chatInput.trim().length > 0 ? this.theme.accent : this.theme.sendIdle)
              .onClick(() => {
                this.onSend()
              })
          } else if (!this.searchMode && this.isStreaming) {
            // 停止生成键（生成中取代发送键）
            Text('■')
              .width(32)
              .height(32)
              .fontSize(12)
              .fontColor(Color.White)
              .textAlign(TextAlign.Center)
              .borderRadius(999)
              .backgroundColor('#E5484D')
              .onClick(() => {
                this.onStop()
              })
          } else {
            // 退出搜索键：占据发送键位置（布局不跳动，放大镜不动）
            Text('✕')
              .width(32)
              .height(32)
              .fontSize(13)
              .fontColor(this.theme.textSecondary)
              .textAlign(TextAlign.Center)
              .borderRadius(999)
              .backgroundColor(this.theme.bgHover)
              .onClick(() => {
                this.searchMode = false
                this.chatInput = ''
                this.onSearchQuery('')
              })
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding(this.isPhone && this.isLandscape ?
        { left: 10, right: 6, top: 4, bottom: 4 } : // 手机横屏：整体收紧
        (this.isLandscape ?
          { left: 16, right: 10, top: 12, bottom: 10 } :
          { left: 10, right: 6, top: 10, bottom: 8 })) // 竖屏收紧：输入框更宽
      .backgroundColor(Color.White)
      .border({ width: 1, color: this.theme.borderSubtle })
      .borderRadius(20)
      .shadow({ radius: 32, color: '#141F2329', offsetX: 0, offsetY: 12 })
      // 智能体圆点：在输入框外、项目选择按钮的正左侧，高度与项目按钮一致（主题色；32×32 大判定范围）
      Row() {
        Row()
          .width(12)
          .height(12)
          .borderRadius(6)
          .backgroundColor(this.theme.accent)
      }
      .width(32)
      .height(32)
      .justifyContent(FlexAlign.Center)
      .position({ x: -28, y: (this.isPhone && this.isLandscape ? 4 : (this.isLandscape ? 12 : 10)) - 9 }) // 与胶囊行同高（手机横屏胶囊行隐藏，贴顶）
      .bindPopup(this.agentPickerShow, {
        builder: () => {
          this.agentPicker()
        },
        placement: Placement.Top,
        targetSpace: 8
      })
      .onClick(() => {
        this.projectPickerShow = false
        if (this.sessionTitle.length > 0) {
          // 已有对话：直接打开对话参数（Chatbox 式）
          this.onConvParams()
        } else {
          // 未开对话：弹三选一（安洁莉娜/陌生的友人/管理智能体）
          this.agentPickerShow = !this.agentPickerShow
        }
      })
      }
        }
        .width(!this.isPhone && this.collapsed && this.isLandscape ? 768 : '100%') // 768 定宽仅限平板横屏收起居中
        .layoutWeight(!this.isPhone && this.collapsed && this.isLandscape ? 0 : 1)
        .height('100%')
        // ── 对话导航轨（Codex 导航轨触屏版）：一轮一根横条，手指位置按正态分布伸缩 ──
        if (this.isLandscape) {
          ConversationRail({
            rounds: this.buildRounds(),
            branches: this.branches,
            visSet: this.visSet,
            visMin: this.visMin,
            visMax: this.visMax,
            onJumpRound: (r: number): void => {
              this.jumpToRound(r)
            },
            onSwitchBranch: (r: number, nid: string): void => {
              this.onSwitchBranch(r, nid)
            }
          })
            .width(52)
            .height('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1) // 占满侧边栏以外的剩余空间（width('100%') 会溢出垫到侧边栏下面，居中错位）
    .height('100%')
    .padding(this.isLandscape ?
      { left: 24, right: 24, top: 20, bottom: 20 } :
      { left: 10, right: 10, top: 16, bottom: 16 }) // 竖屏(手机)收紧边距：输入框更宽
    .backgroundColor(this.theme.bgMain)
  }
}

// 导航轨分支信息（与活跃路径轮次一一对应）：{nid, user, active}
interface RailBranch {
  nid: string
  user: string
  active: boolean
}

// ── 对话导航轨（灵感：Codex 导航轨；触屏版：一轮一根横条，右侧垂直居中） ──
// 手指划过：最近横条变长，周围按正态分布跟随；聚焦时左侧弹出浮窗（加粗用户行 + LLM 三行）。
// 视口内可见轮次黄色高亮；条数上限 32，窗口锚定可见区。
// 对话树标记：分支≥2 的轮次横条右侧加圆点，≥3 加数字；浮窗内列出分支可点击切换
@Component
struct ConversationRail {
  @Prop rounds: ChatMsg[][] = []
  @Prop branches: RailBranch[][] = [] // 每轮的分支列表（长度≥2 = 对话树锚点）
  @Prop visSet: string = '' // 可见轮次下标（逗号分隔）
  @Prop visMin: number = 0 // 可见轮次最小值
  @Prop visMax: number = 0 // 可见轮次最大值（窗口居中锚定）
  onJumpRound: (r: number) => void = () => {
  }
  onSwitchBranch: (anchorRound: number, childNid: string) => void = () => {
  }
  @State focusIdx: number = -1
  @State railH: number = 0
  private pitch: number = 20 // 每轮占高（8 条高 + 上下 6 边距）——空隙 12vp 便于点按
  private touchCancelled: boolean = false // 本次触摸已取消聚焦：Up 前忽略 Move（防手指微动重新聚焦）

  // 条数上限：固定 32 轮（用户定案，不要太挤）；小窗口仍按轨高收缩，最少 8
  private cap(): number {
    return Math.min(32, Math.max(8, Math.floor(this.railH / this.pitch) - 2))
  }

  // 显示窗口：以屏幕可见区为中心（可见轮次在横条中居中高亮）；话题顶部/底部时自然贴边
  private windowStart(total: number): number {
    let c = this.cap()
    if (total <= c) {
      return 0
    }
    let center = Math.floor((this.visMin + this.visMax) / 2)
    let start = center - Math.floor(c / 2)
    if (start < 0) {
      start = 0
    }
    if (start > total - c) {
      start = total - c
    }
    return start
  }

  private shownCount(total: number): number {
    return Math.min(total, this.cap())
  }

  private isVisible(g: number): boolean {
    return (',' + this.visSet + ',').indexOf(',' + g + ',') >= 0
  }

  // 条长：聚焦处最长（40vp），两侧按高斯衰减到基准 12vp。
  // 焦点落在带分支标记轮 ±1 范围内时压低整个高斯振幅（上限 30vp），
  // 保证「聚焦条最长、向两侧依次递减」且圆点/数字有位置不溢出屏幕（与安卓版同语义）
  private barMarkWidth(g: number): number {
    if (this.focusIdx < 0) {
      return 12
    }
    let d = g - this.focusIdx
    let nearMarked = false
    let lo = Math.max(0, this.focusIdx - 1)
    let hi = Math.min(this.rounds.length - 1, this.focusIdx + 1)
    for (let i = lo; i <= hi; i++) {
      if (this.branches.length > i && this.branches[i].length >= 2) {
        nearMarked = true
        break
      }
    }
    let amp = nearMarked ? 18 : 28
    return 12 + amp * Math.exp(-(d * d) / 12.5)
  }

  // 该轮的 LLM 输出文本（缺失返回空串——不显示占位）
  private replyOf(r: ChatMsg[]): string {
    return r[0].role === 'user' ? (r.length > 1 ? r[1].content : '') : r[0].content
  }

  @Builder
  roundPreview(r: ChatMsg[], g: number) {
    Column({ space: 4 }) {
      // 用户输入：加粗单行；该侧缺失则不显示
      if (r[0].role === 'user') {
        Text(r[0].content)
          .fontSize(12)
          .fontColor('#1A1A1A')
          .fontWeight(FontWeight.Bold)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // LLM 输出：三行；该侧缺失则不显示
      if (this.replyOf(r).length > 0) {
        Text(this.replyOf(r))
          .fontSize(12)
          .fontColor('#555555')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      // 对话树锚点：列出全部分支（当前分支高亮），点击切换
      if (this.branches.length > g && this.branches[g].length >= 2) {
        Divider().color('#EEEEEE')
          .margin({ top: 4, bottom: 4 })
        ForEach(this.branches[g], (b: RailBranch) => {
          Text(b.user.length > 0 ? b.user : '（无输入）')
            .fontSize(12)
            .fontColor(b.active ? '#6E9BF2' : '#555555')
            .fontWeight(b.active ? FontWeight.Medium : FontWeight.Normal)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ top: 3, bottom: 3 })
            .onClick(() => {
              this.focusIdx = -1
              this.onSwitchBranch(g, b.nid)
            })
        }, (b: RailBranch) => b.nid)
      }
      Text('点击跳转至此轮')
        .fontSize(10)
        .fontColor('#999999')
    }
    .width(240)
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .backgroundColor(Color.White)
    .borderRadius(10)
    .shadow({ radius: 16, color: '#33000000', offsetX: 0, offsetY: 4 })
    .onClick(() => {
      this.focusIdx = -1 // 跳转即取消加长：横条恢复原样、悬浮窗随之消失
      this.onJumpRound(g)
    })
  }

  build() {
    Column() {
      ForEach(this.rounds.slice(this.windowStart(this.rounds.length)), (r: ChatMsg[], j: number) => {
        // 固定 48 宽容器：横条始终居中——圆点/数字绝对定位在横条右缘外，不挤动横条位置
        Stack({ alignContent: Alignment.Center }) {
          Row()
            .width(this.barMarkWidth(this.windowStart(this.rounds.length) + j))
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.focusIdx === this.windowStart(this.rounds.length) + j ? '#6E9BF2' :
              (this.isVisible(this.windowStart(this.rounds.length) + j) ? '#F0B400' : '#661F2329'))
            .animation({ duration: 120, curve: Curve.EaseOut })
          // 对话树标记：分支≥2 圆点（直径=横条粗细 8vp），≥3 圆点+数字（挂在横条右缘外）
          if (this.branches.length > this.windowStart(this.rounds.length) + j &&
            this.branches[this.windowStart(this.rounds.length) + j].length >= 2) {
            Row({ space: 3 }) {
              Circle({ width: 8, height: 8 })
                .fill('#6E9BF2')
              if (this.branches[this.windowStart(this.rounds.length) + j].length >= 3) {
                Text(this.branches[this.windowStart(this.rounds.length) + j].length.toString())
                  .fontSize(11)
                  .fontColor('#6E9BF2')
              }
            }
            .height(20)
            .alignItems(VerticalAlign.Center)
            .position({
              x: 24 + this.barMarkWidth(this.windowStart(this.rounds.length) + j) / 2 + 6,
              y: 0
            })
          }
        }
        .width(48)
        .height(20)
        .bindPopup(this.focusIdx === this.windowStart(this.rounds.length) + j, {
          builder: () => {
            this.roundPreview(r, this.windowStart(this.rounds.length) + j)
          },
          placement: Placement.Left,
          targetSpace: 12
        })
      }, (r: ChatMsg[], j: number) => (this.windowStart(this.rounds.length) + j).toString() + '-' +
        r[0].content.substring(0, 12))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center) // 条区整体右侧垂直居中
    .onAreaChange((old: Area, area: Area) => {
      this.railH = Number(area.height)
    })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        let total = this.rounds.length
        if (total === 0 || this.railH <= 0 || e.touches.length === 0) {
          return
        }
        let start = this.windowStart(total)
        let shown = this.shownCount(total)
        let y = e.touches[0].y as number
        let used = Math.min(shown * this.pitch, this.railH)
        let topOffset = (this.railH - used) / 2
        let yIn = y - topOffset
        if (yIn < 0 || yIn > used) {
          this.focusIdx = -1 // 点横条区外的空白：取消加长（不锁 Move——从空白滑入条区仍可聚焦）
          return
        }
        let idx = start + Math.max(0, Math.min(shown - 1, Math.floor(yIn / this.pitch)))
        if (this.focusIdx === idx) {
          this.focusIdx = -1 // 再点同一条：双击取消（悬浮窗消失 + 横条变短同步）
          this.touchCancelled = true // 手指微动的 Move 不再重新聚焦，Up 时复位
          return
        }
        this.touchCancelled = false
        this.focusIdx = idx
      } else if (e.type === TouchType.Move && !this.touchCancelled) {
        let total = this.rounds.length
        if (total === 0 || this.railH <= 0 || e.touches.length === 0) {
          return
        }
        let start = this.windowStart(total)
        let shown = this.shownCount(total)
        let y = e.touches[0].y as number
        let used = Math.min(shown * this.pitch, this.railH)
        let topOffset = (this.railH - used) / 2
        let yIn = y - topOffset
        if (yIn < 0 || yIn > used) {
          this.focusIdx = -1 // 划出条区：取消加长（划回则重新聚焦）
          return
        }
        let idx = start + Math.max(0, Math.min(shown - 1, Math.floor(yIn / this.pitch)))
        this.focusIdx = idx
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.touchCancelled = false
      }
    })
  }
}

// 聊天设置面板：API Key/接口/模型/称呼/上下文/时间感知/额外提示词。
// 草稿态编辑，保存才落盘（ChatStore.saveSettings）；每次打开从当前设置初始化。
@Component
struct SettingsPanel {
  settings: ChatSettings = ChatStore.DEFAULT_SETTINGS
  @Prop theme: ThemeTokens = THEME_SKY
  onSave: (s: ChatSettings) => void = () => {
  }
  onClose: () => void = () => {
  }
  @State draftKey: string = ''
  @State draftUrl: string = ''
  @State draftModel: string = ''
  @State draftName: string = ''
  @State draftCtx: string = '20'
  @State draftTime: boolean = true
  @State draftExtra: string = ''
  @State draftChatter: string = '中频'
  @State draftVoice: boolean = true
  @State draftVoiceLang: string = '中文'
  @State testing: boolean = false
  @State testResult: string = ''
  @State testOk: boolean = false
  private testApi: ChatApi = new ChatApi()

  aboutToAppear(): void {
    this.draftKey = this.settings.chat_api_key
    this.draftUrl = this.settings.chat_base_url
    this.draftModel = this.settings.chat_model
    this.draftName = this.settings.player_name
    this.draftCtx = this.settings.context_window_size.toString()
    this.draftTime = this.settings.time_awareness
    this.draftExtra = this.settings.extra_prompt
    this.draftChatter = this.settings.chatter_interval
    this.draftVoice = this.settings.voice_enabled
    this.draftVoiceLang = this.settings.voice_language
  }

  // 测试连接：用表单当前值发一条最小请求（max_tokens 8），验证 key/地址/模型
  private runTest(): void {
    let url = this.draftUrl.trim()
    let key = this.draftKey.trim()
    let model = this.draftModel.trim()
    if (key.length === 0) {
      this.testOk = false
      this.testResult = '请先填写 API Key'
      return
    }
    if (url.length === 0) {
      this.testOk = false
      this.testResult = '请先填写接口地址'
      return
    }
    if (model.length === 0) {
      this.testOk = false
      this.testResult = '请先填写模型名'
      return
    }
    this.testing = true
    this.testResult = ''
    this.testApi.test(url, key, model, {
      onDelta: (t: string) => {
      },
      onReason: (t: string) => {
      },
      onDone: (full: string) => {
        this.testing = false
        this.testOk = true
        try {
          let obj: Record<string, Object> = JSON.parse(full) as Record<string, Object>
          let choices = obj['choices'] as Array<Record<string, Object>>
          let msg = choices[0]['message'] as Record<string, Object>
          let c = msg['content'] as string
          if (c !== undefined && c.length > 0) {
            this.testResult = '连接成功：' + c
            return
          }
        } catch (e) {
          // 落到通用成功提示
        }
        this.testResult = '连接成功'
      },
      onError: (e: string) => {
        this.testing = false
        this.testOk = false
        this.testResult = '连接失败：' + e.substring(0, 100)
      }
    })
  }

  build() {
    Stack() {
      // 遮罩：点空白关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.onClose()
        })
      Column({ space: 12 }) {
        Row() {
          Text('聊天设置')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
          Blank()
          Text('✕')
            .fontSize(16)
            .fontColor(this.theme.textSecondary)
            .padding(6)
            .onClick(() => {
              this.onClose()
            })
        }
        .width('100%')
        Scroll() {
          Column({ space: 12 }) {
            Column({ space: 6 }) {
              Text('API Key').fontSize(12).fontColor(this.theme.textTertiary)
              TextInput({ text: this.draftKey, placeholder: 'sk-…（未配置时为演示模式）' })
                .type(InputType.Password)
                .fontSize(14)
                .onChange((v: string) => {
                  this.draftKey = v
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            Column({ space: 6 }) {
              Text('接口地址').fontSize(12).fontColor(this.theme.textTertiary)
              TextInput({ text: this.draftUrl, placeholder: 'https://api.deepseek.com' })
                .fontSize(14)
                .onChange((v: string) => {
                  this.draftUrl = v
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            Column({ space: 6 }) {
              Text('模型').fontSize(12).fontColor(this.theme.textTertiary)
              TextInput({ text: this.draftModel, placeholder: 'deepseek-v4-flash' })
                .fontSize(14)
                .onChange((v: string) => {
                  this.draftModel = v
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Button(this.testing ? '测试中…' : '测试连接')
                  .fontSize(13)
                  .height(36)
                  .backgroundColor(this.theme.accent)
                  .fontColor(Color.White)
                  .enabled(!this.testing)
                  .onClick(() => {
                    this.runTest()
                  })
                if (this.testResult.length > 0) {
                  Text(this.testResult)
                    .fontSize(12)
                    .fontColor(this.testOk ? '#2E8B57' : '#E5484D')
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
              }
              .width('100%')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            Column({ space: 6 }) {
              Text('玩家称呼').fontSize(12).fontColor(this.theme.textTertiary)
              TextInput({ text: this.draftName, placeholder: '博士' })
                .fontSize(14)
                .onChange((v: string) => {
                  this.draftName = v
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            Column({ space: 6 }) {
              Text('上下文条数（1-100）').fontSize(12).fontColor(this.theme.textTertiary)
              TextInput({ text: this.draftCtx, placeholder: '20' })
                .type(InputType.Number)
                .fontSize(14)
                .onChange((v: string) => {
                  this.draftCtx = v
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            Row() {
              Text('时间感知').fontSize(13).fontColor(this.theme.textPrimary)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.draftTime })
                .onChange((v: boolean) => {
                  this.draftTime = v
                })
            }
            .width('100%')
            Row() {
              Text('主动性发言频率').fontSize(13).fontColor(this.theme.textPrimary)
              Blank()
              ForEach(['低频', '中频', '高频'], (opt: string) => {
                Text(opt)
                  .fontSize(13)
                  .fontColor(this.draftChatter === opt ? this.theme.accent : this.theme.textSecondary)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.draftChatter = opt
                  })
              }, (opt: string) => opt)
            }
            .width('100%')
            Row() {
              Text('语音').fontSize(13).fontColor(this.theme.textPrimary)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.draftVoice })
                .onChange((v: boolean) => {
                  this.draftVoice = v
                })
            }
            .width('100%')
            Row() {
              Text('语音语言').fontSize(13).fontColor(this.theme.textPrimary)
              Blank()
              ForEach(['中文', '日文'], (opt: string) => {
                Text(opt)
                  .fontSize(13)
                  .fontColor(this.draftVoiceLang === opt ? this.theme.accent : this.theme.textSecondary)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .onClick(() => {
                    this.draftVoiceLang = opt
                  })
              }, (opt: string) => opt)
            }
            .width('100%')
            Column({ space: 6 }) {
              Text('额外提示词（附加在设定后）').fontSize(12).fontColor(this.theme.textTertiary)
              TextArea({ text: this.draftExtra, placeholder: '例如：回复尽量简短' })
                .fontSize(14)
                .constraintSize({ minHeight: 64, maxHeight: 120 })
                .onChange((v: string) => {
                  this.draftExtra = v
                })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .padding({ bottom: 4 })
          .width('100%')
        }
        .constraintSize({ maxHeight: 400 })
        .scrollBar(BarState.Off)
        .width('100%')
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .backgroundColor(this.theme.bgHover)
            .fontColor(this.theme.textBody)
            .onClick(() => {
              this.onClose()
            })
          Button('保存')
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .backgroundColor(this.theme.accent)
            .fontColor(Color.White)
            .onClick(() => {
              let n = parseInt(this.draftCtx)
              if (isNaN(n) || n < 1) {
                n = 20
              }
              if (n > 100) {
                n = 100
              }
              let s: ChatSettings = {
                chat_base_url: this.draftUrl.trim(),
                chat_api_key: this.draftKey.trim(),
                chat_model: this.draftModel.trim(),
                player_name: this.draftName.trim().length > 0 ? this.draftName.trim() : '博士',
                context_window_size: n,
                time_awareness: this.draftTime,
                extra_prompt: this.draftExtra,
                chatter_interval: this.draftChatter,
                voice_enabled: this.draftVoice,
                voice_language: this.draftVoiceLang
              }
              this.onSave(s)
            })
        }
        .width('100%')
      }
      .width('92%')
      .constraintSize({ maxWidth: 460 })
      .padding(20)
      .backgroundColor(Color.White)
      .borderRadius(20)
      .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 8 })
    }
    .width('100%')
    .height('100%')
  }
}

// 单模型数据：骨架 + 纹理 + 固定布局（同一模型所有动画共用：同缩放同锚点同画布，衔接零跳跃）
class PetModel {
  skeleton: Skeleton
  tex: Texture
  layout: StateLayout = new StateLayout()
  baseAnim: string
  menuItems: MenuItem[]
  interactAnim: string | null // 单击互动的动画名（null=无单次互动）
  comboAnims: string[] = [] // 单击连击序列（战斗模型平A两连击）
  clickAnim: string = '' // 点击响应状态（基建=Relax 战斗=Idle；坐下/睡觉等状态点击无响应）
  bottomExtra: number = 0 // 并集低于 setup 的垂直扩展（跨模型归一化用）
  anchorX: number = 0 // 身体对称轴（根骨骼 setup world_x）：对话框/镜像/菜单/触摸层都绕它
  clickLeft: number = 0 // 可点击态并集相对身体轴的左延展（触摸层/菜单用——入场/技能开关链不撑大交互层）
  clickRight: number = 0 // 可点击态并集相对身体轴的右延展
  clickExtraAnims: string[] = [] // 可点击态额外动画（技能待机/技能攻击）
  menuRight: number = 0 // 菜单水平基准：基础待机+互动动画右延展（贴角色身体，不含技能外伸）
  charHalfH: number = 0 // 角色 setup 视觉半高（vp，拖拽边界用）
  charBottomPad: number = 0 // setup 底边距画布底部的距离（归一化后，角色屏幕定位用）
  charCenterPad: number = 0 // setup 垂直中心距画布底部的距离（拖拽垂直参考，与水平中心对称）
  setupMinY: number = 0
  setupH: number = 0
  setupMinX: number = 0
  setupW: number = 0
  centeredAnims: string[] = [] // 特判按状态居中的动画（如坐下/睡觉——固定锚点会显瞬移）
  vSlack: number = 0 // 垂直余量（给按状态居中留空间）
  stateBounds: Map<string, number[]> = new Map() // 特判动画的包围盒
  stateTransforms: Map<string, RenderTransform> = new Map() // 特判动画的居中变换
  extMinX = 0
  extMinY = 0
  extMaxX = 0
  extMaxY = 0
  extraAnims: string[] = [] // 画布并集需覆盖的额外动画（技能链等）

  constructor(skeleton: Skeleton, tex: Texture, baseAnim: string, menuItems: MenuItem[],
    interactAnim: string | null, comboAnims: string[] = [], centeredAnims: string[] = [],
    vSlack: number = 0, extraAnims: string[] = [], clickExtraAnims: string[] = []) {
    this.skeleton = skeleton
    this.tex = tex
    this.baseAnim = baseAnim
    this.menuItems = menuItems
    this.interactAnim = interactAnim
    this.comboAnims = comboAnims
    this.clickAnim = baseAnim
    this.centeredAnims = centeredAnims
    this.vSlack = vSlack
    this.extraAnims = extraAnims
    this.clickExtraAnims = clickExtraAnims
    this.computeLayout()
  }

  // 采样一组动画的水平并集（含 setup 起点；相对身体轴）→ [minX, maxX]
  private sampleX(anims: string[], setup: number[], rootX: number): number[] {
    let sk = this.skeleton
    let mn = setup[0] - rootX
    let mx = setup[2] - rootX
    for (let u = 0; u < anims.length; u++) {
      let anim = sk.data.find_animation(anims[u])
      if (anim === null) {
        continue
      }
      let n = anim.duration > 0 ? 8 : 1
      for (let s = 0; s < n; s++) {
        sk.set_to_setup_pose()
        apply_animation(anim, sk, anim.duration * s / n, true, 1.0)
        sk.update_world_transform()
        let bb = sk.get_bounds()
        mn = Math.min(mn, bb[0] - rootX)
        mx = Math.max(mx, bb[0] + bb[2] - rootX)
      }
    }
    return [mn, mx]
  }

  // 固定布局：缩放按 setup 包围盒（跨模型角色尺寸一致）；画布按 用到的动画并集 ∪ setup 定尺寸
  // （特效/动作扩展由画布一次性容纳）；锚点固定于 setup 中心/底边（角色身体纹丝不动）
  computeLayout(): void {
    let sk = this.skeleton
    sk.set_to_setup_pose()
    sk.update_world_transform()
    let b = sk.get_bounds()
    let setup: number[] = [b[0], b[1], b[0] + b[2], b[1] + b[3]]
    let scale = Math.min((RW - MARGIN * 2) / b[2], (RH - MARGIN * 2) / b[3])
    // 身体对称轴：根骨骼（无父骨骼）的 setup world_x——法杖/头发等外伸部分不再影响锚点；
    // 找不到根骨骼时退回包围盒中心
    let rootX = (setup[0] + setup[2]) / 2
    for (let i = 0; i < sk.bones.length; i++) {
      if (sk.bones[i].parent === null) {
        rootX = sk.bones[i].world_x
        break
      }
    }
    this.anchorX = rootX
    // 水平延展相对身体轴计（左负右正）；垂直仍按世界坐标（脚线锚定不变）
    let minX = setup[0] - rootX
    let minY = setup[1]
    let maxX = setup[2] - rootX
    let maxY = setup[3]
    let wMinX = setup[0]
    let wMaxX = setup[2]
    let used: string[] = [this.baseAnim]
    if (this.interactAnim !== null) {
      used.push(this.interactAnim)
    }
    for (let i = 0; i < this.comboAnims.length; i++) {
      used.push(this.comboAnims[i])
    }
    if (sk.data.find_animation('Start') !== null) {
      used.push('Start')
    }
    for (let i = 0; i < this.menuItems.length; i++) {
      used.push(this.menuItems[i].anim)
    }
    for (let i = 0; i < this.extraAnims.length; i++) {
      used.push(this.extraAnims[i])
    }
    for (let u = 0; u < used.length; u++) {
      let anim = sk.data.find_animation(used[u])
      if (anim === null) {
        continue
      }
      let sampleCount = anim.duration > 0 ? 8 : 1
      for (let s = 0; s < sampleCount; s++) {
        sk.set_to_setup_pose()
        apply_animation(anim, sk, anim.duration * s / sampleCount, true, 1.0)
        sk.update_world_transform()
        let bb = sk.get_bounds()
        minX = Math.min(minX, bb[0] - rootX)
        minY = Math.min(minY, bb[1])
        maxX = Math.max(maxX, bb[0] + bb[2] - rootX)
        maxY = Math.max(maxY, bb[1] + bb[3])
        wMinX = Math.min(wMinX, bb[0])
        wMaxX = Math.max(wMaxX, bb[0] + bb[2])
      }
    }
    // 可点击态并集（触摸层范围）：仅含点击有响应的状态——入场/技能开关链播完即走，
    // 点击无交互；把它们算进去会把触摸层撑大（front 并集右缘 703 单位 vs 可点击态 379）
    let clickUsed: string[] = [this.baseAnim]
    if (this.interactAnim !== null) {
      clickUsed.push(this.interactAnim)
    }
    for (let i = 0; i < this.comboAnims.length; i++) {
      clickUsed.push(this.comboAnims[i])
    }
    for (let i = 0; i < this.menuItems.length; i++) {
      clickUsed.push(this.menuItems[i].anim)
    }
    let r = this.sampleX(clickUsed, setup, rootX)
    let cMinX = r[0]
    let cMaxX = r[1]
    // 菜单贴角色身体：技能待机法杖外伸会把菜单推远（Skill_2_Idle 右缘 349 单位），
    // 故只用基础待机+互动（build 的 Relax 右缘与并集相同——基建菜单位置不变）
    let menuUsed: string[] = [this.baseAnim]
    if (this.interactAnim !== null) {
      menuUsed.push(this.interactAnim)
    }
    this.menuRight = this.sampleX(menuUsed, setup, rootX)[1] * scale
    // 技能待机/技能攻击再扩展触摸层覆盖范围
    r = this.sampleX(this.clickExtraAnims, setup, rootX)
    cMinX = Math.min(cMinX, r[0])
    cMaxX = Math.max(cMaxX, r[1])
    this.clickLeft = -cMinX * scale
    this.clickRight = cMaxX * scale
    this.layout.w = Math.ceil((maxX - minX) * scale) + MARGIN * 2
    this.layout.h = Math.ceil((maxY - minY) * scale) + MARGIN * 2 + this.vSlack
    this.layout.t.scale = scale
    this.layout.t.tx = this.layout.w / 2 - rootX * scale
    this.bottomExtra = Math.max(0, setup[1] - minY) * scale
    this.setupMinY = setup[1]
    this.setupH = setup[3] - setup[1]
    this.setupMinX = setup[0]
    this.setupW = setup[2] - setup[0]
    this.layout.t.ty = (MARGIN + this.bottomExtra) - setup[1] * scale
    this.layout.t.height = this.layout.h
    this.charHalfH = ((setup[3] - setup[1]) / 2) * scale
    this.extMinX = wMinX
    this.extMinY = minY
    this.extMaxX = wMaxX
    this.extMaxY = maxY
    // 特判动画的包围盒（采样循环里顺带收集）
    for (let i = 0; i < this.centeredAnims.length; i++) {
      let name = this.centeredAnims[i]
      let anim = sk.data.find_animation(name)
      if (anim === null) {
        continue
      }
      let sb: number[] = [1e9, 1e9, -1e9, -1e9]
      let sampleCount = anim.duration > 0 ? 8 : 1
      for (let s = 0; s < sampleCount; s++) {
        sk.set_to_setup_pose()
        apply_animation(anim, sk, anim.duration * s / sampleCount, true, 1.0)
        sk.update_world_transform()
        let bb = sk.get_bounds()
        sb[0] = Math.min(sb[0], bb[0])
        sb[1] = Math.min(sb[1], bb[1])
        sb[2] = Math.max(sb[2], bb[0] + bb[2])
        sb[3] = Math.max(sb[3], bb[1] + bb[3])
      }
      this.stateBounds.set(name, sb)
    }
  }

  // 跨模型归一化后调用：统一画布高度/底部扩展，并计算特判动画的居中变换
  finalize(maxBE: number, maxW: number, maxH: number): void {
    let s = this.layout.t.scale
    this.layout.w = maxW
    this.layout.h = maxH
    this.layout.t.height = maxH
    // 身体轴固定在画布中心（原：setup 包围盒中心——法杖外伸导致视觉轴偏移）
    this.layout.t.tx = maxW / 2 - this.anchorX * s
    this.layout.t.ty = (MARGIN + maxBE) - this.setupMinY * s
    this.charCenterPad = MARGIN + maxBE + this.setupH / 2 * s
    this.charBottomPad = MARGIN + maxBE
    for (let i = 0; i < this.centeredAnims.length; i++) {
      let name = this.centeredAnims[i]
      let sb = this.stateBounds.get(name)
      if (sb === undefined) {
        continue
      }
      let t = new RenderTransform()
      t.scale = s
      t.height = maxH
      // 身体轴水平固定（站立/坐下/睡觉衔接零位移）；垂直仍按状态视觉中心对齐
      t.tx = maxW / 2 - this.anchorX * s
      t.ty = this.charCenterPad - ((sb[1] + sb[3]) / 2) * s
      // 钳制：并集内容保持在画布内
      let txMin = MARGIN - this.extMinX * s
      let txMax = maxW - MARGIN - this.extMaxX * s
      if (t.tx < txMin) {
        t.tx = txMin
      }
      if (t.tx > txMax) {
        t.tx = txMax
      }
      let tyMin = MARGIN - this.extMinY * s
      let tyMax = maxH - MARGIN - this.extMaxY * s
      if (t.ty < tyMin) {
        t.ty = tyMin
      }
      if (t.ty > tyMax) {
        t.ty = tyMax
      }
      this.stateTransforms.set(name, t)
    }
  }
}

async function loadModel(context: Context, dir: string, skelName: string, baseAnim: string,
  menuItems: MenuItem[], interactAnim: string | null, comboAnims: string[] = [],
  centeredAnims: string[] = [], vSlack: number = 0, extraAnims: string[] = [],
  clickExtraAnims: string[] = []): Promise<PetModel> {
  let atlasName = skelName.replace('.skel', '.atlas')
  let atlasData = await context.resourceManager.getRawFileContent('spine/' + dir + '/' + atlasName)
  let decoder = util.TextDecoder.create('utf-8')
  let atlas = new TextureAtlas(decoder.decodeToString(atlasData))
  for (let p = 0; p < atlas.pages.length; p++) {
    atlas.pages[p].texture = await loadTexture(context, 'spine/' + dir + '/' + atlas.pages[p].name)
  }
  let skelData = await context.resourceManager.getRawFileContent('spine/' + dir + '/' + skelName)
  let sd = new SkeletonBinary(new AtlasAttachmentLoaderImpl(atlas)).read_skeleton_data(skelData)
  return new PetModel(new Skeleton(sd), atlas.pages[0].texture as Texture, baseAnim, menuItems,
    interactAnim, comboAnims, centeredAnims, vSlack, extraAnims, clickExtraAnims)
}

@Entry
@Component
struct PetPage {
  // ── 聊天（酸橙味来信） ──
  @State chatInput: string = ''
  @State messages: ChatMsg[] = []
  @State streamingText: string = ''
  @State streamingReason: string = '' // 思考过程（流式展示，完成后不落历史）
  @State isStreaming: boolean = false
  @State subtitle: string = ''
  private fakeTimer: number = -1
  private fakeText: string = ''
  private fakeIdx: number = 0
  private chatApi: ChatApi = new ChatApi()
  // 生成中的轮次信息（停止生成用）
  private pendingSid: string = ''
  private pendingNid: string = ''
  private pendingAgentName: string = ''
  private pendingDirect: boolean = false
  @State chatSettings: ChatSettings = ChatStore.DEFAULT_SETTINGS // @State：保存后必须驱动 PetView 的 @Prop 同步
  @State reportCmd: number = 0 // 语音 关→开 计数：+1 即令 PetView 播「干员报到」（避开对象 @Prop 同步不可靠）
  @State chatHistory: ChatHistory = { active_session: '', sessions: [], projects: [], agents: [] } // @State：会话增删改后重赋值触发侧边栏重建
  @State msgVersion: number = 0 // 消息列表整体替换时 +1：ForEach key 带上它，杜绝跨会话复用旧组件
  @State currentProjectPid: string = '' // 新建会话归属项目（''=无项目；持久化）
  @State expandedPids: string = '' // 侧边栏展开的项目文件夹（逗号分隔；持久化）
  @State agentCurrent: string = '' // 活跃智能体 aid（''=默认智能体「安洁莉娜」；持久化）
  @State agentPanelVisible: boolean = false // 智能体管理面板（独立于设置）
  // ── 陪伴模式：摄像头实时画面作背景，桌宠悬浮其上（仅本地预览，不存储不上传） ──
  @State companionMode: boolean = false
  @State companionPending: boolean = false // @State：置位必须触发相机 XComponent 挂载（普通字段不重建）
  @State camScale: number = 1 // 相机组件放大系数（把留白推出屏幕的 cover 裁剪）
  private camCtl: XComponentController = new XComponentController()
  private camInput: camera.CameraInput | null = null
  private camSession: camera.Session | null = null
  private camPreview: camera.PreviewOutput | null = null
  private sessionActionCtl: CustomDialogController | null = null
  private sessionRenameCtl: CustomDialogController | null = null
  private msgActionCtl: CustomDialogController | null = null
  private msgEditCtl: CustomDialogController | null = null
  private confirmCtl: CustomDialogController | null = null
  private projectNameCtl: CustomDialogController | null = null
  private projectActionCtl: CustomDialogController | null = null
  private projectPickCtl: CustomDialogController | null = null
  private convParamCtl: CustomDialogController | null = null
  private agentEditCtl: CustomDialogController | null = null
  private models: Map<string, PetModel> = new Map()
  private sizeScale: number = 0.9 // 尺寸基准（用户 2026-08-15 拍板：平板全屏模式）
  @State modelsReady: boolean = false
  @State settingsVisible: boolean = false
  @State theme: ThemeTokens = THEME_SKY
  private themeName: string = 'sky'
  @State sidebarCollapsed: boolean = false
  // ── 横竖屏适配：mediaquery 监听方向；竖屏自动收起侧边栏（用户仍可手动展开） ──
  @State isLandscape: boolean = true
  private mq: mediaquery.MediaQueryListener | null = null
  private isPhone: boolean = deviceInfo.deviceType === 'phone' // 设备类型：手机/平板差异化适配
  @State subtitleMs: number = 12000 // 字幕展示时长（语音台词 45s）

  aboutToAppear(): void {
    // 方向监听（媒体查询标准方式）：布局随 isLandscape 自适应，侧边栏状态保持用户选择
    this.mq = mediaquery.matchMediaSync('(orientation: landscape)')
    this.isLandscape = this.mq.matches
    this.mq.on('change', (r: mediaquery.MediaQueryResult) => {
      this.isLandscape = r.matches
    })
    this.init()
  }

  aboutToDisappear(): void {
    if (this.mq !== null) {
      this.mq.off('change')
      this.mq = null
    }
  }

  async init(): Promise<void> {
    let ctx = getContext(this)
    await ChatStore.loadDefaultPrompt(ctx) // 默认智能体 = 安洁莉娜 Skill 包
    this.models.set('build', await loadModel(ctx, 'build', 'build_char_1015_aglna2.skel', 'Relax', [
      { label: '待机', anim: 'Relax' },
      { label: '坐下', anim: 'Sit' },
      { label: '睡觉', anim: 'Sleep' }
    ], 'Interact', [], ['Sit', 'Sleep'], 130))
    // 战斗模型：菜单无状态项（单击=平A连击）；背面只有一套攻击，正面有攻击+攻击·下两连击。
    // 技能链动画并入画布并集（extraAnims）
    let skillAnims: string[] = []
    for (let i = 0; i < COMBAT_SKILLS.length; i++) {
      let sk = COMBAT_SKILLS[i]
      for (let j = 0; j < sk.on.length; j++) {
        skillAnims.push(sk.on[j])
      }
      skillAnims.push(sk.idle)
      skillAnims.push(sk.combat)
      for (let j = 0; j < sk.off.length; j++) {
        skillAnims.push(sk.off[j])
      }
    }
    // 可点击态并集：技能待机（循环可点）+ 技能攻击（双击第二击容差）
    let clickSkillAnims: string[] = []
    for (let i = 0; i < COMBAT_SKILLS.length; i++) {
      clickSkillAnims.push(COMBAT_SKILLS[i].idle)
      clickSkillAnims.push(COMBAT_SKILLS[i].combat)
    }
    this.models.set('back', await loadModel(ctx, 'back', 'char_1015_aglna2.skel', 'Idle', [],
      null, ['Attack'], [], 0, skillAnims, clickSkillAnims))
    this.models.set('front', await loadModel(ctx, 'front', 'char_1015_aglna2.skel', 'Idle', [],
      null, ['Attack', 'Attack_Down'], [], 0, skillAnims, clickSkillAnims))
    // 跨模型归一化：共用最大 bottomExtra 与最大画布尺寸
    let maxBE = 0
    let maxW = 0
    let maxH = 0
    this.models.forEach((m: PetModel) => {
      if (m.bottomExtra > maxBE) {
        maxBE = m.bottomExtra
      }
      if (m.layout.w > maxW) {
        maxW = m.layout.w
      }
      if (m.layout.h > maxH) {
        maxH = m.layout.h
      }
    })
    // 全局统一画布：显示盒恒定，切换模型无拉伸
    this.models.forEach((m: PetModel) => {
      m.finalize(maxBE, maxW, maxH)
    })
    this.chatSettings = await ChatStore.loadSettings(ctx)
    this.chatHistory = await ChatStore.loadHistory(ctx)
    this.reloadMessages()
    // 主题（偏好持久化）
    let prefs = preferences.getPreferencesSync(ctx, { name: 'pet_settings' })
    this.themeName = prefs.getSync('pet_theme', 'sky') as string
    this.theme = this.themeName === 'lime' ? THEME_LIME : THEME_SKY
    // 项目状态（持久化）
    this.currentProjectPid = prefs.getSync('project_current', '') as string
    this.expandedPids = prefs.getSync('project_expanded', '') as string
    this.agentCurrent = prefs.getSync('agent_current', '') as string
    this.modelsReady = true
  }

  // 主题切换（天空淡蓝 ↔ 酸橙味），持久化
  toggleTheme(): void {
    this.themeName = this.themeName === 'lime' ? 'sky' : 'lime'
    this.theme = this.themeName === 'lime' ? THEME_LIME : THEME_SKY
    let prefs = preferences.getPreferencesSync(getContext(this), { name: 'pet_settings' })
    prefs.putSync('pet_theme', this.themeName)
    prefs.flush()
  }

  // 会话切换：落盘 active_session + 载入该会话活跃分支消息
  switchSession(sid: string): void {
    this.chatHistory.active_session = sid
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    this.reloadMessages()
  }

  // 活跃分支路径 → 界面消息（msgVersion++ 强制列表重建，杜绝 V1 ForEach 复用旧组件）
  private reloadMessages(): void {
    this.messages = ChatStore.pathMessages(this.chatHistory, this.chatHistory.active_session)
    this.msgVersion++
  }

  // 消息下标 → 活跃路径轮次下标（与 ChatMain.buildRounds 同一配对规则）
  private roundOfMsg(idx: number): number {
    let r = -1
    for (let i = 0; i <= idx; i++) {
      if (this.messages[i].role === 'user') {
        r++
        if (i + 1 <= idx && i + 1 < this.messages.length && this.messages[i + 1].role === 'assistant') {
          i++
        }
      } else {
        r++
      }
    }
    return r
  }

  // 轮次下标 → 节点 nid
  private nidOfRound(r: number): string {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    if (sess === null || r < 0 || r >= sess.path.length) {
      return ''
    }
    return sess.path[r]
  }

  // 导航轨分支信息（与活跃路径轮次一一对应）：{nid, user, active}
  // 锚点语义（用户定案）：在某轮开了分支 → 该轮是父节点下的兄弟之一，圆点挂在该轮上（兄弟数≥2）
  private railBranches(): RailBranch[][] {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    let out: RailBranch[][] = []
    if (sess === null) {
      return out
    }
    for (let i = 0; i < sess.path.length; i++) {
      let node = ChatStore.findRound(sess, sess.path[i])
      let siblings: RoundNode[] = []
      if (node !== null && node.parent !== '') {
        for (let k = 0; k < sess.rounds.length; k++) {
          if (sess.rounds[k].parent === node.parent) {
            siblings.push(sess.rounds[k])
          }
        }
      }
      let list: RailBranch[] = []
      if (siblings.length >= 2) {
        for (let j = 0; j < siblings.length; j++) {
          list.push({
            nid: siblings[j].nid,
            user: siblings[j].user,
            active: sess.path.indexOf(siblings[j].nid) >= 0
          })
        }
      }
      out.push(list)
    }
    return out
  }

  // 导航轨切换分支：圆点轮次的父节点为树锚点（兄弟分支共同前缀），接选定兄弟
  private doSwitchBranch(anchorRound: number, childNid: string): void {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    if (sess === null || anchorRound < 0 || anchorRound >= sess.path.length) {
      return
    }
    let anchorNid = sess.path[anchorRound]
    let node = ChatStore.findRound(sess, anchorNid)
    if (node !== null && node.parent !== '') {
      anchorNid = node.parent
    }
    if (ChatStore.switchBranch(this.chatHistory, this.chatHistory.active_session, anchorNid, childNid)) {
      ChatStore.saveHistory(getContext(this), this.chatHistory)
      this.reloadMessages()
    }
  }

  // 新建会话：清空激活会话（首条消息时自动生成新会话）
  newChat(): void {
    this.chatHistory.active_session = ''
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    this.messages = []
    this.streamingText = ''
    this.isStreaming = false
    this.msgVersion++
    this.refreshHistory()
  }

  // 会话列表结构变化后强制重建侧边栏（@State 只观察第一层，原地改 sessions 不触发）
  private refreshHistory(): void {
    this.chatHistory = {
      active_session: this.chatHistory.active_session,
      sessions: this.chatHistory.sessions.slice(),
      projects: this.chatHistory.projects.slice(),
      agents: this.chatHistory.agents.slice()
    }
  }

  // 长按会话项：操作对话框（重命名/删除）
  private openSessionAction(sid: string): void {
    let sess = ChatStore.findSession(this.chatHistory, sid)
    let title = sess !== null ? sess.title : ''
    this.sessionActionCtl = new CustomDialogController({
      builder: SessionActionDialog({
        title: title,
        onRename: (): void => {
          this.sessionActionCtl?.close()
          this.openSessionRename(sid, title)
        },
        onMoveToProject: (): void => {
          this.sessionActionCtl?.close()
          this.openMoveSession(sid)
        },
        onDelete: (): void => {
          this.sessionActionCtl?.close()
          this.openSessionDeleteConfirm(sid, title)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.sessionActionCtl.open()
  }

  // 删除会话的二级确认
  private openSessionDeleteConfirm(sid: string, title: string): void {
    this.confirmCtl = new CustomDialogController({
      builder: ConfirmDeleteDialog({
        title: '删除会话「' + title + '」？\n该会话的全部对话将丢失',
        onConfirm: (): void => {
          this.confirmCtl?.close()
          this.doDeleteSession(sid)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.confirmCtl.open()
  }

  private openSessionRename(sid: string, title: string): void {
    this.sessionRenameCtl = new CustomDialogController({
      builder: SessionRenameDialog({
        draft: title,
        onConfirm: (text: string): void => {
          this.doRenameSession(sid, text)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.sessionRenameCtl.open()
  }

  private doRenameSession(sid: string, title: string): void {
    if (ChatStore.renameSession(this.chatHistory, sid, title)) {
      ChatStore.saveHistory(getContext(this), this.chatHistory)
      this.refreshHistory()
    }
  }

  // 删除会话；删除的是当前会话则清空聊天区（下一条消息自动开新会话）
  private doDeleteSession(sid: string): void {
    ChatStore.deleteSession(this.chatHistory, sid)
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    if (this.chatHistory.active_session === '') {
      this.messages = []
      this.streamingText = ''
      this.isStreaming = false
      this.msgVersion++
    }
    this.refreshHistory()
  }

  // ── 项目操作（文件夹语义：删除项目不删会话） ──

  private saveProjectPrefs(): void {
    let prefs = preferences.getPreferencesSync(getContext(this), { name: 'pet_settings' })
    prefs.putSync('project_current', this.currentProjectPid)
    prefs.putSync('project_expanded', this.expandedPids)
    prefs.flush()
  }

  // 胶囊显示的当前项目：有活跃会话=会话所属项目；无活跃会话=新建会话归属
  private composerProjectPid(): string {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    return sess !== null ? sess.pid : this.currentProjectPid
  }

  // 项目胶囊选择：有活跃会话=移动该会话到所选项目；无=设定新建会话归属
  // 项目胶囊选择：只设定新建会话的归属。已有会话时胶囊仅显示该会话所属项目，不可变更
  private doSelectProject(pid: string): void {
    this.currentProjectPid = pid
    this.saveProjectPrefs()
  }

  // ── 对话参数（Chatbox 式：每对话上下文条数 + 人设查看/修改） ──

  private openConvParams(): void {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    let aid = sess !== null ? sess.agent_aid : this.agentCurrent
    let locked = aid === ''
    this.convParamCtl = new CustomDialogController({
      builder: ConvParamDialog({
        theme: this.theme,
        ctxDraft: sess !== null && sess.context_size > 0 ? sess.context_size.toString() : '',
        agentName: this.agentNameOf(aid),
        // 彩蛋隐秘性：前端始终显示安洁莉娜本体的 Skill（实际对话用彩蛋人设，此处不透露）
        agentPrompt: aid === '' ? ChatStore.defaultAgentPrompt :
          ChatStore.activeAgentPrompt(this.chatHistory, aid, ''),
        locked: locked,
        onSaveCtx: (text: string): void => {
          this.doSaveConvCtx(text)
        },
        onSavePrompt: (text: string): void => {
          this.doSaveConvPrompt(aid, text)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.convParamCtl.open()
  }

  private doSaveConvCtx(text: string): void {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    if (sess === null) {
      return
    }
    let n = 0
    if (text.length > 0) {
      n = parseInt(text)
      if (isNaN(n) || n < 0) {
        n = 0
      }
      if (n > 100) {
        n = 100
      }
    }
    sess.context_size = n
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    this.refreshHistory()
  }

  // 仅自定义智能体的人设可在此修改（安洁莉娜锁定，UI 已禁用）
  private doSaveConvPrompt(aid: string, text: string): void {
    if (aid === '' || text.length === 0) {
      return
    }
    let a = ChatStore.agentOf(this.chatHistory, aid)
    if (a === null) {
      return
    }
    ChatStore.renameAgent(this.chatHistory, aid, a.name, text)
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    this.refreshHistory()
  }

  // ── 话题标题 ──

  private activeSessionTitle(): string {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    return sess !== null ? sess.title : ''
  }

  // 点击话题标题：直接重命名（对话界面内）
  private openRenameTopic(): void {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    if (sess === null) {
      return
    }
    this.sessionRenameCtl = new CustomDialogController({
      builder: SessionRenameDialog({
        draft: sess.title,
        onConfirm: (text: string): void => {
          this.doRenameSession(this.chatHistory.active_session, text)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.sessionRenameCtl.open()
  }

  // ── 智能体 ──

  private doSelectAgent(aid: string): void {
    this.agentCurrent = aid
    let prefs = preferences.getPreferencesSync(getContext(this), { name: 'pet_settings' })
    prefs.putSync('agent_current', aid)
    prefs.flush()
  }

  private agentNameOf(aid: string): string {
    if (aid === '') {
      return '安洁莉娜' // 默认智能体 = Skill 注入的安洁莉娜
    }
    if (aid === '~raw') {
      return '陌生的友人' // 空智能体：无提示词，直连大模型
    }
    let a = ChatStore.agentOf(this.chatHistory, aid)
    return a !== null ? a.name : '安洁莉娜'
  }

  // 输入框占位符：按当前会话绑定的智能体（无会话=当前选取）
  private composerPlaceholderText(): string {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    let aid = sess !== null ? sess.agent_aid : this.agentCurrent
    if (aid === '') {
      return '与安洁莉娜对话…'
    }
    if (aid === '~raw') {
      return '直接与大模型对话…'
    }
    return '给「' + this.agentNameOf(aid) + '」写信…'
  }

  // 管理面板的增删改
  private doCreateAgent(name: string, prompt: string): void {
    let aid = ChatStore.newAgent(this.chatHistory, name, prompt)
    if (aid !== '') {
      ChatStore.saveHistory(getContext(this), this.chatHistory)
      this.refreshHistory()
      this.doSelectAgent(aid) // 新建后自动启用
    }
  }

  private doUpdateAgent(aid: string, name: string, prompt: string): void {
    if (ChatStore.renameAgent(this.chatHistory, aid, name, prompt)) {
      ChatStore.saveHistory(getContext(this), this.chatHistory)
      this.refreshHistory()
    }
  }

  private doDeleteAgent(aid: string): void {
    ChatStore.deleteAgent(this.chatHistory, aid)
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    if (this.agentCurrent === aid) {
      this.doSelectAgent('')
    }
    this.refreshHistory()
  }

  // 新建智能体对话框
  private openAgentNew(): void {
    this.agentEditCtl = new CustomDialogController({
      builder: AgentEditDialog({
        theme: this.theme,
        isLandscape: this.isLandscape,
        title: '新建智能体',
        canDelete: false,
        onConfirm: (name: string, prompt: string): void => {
          this.doCreateAgent(name, prompt)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.agentEditCtl.open()
  }

  // 编辑智能体对话框（长按管理面板条目；删除带二级确认）
  private openAgentEdit(aid: string): void {
    let a = ChatStore.agentOf(this.chatHistory, aid)
    if (a === null) {
      return
    }
    let aname = a.name
    let aprompt = a.prompt
    this.agentEditCtl = new CustomDialogController({
      builder: AgentEditDialog({
        theme: this.theme,
        isLandscape: this.isLandscape,
        title: '编辑智能体',
        draftName: aname,
        draftPrompt: aprompt,
        canDelete: true,
        onConfirm: (name: string, prompt: string): void => {
          this.doUpdateAgent(aid, name, prompt)
        },
        onDelete: (): void => {
          this.openAgentDeleteConfirm(aid, aname)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.agentEditCtl.open()
  }

  private openAgentDeleteConfirm(aid: string, name: string): void {
    this.confirmCtl = new CustomDialogController({
      builder: ConfirmDeleteDialog({
        title: '删除智能体「' + name + '」？',
        onConfirm: (): void => {
          this.confirmCtl?.close()
          this.doDeleteAgent(aid)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.confirmCtl.open()
  }

  // ── 对话搜索（Chatbox 式全文检索：跨会话 × 对话树全部节点） ──
  @State searchResults: SearchResult[] = []
  @State scrollCmd: number = 0 // 滚动指令计数（驱动 ChatMain 定位到目标轮次）
  @State scrollRound: number = 0

  private doSearch(text: string): void {
    this.searchResults = ChatStore.searchInSession(this.chatHistory, this.chatHistory.active_session, text)
  }

  // 点击搜索结果：滚动定位到命中轮（当前会话活跃分支内，无需切换）
  private pickSearchResult(r: SearchResult): void {
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    if (sess === null || r.nid === '') {
      return
    }
    let roundIdx = sess.path.indexOf(r.nid)
    if (roundIdx >= 0) {
      this.scrollRound = roundIdx
      this.scrollCmd++
    }
  }

  // ── 陪伴模式 ──
  // 菜单「陪伴/退出陪伴」入口：用户主动点击后才申请相机权限（审核合规要求），
  // 拒绝则停留原界面提示，不闪退不重复骚扰
  private toggleCompanion(): void {
    if (this.companionMode || this.companionPending) {
      this.stopCompanion()
      return
    }
    let at = abilityAccessCtrl.createAtManager()
    at.requestPermissionsFromUser(getContext(this), ['ohos.permission.CAMERA']).then((res) => {
      let granted = res.authResults.length > 0 && res.authResults[0] === 0
      if (!granted) {
        this.subtitle = '未获得相机权限，无法进入陪伴模式'
        return
      }
      // 先挂载相机 XComponent（onLoad 回调里启动相机会话）
      this.companionPending = true
    }).catch(() => {
      this.subtitle = '相机权限申请失败，无法进入陪伴模式'
    })
  }

  // 启动相机会话：预览流直通 XComponent 表面（像素不进应用内存，不落盘）
  private async openCameraPreview(): Promise<void> {
    try {
      let cm = camera.getCameraManager(getContext(this))
      let cams = cm.getSupportedCameras()
      if (cams.length === 0) {
        this.companionPending = false
        this.subtitle = '未找到可用相机'
        return
      }
      // 优先后置（拍环境作背景）
      let device = cams[0]
      for (let i = 0; i < cams.length; i++) {
        if (cams[i].cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) {
          device = cams[i]
          break
        }
      }
      let input = cm.createCameraInput(device)
      await input.open()
      let cap = cm.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO)
      if (cap.previewProfiles.length === 0) {
        await input.close()
        this.companionPending = false
        this.subtitle = '相机不支持预览'
        return
      }
      // 屏幕物理像素与比例
      let d0 = display.getDefaultDisplaySync()
      let scrW = d0.width
      let scrH = d0.height
      let scrRatio = scrW / scrH
      // 选与屏幕比例最接近的预览配置（旋转后按横向比例比较——流会被 setPreviewRotation 转正）
      let best = cap.previewProfiles[0]
      let bestDiff = 1e9
      for (let i = 0; i < cap.previewProfiles.length; i++) {
        let p = cap.previewProfiles[i]
        let r = Math.max(p.size.width, p.size.height) / Math.min(p.size.width, p.size.height)
        let diff = Math.abs(r - scrRatio)
        if (diff < bestDiff) {
          bestDiff = diff
          best = p
        }
      }
      let sid = this.camCtl.getXComponentSurfaceId()
      let preview = cm.createPreviewOutput(best, sid)
      let session = cm.createSession<camera.Session>(camera.SceneMode.NORMAL_PHOTO)
      session.beginConfig()
      session.addInput(input)
      session.addOutput(preview)
      await session.commitConfig()
      // 预览旋转：横屏应用 vs 镜头安装角——官方公式 = getPreviewRotation(displayRotation × ROTATION_90)
      // 必须在 commitConfig 之后设置（commit 前调用会致相机服务致命错误 7400201）
      let dispRot = display.getDefaultDisplaySync().rotation
      preview.setPreviewRotation(preview.getPreviewRotation(dispRot * camera.ImageRotation.ROTATION_90), false)
      // 白边根治：放大相机组件把表面内的留白推出屏幕（cover 裁剪）。
      // 流（旋转后）比例 effRatio vs 屏幕 scrRatio——放大系数 = max(r, 1/r)
      let pw = Math.max(best.size.width, best.size.height)
      let ph = Math.min(best.size.width, best.size.height)
      let effRatio = pw / ph
      let r = effRatio / scrRatio
      this.camScale = Math.max(r, 1 / r)
      await session.start()
      this.camInput = input
      this.camSession = session
      this.camPreview = preview
      // 先置 companionMode 保持组件挂载，再清 pending（同批重建，组件不卸载）
      this.companionMode = true
      this.companionPending = false
    } catch (e) {
      hilog.error(0x0000, 'PetCam', 'open fail %{public}s', JSON.stringify(e))
      this.companionPending = false
      this.subtitle = '相机启动失败'
    }
  }

  private async stopCompanion(): Promise<void> {
    this.companionPending = false
    this.companionMode = false
    this.camScale = 1
    if (this.camSession !== null) {
      try {
        await this.camSession.stop()
      } catch (e) {
      }
      try {
        await this.camSession.release()
      } catch (e2) {
      }
      this.camSession = null
    }
    if (this.camInput !== null) {
      try {
        await this.camInput.close()
      } catch (e3) {
      }
      this.camInput = null
    }
    this.camPreview = null
  }

  // 文件夹展开/收起（持久化；箭头两态静态切换，不做旋转动画）
  private doToggleProject(pid: string): void {
    let arr: string[] = []
    let found = false
    if (this.expandedPids.length > 0) {
      arr = this.expandedPids.split(',')
      for (let i = arr.length - 1; i >= 0; i--) {
        if (arr[i] === pid) {
          arr.splice(i, 1)
          found = true
        }
      }
    }
    if (!found) {
      arr.push(pid)
    }
    this.expandedPids = arr.join(',')
    this.saveProjectPrefs()
  }

  // 新建项目对话框
  private openNewProject(): void {
    this.projectNameCtl = new CustomDialogController({
      builder: ProjectNameDialog({
        title: '新建项目',
        onConfirm: (text: string): void => {
          let pid = ChatStore.newProject(this.chatHistory, text)
          if (pid !== '') {
            ChatStore.saveHistory(getContext(this), this.chatHistory)
            this.refreshHistory()
            // 新建后自动展开该文件夹
            this.expandedPids = this.expandedPids.length > 0 ? this.expandedPids + ',' + pid : pid
            this.saveProjectPrefs()
          }
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.projectNameCtl.open()
  }

  // 长按文件夹：重命名/删除
  private openProjectAction(pid: string): void {
    let name = ''
    for (let i = 0; i < this.chatHistory.projects.length; i++) {
      if (this.chatHistory.projects[i].pid === pid) {
        name = this.chatHistory.projects[i].name
      }
    }
    this.projectActionCtl = new CustomDialogController({
      builder: ProjectActionDialog({
        title: name,
        onRename: (): void => {
          this.projectActionCtl?.close()
          this.openProjectRename(pid, name)
        },
        onDelete: (): void => {
          this.projectActionCtl?.close()
          this.openProjectDeleteConfirm(pid, name)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.projectActionCtl.open()
  }

  private openProjectRename(pid: string, name: string): void {
    this.projectNameCtl = new CustomDialogController({
      builder: ProjectNameDialog({
        title: '重命名项目',
        draft: name,
        onConfirm: (text: string): void => {
          if (ChatStore.renameProject(this.chatHistory, pid, text)) {
            ChatStore.saveHistory(getContext(this), this.chatHistory)
            this.refreshHistory()
          }
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.projectNameCtl.open()
  }

  private openProjectDeleteConfirm(pid: string, name: string): void {
    this.confirmCtl = new CustomDialogController({
      builder: ConfirmDeleteDialog({
        title: '删除项目「' + name + '」？\n项目内的对话不会被删除，将变为无项目',
        onConfirm: (): void => {
          this.confirmCtl?.close()
          if (ChatStore.deleteProject(this.chatHistory, pid)) {
            ChatStore.saveHistory(getContext(this), this.chatHistory)
            if (this.currentProjectPid === pid) {
              this.currentProjectPid = ''
            }
            this.saveProjectPrefs()
            this.refreshHistory()
          }
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.confirmCtl.open()
  }

  // 移动会话到项目（会话操作框的「移动到项目」）
  private openMoveSession(sid: string): void {
    let sess = ChatStore.findSession(this.chatHistory, sid)
    if (sess === null) {
      return
    }
    this.projectPickCtl = new CustomDialogController({
      builder: ProjectPickDialog({
        current: sess.pid,
        projects: this.chatHistory.projects,
        onPick: (pid: string): void => {
          if (ChatStore.moveSession(this.chatHistory, sid, pid)) {
            ChatStore.saveHistory(getContext(this), this.chatHistory)
            // 移入项目后自动展开目标文件夹（收起时移入会"消失"，用户会以为没生效）
            if (pid !== '' && (',' + this.expandedPids + ',').indexOf(',' + pid + ',') < 0) {
              this.expandedPids = this.expandedPids.length > 0 ? this.expandedPids + ',' + pid : pid
              this.saveProjectPrefs()
            }
            this.refreshHistory()
          }
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.projectPickCtl.open()
  }

  // ── 单条消息操作（长按气泡；全部对对话树轮次节点操作） ──
  // 用户消息：[编辑][编辑并重发][删除]；助手消息：[编辑][重新生成][删除]
  private openMsgAction(idx: number): void {
    if (idx < 0 || idx >= this.messages.length) {
      return
    }
    let sid = this.chatHistory.active_session
    let nid = this.nidOfRound(this.roundOfMsg(idx))
    if (nid === '') {
      return
    }
    let m = this.messages[idx]
    let content = m.content
    this.msgActionCtl = new CustomDialogController({
      builder: MessageActionDialog({
        preview: content,
        role: m.role,
        onEdit: (): void => {
          this.msgActionCtl?.close()
          this.openMsgEdit(sid, nid, m.role === 'user', content)
        },
        onEditResend: (): void => {
          this.msgActionCtl?.close()
          this.openMsgEditResend(sid, nid, content)
        },
        onRegen: (): void => {
          this.msgActionCtl?.close()
          this.doRegen(sid, nid)
        },
        onCopy: (): void => {
          this.msgActionCtl?.close()
          this.doCopyMessage(content)
        },
        onDelete: (): void => {
          this.msgActionCtl?.close()
          this.openMsgDeleteConfirm(sid, nid, m.role === 'user')
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.msgActionCtl.open()
  }

  // 复制消息内容到系统剪贴板
  private doCopyMessage(content: string): void {
    let pb = pasteboard.getSystemPasteboard()
    let data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, content)
    pb.setData(data).then(() => {
      this.subtitle = '已复制'
      this.subtitleMs = 2000
    })
  }

  // 删除单条消息的二级确认；仅当该轮两侧都空（整节点删除）且为锚点时带子树警告
  private openMsgDeleteConfirm(sid: string, nid: string, isUser: boolean): void {
    let sess = ChatStore.findSession(this.chatHistory, sid)
    let node = sess !== null ? ChatStore.findRound(sess, nid) : null
    let willRemoveNode = node !== null && (isUser ? node.assistant === '' : node.user === '')
    let anchor = willRemoveNode && ChatStore.isAnchor(this.chatHistory, sid, nid)
    this.confirmCtl = new CustomDialogController({
      builder: ConfirmDeleteDialog({
        title: anchor ? '该轮是对话树锚点，删除将连同其全部后续分支一并删除，确定？' : '删除这条消息？',
        onConfirm: (): void => {
          this.confirmCtl?.close()
          this.doDeleteMessage(sid, nid, isUser)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.confirmCtl.open()
  }

  // 原地编辑（不开分支——编辑即改上下文，对话自由的优点）
  private openMsgEdit(sid: string, nid: string, isUser: boolean, content: string): void {
    this.msgEditCtl = new CustomDialogController({
      builder: MessageEditDialog({
        draft: content,
        onConfirm: (text: string): void => {
          let t = text.trim()
          if (t.length === 0) {
            return
          }
          ChatStore.editRoundContent(this.chatHistory, sid, nid, isUser, t)
          ChatStore.saveHistory(getContext(this), this.chatHistory)
          if (sid === this.chatHistory.active_session) {
            this.reloadMessages()
          }
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.msgEditCtl.open()
  }

  // 编辑并重发（Chatbox 语义）：改用户输入 → 开新分支 → 重新生成回复
  private openMsgEditResend(sid: string, nid: string, content: string): void {
    this.msgEditCtl = new CustomDialogController({
      builder: MessageEditDialog({
        draft: content,
        onConfirm: (text: string): void => {
          let t = text.trim()
          if (t.length === 0 || this.isStreaming) {
            return
          }
          this.doRegenWith(sid, nid, t)
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
    this.msgEditCtl.open()
  }

  // 重新生成：同一条用户输入开新分支
  private doRegen(sid: string, nid: string): void {
    if (this.isStreaming) {
      return
    }
    let sess = ChatStore.findSession(this.chatHistory, sid)
    if (sess === null) {
      return
    }
    let node = ChatStore.findRound(sess, nid)
    if (node === null) {
      return
    }
    this.doRegenWith(sid, nid, node.user)
  }

  // 开分支 + 流式重新生成（newUserText = 分支的用户输入）
  private doRegenWith(sid: string, nid: string, newUserText: string): void {
    if (this.isStreaming) {
      return
    }
    if (this.chatSettings.chat_api_key.length === 0) {
      this.subtitle = '未配置 API Key，无法重新生成'
      return
    }
    let newNid = ChatStore.editResendBranch(this.chatHistory, sid, nid, newUserText)
    if (newNid === '') {
      return
    }
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    if (sid === this.chatHistory.active_session) {
      this.reloadMessages()
    }
    this.isStreaming = true
    this.streamingText = ''
    this.streamingReason = ''
    this.pendingSid = sid
    this.pendingNid = newNid
    this.pendingAgentName = ''
    this.pendingDirect = false
    let sess = ChatStore.findSession(this.chatHistory, sid)
    let aid = sess !== null ? sess.agent_aid : this.agentCurrent
    let agentName = this.agentNameOf(aid)
    // 安洁莉娜 = 直接对话：字幕随流同步输出；其他智能体 = 信使语义
    let direct = aid === '' // 仅默认智能体安洁莉娜=直接对话；其余（含陌生的友人）=信使语义
    if (direct) {
      this.subtitle = ''
    } else {
      this.subtitle = '寄信给「' + agentName + '」…'
      this.subtitleMs = 4000
    }
    let sessCtx = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    let msgs = ChatStore.buildPathMessages(this.chatHistory, this.chatSettings,
      ChatStore.activeAgentPrompt(this.chatHistory, this.agentCurrent, this.chatSettings.extra_prompt), sessCtx !== null ? sessCtx.context_size : 0)
    this.chatApi.send(this.chatSettings.chat_base_url, this.chatSettings.chat_api_key,
      this.chatSettings.chat_model, msgs, {
        onDelta: (t: string) => {
          this.streamingText += t
          if (direct && sid === this.chatHistory.active_session) {
            this.subtitle += t
            this.subtitleMs = 12000
          }
        },
        onReason: (t: string) => {
          if (sid === this.chatHistory.active_session) {
            this.streamingReason += t
          }
        },
        onDone: (full: string) => {
          this.finishRound(full, sid, newNid, agentName, direct)
        },
        onError: (e: string) => {
          this.finishRound('（寄信失败了：' + e.substring(0, 80) + '）', sid, newNid, agentName, direct)
        }
      })
  }

  private doDeleteMessage(sid: string, nid: string, isUser: boolean): void {
    ChatStore.deleteMessageSide(this.chatHistory, sid, nid, isUser)
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    if (sid === this.chatHistory.active_session) {
      this.reloadMessages()
    }
  }

  // 发送消息：活跃分支末尾追加新轮 + 真实流式 API（未配置 key 时回退假打字演示）
  sendChat(): void {
    let text = this.chatInput.trim()
    if (text.length === 0 || this.isStreaming) {
      return
    }
    this.chatInput = ''
    let sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    if (sess === null) {
      ChatStore.newSession(this.chatHistory, text, this.currentProjectPid, this.agentCurrent)
      sess = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
    }
    let sid = this.chatHistory.active_session
    let aid = sess !== null ? sess.agent_aid : this.agentCurrent
    let nid = ChatStore.appendUserRound(this.chatHistory, sid, text)
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    this.reloadMessages()
    this.isStreaming = true
    this.streamingText = ''
    this.streamingReason = ''
    this.pendingSid = sid
    this.pendingNid = nid
    this.pendingAgentName = this.agentNameOf(aid)
    this.pendingDirect = aid === ''
    if (this.chatSettings.chat_api_key.length > 0) {
      // 真实流式（上下文 = 仅活跃分支路径；agent=本对话绑定的智能体）
      let agentName = this.agentNameOf(aid)
      // 安洁莉娜 = 直接对话：字幕随流同步输出内容；其他智能体 = 信使语义（只提示寄信/收信）
      let direct = aid === '' // 仅默认智能体安洁莉娜=直接对话；其余（含陌生的友人）=信使语义
      if (direct) {
        this.subtitle = ''
      } else {
        this.subtitle = '寄信给「' + agentName + '」…'
        this.subtitleMs = 4000
      }
      let sessCtx = ChatStore.findSession(this.chatHistory, this.chatHistory.active_session)
      let msgs = ChatStore.buildPathMessages(this.chatHistory, this.chatSettings,
        ChatStore.activeAgentPrompt(this.chatHistory, aid, this.chatSettings.extra_prompt), sessCtx !== null ? sessCtx.context_size : 0)
      this.chatApi.send(this.chatSettings.chat_base_url, this.chatSettings.chat_api_key,
        this.chatSettings.chat_model, msgs, {
          onDelta: (t: string) => {
            this.streamingText += t
            if (direct && sid === this.chatHistory.active_session) {
              this.subtitle += t
              this.subtitleMs = 12000
            }
          },
          onReason: (t: string) => {
            if (sid === this.chatHistory.active_session) {
              this.streamingReason += t
            }
          },
          onDone: (full: string) => {
            this.finishRound(full, sid, nid, agentName, direct)
          },
          onError: (e: string) => {
            this.finishRound('（寄信失败了：' + e.substring(0, 80) + '）', sid, nid, agentName, direct)
          }
        })
    } else {
      // 假打字演示（未配置 key）
      this.fakeText = '博士，先帮我在设置里填上 API Key 吧～'
      this.fakeIdx = 0
      if (this.fakeTimer >= 0) {
        clearInterval(this.fakeTimer)
      }
      this.fakeTimer = setInterval(() => {
        this.fakeIdx++
        this.streamingText = this.fakeText.substring(0, this.fakeIdx)
        if (this.fakeIdx >= this.fakeText.length) {
          clearInterval(this.fakeTimer)
          this.fakeTimer = -1
          this.finishRound(this.fakeText, sid, nid, '安洁莉娜', true)
        }
      }, 30)
    }
  }

  // 停止生成：中断流式，保留已生成部分（标注已停止）
  private stopGeneration(): void {
    if (!this.isStreaming) {
      return
    }
    this.chatApi.cancel()
    let text = this.streamingText.trim()
    let full = text.length > 0 ? text + '（已停止）' : '（已停止）'
    this.finishRound(full, this.pendingSid, this.pendingNid, this.pendingAgentName, this.pendingDirect)
  }

  // 轮次完成：填充该轮助手回复 + 落盘。
  // direct=true（安洁莉娜直聊）：字幕=完整回复；否则信使语义只提示收到来信
  finishRound(full: string, sid: string, nid: string, agentName: string, direct: boolean): void {
    ChatStore.setReason(this.chatHistory, sid, nid, this.streamingReason)
    ChatStore.setAssistant(this.chatHistory, sid, nid, full)
    ChatStore.saveHistory(getContext(this), this.chatHistory)
    if (sid === this.chatHistory.active_session) {
      this.streamingText = ''
      this.streamingReason = ''
      this.isStreaming = false
      this.reloadMessages()
      if (direct) {
        this.subtitle = full
        this.subtitleMs = 12000
      } else {
        this.subtitle = '收到「' + agentName + '」的来信'
        this.subtitleMs = 4000
      }
    }
  }

  build() {
    Stack() {
      // ── 陪伴模式：摄像头实时画面背景层（最底；仅本地预览） ──
      if (this.companionMode || this.companionPending) {
        XComponent({ id: 'cameraPrev', type: XComponentType.SURFACE, controller: this.camCtl })
          .width('100%')
          .height('100%')
          .scale({ x: this.camScale, y: this.camScale }) // cover 裁剪：把表面留白推出屏幕
          .onLoad(() => {
            // 注意：不能在启动会话前清 pending——@State 变化会卸载本组件，surfaceId 变空
            if (this.companionPending) {
              this.openCameraPreview()
            }
          })
      }
      // ── 聊天终端（陪伴模式隐藏，屏幕只剩桌宠） ──
      if (!this.companionMode) {
      Row() {
        ChatSidebar({
          sessions: this.chatHistory.sessions.slice(),
          projects: this.chatHistory.projects,
          activeSid: this.chatHistory.active_session,
          theme: this.theme,
          collapsed: this.sidebarCollapsed,
          isLandscape: this.isLandscape,
          expandedPids: this.expandedPids,
          onToggleCollapse: (): void => {
            this.sidebarCollapsed = !this.sidebarCollapsed
          },
          onNewSession: (): void => {
            this.newChat()
          },
          onNewProject: (): void => {
            this.openNewProject()
          },
          onSelectSession: (sid: string): void => {
            this.switchSession(sid)
          },
          onToggleProject: (pid: string): void => {
            this.doToggleProject(pid)
          },
          onLongPressProject: (pid: string): void => {
            this.openProjectAction(pid)
          },
          onOpenSettings: (): void => {
            this.settingsVisible = true
          },
          onOpenAgents: (): void => {
            this.agentPanelVisible = true
          },
          onToggleTheme: (): void => {
            this.toggleTheme()
          },
          onLongPressSession: (sid: string): void => {
            this.openSessionAction(sid)
          }
        })
        ChatMain({
          chatInput: $chatInput,
          messages: this.messages,
          msgVersion: this.msgVersion,
          streamingText: this.streamingText,
          streamingReason: this.streamingReason,
          isStreaming: this.isStreaming,
          theme: this.theme,
          branches: this.railBranches(),
          projects: this.chatHistory.projects,
          projectPid: this.composerProjectPid(),
          onLongPressMsg: (idx: number): void => {
            this.openMsgAction(idx)
          },
          onSwitchBranch: (r: number, nid: string): void => {
            this.doSwitchBranch(r, nid)
          },
          onSelectProject: (pid: string): void => {
            this.doSelectProject(pid)
          },
          searchResults: this.searchResults,
          playerName: this.chatSettings.player_name.length > 0 ? this.chatSettings.player_name : '博士',
          agentName: this.agentNameOf(this.agentCurrent),
          composerPlaceholder: this.composerPlaceholderText(),
          sessionTitle: this.activeSessionTitle(),
          onRenameTopic: (): void => {
            this.openRenameTopic()
          },
          agents: this.chatHistory.agents,
          agentAid: this.agentCurrent,
          onSelectAgent: (aid: string): void => {
            this.doSelectAgent(aid)
          },
          onManageAgents: (): void => {
            this.agentPanelVisible = true
          },
          onConvParams: (): void => {
            this.openConvParams()
          },
          scrollCmd: this.scrollCmd,
          scrollRound: this.scrollRound,
          onSearchQuery: (text: string): void => {
            this.doSearch(text)
          },
          onPickSearchResult: (r: SearchResult): void => {
            this.pickSearchResult(r)
          },
          collapsed: this.sidebarCollapsed,
          isLandscape: this.isLandscape,
          onSend: (): void => {
            this.sendChat()
          },
          onStop: (): void => {
            this.stopGeneration()
          }
        })
      }
      .width('100%')
      .height('100%')
      .animation({ duration: 200, curve: Curve.EaseOut }) // 侧边栏折叠时主界面平滑左移
      }
      // ── 宠物（悬浮在聊天上层：独立子组件，帧循环/渲染/手势全在内部） ──
      if (this.modelsReady) {
        PetView({
          models: this.models,
          sizeScale: this.isPhone ? 0.6 : this.sizeScale, // 手机（横竖屏一致）0.6；平板 0.9
          subtitleText: this.subtitle,
          chatSettings: this.chatSettings,
          reportCmd: this.reportCmd,
          agentPrompt: ChatStore.activeAgentPrompt(this.chatHistory, this.agentCurrent, this.chatSettings.extra_prompt),
          companionActive: this.companionMode,
          subtitleMs: this.subtitleMs,
          onProactiveLine: (text: string, ms?: number): void => {
            this.subtitle = text
            if (ms !== undefined) {
              this.subtitleMs = ms
            }
          },
          onOpenSettings: (): void => {
            this.settingsVisible = true
          },
          onToggleCompanion: (): void => {
            this.toggleCompanion()
          }
        })
      }
      // ── 智能体管理面板（独立入口：与设置分开的交互逻辑） ──
      if (this.agentPanelVisible) {
        AgentPanel({
          agents: this.chatHistory.agents,
          activeAid: this.agentCurrent,
          theme: this.theme,
          onClose: (): void => {
            this.agentPanelVisible = false
          },
          onNew: (): void => {
            this.openAgentNew()
          },
          onEdit: (aid: string): void => {
            this.openAgentEdit(aid)
          },
          onSelect: (aid: string): void => {
            this.doSelectAgent(aid)
          }
        })
      }
      // ── 聊天设置面板（最上层） ──
      if (this.settingsVisible) {
        SettingsPanel({
          settings: this.chatSettings,
          theme: this.theme,
          onSave: (s: ChatSettings): void => {
            let wasVoiceOn = this.chatSettings.voice_enabled
            this.chatSettings = s
            ChatStore.saveSettings(getContext(this), s)
            this.settingsVisible = false
            // Windows 复刻：语音由关→开，立即播「干员报到」
            if (!wasVoiceOn && s.voice_enabled) {
              this.reportCmd++
            }
          },
          onClose: (): void => {
            this.settingsVisible = false
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
@Component
struct PetView {
  models: Map<string, PetModel> = new Map()
  sizeScale: number = 0.9
  onOpenSettings: () => void = () => {
  }
  @Prop companionActive: boolean = false // 陪伴模式（摄像头背景+仅桌宠）
  onToggleCompanion: () => void = () => {
  }
  @Prop @Watch('onSubtitle') subtitleText: string = ''
  @Prop subtitleMs: number = 12000 // 字幕展示时长（语音台词更长）
  @State curKey: string = 'build' // @State：切模型必须驱动触摸层几何重建（普通字段在部分更新下不重算）
  private animName: string = 'Relax'
  private animTime: number = 0
  private loop: boolean = true
  private chainQueue: string[] = [] // 动画链队列（平A连击/技能开启关闭链）
  private afterChainAnim: string | null = null // 链播完后落地的循环动画（null=回持久状态）
  private activeSkill: number = -1 // 当前开启的技能（-1=无）
  private lastTapTime: number = 0
  private lastTapX: number = -9999
  private lastTapY: number = -9999
  @State menuVisible: boolean = false
  private modeItems: MenuItem[] = [
    { label: '基建', anim: 'build' },
    { label: '战斗', anim: 'front' } // 战斗模式默认正面入场（视角区可切背面）
  ]
  private combatViewItems: MenuItem[] = [
    { label: '背面', anim: 'back' },
    { label: '正面', anim: 'front' }
  ]
  private stopped: boolean = false
  private frameCb: PetFrameCallback | null = null
  private curLayout: StateLayout | null = null
  private curTransform: RenderTransform | null = null
  // 显示框尺寸（全局统一画布后恒定，vp）
  private displayW: number = RW * 0.9
  private displayH: number = RH * 0.9
  // 光栅分辨率旋钮：缓冲几何 = vp × rasterScale，RS 缩放到表面
  // （=设备密度 → 物理 1:1 最清晰但光栅最贵；先 1.5 保帧率，实测后上调）
  private rasterScale: number = 1.1
  private xcCtl: XComponentController = new XComponentController()
  private displayCur: RenderTransform = new RenderTransform() // 每帧显示空间变换（vp）
  // 拖拽移动（长按激活）：直接维护角色底部中心的屏幕坐标
  @State charPosX: number = 0
  @State charPosY: number = 0
  private charPosInit: boolean = false
  private displayT: RenderTransform = new RenderTransform() // 显示空间变换（vp）
  private surfaceReady: boolean = false
  @State subtitleVisible: boolean = false
  private subtitleTimer: number = -1
  private subtitleFontSize: number = 15 // 字幕字号（与对话框消息同字号；2026-08-17 定案）
  @State facing: number = 1 // 朝向：1=右 -1=左（拖动方向决定）
  private dragBaseX: number = 0
  private dragBaseY: number = 0
  private lastDragPosX: number = 0
  // 触摸层在角色盒内的偏移（命中测试补坐标用：触摸层局部坐标 ≠ 三角形盒坐标）
  // @State：触摸层位置/尺寸必须随模型切换重建（战斗双击失效的真凶=这里用普通字段，
  // 切模型后层停留在旧几何而换算公式已用新偏移，点击整体偏移 ~223vp 全部落空）
  @State touchOx: number = 0
  @State touchOy: number = 0
  @State touchW: number = 337
  @State touchH: number = 337
  // ── 自由移动（Windows pet_window.py start_flight/flight_move_step 复刻） ──
  // 基建 Relax 待机 / 三技能 Skill_3_Idle 待机时随机游走；拖动/互动/菜单/切模型打断
  private wanderTimer: number = -1
  private moveActive: boolean = false
  private moveTargetX: number = 0
  private moveTargetY: number = 0
  private moveReturnAnim: string = ''
  private stuckCount: number = 0
  private stuckPosX: number = -9999
  private stuckPosY: number = -9999
  private dragging: boolean = false
  // ── 主动性发言（Windows proactive_speech 复刻：频率三档、预设台词/LLM 现编、5 条去重） ──
  @Prop @Watch('onChatSettingsChange') chatSettings: ChatSettings = ChatStore.DEFAULT_SETTINGS
  @Prop @Watch('onReportCmd') reportCmd: number = 0 // 语音 关→开 计数（父组件 +1 即播报到语音）
  @Prop agentPrompt: string = '' // 活跃智能体的系统提示词（碎碎念现编用）
  private lastReportCmd: number = 0
  onProactiveLine: (text: string, ms?: number) => void = () => {
  }
  private proactiveTimer: number = -1
  private chatterRunning: boolean = false
  private chatterCache: string[] = []
  // ── 语音（Windows _voice_click/_play_voice/_idle_voice_trigger 复刻） ──
  private voiceCooldown: boolean = false
  private voiceCdTimer: number = -1
  private voicePlayer: media.AVPlayer | null = null // 成员持有防 GC（局部变量会被回收 → 无声）
  private idleVoiceTimer: number = -1
  private idleVoicePlayed: boolean = false

  private curModel(): PetModel | null {
    let m = this.models.get(this.curKey)
    return m === undefined ? null : m
  }

  // 切换模型：固定布局 + 每模型一套缓冲/帧图（异步创建期间跳帧）
  private setModel(key: string): void {
    let model = this.models.get(key)
    if (model === undefined) {
      return
    }
    this.curKey = key
    this.curLayout = model.layout
    this.curTransform = model.layout.t
    // 显示空间（vp）：模型画布 × 尺寸倍率；XComponent 缓冲为物理像素（C++ 侧缩放）
    this.displayW = model.layout.w * this.sizeScale
    this.displayH = model.layout.h * this.sizeScale
    this.displayT.scale = model.layout.t.scale * this.sizeScale
    this.displayT.tx = model.layout.t.tx * this.sizeScale
    this.displayT.ty = model.layout.t.ty * this.sizeScale
    this.displayT.height = model.layout.h * this.sizeScale
    // 角色初始屏幕位置（仅首次；切模式保持用户拖拽的位置）
    if (!this.charPosInit) {
      this.charPosInit = true
      let d0 = display.getDefaultDisplaySync()
      let sw = px2vp(d0.width)
      let sh = px2vp(d0.height)
      this.charPosX = sw / 2
      this.charPosY = sh * 0.2 + (model.layout.h / 2 - model.charCenterPad) * this.sizeScale
    }
    // 触摸层偏移（身体轴为基准：左延展 clickLeft / 右延展 clickRight，×1.25 余量）
    this.touchOx = this.displayW / 2 - model.clickLeft * 1.25 * this.sizeScale
    this.touchOy = this.displayH - (model.charCenterPad + model.charHalfH * 1.25) * this.sizeScale
    this.touchW = (model.clickLeft + model.clickRight) * 1.25 * this.sizeScale
    this.touchH = model.charHalfH * 2.5 * this.sizeScale
  }

  onVsyncFrame(dt: number): void {
    if (this.stopped) {
      return
    }
    this.tick(dt)
    if (!this.stopped && this.frameCb !== null) {
      this.getUIContext().postFrameCallback(this.frameCb)
    }
  }

  tick(dt: number): void {
    let model = this.curModel()
    if (model === null || this.curLayout === null) {
      return
    }
    // 真实 dt 推进（VSync 时间戳）：帧率稳定时 ≈ 固定步长；下跌时跳帧保实时速度
    this.animTime += dt
    // once 动画播完：链队列有下一段则继续，否则落到 afterChainAnim（或持久状态）
    if (!this.loop) {
      let anim = model.skeleton.data.find_animation(this.animName)
      if (anim !== null && this.animTime >= anim.duration) {
        if (this.chainQueue.length > 0) {
          this.animName = this.chainQueue.shift()!
          this.animTime = 0
          this.curTransform = model.stateTransforms.get(this.animName) ?? model.layout.t
        } else {
          this.animName = this.afterChainAnim ?? model.baseAnim
          this.afterChainAnim = null
          this.animTime = 0
          this.loop = true
          this.curTransform = model.stateTransforms.get(this.animName) ?? model.layout.t
        }
      }
    }
    let sk = model.skeleton
    sk.set_to_setup_pose()
    let anim = sk.data.find_animation(this.animName)
    if (anim !== null) {
      apply_animation(anim, sk, this.animTime, this.loop, 1.0)
    }
    sk.update_world_transform()
    // 收集（vp 显示空间）→ C++ 一次调用：顶点上传+GPU 光栅化+上屏（GLES3）
    let ct = this.curTransform
    if (ct !== null) {
      this.displayCur.scale = ct.scale * this.sizeScale
      this.displayCur.tx = ct.tx * this.sizeScale
      this.displayCur.ty = ct.ty * this.sizeScale
      this.displayCur.height = this.displayH
      let batch = collect_triangles(sk, this.displayW, this.displayH, this.displayCur)
      render_frame_gl(batch.tris.buffer, batch.colors.buffer, batch.flags.buffer, batch.triCount,
        batch.segFlat.buffer, batch.segSizes.buffer, batch.segCount,
        model.tex.pixels.buffer, model.tex.width, model.tex.height,
        this.displayW, this.displayH, this.rasterScale)
    }
    // 自由移动步进（与渲染同帧率；真实 dt）
    this.moveStep(dt)
  }

  // ── 自由移动（Windows 复刻：15-40s 随机间隔、8-20s 重试、卡住 ~1s 放弃） ──
  private scheduleWander(retry: boolean): void {
    if (this.wanderTimer >= 0) {
      clearTimeout(this.wanderTimer)
      this.wanderTimer = -1
    }
    let lo = retry ? 8000 : 15000
    let hi = retry ? 20000 : 40000
    let delay = lo + Math.random() * (hi - lo)
    this.wanderTimer = setTimeout(() => {
      this.wanderTimer = -1
      this.startWander()
    }, delay)
  }

  private cancelWander(): void {
    this.moveActive = false
    if (this.wanderTimer >= 0) {
      clearTimeout(this.wanderTimer)
      this.wanderTimer = -1
    }
  }

  // 出发条件（用户定案）：基建 Relax 待机，或三技能 Skill_3_Idle 待机；非拖动非单次动画
  private startWander(): void {
    let model = this.curModel()
    if (model === null || this.dragging || !this.loop) {
      this.scheduleWander(true)
      return
    }
    let isFlyIdle = this.activeSkill === 2 && this.animName === 'Skill_3_Idle'
    let isGroundIdle = this.curKey === 'build' && this.animName === 'Relax'
    if (!isFlyIdle && !isGroundIdle) {
      this.scheduleWander(true)
      return
    }
    let sw = this.screenW()
    let sh = this.screenH()
    this.moveTargetX = 40 + Math.random() * (sw - 80)
    this.moveTargetY = 40 + Math.random() * (sh - 80)
    this.moveReturnAnim = isFlyIdle ? 'Skill_3_Idle' : 'Relax'
    if (isGroundIdle) {
      // 基建走动：有 Move 动画则播 Move（原地走 + 盒平移），否则维持 Relax
      let mv = model.skeleton.data.find_animation('Move')
      this.animName = mv !== null ? 'Move' : 'Relax'
      this.curTransform = model.layout.t
    }
    this.moveActive = true
    this.stuckCount = 0
    this.stuckPosX = -9999
    this.stuckPosY = -9999
  }

  // 每帧步进（Windows flight_move_step 同款：向目标匀速、朝向跟随、卡住放弃、到达回落）
  private moveStep(dt: number): void {
    if (!this.moveActive) {
      return
    }
    let dx = this.moveTargetX - this.charPosX
    let dy = this.moveTargetY - this.charPosY
    let dist = Math.sqrt(dx * dx + dy * dy)
    let step = 280 * dt // 移动速度 vp/s（可调旋钮）
    if (dist <= step || dist < 2) {
      this.charPosX = this.moveTargetX
      this.charPosY = this.moveTargetY
      this.moveActive = false
      let model = this.curModel()
      if (model !== null && this.moveReturnAnim.length > 0) {
        this.animName = this.moveReturnAnim
        this.curTransform = model.stateTransforms.get(this.animName) ?? model.layout.t
      }
      this.scheduleWander(false)
      return
    }
    // 卡住检测（~1 秒原地 → 放弃）
    if (Math.abs(this.charPosX - this.stuckPosX) < 0.5 && Math.abs(this.charPosY - this.stuckPosY) < 0.5) {
      this.stuckCount++
    } else {
      this.stuckCount = 0
      this.stuckPosX = this.charPosX
      this.stuckPosY = this.charPosY
    }
    if (this.stuckCount > 60) {
      this.moveActive = false
      let model = this.curModel()
      if (model !== null && this.moveReturnAnim.length > 0) {
        this.animName = this.moveReturnAnim
        this.curTransform = model.stateTransforms.get(this.animName) ?? model.layout.t
      }
      this.scheduleWander(true)
      return
    }
    // 朝向（frame_dx 语义）
    if (dx < -2) {
      this.facing = -1
    } else if (dx > 2) {
      this.facing = 1
    }
    let sw = this.screenW()
    let sh = this.screenH()
    let nx = this.charPosX + dx / dist * step
    let ny = this.charPosY + dy / dist * step
    this.charPosX = Math.max(40, Math.min(sw - 40, nx))
    this.charPosY = Math.max(40, Math.min(sh - 40, ny))
  }

  // 设置变化（如频率切换）：立即按新频率重新调度，不等旧定时器到期
  onChatSettingsChange(): void {
    this.scheduleProactive(false)
  }

  // 语音 关→开：父组件 reportCmd +1 触发（计数器同步比对象 @Prop 可靠）
  onReportCmd(): void {
    hilog.info(0x0000, 'PetVoiceDbg', 'reportCmd=%{public}d last=%{public}d', this.reportCmd,
      this.lastReportCmd)
    if (this.reportCmd !== this.lastReportCmd) {
      this.lastReportCmd = this.reportCmd
      // 延迟一个事件循环再播：@Watch 回调处于渲染阶段，此时同步改父组件 @State
      // （字幕）会被吞——音频能播但气泡不显示
      setTimeout(() => {
        this.playVoice('干员报到')
      }, 0)
    }
  }

  // 点击语音（Windows _voice_click 复刻：冷却 10 秒内=戳一下；战斗=技能开启时作战台词/否则选中台词；否则随机 BASE_TALK）
  private voiceClick(): void {
    if (this.voiceCooldown) {
      this.playVoice('戳一下')
      return
    }
    let pool: string[] = BASE_TALK
    if (this.curKey === 'back' || this.curKey === 'front') {
      pool = this.activeSkill >= 0 ? COMBAT_FIGHT : COMBAT_SELECT
    }
    let name = pool[Math.floor(Math.random() * pool.length)]
    this.playVoice(name)
    this.voiceCooldown = true
    if (this.voiceCdTimer >= 0) {
      clearTimeout(this.voiceCdTimer)
    }
    this.voiceCdTimer = setTimeout(() => {
      this.voiceCooldown = false
      this.voiceCdTimer = -1
    }, 10000)
  }

  // 闲置语音（Windows _idle_voice_trigger：启动 60 秒后播一次；字幕可见→15s 重试，
  // 拖动/移动/单次动画/战斗模式→60s 重试）
  private idleVoiceTrigger(): void {
    if (this.idleVoicePlayed) {
      return
    }
    if (this.subtitleVisible) {
      this.idleVoiceTimer = setTimeout(() => {
        this.idleVoiceTimer = -1
        this.idleVoiceTrigger()
      }, 15000)
      return
    }
    if (this.dragging || this.moveActive || !this.loop ||
      this.curKey === 'back' || this.curKey === 'front') {
      this.idleVoiceTimer = setTimeout(() => {
        this.idleVoiceTimer = -1
        this.idleVoiceTrigger()
      }, 60000)
      return
    }
    this.playVoice('闲置')
    this.idleVoicePlayed = true
  }

  // 语音开关（同步读 preferences——@Prop 同步有延迟，切换后第一句会读到旧值）
  private voiceEnabledNow(): boolean {
    let prefs = preferences.getPreferencesSync(getContext(this), { name: 'pet_settings' })
    return prefs.getSync('voice_enabled', true) as boolean
  }

  // 播放语音 + 台词字幕（Windows _play_voice：AVPlayer fdSrc 播 rawfile wav；
  // 字幕 45 秒后自动收起；受语音开关与语言设置控制）。
  // 单播放器语义：播放前强制停止旧语音（Windows setSource 替换即停——点击重置播放状态）。
  private playVoice(name: string): void {
    let en = this.voiceEnabledNow()
    hilog.info(0x0000, 'PetVoiceDbg', 'playVoice %{public}s enabled=%{public}d', name, en ? 1 : 0)
    if (!en) {
      return
    }
    let prefs = preferences.getPreferencesSync(getContext(this), { name: 'pet_settings' })
    this.releaseVoice()
    let lang = prefs.getSync('voice_language', '中文') as string
    let file = VOICE_FILES.get(name)
    if (file !== undefined) {
      let dir = lang === '日文' ? 'voice_jp/' : 'voice/'
      getContext(this).resourceManager.getRawFd(dir + file).then((fdInfo) => {
        media.createAVPlayer().then((player: media.AVPlayer) => {
          this.voicePlayer = player
          // AVPlayer 是严格异步状态机：必须在 stateChange 回调里驱动流转
          // （idle→设 fdSrc；initialized→prepare；prepared→play），直接连调会静默无声
          let fdSet = false
          player.on('stateChange', (state: string) => {
            if (state === 'idle' && !fdSet) {
              fdSet = true
              player.fdSrc = { fd: fdInfo.fd, offset: fdInfo.offset, length: fdInfo.length }
            } else if (state === 'initialized') {
              player.prepare().catch((e: Error) => {
                hilog.error(0x0000, 'PetVoice', 'prepare fail %{public}s', JSON.stringify(e))
                this.releaseVoice()
              })
            } else if (state === 'prepared') {
              player.play().catch((e: Error) => {
                hilog.error(0x0000, 'PetVoice', 'play fail %{public}s', JSON.stringify(e))
                this.releaseVoice()
              })
            } else if (state === 'completed' || state === 'error') {
              this.releaseVoice()
            }
          })
          player.on('error', (e) => {
            hilog.error(0x0000, 'PetVoice', 'player error %{public}s', JSON.stringify(e))
          })
          // 创建后初始即 idle：该状态可能不触发 change 事件，主动补一次
          if (player.state === 'idle') {
            fdSet = true
            player.fdSrc = { fd: fdInfo.fd, offset: fdInfo.offset, length: fdInfo.length }
          }
        }).catch((e: Error) => {
          hilog.error(0x0000, 'PetVoice', 'create fail %{public}s', JSON.stringify(e))
          this.releaseVoice()
        })
      }).catch((e: Error) => {
        hilog.error(0x0000, 'PetVoice', 'getRawFd fail %{public}s', JSON.stringify(e))
      })
    }
    let text = VOICE_LINES.get(name)
    if (text !== undefined) {
      this.onProactiveLine(text, 45000)
    }
  }

  private releaseVoice(): void {
    if (this.voicePlayer !== null) {
      try {
        this.voicePlayer.release()
      } catch (e) {
      }
      this.voicePlayer = null
    }
  }

  // 启动问候（Windows _greeting_voice：周年庆典 05-01~04 > 新年祝福 > 问候；生日需设置项暂缺）
  private greetingVoiceName(): string {
    let d = new Date()
    let mm = (d.getMonth() + 1).toString().padStart(2, '0')
    let dd = d.getDate().toString().padStart(2, '0')
    let today = mm + '-' + dd
    if (today >= '05-01' && today <= '05-04') {
      return '周年庆典'
    }
    if (today >= '01-01' && today <= '01-03') {
      return '新年祝福'
    }
    if ((today >= '01-28' && today <= '02-05') || (today >= '02-15' && today <= '02-22')) {
      return '新年祝福'
    }
    return '问候'
  }

  // ── 主动性发言（Windows reschedule_proactive/proactive_speech 复刻） ──
  private scheduleProactive(retry: boolean): void {
    if (this.proactiveTimer >= 0) {
      clearTimeout(this.proactiveTimer)
      this.proactiveTimer = -1
    }
    let lo: number
    let hi: number
    if (retry) {
      lo = 15000
      hi = 30000
    } else if (this.chatSettings.chatter_interval === '低频') {
      lo = 120000
      hi = 300000
    } else if (this.chatSettings.chatter_interval === '高频') {
      lo = 15000
      hi = 45000
    } else {
      lo = 45000
      hi = 120000
    }
    let delay = lo + Math.random() * (hi - lo)
    this.proactiveTimer = setTimeout(() => {
      this.proactiveTimer = -1
      this.proactiveSpeech()
    }, delay)
  }

  private proactiveSpeech(): void {
    // 跳过条件：字幕可见/拖动/移动中/单次动画播放中/闲聊请求进行中 → 短间隔重试
    if (this.subtitleVisible || this.dragging || this.moveActive || !this.loop || this.chatterRunning) {
      this.scheduleProactive(true)
      return
    }
    let apiOk = this.chatSettings.chat_base_url.length > 0 &&
      this.chatSettings.chat_api_key.length > 0 && this.chatSettings.chat_model.length > 0
    if (!apiOk) {
      // 预设台词：三技能开启（飞行状态）用飞行台词，否则闲置台词
      this.onProactiveLine(this.activeSkill === 2 ? FLIGHT_PROACTIVE_LINE : IDLE_PROACTIVE_LINE, 12000)
      this.scheduleProactive(false)
      return
    }
    // LLM 现编（流式收集完整回复；最近 5 条去重；用活跃智能体的提示词）
    this.chatterRunning = true
    let msgs: ChatMsg[] = [
      { role: 'system', content: this.agentPrompt },
      { role: 'user', content: CHATTER_PROMPT }
    ]
    new ChatApi().send(this.chatSettings.chat_base_url, this.chatSettings.chat_api_key,
      this.chatSettings.chat_model, msgs, {
        onDelta: (t: string) => {
        },
        onReason: (t: string) => {
        },
        onDone: (full: string) => {
          this.chatterRunning = false
          let text = full.trim()
          if (text.length > 0 && this.chatterCache.indexOf(text) < 0) {
            this.chatterCache.push(text)
            if (this.chatterCache.length > 5) {
              this.chatterCache.shift()
            }
            this.onProactiveLine(text, 12000)
          }
          this.scheduleProactive(false)
        },
        onError: (e: string) => {
          this.chatterRunning = false
          this.scheduleProactive(false)
        }
      })
  }


  aboutToAppear(): void {
    this.initChild()
  }

  onSubtitle(): void {
    if (this.subtitleText.length === 0) {
      return
    }
    this.subtitleVisible = true
    if (this.subtitleTimer >= 0) {
      clearTimeout(this.subtitleTimer)
    }
    this.subtitleTimer = setTimeout(() => {
      this.subtitleVisible = false
      this.subtitleTimer = -1
    }, this.subtitleMs)
  }

  aboutToDisappear(): void {
    this.stopped = true
    this.cancelWander()
    if (this.proactiveTimer >= 0) {
      clearTimeout(this.proactiveTimer)
      this.proactiveTimer = -1
    }
    if (this.voiceCdTimer >= 0) {
      clearTimeout(this.voiceCdTimer)
      this.voiceCdTimer = -1
    }
    if (this.idleVoiceTimer >= 0) {
      clearTimeout(this.idleVoiceTimer)
      this.idleVoiceTimer = -1
    }
    this.releaseVoice()
  }

  aboutToAppear2(): void {
  }

  async initChild(): Promise<void> {
    this.setModel('build')
    this.frameCb = new PetFrameCallback(this)
    this.getUIContext().postFrameCallback(this.frameCb)
    this.scheduleWander(false)
    this.scheduleProactive(false)
    // 启动问候（Windows：500ms 后播放日期问候）
    setTimeout(() => {
      this.playVoice(this.greetingVoiceName())
    }, 500)
    // 闲置语音（Windows _idle_voice_trigger：60 秒后触发一次）
    this.idleVoiceTimer = setTimeout(() => {
      this.idleVoiceTimer = -1
      this.idleVoiceTrigger()
    }, 60000)
  }

  screenW(): number {
    let d = display.getDefaultDisplaySync()
    return px2vp(d.width)
  }

  screenH(): number {
    let d = display.getDefaultDisplaySync()
    return px2vp(d.height)
  }

  // 单击互动 / 双击菜单。原版语义：动画播放中点击不打断不重置，播完再点才触发新动画。
  // 像素级命中：点中角色本体（上一帧三角形内）才算，空处点击无反应（Windows 同款手感）。
  // 注意：event 坐标是触摸层局部坐标，三角形在角色盒坐标——补上触摸层偏移
  onPetTap(event: ClickEvent): void {
    let gx = event.x + this.touchOx
    let gy = event.y + this.touchOy
    let now = Date.now()
    // 双击判定不依赖第二击命中（战斗平A前冲后角色已移位，第二击像素命中会落空）：
    // 时间窗 300ms + 位置邻近 60vp 内即算双击
    if (now - this.lastTapTime < 300 &&
      Math.abs(gx - this.lastTapX) < 60 && Math.abs(gy - this.lastTapY) < 60) {
      this.lastTapTime = 0
      this.menuVisible = !this.menuVisible // 双击开关菜单
      return
    }
    let hit = hit_test_point(gx, gy)
    if (!hit) {
      return
    }
    this.lastTapTime = now
    this.lastTapX = gx
    this.lastTapY = gy
    // 互动打断自由移动（Windows 同款：interact/menu 时取消航线）
    this.cancelWander()
    this.scheduleWander(true)
    // 点击语音（Windows _voice_click）
    this.voiceClick()
    let model = this.curModel()
    // 原作语义：循环状态（含坐下/睡觉）点击都会响应——角色被"叫醒"，播互动后回普通待机
    if (model !== null && this.loop) {
      if (this.activeSkill >= 0) {
        // 技能开启时：点击=技能攻击（一次 → 回技能待机）
        let sk = COMBAT_SKILLS[this.activeSkill]
        this.animName = sk.combat
        this.afterChainAnim = sk.idle
        this.animTime = 0
        this.loop = false
        this.curTransform = model.layout.t
      } else if (model.interactAnim !== null) {
        model.baseAnim = model.clickAnim // 叫醒：播完回点击响应状态（待机）
        this.animName = model.interactAnim
        this.animTime = 0
        this.loop = false
        this.curTransform = model.stateTransforms.get(this.animName) ?? model.layout.t
      } else if (model.comboAnims.length > 0) {
        this.chainQueue = model.comboAnims.slice()
        this.animName = this.chainQueue.shift()!
        this.animTime = 0
        this.loop = false
        this.curTransform = model.layout.t
      }
    }
  }

  // 技能开关：开启→入场链→技能待机；关闭→关闭链→回普通待机
  toggleSkill(idx: number): void {
    let model = this.curModel()
    if (model === null) {
      return
    }
    this.cancelWander()
    this.scheduleWander(true)
    let sk = COMBAT_SKILLS[idx]
    if (this.activeSkill === idx) {
      this.activeSkill = -1
      this.chainQueue = sk.off.slice()
      this.afterChainAnim = null
    } else {
      this.activeSkill = idx
      this.chainQueue = sk.on.slice()
      this.afterChainAnim = sk.idle
      // Windows _toggle_skill：开启技能播作战台词
      this.playVoice(COMBAT_FIGHT[Math.floor(Math.random() * COMBAT_FIGHT.length)])
    }
    this.animName = this.chainQueue.shift()!
    this.animTime = 0
    this.loop = false
    this.curTransform = model.layout.t
  }

  applyMenu(item: MenuItem): void {
    let model = this.curModel()
    if (model === null) {
      return
    }
    this.cancelWander()
    this.scheduleWander(true)
    if (item.once) {
      // 单次动画（如攻击）：播完回持久状态
      this.animName = item.anim
      this.animTime = 0
      this.loop = false
    } else {
      model.baseAnim = item.anim
      this.animName = item.anim
      this.animTime = 0
      this.loop = true
    }
    this.curTransform = model.stateTransforms.get(this.animName) ?? model.layout.t
  }

  switchModel(key: string): void {
    let model = this.models.get(key)
    if (model === undefined) {
      return
    }
    let wasCombat = this.curKey === 'back' || this.curKey === 'front'
    this.cancelWander()
    this.scheduleWander(true)
    this.setModel(key)
    this.animTime = 0
    // 朝向为持久状态，切模型不重置（用户 2026-08-16 定案）
    this.activeSkill = -1 // 换模型关闭技能
    this.chainQueue = []
    this.afterChainAnim = null
    // 模式切换语音（Windows toggle_combat_mode：入战斗=部署台词、回基建=任命助理；
    // 视角切换 back↔front 不播——Windows toggle_combat_view 无语音）
    let nowCombat = key === 'back' || key === 'front'
    if (wasCombat !== nowCombat) {
      if (this.voiceEnabledNow()) {
        this.playVoice(nowCombat ? COMBAT_DEPLOY[Math.floor(Math.random() * COMBAT_DEPLOY.length)] : '任命助理')
      } else {
        this.onProactiveLine(nowCombat ? '进入战斗形态，博士。' : '回到基建形态，博士。', 3000)
      }
    }
    // 入场动画：有 Start 的模型（战斗背面/正面）先播一次再进待机
    let start = model.skeleton.data.find_animation('Start')
    if (start !== null) {
      this.animName = 'Start'
      this.loop = false
    } else {
      this.animName = model.baseAnim
      this.loop = true
    }
    this.curTransform = model.stateTransforms.get(this.animName) ?? model.layout.t
  }

  build() {
    Stack() {
      // 字幕条：气泡底边贴在角色头顶上方 14vp、水平居中于角色（容器方案：
      // 底部对齐的透明列，任意行数都居中靠上、向上生长；position 只锚定左上角，
      // markAnchor 仅对变换生效——直接用 position 会与角色右上重叠）
      if (this.subtitleVisible) {
        Column() {
          Text(this.subtitleText)
            .fontSize(this.subtitleFontSize)
            .fontColor(Color.White)
            .backgroundColor('#CC1F2329')
            .borderRadius(10)
            .padding({ left: 14, right: 14, top: 9, bottom: 9 })
            .constraintSize({ maxWidth: 360 })
            .textAlign(TextAlign.Center)
        }
        .width(this.screenW())
        .height(this.charPosY - ((this.curModel()?.charHalfH ?? 150) * this.sizeScale) - 14)
        .position({ x: this.charPosX - this.screenW() / 2, y: 0 })
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
      }
      // 角色区域（居中定尺寸，不被菜单挤占）
      Stack() {
        XComponent({ id: 'petx', type: XComponentType.TEXTURE, libraryname: 'raster', controller: this.xcCtl })
          .width(this.displayW)
          .height(this.displayH)
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.None) // 触摸穿透：表面不吞点击，聊天界面在其下方正常交互
          .scale({ x: this.facing, y: 1 }) // 朝向镜像（纯变换零成本）
          .onLoad(() => {
            this.surfaceReady = true
            // 框架 Export 回调链在本机未触发 → 主动用 surfaceId 建窗
            let sid = this.xcCtl.getXComponentSurfaceId()
            if (sid.length > 0) {
              init_surface(sid)
            }
          })
        // 透明触摸层：XComponent 表面吞掉触摸（单击/双击/长按全失效的根因），
        // 交互全部挂在这个纯 ArkTS 覆盖层上（对 GL 路线同样适用）。
        // 覆盖可点击态并集（×1.25 余量）：不吞聊天点击，也不被入场/特效动画撑大
        Column()
          .width(this.touchW)
          .height(this.touchH)
          .position({
            x: this.touchOx,
            y: this.touchOy
          })
          .backgroundColor(Color.Transparent)
          .draggable(false) // 防华为中转站长按挟持（必须直接挂在触摸层上）
          .onClick((event: ClickEvent) => {
            this.onPetTap(event)
          })
          .gesture(
            GestureGroup(GestureMode.Sequence,
              LongPressGesture({ duration: 300 }),
              PanGesture()
                .onActionStart((event: GestureEvent) => {
                  this.dragBaseX = this.charPosX
                  this.dragBaseY = this.charPosY
                  this.dragging = true
                  this.cancelWander()
                })
                .onActionEnd(() => {
                  this.dragging = false
                  this.scheduleWander(true)
                })
                .onActionUpdate((event: GestureEvent) => {
                  let sw = this.screenW()
                  let sh = this.screenH()
                  // 桌宠语义：允许贴着屏幕边（保留 40vp 可见，部分出屏）——
                  // "完全可见"钳制会把垂直行程压死（横屏高度仅 ~533vp，角色高 ~286vp）
                  this.charPosX = Math.max(40, Math.min(sw - 40, this.dragBaseX + event.offsetX))
                  this.charPosY = Math.max(40, Math.min(sh - 40, this.dragBaseY + event.offsetY))
                  // 朝向 = 角色位置的帧间增量方向（Windows frame_dx 同款，位置数据已证明跟手）
                  let frameDx = this.charPosX - this.lastDragPosX
                  if (frameDx > 1) {
                    this.facing = 1
                  } else if (frameDx < -1) {
                    this.facing = -1
                  }
                  this.lastDragPosX = this.charPosX
                })
            )
          )
        // 菜单：绝对定位溢出到角色右侧（不参与布局，零挤占；在触摸层之上）
        if (this.menuVisible) {
          Column() {
            // 状态区（随模型变化；战斗模型无状态项则跳过）
            if ((this.curModel()?.menuItems.length ?? 0) > 0) {
              ForEach(this.curModel()?.menuItems, (item: MenuItem, index: number) => {
                Column() {
                  Text(item.label)
                    .fontSize(13)
                    .fontColor('#E6FFFFFF')
                }
                .width('100%')
                .height(36)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.applyMenu(item)
                  this.menuVisible = false
                })
                if (index < (this.curModel()?.menuItems.length ?? 0) - 1) {
                  Divider()
                    .color('#2EFFFFFF')
                    .width('80%')
                }
              }, (item: MenuItem) => item.anim)
              Divider()
                .color('#55FFFFFF')
                .width('90%')
            }
            // 模式区
            ForEach(this.modeItems, (item: MenuItem, index: number) => {
              Column() {
                Text(item.label)
                  .fontSize(13)
                  .fontColor((this.curKey === 'back' || this.curKey === 'front') && item.anim === 'back' ?
                    '#FFFFD080' : (this.curKey === item.anim ? '#FFFFD080' : '#E6FFFFFF'))
              }
              .width('100%')
              .height(36)
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.switchModel(item.anim)
                this.menuVisible = false
              })
              if (index < this.modeItems.length - 1) {
                Divider()
                  .color('#2EFFFFFF')
                  .width('80%')
              }
            }, (item: MenuItem) => item.anim)
            // 陪伴模式（摄像头背景 + 仅桌宠悬浮）
            Divider()
              .color('#55FFFFFF')
              .width('90%')
            Column() {
              Text(this.companionActive ? '退出陪伴' : '陪伴')
                .fontSize(13)
                .fontColor(this.companionActive ? '#FF8FFF8F' : '#E6FFFFFF')
            }
            .width('100%')
            .height(36)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              this.menuVisible = false
              this.onToggleCompanion()
            })
            // 视角区（仅战斗模式下显示）
            if (this.curKey === 'back' || this.curKey === 'front') {
              Divider()
                .color('#55FFFFFF')
                .width('90%')
              ForEach(this.combatViewItems, (item: MenuItem, index: number) => {
                Column() {
                  Text(item.label)
                    .fontSize(13)
                    .fontColor(this.curKey === item.anim ? '#FFFFD080' : '#E6FFFFFF')
                }
                .width('100%')
                .height(36)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.switchModel(item.anim)
                  this.menuVisible = false
                })
                if (index < this.combatViewItems.length - 1) {
                  Divider()
                    .color('#2EFFFFFF')
                    .width('80%')
                }
              }, (item: MenuItem) => item.anim)
              Divider()
                .color('#55FFFFFF')
                .width('90%')
              // 技能区（开关式）
              ForEach(COMBAT_SKILLS, (sk: SkillDef, index: number) => {
                Column() {
                  Text(sk.label)
                    .fontSize(13)
                    .fontColor(this.activeSkill === index ? '#FF8FFF8F' : '#E6FFFFFF')
                }
                .width('100%')
                .height(36)
                .justifyContent(FlexAlign.Center)
                .onClick(() => {
                  this.toggleSkill(index)
                  this.menuVisible = false
                })
                if (index < COMBAT_SKILLS.length - 1) {
                  Divider()
                    .color('#2EFFFFFF')
                    .width('80%')
                }
              }, (sk: SkillDef) => sk.label)
            }
          }
          .width(88)
          .backgroundColor('#D91A1A28')
          .borderRadius(14)
          .padding({ top: 4, bottom: 4 })
          .shadow({ radius: 12, color: '#66000000', offsetX: 0, offsetY: 2 })
          .animation({ duration: 150, curve: Curve.EaseOut })
          .position({
            x: this.displayW / 2 + (this.curModel()?.menuRight ?? 150) * this.sizeScale + 12,
            y: this.displayH - (this.curModel()?.charCenterPad ?? 200) * this.sizeScale - 130
          })
        }
      }
      .width(this.displayW)
      .height(this.displayH)
      .hitTestBehavior(HitTestMode.None) // 自身不响应也不阻塞兄弟：聊天界面在其下层正常可点
      .translate({
        x: this.charPosX - this.screenW() / 2,
        y: this.charPosY - this.screenH() / 2 -
          ((this.curModel()?.layout.h ?? RH) / 2 - (this.curModel()?.charCenterPad ?? MARGIN)) * this.sizeScale
      })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None) // PetView 根容器同样穿透（子节点如触摸层/菜单仍正常响应）
  }
}