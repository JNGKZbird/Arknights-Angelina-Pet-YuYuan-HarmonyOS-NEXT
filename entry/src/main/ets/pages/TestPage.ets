/**
 * spine38 loader 验证页（临时）：加载三套 skel 输出摘要，与 Python test_spine_load.py 基准比对。
 * 验证通过后可删除本页并恢复 main_pages.json。
 */
import {
  SkeletonBinary, SkeletonData, Skin, AttachmentLoader, Attachment,
  RegionAttachment, MeshAttachment, BoundingBoxAttachment, PathAttachment,
  PointAttachment, ClippingAttachment
} from '../spine38/loader'
import { Skeleton } from '../spine38/skeleton'
import { apply_animation } from '../spine38/animation'
import { Animation } from '../spine38/loader'
import { ChatApi, ChatMsg } from '../model/ChatApi'
import { ChatStore, ChatHistory } from '../model/ChatStore'
import { TextureAtlas, AtlasAttachmentLoaderImpl } from '../spine38/atlas'
import { render_skeleton_cpu, render_skeleton_cpu_native, RenderTransform, Texture } from '../spine38/renderer'
import { image } from '@kit.ImageKit'
import { util } from '@kit.ArkTS'

class StubLoader extends AttachmentLoader {
  new_region_attachment(skin: Skin, name: string, path: string): RegionAttachment | null {
    return new RegionAttachment(name)
  }

  new_mesh_attachment(skin: Skin, name: string, path: string): MeshAttachment | null {
    return new MeshAttachment(name)
  }

  new_bounding_box_attachment(skin: Skin, name: string): BoundingBoxAttachment | null {
    return new BoundingBoxAttachment(name)
  }

  new_path_attachment(skin: Skin, name: string): PathAttachment | null {
    return new PathAttachment(name)
  }

  new_point_attachment(skin: Skin, name: string): PointAttachment | null {
    return new PointAttachment(name)
  }

  new_clipping_attachment(skin: Skin, name: string): ClippingAttachment | null {
    return new ClippingAttachment(name)
  }
}

function countClips(sd: SkeletonData): number {
  let clips = 0
  sd.skins.forEach((skin: Skin) => {
    skin.attachments.forEach((inner: Map<string, Attachment>) => {
      inner.forEach((att: Attachment) => {
        if (att instanceof ClippingAttachment) {
          clips++
        }
      })
    })
  })
  return clips
}

// Python 基准（setup 姿态骨骼指纹，2026-08-14 生成）
class ExpectedFingerprint {
  model: string
  bones: number
  fx: number
  fy: number
  fa: number
  fb: number
  fc: number
  fd: number
  fr: number
  bx: number
  by: number
  bw: number
  bh: number
  cache: number

  constructor(model: string, bones: number, fx: number, fy: number, fa: number, fb: number,
    fc: number, fd: number, fr: number, bx: number, by: number, bw: number, bh: number,
    cache: number) {
    this.model = model
    this.bones = bones
    this.fx = fx
    this.fy = fy
    this.fa = fa
    this.fb = fb
    this.fc = fc
    this.fd = fd
    this.fr = fr
    this.bx = bx
    this.by = by
    this.bw = bw
    this.bh = bh
    this.cache = cache
  }
}

const EXPECTED: ExpectedFingerprint[] = [
  new ExpectedFingerprint('build', 172, -2543.916485, 31300.559933, 17.382774, 81.536394,
    -81.532680, 17.381254, -2179.849955, -245.47, -4.50, 397.70, 465.00, 188),
  new ExpectedFingerprint('back', 148, -3374.049788, 25214.711230, 12.889570, 74.721280,
    -74.717566, 12.888051, -2003.069962, -240.65, -4.50, 395.85, 465.00, 156),
  new ExpectedFingerprint('front', 174, -2542.116401, 31853.749926, 18.401273, 82.536223,
    -82.532509, 18.399754, -2179.849955, -240.65, -4.50, 392.88, 465.00, 192)
]

// 动画指纹基准（Python 2026-08-14 生成）：model|动画|t|fx|fy|bounds
const ANIM_EXPECTED: string[] = [
  'build|Default|0|1333.235697|37820.491486|-208.91|27.64|479.79|427.72',
  'build|Default|0|1333.235697|37820.491486|-208.91|27.64|479.79|427.72',
  'build|Interact|0|1333.235697|37820.491486|-208.91|27.64|479.79|427.72',
  'build|Interact|1.9166666269|1737.099494|37972.277604|-211.87|12.58|484.75|440.44',
  'build|Move|0|1808.322748|36726.429292|-213.93|24.23|488.11|426.39',
  'build|Move|0.5|1853.153723|33924.932187|-225.52|5.81|500.53|427.47',
  'build|Relax|0|1333.235697|37820.491486|-208.91|27.64|479.79|427.72',
  'build|Relax|2|1333.235697|37820.491486|-208.91|27.64|479.79|427.72',
  'build|Sit|0|-1503.845843|11395.702368|-197.73|-132.18|353.70|414.38',
  'build|Sit|1.3333333731|-245.795516|11446.555119|-206.89|-132.16|356.81|422.71',
  'back|Attack|0|-1959.121114|26171.992206|-268.33|-2.41|428.96|424.78',
  'back|Attack|0.75|-1162.120094|28339.651263|-246.89|-2.41|478.89|461.62',
  'back|Default|0|-1667.931112|26199.542205|-268.33|-2.41|428.96|424.78',
  'back|Default|0|-1667.931112|26199.542205|-268.33|-2.41|428.96|424.78',
  'back|Idle|0|-1667.931112|26199.542205|-268.33|-2.41|428.96|424.78',
  'back|Idle|2|-1667.931112|26199.542205|-268.33|-2.41|428.96|424.78',
  'back|Skill_1_End|0|-2449.715512|29235.737036|-243.02|34.31|490.33|419.44',
  'back|Skill_1_End|0.5|-4751.571651|30297.067216|-348.08|39.23|543.52|414.95',
  'back|Skill_1_Idle|0|-2449.715512|29235.737036|-243.02|34.31|490.33|419.44',
  'back|Skill_1_Idle|2|-2449.715512|29235.737036|-243.02|34.31|490.33|419.44',
  'front|Attack|0|-1561.713443|33156.465588|-270.64|-1.64|433.96|420.51',
  'front|Attack|0.75|135.115436|34318.272678|-260.67|-1.41|476.86|463.65',
  'front|Attack_Down|0|-1561.713443|33156.465588|-270.64|-1.64|433.96|420.51',
  'front|Attack_Down|0.75|395.291693|33580.522801|-238.71|-1.41|438.37|463.65',
  'front|Default|0|-1270.523441|33184.015587|-270.64|-1.64|433.96|420.51',
  'front|Default|0|-1270.523441|33184.015587|-270.64|-1.64|433.96|420.51',
  'front|Die|0|-1270.523441|33184.015587|-270.64|-1.64|433.96|420.51',
  'front|Die|0.5|-3954.236729|32834.632181|-331.54|-1.52|502.48|419.66',
  'front|Idle|0|-1270.523441|33184.015587|-270.64|-1.64|433.96|420.51',
  'front|Idle|2|-1270.523441|33184.015587|-270.64|-1.64|433.96|420.51'
]

function boneSums(sk: Skeleton): number[] {
  let fx = 0.0
  let fy = 0.0
  for (let i = 0; i < sk.bones.length; i++) {
    fx += sk.bones[i].world_x
    fy += sk.bones[i].world_y
  }
  return [fx, fy]
}

// 加载 PNG 纹理。设备解码管线会输出预乘像素（readPixelsToBuffer 返回内部预乘存储），
// 此处读回后反预乘一次得到直通 alpha。
async function loadTexture(context: Context, rawfilePath: string): Promise<Texture> {
  let data = await context.resourceManager.getRawFileContent(rawfilePath)
  let imageSource = image.createImageSource(data.buffer)
  let pixelMap = await imageSource.createPixelMap()
  let buffer = new ArrayBuffer(pixelMap.getPixelBytesNumber())
  await pixelMap.readPixelsToBuffer(buffer)
  let bytes = new Uint8Array(buffer)
  let probe = (12 * 752 + 285) * 4 // build 模型 752 宽，固定探针
  let rawBefore = bytes[probe]
  for (let i = 0; i < bytes.length; i += 4) {
    let a = bytes[i + 3]
    if (a > 0 && a < 255) {
      bytes[i] = Math.min(255, Math.round(bytes[i] * 255 / a))
      bytes[i + 1] = Math.min(255, Math.round(bytes[i + 1] * 255 / a))
      bytes[i + 2] = Math.min(255, Math.round(bytes[i + 2] * 255 / a))
    }
  }
  let afterLoop = bytes[probe]
  let buf2 = new ArrayBuffer(pixelMap.getPixelBytesNumber())
  await pixelMap.readPixelsToBuffer(buf2)
  let b2 = new Uint8Array(buf2)
  let secondRead = b2[probe]
  let info = pixelMap.getImageInfoSync()
  let tex = new Texture()
  tex.width = info.size.width
  tex.height = info.size.height
  tex.pixels = bytes
  tex.debug = 'R通道探针 原始读回=' + rawBefore + ' → 循环后=' + afterLoop + ' → 二次读回=' + secondRead
  return tex
}

async function createFramePm(context: Context, w: number, h: number): Promise<image.PixelMap> {
  let shell = await context.resourceManager.getRawFileContent('pixel1x1.png')
  let imageSource = image.createImageSource(shell.buffer)
  let opts: image.DecodingOptions = {
    editable: true,
    desiredSize: { width: w, height: h },
    desiredPixelFormat: image.PixelMapFormat.RGBA_8888
  }
  return await imageSource.createPixelMap(opts)
}

@Entry
@Component
struct TestPage {
  @State result: string = '加载中...'
  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private renderSk: Skeleton | null = null
  private renderReady: boolean = false
  private frameBuffer: Uint8Array = new Uint8Array(300 * 366 * 4)
  private premulBuf: Uint8Array = new Uint8Array(300 * 366 * 4)
  private pmA: image.PixelMap | null = null
  private pmB: image.PixelMap | null = null
  private useA: boolean = true
  private tex0: Texture | null = null
  @State displayPm: image.PixelMap | null = null

  aboutToAppear(): void {
    this.runTest()
  }

  async runTest(): Promise<void> {
    try {
      let ctx = getContext(this)
      let models: string[][] = [
        ['build', 'spine/build/build_char_1015_aglna2.skel'],
        ['back', 'spine/back/char_1015_aglna2.skel'],
        ['front', 'spine/front/char_1015_aglna2.skel']
      ]
      let lines: string[] = []
      // ── ChatApi SSE 解析器冒烟（假数据，无网络） ──
      let sseSample: string[] = []
      sseSample.push('data: {"choices":[{"delta":{"content":"你好"}}]}')
      sseSample.push('')
      sseSample.push('data: {"choices":[{"delta":{"content":"，博士"}}]}')
      sseSample.push('')
      sseSample.push('data: [DONE]')
      sseSample.push('')
      let parsed = ChatApi.parseSseChunk(sseSample.join('\n'))
      lines.push('[SSE解析] 增量=' + JSON.stringify(parsed) + '（应=你好/，博士）')
      // ── ChatStore 上下文拼装冒烟 ──
      let h0: ChatHistory = { active_session: '', sessions: [], projects: [], agents: [] }
      let sid0 = ChatStore.newSession(h0, '测试首条消息标题')
      h0.active_session = sid0
      let nid0 = ChatStore.appendUserRound(h0, sid0, '早上好')
      ChatStore.setAssistant(h0, sid0, nid0, '早安，博士')
      let s0 = ChatStore.DEFAULT_SETTINGS
      ChatStore.appendUserRound(h0, sid0, '今天天气不错')
      let msgs0 = ChatStore.buildPathMessages(h0, s0, '测试提示词')
      lines.push('[上下文] system=' + msgs0[0].role + ' 条数=' + msgs0.length +
        ' 末条前缀=' + (msgs0[msgs0.length - 1].content.substring(0, 6)) + '（应为[HH:MM]）')
      // ── 实时 API 冒烟（需在设置中配置 key；未配置仅提示） ──
      let settings0 = await ChatStore.loadSettings(ctx)
      if (settings0.chat_api_key.length > 0) {
        lines.push('[API冒烟] 发起请求 model=' + settings0.chat_model)
        let api0 = new ChatApi()
        let testMsgs: ChatMsg[] = []
        testMsgs.push({ role: 'user', content: '请回复：酸橙' })
        api0.send(settings0.chat_base_url, settings0.chat_api_key, settings0.chat_model,
          testMsgs, {
            onDelta: (t: string) => {
            },
            onReason: (t: string) => {
            },
            onDone: (full: string) => {
              this.result = lines.join('\n') + '\n[API冒烟] 完成：' + full
            },
            onError: (e: string) => {
              this.result = lines.join('\n') + '\n[API冒烟] 失败：' + e
            }
          })
      } else {
        lines.push('[API冒烟] 未配置 key（设置面板实装后可测）')
      }
      for (let i = 0; i < models.length; i++) {
        let data = await ctx.resourceManager.getRawFileContent(models[i][1])
        let sd = new SkeletonBinary(new StubLoader()).read_skeleton_data(data)
        let names: string[] = []
        for (let a = 0; a < sd.animations.length; a++) {
          names.push(sd.animations[a].name)
        }
        let dur: string[] = []
        let limit = Math.min(6, sd.animations.length)
        for (let a = 0; a < limit; a++) {
          dur.push(sd.animations[a].name + '=' + sd.animations[a].duration.toFixed(2) + 's')
        }
        lines.push(models[i][0] + ': 版本=' + sd.version + ' 骨骼=' + sd.bones.length +
          ' 插槽=' + sd.slots.length + ' 动画=' + sd.animations.length + ' 皮肤=' + sd.skins.length)
        lines.push('  动画列表: ' + names.join(', '))
        lines.push('  时长: ' + dur.join(', '))
        lines.push('  裁剪附件: ' + countClips(sd))
        // setup 姿态骨骼指纹（对照 Python 基准）
        let sk = new Skeleton(sd)
        sk.set_to_setup_pose()
        sk.update_world_transform()
        let fx = 0.0
        let fy = 0.0
        let fa = 0.0
        let fb = 0.0
        let fc = 0.0
        let fd = 0.0
        let fr = 0.0
        for (let b = 0; b < sk.bones.length; b++) {
          let bone = sk.bones[b]
          fx += bone.world_x
          fy += bone.world_y
          fa += bone.a
          fb += bone.b
          fc += bone.c
          fd += bone.d
          fr += bone.rotation
        }
        let bounds = sk.get_bounds()
        let exp = EXPECTED[i]
        let ok = exp.bones === sd.bones.length &&
          Math.abs(fx - exp.fx) < 0.001 && Math.abs(fy - exp.fy) < 0.001 &&
          Math.abs(fa - exp.fa) < 0.001 && Math.abs(fb - exp.fb) < 0.001 &&
          Math.abs(fc - exp.fc) < 0.001 && Math.abs(fd - exp.fd) < 0.001 &&
          Math.abs(fr - exp.fr) < 0.001 &&
          Math.abs(bounds[0] - exp.bx) < 0.01 && Math.abs(bounds[1] - exp.by) < 0.01 &&
          Math.abs(bounds[2] - exp.bw) < 0.01 && Math.abs(bounds[3] - exp.bh) < 0.01 &&
          sk.update_cache.length === exp.cache
        lines.push('  [骨架指纹] ' + (ok ? 'PASS' : 'FAIL'))
        if (!ok) {
          lines.push('  实际: fx=' + fx.toFixed(6) + ' fy=' + fy.toFixed(6) +
            ' bounds=(' + bounds[0].toFixed(2) + ',' + bounds[1].toFixed(2) + ') cache=' +
            sk.update_cache.length)
        }
        // 动画指纹
        let anim_pass = 0
        let anim_total = 0
        for (let r = 0; r < ANIM_EXPECTED.length; r++) {
          let parts = ANIM_EXPECTED[r].split('|')
          if (parts[0] !== models[i][0]) {
            continue
          }
          anim_total++
          let an: Animation | null = sd.find_animation(parts[1])
          let t = parseFloat(parts[2])
          let exp_fx = parseFloat(parts[3])
          let exp_fy = parseFloat(parts[4])
          let exp_bx = parseFloat(parts[5])
          let exp_by = parseFloat(parts[6])
          let exp_bw = parseFloat(parts[7])
          let exp_bh = parseFloat(parts[8])
          sk.set_to_setup_pose()
          apply_animation(an!, sk, t, true, 1.0)
          sk.update_world_transform()
          let sums = boneSums(sk)
          let ab = sk.get_bounds()
          let aok = Math.abs(sums[0] - exp_fx) < 0.01 && Math.abs(sums[1] - exp_fy) < 0.01 &&
            Math.abs(ab[0] - exp_bx) < 0.01 && Math.abs(ab[1] - exp_by) < 0.01 &&
            Math.abs(ab[2] - exp_bw) < 0.01 && Math.abs(ab[3] - exp_bh) < 0.01
          if (aok) {
            anim_pass++
          } else {
            lines.push('  失败: ' + parts[1] + ' t=' + parts[2] + ' 实际 fx=' + sums[0].toFixed(6) +
              ' fy=' + sums[1].toFixed(6) + ' bounds=(' + ab[0].toFixed(2) + ',' + ab[1].toFixed(2) +
              ') ' + ab[2].toFixed(2) + 'x' + ab[3].toFixed(2))
          }
        }
        lines.push('  [动画指纹] ' + (anim_pass === anim_total ? 'PASS' : 'FAIL') +
          ' ' + anim_pass + '/' + anim_total)
        lines.push('')
      }
      this.result = lines.join('\n')
      // 渲染验证：build 模型 Default@t=0（分步日志定位）
      try {
        this.result += '\n[渲染] 读取 atlas...'
        let atlasData = await ctx.resourceManager.getRawFileContent('spine/build/build_char_1015_aglna2.atlas')
        let decoder = util.TextDecoder.create('utf-8')
        let atlas = new TextureAtlas(decoder.decodeToString(atlasData))
        this.result += '\n[渲染] atlas 解析 OK, pages=' + atlas.pages.length
        for (let p = 0; p < atlas.pages.length; p++) {
          let page = atlas.pages[p]
          this.result += '\n[渲染] 加载贴图 ' + page.name + ' ...'
          page.texture = await loadTexture(ctx, 'spine/build/' + page.name)
          this.result += '\n[渲染] 贴图 OK'
          let tdbg = page.texture as Texture
          let si = (12 * tdbg.width + 285) * 4
          this.result += '\n[贴图像素] (285,12) RGBA=' + tdbg.pixels[si] + ',' + tdbg.pixels[si + 1] +
            ',' + tdbg.pixels[si + 2] + ',' + tdbg.pixels[si + 3] + '（应=155,106,89,209）'
          this.result += '\n[贴图取证] ' + tdbg.debug
        }
        let rskelData = await ctx.resourceManager.getRawFileContent('spine/build/build_char_1015_aglna2.skel')
        let rsd = new SkeletonBinary(new AtlasAttachmentLoaderImpl(atlas)).read_skeleton_data(rskelData)
        this.result += '\n[渲染] 骨架 OK'
        // UV 调试（对照 Python 基准：page 752x752；B_L_O_Hand_A x=692 y=82 25x38 deg=90）
        let page0 = atlas.pages[0]
        this.result += '\n[UV调试] page=' + page0.width + 'x' + page0.height
        if (atlas.regions.length > 0) {
          let r0 = atlas.regions[0]
          this.result += '\n[UV调试] region=' + r0.name + ' x=' + r0.x + ' y=' + r0.y + ' ' +
            r0.width + 'x' + r0.height + ' u=' + r0.u.toFixed(6) + ' v=' + r0.v.toFixed(6) +
            ' deg=' + r0.degrees
        }
        let skin0 = rsd.skins[0]
        let firstMesh: MeshAttachment | null = null
        for (let inner of skin0.attachments.values()) {
          if (firstMesh !== null) {
            break
          }
          for (let att of inner.values()) {
            if (att instanceof MeshAttachment) {
              firstMesh = att
              break
            }
          }
        }
        if (firstMesh !== null) {
          let fu = firstMesh.uvs!
          this.result += '\n[UV调试] mesh=' + firstMesh.name + ' wvl=' + firstMesh.world_vertices_length +
            ' uvs=' + fu[0].toFixed(6) + ',' + fu[1].toFixed(6) + ',' + fu[2].toFixed(6) + ',' +
            fu[3].toFixed(6) + ',' + fu[4].toFixed(6) + ',' + fu[5].toFixed(6)
        }
        let rsk = new Skeleton(rsd)
        rsk.set_to_setup_pose()
        let danim: Animation | null = rsd.find_animation('Default')
        apply_animation(danim!, rsk, 0, true, 1.0)
        rsk.update_world_transform()
        this.renderSk = rsk
        this.tex0 = atlas.pages[0].texture as Texture
        this.renderReady = true
        // 官方配方：用 1×1 透明 PNG 壳 + desiredPixelFormat 指定格式创建可写 PixelMap
        // （直接 createPixelMap(buffer, opts) 的实际格式可能不是 RGBA_8888，alpha 被丢弃）
        this.pmA = await createFramePm(ctx, 300, 366)
        this.pmB = await createFramePm(ctx, 300, 366)
        let finfo = this.pmA.getImageInfoSync()
        this.result += '\n[帧格式] pixelFormat=' + finfo.pixelFormat + ' alphaType=' + finfo.alphaType
        this.result += '\n[渲染] 姿态就绪，调用 drawFrame'
        this.drawFrame()
      } catch (e) {
        this.result += '\n[渲染失败] ' + JSON.stringify(e)
        return
      }
    } catch (e) {
      this.result = '加载失败: ' + JSON.stringify(e)
    }
  }

  drawFrame(): void {
    if (!this.renderReady || this.renderSk === null || this.pmA === null || this.pmB === null) {
      return
    }
    const RW = 300
    const RH = 366
    const MARGIN = 14
    let b = this.renderSk.get_bounds()
    let scale = Math.min((RW - MARGIN * 2) / b[2], (RH - MARGIN * 2) / b[3])
    let t = new RenderTransform()
    t.scale = scale
    t.tx = RW / 2 - (b[0] + b[2] / 2) * scale
    t.ty = MARGIN - b[1] * scale
    t.height = RH
    try {
      let t0 = Date.now()
      render_skeleton_cpu(this.renderSk, this.frameBuffer, RW, RH, t)
      let cost = Date.now() - t0
      this.result += '\n[渲染] ArkTS ' + cost + 'ms（光栅 ' + t.stats[1] + 'ms）'
      if (this.tex0 !== null) {
        let t1 = Date.now()
        render_skeleton_cpu_native(this.renderSk, this.tex0, this.frameBuffer, RW, RH, t)
        let ncost = Date.now() - t1
        this.result += '\n[渲染] C++内核 ' + ncost + 'ms'
      }
      this.finishFrame()
    } catch (e) {
      this.result += '\n[渲染失败] ' + (e as Error).message
    }
  }

  finishFrame(): void {
    if (this.pmA === null || this.pmB === null) {
      return
    }
    // 转预乘后写入（帧 PixelMap 声明 PREMUL，直通写入会透明变黑——A/B 实证）
    for (let i = 0; i < this.frameBuffer.length; i += 4) {
      let a = this.frameBuffer[i + 3]
      this.premulBuf[i] = Math.round(this.frameBuffer[i] * a / 255)
      this.premulBuf[i + 1] = Math.round(this.frameBuffer[i + 1] * a / 255)
      this.premulBuf[i + 2] = Math.round(this.frameBuffer[i + 2] * a / 255)
      this.premulBuf[i + 3] = a
    }
    // 双缓冲：写完交换 @State 触发 Image 重绘
    let target = this.useA ? this.pmA : this.pmB
    this.useA = !this.useA
    target.writeBufferToPixels(this.premulBuf.buffer).then(() => {
      this.displayPm = target
    }).catch((err: Object) => {
      this.result += '\n[写入失败] ' + JSON.stringify(err)
    })
  }

  build() {
    Scroll() {
      Column() {
        Text('spine38 验证（对照 Python 基准）')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .margin({ bottom: 8 })
        Text(this.result)
          .fontSize(11)
          .lineHeight(16)
          .width('100%')
          .textAlign(TextAlign.Start)
        Column() {
          Image(this.displayPm)
            .width(300)
            .height(366)
            .objectFit(ImageFit.Fill)
        }
        .width(300)
        .height(366)
        .backgroundColor('#FFFF0000') // 亮红测试底：一眼分辨透明是否生效
        .margin({ top: 8 })
        .onAppear(() => {
          this.drawFrame()
        })
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
