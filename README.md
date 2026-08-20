# Arknights Angelina Pet — 予愿安洁莉娜桌宠（鸿蒙 HarmonyOS NEXT 版）

![予愿安洁莉娜](../README.md) 的鸿蒙移植版：基于 ArkTS + C++ 的《明日方舟》予愿安洁莉娜桌面桌宠，v3.0 基线（官方 spine-ts 3.8 裁剪管线 + deform 权重条目索引 + 状态包围盒底边布局锚定）。

> 基于 [AstrariaX/Angelina-pet](https://github.com/AstrariaX/Angelina-pet) 深度重做，特此向原作者致谢。本项目为粉丝同人作品，素材版权归《明日方舟》/ 鹰角网络所有。

## 三端开源

| 平台 | 仓库 |
|---|---|
| Windows | [Arknights-Angelina-Pet-YuYuan](https://github.com/JNGKZbird/Arknights-Angelina-Pet-YuYuan) |
| 鸿蒙（本仓库） | [Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT](https://github.com/JNGKZbird/Arknights-Angelina-Pet-YuYuan-HarmonyOS-NEXT) |
| 安卓 | [JNGKZbird-Arknights-Angelina-Pet--YuYuan-Android](https://github.com/JNGKZbird/JNGKZbird-Arknights-Angelina-Pet--YuYuan-Android) |

> 本仓库使用 ArkTS（.ets）编写，GitHub 语言统计暂不识别 ArkTS，语言占比显示不准确，以目录结构为准。未来**可能**推出 iOS 版本。

## 技术栈

- **语言**：ArkTS（UI 层）+ C++（渲染内核）
- **渲染**：GLES3 掩码纹理管线（v3.0 官方 S-H 裁剪语义）
- **架构**：Canvas 2D 逐三角形绘制已弃用（GPU 爆炸实证），CPU/GPU 光栅化直译 Windows 版 spine38 路线

## 构建

```bash
cd D:\Arknights-Angelina-pet
export JAVA_HOME="D:\devecostudio-windows-6.1.1.300\DevEco Studio\jbr"
export PATH="$JAVA_HOME/bin:$PATH"
export DEVECO_SDK_HOME="D:\devecostudio-windows-6.1.1.300\DevEco Studio\sdk"
"D:\devecostudio-windows-6.1.1.300\DevEco Studio\tools\hvigor\bin\hvigorw.bat" --mode module -p product=default assembleHap --no-daemon
```

部署：DevEco Studio 打开工程 → Run（需华为账号签名）。

## 目录结构

```
AppScope/            # 应用配置
entry/               # 主模块（ets 页面 + cpp 渲染内核）
hvigor/              # 构建工具配置
HANDOFF.md           # 交接文档
```
