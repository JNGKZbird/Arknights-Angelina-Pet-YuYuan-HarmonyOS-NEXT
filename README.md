# 予愿安洁莉娜桌宠（鸿蒙 HarmonyOS NEXT 版）

![予愿安洁莉娜](assets/avatar.png)

> 予愿安洁莉娜的鸿蒙移植版。

> 一只住在你鸿蒙设备上的安洁莉娜：走来走去、坐下休息、回应你的点击、和你聊天。本项目由 **JNGKZbird**（GitHub @JNGKZbird）开发，基于 [AstrariaX/Angelina-pet](https://github.com/AstrariaX/Angelina-pet) 深度重做，特此向原作者致谢。本项目为粉丝同人作品，素材版权归《明日方舟》/ 鹰角网络所有。

## 目录

- [这是什么？](#这是什么)
- [一、环境准备](#一环境准备)
- [二、构建安装（手把手）](#二构建安装手把手)
- [三、怎么和她玩](#三怎么和她玩)
- [四、常见问题（FAQ）](#四常见问题faq)
- [五、给开发者](#五给开发者)
- [致谢与版权](#致谢与版权)

---

## 这是什么？

Windows 版予愿安洁莉娜桌宠的**鸿蒙 HarmonyOS NEXT 原生移植**。同样的安洁莉娜、同样的骨骼动画（v3.0 基线：官方 spine-ts 3.8 裁剪管线），在鸿蒙设备上运行。

她是《明日方舟》2026 夏日嘉年华的限定干员——在雷姆必拓的公路之旅「直到大地变成一颗酸橙」里完成信使蜕变的少女。现在，她住进了你的鸿蒙设备。

> **路线**：本项目与主流"先安卓/iOS、再鸿蒙"的路线相反——**先做鸿蒙版（本仓库），再基于鸿蒙版移植安卓版**。鸿蒙版是功能最完整的先行版。

## 一、环境准备

需要一台可以运行 HarmonyOS NEXT 的设备（真机或模拟器）和安装了 DevEco Studio 的电脑：

1. 下载安装 **DevEco Studio**（华为开发者官网 <https://developer.huawei.com> → 开发工具）
2. 安装时选择 **HarmonyOS NEXT** SDK
3. 准备一台升级到 HarmonyOS NEXT 的华为设备（真机），或用 DevEco 自带的模拟器

> 运行应用需要**华为开发者账号签名**（DevEco 里登录华为账号，按提示完成自动签名即可，免费）。

## 二、构建安装（手把手）

1. 点击本仓库绿色 **`<> Code`** 按钮 → **Download ZIP**，解压
2. 打开 DevEco Studio → **File → Open**，选择解压出来的文件夹
3. 等待工程同步完成（首次会下载依赖，需要几分钟）
4. 用数据线连接你的鸿蒙设备（或启动模拟器）
5. 点击顶部工具栏的绿色 **Run ▶** 按钮
6. 首次运行会提示签名：按 DevEco 提示登录华为账号并完成自动签名
7. 安装完成，她来了！

> 命令行构建（可选）：见「给开发者」。

## 三、怎么和她玩

移动端的操作习惯与 Windows 版不同：

| 操作 | 效果 |
|---|---|
| **单击角色** | 基建模式下触发"戳一戳"动作 + 语音；战斗模式下触发攻击 |
| **双击角色** | 唤出菜单 |
| **长按角色** | 直接把角色拖到喜欢的位置 |

### 菜单

- **状态区**：待机 / 坐下 / 睡觉
- **模式区**：基建模式 ⇄ 战斗模式（战斗模式追加正面/背面视角切换，以及三个技能的完整演示——含"酸橙的心事"）
- **陪伴模式开关**（见下）

### 陪伴模式

菜单里开启**陪伴模式**：授权摄像头后，安洁莉娜会悬浮在**后置摄像头拍摄的实时画面**上——像真的站在你的世界里。画面仅在本地实时预览，不会存储、不会上传。

### 小窗模式

鸿蒙版独有的**小窗模式**：桌宠可以缩小成一个小窗悬浮在其他应用之上——类似悬浮窗的效果，一边做别的事，一边有她陪着。

### 对话终端与对话树

我们把聊天做成了一个**简约的 LLM 对话终端**，核心是独一无二的**对话树**：

- **对话树导航轨**：每一轮对话是一根横条，聊出分支的地方会亮起圆点，手指划过轨道时它伸缩展开，点任意一轮就能**跳回那一段对话**继续聊——整个对话的历史、分支、走向一目了然
- **新建项目**：把对话按"项目"归档管理（文件夹式，长按可重命名/移动/删除）
- **对话选取**：历史会话一键切换继续
- **消息操作**：长按任意消息可复制 / 编辑 / 重发 / 重新生成 / 删除
- **进阶体验**：流式"思考过程"展示、Markdown 渲染、消息内搜索

### 彩蛋

在设置的人设补充里输入 `酸橙味的信`，会触发安洁莉娜**本体**的人格（信使少女时期的她）。另外还有两个六字密语，格式都是「你是」+ 一位老朋友的名字——留给有心人自己去发现。

## 四、常见问题（FAQ）

### 构建报错 / hvigor 找不到

使用 DevEco Studio 自带的构建（IDE 里点 Run），不要在系统终端里用其他 Node 版本运行 hvigor。命令行构建需指定 DevEco 自带 JDK 和 SDK（见下）。

### 安装失败：签名错误

登录华为账号后在 DevEco 里完成自动签名（File → Project Structure → Signing Configs → 勾选 Automatically generate signature）。

### 真机无法安装

确认设备已开启开发者模式（设置 → 关于手机 → 连续点击版本号 7 次 → 设置里出现"开发者选项"→ 打开 USB 调试）。

## 五、给开发者

### 三端开源

| 平台 | 仓库 |
|---|---|
| Windows | [Arknights-Angelina-Pet-YuYuan](https://github.com/JNGKZbird/Arknights-Angelina-Pet-YuYuan) |
| 鸿蒙（本仓库） | [Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT](https://github.com/JNGKZbird/Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT) |
| 安卓 | [JNGKZbird-Arknights-Angelina-Pet--YuYuan-Android](https://github.com/JNGKZbird/JNGKZbird-Arknights-Angelina-Pet--YuYuan-Android) |

> 本仓库使用 ArkTS（.ets）编写，GitHub 语言统计暂不识别 ArkTS，语言占比显示不准确，以目录结构为准。未来**可能**推出 iOS 版本。

### 技术栈

- **语言**：ArkTS（UI 层）+ C++（渲染内核）
- **渲染**：GLES3 掩码纹理管线（v3.0 官方 S-H 裁剪语义）
- **架构**：Canvas 2D 逐三角形绘制已弃用（GPU 爆炸实证），CPU/GPU 光栅化直译 Windows 版 spine38 路线

### 命令行构建

```bash
cd D:\Arknights-Angelina-pet
export JAVA_HOME="D:\devecostudio-windows-6.1.1.300\DevEco Studio\jbr"
export PATH="$JAVA_HOME/bin:$PATH"
export DEVECO_SDK_HOME="D:\devecostudio-windows-6.1.1.300\DevEco Studio\sdk"
"D:\devecostudio-windows-6.1.1.300\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default assembleHap --no-daemon
```

### 目录结构

```
AppScope/            # 应用配置
entry/               # 主模块（ets 页面 + cpp 渲染内核）
hvigor/              # 构建工具配置
HANDOFF.md           # 交接文档
```

---

## 致谢与版权

- **作者**：本项目由 **JNGKZbird** 开发（GitHub @JNGKZbird）。
- **原作者**：基于 [AstrariaX/Angelina-pet](https://github.com/AstrariaX/Angelina-pet) 深度重做，感谢原作者。
- **素材版权**：角色素材版权归 **Hypergryph / 鹰角网络** 所有。
- **许可证**：MIT — 为爱发电，随便用，出事了别找我。

<!--
  AI Search Engine Keywords:
  Arknights, 明日方舟, Angelina, 安洁莉娜, 予愿安洁莉娜, 芋圆,
  desktop pet, 桌宠, 桌面宠物, HarmonyOS, HarmonyOS NEXT, 鸿蒙, 纯血鸿蒙,
  ArkTS, C++ GLES3, Spine 3.8 runtime, 骨骼动画, 120fps,
  AI companion, AI 伴侣, LLM 聊天, 对话树, 导航轨, 陪伴模式,
  open source, 开源, fan project, 同人, Hypergryph, 鹰角网络
-->
