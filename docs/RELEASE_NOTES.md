# AnchorScroll 1.0.3 预发布版

独立 macOS 菜单栏中键自动滚动工具，Apple Silicon，macOS 14 起。

## 本次提供两种安装产物

| 文件 | 说明 |
| --- | --- |
| `AnchorScroll-1.0.3-macOS-arm64.dmg` | 安装镜像：打开后把 AnchorScroll.app 拖入「应用程序」 |
| `AnchorScroll-1.0.3-macOS-arm64.zip` | 免安装压缩包：解压后得到 AnchorScroll.app |

校验值见同目录的 `SHA256SUMS.md`。

## 版本要点

- 点按中键后按距中心的距离持续滚动；回中心停止，点击或 Esc 退出。
- 修复固定锚点 HID 滚动事件拉回真实指针的问题。
- 增加垂直方向反转开关，默认不反转。
- 包含银白蓝色应用图标、设置界面及原生测试窗口。
- 浏览器建议 Command＋左键打开新标签页；Option＋中键可能触发分屏。

## 已知边界

内核 286 条断言通过；当前完整 GUI 和多应用兼容性验收仍未完成。仅本机 ad-hoc 签名，未经 Developer ID 签名和 Apple 公证，首次打开可能需要右键选择「打开」。Mos 共存存在已知问题。滚动目标随指针所在区域变化。请作为预发布版试用，勿描述为完美兼容版。

本版本以 **MIT License** 发布，详见仓库根目录 `LICENSE`。
