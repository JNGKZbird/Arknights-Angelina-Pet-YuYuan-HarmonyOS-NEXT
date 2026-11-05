# 予愿安洁莉娜桌宠（正式名：酸橙味的信）· 鸿蒙 HarmonyOS NEXT 版 · 三端实现 · Spine 3.8

《酸橙味的信》是予愿安洁莉娜桌宠的正式软件名。
《酸橙味的信》由 JNGKZbird 独立重做并维护，原作：AstrariaX / Angelina-pet。
《酸橙味的信》鸿蒙版是移动端先行版，面向《明日方舟》玩家的鸿蒙原生手机/平板桌宠：ArkTS + C++ GLES3 实时渲染 Spine 3.8 骨骼，带 LLM 对话树/导航轨、小窗模式、摄像头陪伴与自定义智能体。
《酸橙味的信》原创代码采用 MIT 许可；`entry/src/main/ets/spine38/` 按 Spine Runtimes License 授权，不是 MIT。

> 人类对前进的渴望本就不可战胜。万物互联，全面自主——我们有着有限的寿命，却有着无穷的野心。加入鸿蒙生态，和我们一起，书写属于我们的未来。
>
> ——受鸿蒙精神与《明日方舟》「孤星」启发

《酸橙味的信》的日常体验是：安洁莉娜住在鸿蒙设备上，单击戳一戳，双击唤出菜单，长按拖动换位置；菜单里能切换基建/战斗、开摄像头陪伴。配置 AI 后，她会聊天，并在空闲时碎碎念；不配置也能使用动作、语音与战斗。对话与设置默认留在本机。小窗由系统自由窗口提供。

设置里还藏了三个彩蛋：输入「酸橙味的信」，就会切换到安洁莉娜本体的人格；另外两个，都是「你是」加某位角色的四字名字。是谁，自己试试~

## 一、速览

- **正式名**：《酸橙味的信》是予愿安洁莉娜桌宠的正式软件名。仓库名：`Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT`；别名：YuYuan、芋圆；安装后的应用名即《酸橙味的信》。
- **是什么 / 给谁**：面向《明日方舟》玩家的鸿蒙 NEXT 手机/平板桌宠；小窗、摄像头陪伴、中/日语音与基建/战斗都在同一个应用里。
- **平台**：鸿蒙 NEXT（HarmonyOS NEXT）原生应用；Windows 为主仓，安卓为另一移动端子仓。
- **渲染**：Spine 3.8 实时骨骼；ArkTS + C++ GLES3，GLES3 掩码纹理管线；核心语义与 Windows 版 `spine38/` 同源，非逐帧序列。
- **智能功能**：OpenAI 兼容 AI 聊天、LLM 对话树/导航轨、自定义智能体、LLM 碎碎念；本地优先，无遥测。
- **素材分发**：自 v3.1 起，素材不随仓库分发，首次启动时由程序下载。首次启动需要联网。
- **许可**：原创代码 MIT；`entry/src/main/ets/spine38/` 按 Spine Runtimes License（非 MIT）；项目持有 Spine Editor 许可（Spine Essential）。

## 二、三端与关联项目

> “从古老的祖先学会使用工具与火至今，人类唯一的壮举即是‘传承’。”
>
> ——《明日方舟》「孤星」旁白

《酸橙味的信》支持 Windows、鸿蒙 NEXT、安卓三端，鸿蒙与安卓为子仓库。本页是鸿蒙子仓。

- **Windows 主仓**：[Arknights-Angelina-Pet-YuYuan](https://github.com/JNGKZbird/Arknights-Angelina-Pet-YuYuan) — Python + PySide6。
  渲染核心衍生自官方 spine-ts 3.8（按 Spine Runtimes License，非 MIT），Python 运行时自研；Windows 端最高 120fps。
- **鸿蒙（本仓库）**：[Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT](https://github.com/JNGKZbird/Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT) — ArkTS + C++ GLES3。
- **安卓子仓**：[JNGKZbird-Arknights-Angelina-Pet--YuYuan-Android](https://github.com/JNGKZbird/JNGKZbird-Arknights-Angelina-Pet--YuYuan-Android) — Kotlin + Compose，安卓原生移植。
- **人格蒸馏库**：[Arknights-Persona-Distill](https://github.com/JNGKZbird/Arknights-Persona-Distill) — 《明日方舟》干员人格包，可导入桌宠。
- **能天使桌宠 · 捣蛋鬼**：[lemuel-scamp](https://github.com/JNGKZbird/lemuel-scamp) — 另一款桌面宠物，主角是能天使和她的异格「新约能天使」。
- **素材档案库**：[Arknights-Desktop-Pets-Archive](https://github.com/JNGKZbird/Arknights-Desktop-Pets-Archive) — 素材 zip 与下载包。

三端三套独立代码，都实现同一套 Spine 渲染管线语义；鸿蒙端用 GLES3 掩码纹理管线，S-H 裁剪语义衍生自官方 spine-ts 3.8。

## 三、她能做什么

《酸橙味的信》鸿蒙版把角色、聊天与桌面互动放在同一个应用里。下表只列鸿蒙版已实装的能力。

| 功能 | 鸿蒙说明 |
|---|---|
| Spine 3.8 实时骨骼 | ArkTS + C++ GLES3；GLES3 掩码纹理管线；实时骨骼动画，非逐帧序列 |
| AI 聊天 | OpenAI 兼容；可接 DeepSeek、Moonshot、智谱等；地址、密钥、模型、上下文条数可配 |
| LLM 对话终端 | 流式思考过程、Markdown 渲染、消息内搜索 |
| 对话树 + 导航轨 | 每轮一根横条；分支亮圆点；点任意一轮跳回；导航轨在横屏显示 |
| 项目 / 文件夹归档 | 对话按项目归档；项目可重命名/删除，会话可移动到项目 |
| 自定义智能体 | 不预设角色智能体；默认只有安洁莉娜与空智能体「陌生的友人」，其余自建，名称与提示词可改；非默认智能体以“来信”形式提示回复 |
| 中 / 日语音 | 中文/日文切换；点击语音与基建/战斗语音 |
| 戳一戳 | 基建模式点击触发动作与语音；战斗模式触发攻击 |
| 基建 / 战斗模式 | 普攻连击、技能 1/2/3 完整动画、正/背面视角 |
| 小窗模式 | 系统自由窗口；在系统多任务/自由窗口里把小窗悬浮在其他应用之上（鸿蒙独有） |
| 摄像头陪伴 | 授权后把实时画面作背景；仅本地预览，不存储、不上传，无拍照/录像 |
| LLM 碎碎念 | 空闲时由 LLM 自发独白；设置里的“主动性发言频率”低/中/高可调；无 Key 时用预设台词 |
| 人格包 / 彩蛋 | 设置“额外提示词”可切换人格；输入「酸橙味的信」切本体人格 |
| 素材首启下载 | v3.1 起素材不随 HAP 分发；首次启动由程序下载，也可手动导入官方 zip |

### 对话树与导航轨

对话按轮次组织成树：重新生成或编辑重发，会在同一父节点下开兄弟分支，活跃路径高亮。横屏时显示导航轨，每轮一根横条，分支处亮圆点；点任意一轮就能跳回那一段继续聊。竖屏不显示导航轨，用历史对话切换。

### 小窗模式

鸿蒙版声明支持系统自由窗口（floating）。在系统多任务/自由窗口里，可以把桌宠放进小窗，悬浮在其他应用之上。应用内没有额外的小窗开关，入口由系统提供。

### 摄像头陪伴

在菜单里开启陪伴模式，授权相机后，桌宠会站在摄像头的实时画面上。预览流直接送到显示表面，应用不读取、不保存帧数据，不落盘、不上传；没有拍照/录像功能。优先使用后置摄像头，没有后置时使用可用摄像头。

## 四、平台差异

《酸橙味的信》支持 Windows、鸿蒙 NEXT、安卓三端，鸿蒙与安卓为子仓库。

| 功能 | Windows | 鸿蒙 | 安卓 |
|---|---|---|---|
| LLM 对话树 + 导航轨 | — | ✓ | ✓ |
| 小窗模式 | — | ✓（鸿蒙独有） | — |
| 摄像头陪伴模式 | — | ✓ | ✓ |
| 记忆管理 | ✓ | — | — |
| 全屏自动隐藏 | ✓ | — | — |

上表只列平台能力差异。安卓端功能以安卓子仓 README 为准。

## 五、许可与素材边界

《酸橙味的信》原创代码采用 MIT 许可，见 LICENSE。`entry/src/main/ets/spine38/` 衍生自官方 spine-ts 3.8，按 Spine Runtimes License 授权，**不是 MIT**。项目持有 Esoteric Software 的 Spine Editor 许可（Spine Essential）。《明日方舟》游戏素材版权归上海鹰角网络有限公司，不随本仓库分发；本项目为非官方二创。本项目与 Esoteric Software 无官方合作或背书关系。

该许可依据 Spine Editor License Agreement 第 2 节，将 Spine Runtimes 集成进本产品。终端用户直接使用《酸橙味的信》不需要购买 Spine；第三方修改、适配或衍生包含 Spine Runtimes 的代码或产品，需要自行取得许可。

游戏素材不适用 MIT；仓库保留代码、角色清单、Skill 包、示例配置与许可文件，游戏素材不在仓库内。

许可原文：[LICENSE](LICENSE) · [NOTICE.md](NOTICE.md) · [LICENSES/README.md](LICENSES/README.md)。分发本仓库时，请保留 LICENSE、NOTICE.md 与 LICENSES/ 中的许可原文。

**English summary (license & provenance)**

- Original code is MIT. `entry/src/main/ets/spine38/` is a derivative of the official spine-ts 3.8 runtime, used under the Spine Runtimes License, not MIT.
- The project holds a Spine Editor license (Spine Essential) from Esoteric Software.
- Game assets are © Shanghai Hypergryph Network Technology Co., Ltd.; they are not distributed with this repository.
- There is no official cooperation or endorsement from Esoteric Software.

## 六、快速开始

《酸橙味的信》鸿蒙版需要一台 HarmonyOS NEXT 设备（真机或模拟器）。可以下载 Release 的已签名 HAP，也可以用 DevEco Studio 从源码构建。

> 自 v3.1 起，素材不随仓库分发，首次启动时由程序下载。

首次启动需要联网；如果自动下载失败，可从[素材档案库](https://github.com/JNGKZbird/Arknights-Desktop-Pets-Archive)下载官方 zip，在安装页手动导入。程序会先校验整包 SHA-256，再逐文件校验大小与 SHA-256。

### 方式一：安装 Release HAP

1. 打开 [Release v3.1](https://github.com/JNGKZbird/Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT/releases/tag/v3.1)，下载 `AngelinaPet-v3.1-HarmonyOS.hap`（约 4 MB，不含素材）。
2. 在设备上开启开发者模式：设置 → 关于本机/关于手机，按系统提示连续点击；再到“开发者选项”打开 USB 调试与“允许通过 USB 安装应用”。
3. 用数据线连接电脑，运行 `hdc list targets`，确认能看到设备。
4. 运行 `hdc install AngelinaPet-v3.1-HarmonyOS.hap`；首次启动按提示下载素材。

`hdc` 随 DevEco Studio 或 Command Line Tools 提供。若安装提示签名错误或 `TEST_ONLY`，说明该 HAP 的签名不包含你的设备；改用方式二，在 DevEco 中用自动签名构建。

### 方式二：从源码构建

1. 安装 [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)；安装时选择 HarmonyOS NEXT SDK（工程目标 6.1.1(24)）。
2. 在仓库页点 **Code → Download ZIP**，解压；DevEco Studio → **File → Open** 选择解压目录。
3. 等待工程同步完成；首次会下载依赖。
4. 连接设备（开启开发者模式与 USB 调试）或启动模拟器。
5. 点击顶部 **Run ▶**；按提示登录华为账号，完成自动签名。
6. 首次启动按提示下载素材。

仓库不跟踪 `build-profile.json5`，只提供 `build-profile.example.json5`；签名配置由 DevEco 自动生成。

### 构建失败时

- hvigor 找不到：用 DevEco Studio 自带构建，不要在系统终端里换别的 Node。
- 签名错误：登录华为账号 → File → Project Structure → Signing Configs → 勾选 Automatically generate signature。
- 真机不识别：确认 USB 调试与“允许通过 USB 安装应用”已开；`hdc list targets` 能看到设备。
- 素材下载失败：检查网络，或从素材档案库手动导入官方 zip。

## 七、操作

《酸橙味的信》鸿蒙版的操作集中在单击、双击、长按与菜单。

| 操作 | 效果 |
|---|---|
| 单击角色 | 基建模式触发戳一戳动作与语音；战斗模式触发攻击 |
| 双击角色 | 唤出菜单 |
| 长按角色 | 拖动换位置 |
| 菜单 | 待机/坐下/睡觉；基建 ⇄ 战斗；战斗时正面/背面视角；陪伴模式 |
| 小窗 | 在系统多任务/自由窗口里把应用放进小窗（系统能力） |
| 对话 | 进入聊天终端；横屏显示导航轨 |

## 八、AI 配置

《酸橙味的信》的 AI 聊天走 OpenAI 兼容接口；不配置也能使用动作、语音与战斗。

1. 在服务商注册账号并创建 API Key。
2. 打开聊天终端 → 设置，填写 API 地址、API 密钥与模型名。
3. 还可以设置玩家称呼、上下文条数（1–100）、时间感知与额外提示词。
4. 保存后开始对话。

默认接口地址是 `https://api.deepseek.com`，默认模型是 `deepseek-v4-flash`；以你账号实际可用的模型为准。Moonshot、智谱等 OpenAI 兼容服务同样可用，把地址、密钥与模型换成对应的即可。

API 密钥只保存在你本地的设置里，不会被上传。

> 《酸橙味的信》本地优先：除用户主动配置的 AI 接口请求与素材下载外，聊天记录、设置与运行数据都保存在本机；没有遥测，没有上报端点。摄像头画面仅本地预览，不存储、不上传，无拍照/录像。

聊天没有反应时，依次检查：接口地址是否填写正确，API 密钥是否完整，账户是否还有余额。未填 API Key 时，聊天会使用预设回复。

## 九、常见问题

### 《酸橙味的信》是什么？

《酸橙味的信》是予愿安洁莉娜桌宠的正式软件名。安装后的应用名就是《酸橙味的信》；设置“额外提示词”输入“酸橙味的信”会切换到安洁莉娜本体的人格。

### 谁开发的？和 AstrariaX / Angelina-pet 是什么关系？

《酸橙味的信》由 JNGKZbird 独立重做并维护，原作：AstrariaX / Angelina-pet。原作的创意与工作为《酸橙味的信》提供了起点。

### 支持哪些平台？

《酸橙味的信》支持 Windows、鸿蒙 NEXT、安卓三端，鸿蒙与安卓为子仓库。本页是鸿蒙子仓；Windows 与安卓分别在各自仓库维护。

### 下载后为什么没有角色素材？

自 v3.1 起，素材不随仓库分发，首次启动时由程序下载。首次启动需要联网；如果自动下载失败，可从素材档案库下载官方 zip，在安装页手动导入。程序会先校验整包 SHA-256，再逐文件校验大小与 SHA-256。

### 鸿蒙版有摄像头、对话树或小窗吗？

有。鸿蒙版有对话树/导航轨（导航轨横屏显示）、摄像头陪伴与系统小窗；Windows 版没有这三项，安卓版没有小窗。

### 需要购买 Spine 吗？

直接使用《酸橙味的信》不需要购买 Spine。第三方修改、适配或衍生包含 Spine Runtimes 的代码或产品，需要自行取得许可。`spine38/` 按 Spine Runtimes License 授权，不是 MIT。

### 素材可以商用吗？

不可以。《明日方舟》游戏素材版权归上海鹰角网络有限公司，仅限个人非商业使用，不适用 MIT，也不随仓库分发。

### 聊天记录会上传吗？摄像头画面会被保存吗？

不会。《酸橙味的信》本地优先：除用户主动配置的 AI 接口请求与素材下载外，聊天记录、设置与运行数据都保存在本机；没有遥测，没有上报端点。摄像头画面仅本地预览。

### 有现成安装包吗？需要什么开发环境？

有。Release v3.1 提供已签名 HAP（约 4 MB，不含素材）；安装需要开启开发者模式的 HarmonyOS NEXT 设备。也可以从源码构建，需要 DevEco Studio 与华为账号自动签名。

### 可以换人格或角色包吗？

可以。鸿蒙版用自定义智能体加载人格提示词；设置里的“额外提示词”可切换人格。

一共有三个彩蛋：输入「酸橙味的信」切换到安洁莉娜本体人格；输入「你是」加某位角色的四字名字，切换到对应人格，这类六字彩蛋有两个。关键词必须完整输入，多一个字都不会触发。具体是谁，留给你自己试~

更多干员人格可从[人格蒸馏库](https://github.com/JNGKZbird/Arknights-Persona-Distill)获取。

### 帧率是多少？

鸿蒙端没有固定帧率档位，渲染跟随设备 VSync，实际帧率随设备性能与场景变化；Windows 端最高 120fps。

### 为什么 GitHub 显示的语言占比不对？

GitHub 语言统计暂不识别 ArkTS，语言占比显示不准确，以目录结构为准。

## 十、技术亮点（给开发者）

《酸橙味的信》鸿蒙版使用 ArkTS + C++ GLES3；渲染核心与 Windows 版同源，衍生自官方 spine-ts 3.8。

- ArkUI/ArkTS 负责 UI 与业务（Stage 模型，`UIAbility`），C++ 负责渲染内核；CMake 构建 `arm64-v8a`。
- GLES3 掩码纹理管线；S-H 裁剪语义衍生自官方 spine-ts 3.8。
- Canvas 2D 逐三角形绘制已弃用（GPU 爆炸实证）；CPU/GPU 光栅化与 Windows 版 `spine38/` 同一套核心语义。
- 对话树用 `RoundNode` + `path` 活跃分支；重新生成或编辑重发会在同一父节点下开兄弟节点。
- 导航轨在横屏渲染，一轮一根横条，按高斯衰减伸缩，分支圆点/数字，点击跳转。
- 工程 `modelVersion` 为 6.1.1；targetSdk/compatibleSdk 为 6.1.1(24)。仓库不含 `hvigorw`，命令行构建用 DevEco 自带工具。

### 从源码构建（命令行）

```bash
# 用 DevEco Studio 自带的 JDK、SDK 与 hvigorw；路径按你的安装目录替换
export JAVA_HOME="<DevEco Studio>/jbr"
export DEVECO_SDK_HOME="<DevEco Studio>/sdk"
"<DevEco Studio>/tools/hvigor/bin/hvigorw.bat" --mode module -p product=default assembleHap --no-daemon
```

### 目录结构

```text
AppScope/                     # 应用配置
entry/
├── src/main/ets/
│   ├── entryability/         # EntryAbility：窗口、权限、启动路由
│   ├── pages/                # Index / PetPage / AssetSetupPage
│   ├── model/                # ChatApi、ChatStore、Voice、AssetStore
│   ├── components/           # MarkdownView 等
│   └── spine38/              # Spine 3.8 运行时（衍生自 spine-ts 3.8）
├── src/main/cpp/             # C++ 渲染内核
└── src/main/resources/       # 资源、rawfile/asset_manifest.json、skill/
hvigor/                       # 构建配置
```

## 十一、已知限制与适用边界

《酸橙味的信》鸿蒙版的功能以本页表格为准，平台边界如下。

- 需要 HarmonyOS NEXT 设备（真机或模拟器）；源码构建需要 DevEco Studio 与华为账号签名。
- Release HAP 安装需要开发者模式；签名不匹配时改用源码构建。
- 首次启动需要联网下载素材；也可以手动导入官方 zip。
- 记忆管理与全屏自动隐藏仅 Windows 版提供。
- 导航轨只在横屏显示。
- 摄像头陪伴需要相机权限；画面仅本地预览。
- 游戏素材仅限个人非商业使用，不适用 MIT，也不随仓库分发。

### 路线图（远期，未实装）

- 记忆库 / 知识库：与人格蒸馏、知识库协同项目联动，引入记忆行为。

## 十二、致谢

《酸橙味的信》建立在原作与这些开源项目之上。

- **原作**：[AstrariaX / Angelina-pet](https://github.com/AstrariaX/Angelina-pet)。感谢原作者的创意与工作。
- **Spine**：Esoteric Software LLC 的 Spine Runtimes 与 Spine Editor；`entry/src/main/ets/spine38/` 衍生自官方 spine-ts 3.8。
- **素材**：《明日方舟》角色立绘、动画、语音等素材版权归上海鹰角网络有限公司所有。
- **素材档案库**：[Arknights-Desktop-Pets-Archive](https://github.com/JNGKZbird/Arknights-Desktop-Pets-Archive)。
- **构建工具**：DevEco Studio 与 HarmonyOS SDK。

> 为爱发电，随便用，出事了别找我。

这个项目是我个人对鸿蒙系统项目的早期尝试。日后的捣蛋鬼 · 鸿蒙版会以它的技术积累为基础，继续升级。我们正在做，也会认真做下去。
