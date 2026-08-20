# 予愿安洁莉娜桌宠（鸿蒙 HarmonyOS NEXT 版）

![予愿安洁莉娜](../../README.md) 的鸿蒙移植版。

> 一只住在你鸿蒙设备上的安洁莉娜：走来走去、坐下休息、回应你的点击、和你聊天。基于 [AstrariaX/Angelina-pet](https://github.com/AstrariaX/Angelina-pet) 深度重做，特此向原作者致谢。本项目为粉丝同人作品，素材版权归《明日方舟》/ 鹰角网络所有。

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

与 Windows 版一致的操作习惯：

- **点击角色**：互动动作 + 语音
- **双击**：打开聊天（需配置 AI）
- **菜单**：坐下/睡觉、战斗形态切换、三技能演示、聊天历史、记忆管理等

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

- **原作者**：基于 [AstrariaX/Angelina-pet](https://github.com/AstrariaX/Angelina-pet) 深度重做，感谢原作者。
- **素材版权**：角色素材版权归 **Hypergryph / 鹰角网络** 所有。
- **许可证**：MIT — 为爱发电，随便用，出事了别找我。
