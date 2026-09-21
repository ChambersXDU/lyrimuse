# 01. 总览与架构

## 定位

Lyrimuse 是一个 Swift/AppKit 菜单栏 App。它读取当前播放器曲目，自动获取歌词并写入本地 JSON/歌词文件缓存，再由悬浮歌词、菜单栏和歌词管理窗口共同消费。歌词获取、匹配和缓存都在 App 进程内完成。

## 进程与模块

| 模块 | 作用 |
|---|---|
| `lyrimuse` | 菜单栏、设置、播放状态、歌词搜索、缓存和所有展示面 |
| `LyrimuseCore` | 播放快照、LRC/YRC 解析、歌词模型、五源 Provider、Matcher、Resolver 和缓存读取 |
| `lyrimuse-selftest` | 不依赖 Xcode 的 Swift 自测包 |
| `media-control` | 非 Apple Music 播放器的系统 Now Playing 读取工具；Apple Music 走 AppleScript |

歌词主链路如下：

```text
Apple Music 换歌
    -> LocalPlaybackSource
    -> LyricsSearchService
    -> LyricsResolver
    -> LRCLIB / 酷我 / 网易云 / 酷狗 / QQ 音乐
    -> LyricsMatcher
    -> EnrichCacheStore
    -> LyricsSyncEngine / 悬浮歌词 / 菜单栏歌词
```

Provider 只负责请求、必要的协议解码和候选解析；Resolver 负责并发汇总并隔离单源错误；Matcher 负责统一评分。缓存由 Swift 单进程拥有，没有进程间通信或缓存合并协议。

## 数据与配置

- `~/.config/lyrimuse/lyrimuse-enrich-cache.json` 保存曲目元信息、歌词、译文、罗马音、逐字时间和来源。
- `~/.config/lyrimuse/lyrics/` 保存可编辑的 `.lrc`、`.tr.lrc`、`.roma.lrc` 和 `.yrc` 文件。
- `lyrimuse-features.json` 保存播放器、歌词来源和歌词显示选项；Swift 直接读写。
- App 登录项由 `SMAppService` 管理；歌词搜索不需要独立后台服务。

## 构建与测试

`lyrimuse/build.sh` 只构建 Swift targets、组装 App、签名和可选重启 App。`swift run --package-path lyrimuse lyrimuse-selftest` 只保留歌词解析、候选解析和同步时间轴三组核心回归；UI、设置和几何通过实际使用检查。
