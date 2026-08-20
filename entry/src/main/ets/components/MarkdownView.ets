/**
 * MarkdownView — 轻量 Markdown 渲染（LLM 回复常用子集）。
 * 行级解析：代码块 ```、标题 #~###、无序列表 -/*、有序列表 1.、引用 >、段落；
 * 行内：粗体 **x**、行内代码 `x`。ArkUI 无富文本引擎，用 Text+Span 组合渲染。
 */

// 行内段：粗体/行内代码标记
export class MdSeg {
  text: string = ''
  bold: boolean = false
  code: boolean = false
}

// 块：p=段落 code=代码块 h=标题 li=无序项 ol=有序项（num=序号） quote=引用
export class MdBlock {
  kind: string = 'p'
  segs: MdSeg[] = []
  num: number = 0
}

// 行内解析：**粗体** 与 `行内代码`（找最早出现的开标记，配对关闭）
function parseInline(line: string): MdSeg[] {
  let out: MdSeg[] = []
  let rest = line
  while (rest.length > 0) {
    let bOpen = rest.indexOf('**')
    let cOpen = rest.indexOf('`')
    let open = -1
    let closer = ''
    if (bOpen >= 0 && (cOpen < 0 || bOpen <= cOpen)) {
      open = bOpen
      closer = '**'
    } else if (cOpen >= 0) {
      open = cOpen
      closer = '`'
    }
    if (open < 0) {
      out.push({ text: rest, bold: false, code: false })
      break
    }
    if (open > 0) {
      out.push({ text: rest.substring(0, open), bold: false, code: false })
    }
    let closeIdx = rest.indexOf(closer, open + closer.length)
    if (closeIdx < 0) {
      out.push({ text: rest.substring(open), bold: false, code: false })
      break
    }
    let inner = rest.substring(open + closer.length, closeIdx)
    if (inner.length > 0) {
      out.push({ text: inner, bold: closer === '**', code: closer === '`' })
    }
    rest = rest.substring(closeIdx + closer.length)
  }
  return out
}

function isOlStart(t: string): boolean {
  let dot = t.indexOf('. ')
  if (dot <= 0) {
    return false
  }
  for (let i = 0; i < dot; i++) {
    if (t[i] < '0' || t[i] > '9') {
      return false
    }
  }
  return true
}

function olNum(t: string): number {
  let dot = t.indexOf('. ')
  let n = parseInt(t.substring(0, dot))
  return isNaN(n) ? 1 : n
}

// 块级解析
export function mdParse(text: string): MdBlock[] {
  let lines = text.split('\n')
  let blocks: MdBlock[] = []
  let i = 0
  while (i < lines.length) {
    let raw = lines[i]
    let t = raw.trim()
    // 代码块
    if (t.startsWith('```')) {
      let buf: string[] = []
      i++
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        buf.push(lines[i])
        i++
      }
      i++ // 跳过结束 ```
      let b = new MdBlock()
      b.kind = 'code'
      let s = new MdSeg()
      s.text = buf.join('\n')
      b.segs.push(s)
      blocks.push(b)
      continue
    }
    // 标题
    if (t.startsWith('### ')) {
      let b = new MdBlock()
      b.kind = 'h'
      b.segs = parseInline(t.substring(4))
      blocks.push(b)
      i++
      continue
    }
    if (t.startsWith('## ')) {
      let b = new MdBlock()
      b.kind = 'h'
      b.segs = parseInline(t.substring(3))
      blocks.push(b)
      i++
      continue
    }
    if (t.startsWith('# ')) {
      let b = new MdBlock()
      b.kind = 'h'
      b.segs = parseInline(t.substring(2))
      blocks.push(b)
      i++
      continue
    }
    // 无序列表
    if (t.startsWith('- ') || t.startsWith('* ')) {
      let b = new MdBlock()
      b.kind = 'li'
      b.segs = parseInline(t.substring(2))
      blocks.push(b)
      i++
      continue
    }
    // 有序列表
    if (isOlStart(t)) {
      let b = new MdBlock()
      b.kind = 'ol'
      b.num = olNum(t)
      b.segs = parseInline(t.substring(t.indexOf('. ') + 2))
      blocks.push(b)
      i++
      continue
    }
    // 引用
    if (t.startsWith('>')) {
      let b = new MdBlock()
      b.kind = 'quote'
      b.segs = parseInline(t.substring(1).trim())
      blocks.push(b)
      i++
      continue
    }
    // 空行
    if (t.length === 0) {
      i++
      continue
    }
    // 段落：连续非块起始行合并
    let buf: string[] = []
    while (i < lines.length) {
      let t2 = lines[i].trim()
      if (t2.length === 0 || t2.startsWith('```') || t2.startsWith('# ') || t2.startsWith('## ') ||
        t2.startsWith('### ') || t2.startsWith('- ') || t2.startsWith('* ') || t2.startsWith('>') ||
        isOlStart(t2)) {
        break
      }
      buf.push(lines[i])
      i++
    }
    let b = new MdBlock()
    b.kind = 'p'
    b.segs = parseInline(buf.join('\n'))
    blocks.push(b)
  }
  return blocks
}

// ── 渲染组件 ──
@Component
export struct MarkdownView {
  @Prop text: string = ''
  @Prop fontColor: string = '#1A1A1A'
  @Prop baseSize: number = 15

  private blocks(): MdBlock[] {
    return mdParse(this.text)
  }

  @Builder
  inlineSegs(segs: MdSeg[], size: number, weight: FontWeight, color: string) {
    ForEach(segs, (s: MdSeg, i2: number) => {
      Span(s.text)
        .fontSize(size)
        .fontColor(s.code ? '#C7254E' : color)
        .fontWeight(s.bold ? FontWeight.Bold : weight)
    }, (s: MdSeg, i2: number) => i2.toString() + '-' + s.text.substring(0, 8))
  }

  build() {
    Column({ space: 4 }) {
      ForEach(this.blocks(), (b: MdBlock, idx: number) => {
        if (b.kind === 'code') {
          Text(b.segs.length > 0 ? b.segs[0].text : '')
            .fontSize(this.baseSize - 2)
            .fontColor('#333333')
            .backgroundColor('#F5F5F5')
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .width('100%')
        } else if (b.kind === 'h') {
          Text() {
            this.inlineSegs(b.segs, this.baseSize + 2, FontWeight.Bold, this.fontColor)
          }
          .lineHeight(26)
        } else if (b.kind === 'li') {
          Row() {
            Text('•  ')
              .fontSize(this.baseSize)
              .fontColor(this.fontColor)
            Text() {
              this.inlineSegs(b.segs, this.baseSize, FontWeight.Normal, this.fontColor)
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else if (b.kind === 'ol') {
          Row() {
            Text(b.num.toString() + '.  ')
              .fontSize(this.baseSize)
              .fontColor(this.fontColor)
            Text() {
              this.inlineSegs(b.segs, this.baseSize, FontWeight.Normal, this.fontColor)
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else if (b.kind === 'quote') {
          Row() {
            Text('')
              .width(3)
              .height(30)
              .borderRadius(2)
              .backgroundColor('#DDDDDD')
              .margin({ right: 8 })
            Text() {
              this.inlineSegs(b.segs, this.baseSize - 1, FontWeight.Normal, '#777777')
            }
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          Text() {
            this.inlineSegs(b.segs, this.baseSize, FontWeight.Normal, this.fontColor)
          }
          .lineHeight(24)
        }
      }, (b: MdBlock, idx: number) => idx.toString() + '-' + b.kind + '-' + b.segs.length.toString())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
