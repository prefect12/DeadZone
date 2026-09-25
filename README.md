<p align="center">
  <img src="Resources/icon.png" width="160" alt="DeadZone icon">
</p>

<h1 align="center">DeadZone</h1>

<p align="center">
  把显示器上坏掉的区域"挖掉"，让一块局部损坏的屏幕继续像正常屏幕一样使用。<br>
  <sub>Carve out the broken part of your monitor on macOS — windows and the cursor treat it as if it doesn't exist.</sub>
</p>

<p align="center">
  <img src="Resources/demo.gif" width="720" alt="DeadZone 示意动画">
  <br><sub>示意动画 · Illustration</sub>
</p>

---

## 为什么

显示器的某一角坏了（花屏、黑屏、闪烁），但其余部分完好，扔掉可惜。macOS 不支持"异形屏幕"，窗口会照样跑进坏掉的地方，鼠标进去了也看不见。

DeadZone 让坏区在使用上"不存在"：

- **窗口进不去**：拖进坏区的窗口松手即被推出，贴着坏区边缘摆放
- **最大化 / 全屏 = 顶着坏区最大化**：点绿色按钮、双击标题栏时，窗口铺满"避开坏区后最大的矩形"，不会真的进入系统全屏
- **鼠标进不去**：光标碰到边界会沿分界线平滑滑动，不会迷失在黑区里
- **黑色遮罩**：用纯黑盖住坏区，减少花屏干扰
- **不规则形状**：沿坏区边界画一条线即可，线的右上方都算坏区
- 按显示器分别记忆，改分辨率、拔插显示器后仍然有效

## 安装

需要 macOS 13 及以上，Apple 芯片和 Intel 均可。

### 从源码构建

需要 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/prefect12/DeadZone.git
cd DeadZone
./build.sh --install
```

App 会被安装到 `~/Applications/DeadZone.app` 并自动启动。

### 使用下载的 Release

解压后把 `DeadZone.app` 放进"应用程序"。由于没有 Apple 开发者签名，首次打开需要在 Finder 中**右键 → 打开**，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/DeadZone.app
```

## 使用

1. **授予辅助功能权限**：系统设置 → 隐私与安全性 → 辅助功能，打开 DeadZone。
   挪动其他应用的窗口、拦截鼠标都需要这个权限。
2. **标记坏区**：首次启动会在外接显示器上进入编辑界面。
   - 在**看得见的一侧**沿坏区边界画线，单击逐点或按住拖动都可以
   - 线两端会自动延伸到屏幕边缘，**线的右上方**全部视为坏区（红色预览）
   - 屏幕上有一条贯穿全屏的绿色十字线，鼠标就算进了黑区也能看出它在哪
   - 双击、回车或右键保存；Esc 取消；Delete 删除上一个点；C 清空重画
3. 以后要重新编辑：点菜单栏图标 → 编辑坏区；如果菜单栏图标被刘海挡住，**再次打开 DeadZone.app** 也会进入编辑界面。

菜单栏中可以单独开关黑色遮罩、窗口避让、鼠标拦截，以及开机自动启动。

## 工作原理

| 功能 | 实现 |
| --- | --- |
| 坏区形状 | 以约 4pt 的网格蒙版存储，按屏幕比例映射，存于 `UserDefaults`，以显示器 UUID 区分 |
| 黑色遮罩 | 与坏区同形状、屏保层级、鼠标穿透的无边框窗口 |
| 窗口避让 | `CGWindowList` 找出与坏区重叠的窗口，经 Accessibility API 平移或缩小，选改动最小的方案 |
| 最大化 | 在可用区域内求避开坏区的最大矩形；系统全屏会被退出并改为该矩形 |
| 鼠标拦截 | 独立线程上的 `CGEventTap`，在事件送达前把光标投影到分界线上，实现贴边滑动 |

所有逻辑都在单个文件 [`main.swift`](main.swift) 中，不依赖任何第三方库，**不联网，不收集任何数据**。

## 已知限制

- macOS 无法真正改变屏幕形状，DeadZone 是在行为层面模拟
- 如果菜单栏在这块屏幕上，坏区里的状态栏图标仍会被挡住；建议把主显示器设为另一块屏幕
- 正在拖动窗口的过程中，窗口可以暂时进入坏区，松手后才会被推出
- 这块屏幕上的系统全屏（包括网页视频全屏）都会被改为"顶着坏区最大化"
- 目前的编辑方式针对**右上角**的坏区；其他位置的坏区需要修改代码

## 开发

```bash
./build.sh            # 构建到 build/DeadZone.app（Universal）
./build.sh --install  # 构建、安装并启动
swift scripts/make_icon.swift Resources/icon.png   # 重新生成图标 PNG
swift scripts/make_demo.swift Resources/demo.gif   # 重新生成 README 示意动画
```

使用 ad-hoc 签名，并把指定要求固定为 bundle id，重新编译后不需要重新授予辅助功能权限。

## License

[MIT](LICENSE)
