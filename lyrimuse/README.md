# Lyrimuse

原生 macOS 菜单栏 + 桌面悬浮歌词，跟着 Apple Music、QQ 音乐、网易云音乐、酷狗或 Spotify 播放实时
显示逐字同步歌词（也可以选"自动识别"，跟随 macOS 当前系统级 Now Playing 焦点），显示成一个
常驻置顶、跨 Space 的小悬浮窗，或者直接显示在菜单栏——类似网易云/QQ 音乐桌面客户端的
"桌面歌词"。另外还有一个"歌词管理"窗口，可以查看/手改/删除/重新搜索每首歌的歌词候选。

播放状态仍然由 Apple Music 自动化或系统级 MediaRemote 读取；歌词查询现在由 App 内的 Swift
Resolver 直接并发请求 LRCLIB、酷我、网易云、酷狗和 QQ 音乐，匹配结果后写入单进程缓存。
换歌会自动触发查询，已有缓存可以离线显示；没有匹配结果时会正常显示"暂无歌词"，不会启动独立歌词服务。

如果想要跨设备/跨房间同步展示（比如手机上也能看当前播放），或者想把"正在播放"做成一个
公开网页/飞书卡片分享出去，见独立仓库
[Yudaotor/nowplaying-workers](https://github.com/Yudaotor/nowplaying-workers)——那是一套
完全独立、可选的功能，Lyrimuse 只负责单向推送状态给它，不依赖它也能正常显示悬浮歌词。

## 依赖与运行方式

- Swift 工具链（Command Line Tools 自带即可，不需要装完整 Xcode——已实测确认，
  `Package.swift` 用的是纯 SwiftPM 可执行 target，不是 `.xcodeproj`）。
- 歌词查询、匹配、解码与缓存都在 Swift App/Core 内完成，不需要 Go 工具链，也不需要单独的后台进程。
- 2026-07-24 起，构建 QQ 音乐/网易云音乐/Spotify/自动识别这几个播放源的支持需要
  [ungive/media-control](https://github.com/ungive/media-control)（BSD-3-Clause，这几个
  播放源统一走它读取系统级 MediaRemote，不是各自独立集成）——`build.sh` 会把这份二进制
  拷进 `.app` 包（`Contents/Resources/media-control`），最终用户不需要自己装任何东西。
  **不需要提前手动 `brew install media-control`**：2026-07-27 起 `build.sh` 检测到本机
  没装会自动装一次（前提是本机已经装了 Homebrew）；如果自动
  安装失败（没网/没装 Homebrew 本身），会打个警告继续构建，只是这次构建出来的 App
  不支持切换到这几个播放源（Apple Music 不受影响）。
- 打包成正经的 `.app`：`build.sh` 把 release 构建的 Swift 可执行文件+图标+
  `Info.plist` 组装安装到 `/Applications/Lyrimuse.app`，可以拖进 Dock 当
  启动器双击打开。`Info.plist` 里仍然设 `LSUIElement`，运行期间照旧不占 Dock/Cmd-Tab（跟
  改造前的 `NSApp.setActivationPolicy(.accessory)` 运行时调用双保险）。SwiftPM 给每个
  声明了 `resources` 的 target 生成的 `Bundle.module` 资源包（本地化文案等）按访问器的
  固定查找路径搬到了 `.app` 包根目录，不是常见的 `Contents/Resources/`，细节见 `build.sh`
  里的注释。

## 目录结构

- `Sources/LyrimuseCore/` —— 纯逻辑 library target（歌词解析/网络/进度外推/数据模型），
  不依赖 AppKit/SwiftUI，方便脱离 GUI 单独测试。
- `Sources/lyrimuse/` —— App 本体（菜单栏、悬浮窗、设置面板、开机启动管理）。
- `Sources/lyrimuse-selftest/` —— 手写的极简断言测试(`swift run lyrimuse-selftest`)。
  **这台机器没有完整 Xcode，`XCTest`/`Testing` 两个官方测试框架都用不了**(`swift test` 报
  "no such module")，所以用普通可执行 target + 手写比较代替。

## 构建 / 运行

```bash
./build.sh               # release 构建(本机架构) + 装到 /Applications/Lyrimuse.app + 重启(如果当前有实例在跑)
./build.sh --universal   # 编 arm64 + x86_64(给 Intel 的兼容包)
./build.sh --no-restart  # 只构建
./build.sh --dest <路径> # 组装到指定路径(隐含 --no-restart),package.sh 用这个一次出两种架构
swift run lyrimuse-selftest   # 跑歌词解析器的合成字符串测试
```

发布资产由 `package.sh` 打(输出到 `lyrimuse/dist/`)。它**自己调 `build.sh --dest` 构建两份**,
不打包 `/Applications` 那份:

```bash
LYRIMUSE_VERSION=1.2.1 ./package.sh
```

出两套资产 —— 主包 arm64-only(`Lyrimuse-v*-macos.*`)和 Intel 兼容包 universal
(`Lyrimuse-v*-macos-intel.*`),各含 zip + sha256 + dmg。为什么要分成两份、以及为什么主包
必须彻底不含 x86_64(含了 macOS 27 就会对多数用户弹"需要更新 App"),见 `build.sh` 顶部注释。

打包前有两道**硬闸门**(不是警告):每个二进制的架构必须跟该变体的目标完全一致(缺一半、
或多带一份都拦),以及 `codesign --deep --strict` 必须通过。v1.0.0~v1.2.0 三个版本都在没人
察觉的情况下发成了 arm64-only,这两道闸门就是为此加的。

发布流程只上传对应架构的 zip、sha256 和 dmg 资产。

## 开机启动

菜单栏里的"开机启动"开关使用 macOS `SMAppService` 注册 App 本身；它只负责用户选择的开机
启动，不参与歌词查询，也不是后台常驻服务。
