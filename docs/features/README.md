# Lyrimuse 功能现状文档

这组文档描述当前 Swift App 的实际行为。歌词链路只有一个进程：Apple Music 的曲目变化由 App 发现，`LyricsResolver` 并发查询五个歌词源，`LyricsMatcher` 选出结果，`EnrichCacheStore` 持久化，悬浮歌词和菜单栏歌词继续消费同一份缓存。

## 章节索引

| 章 | 文件 | 覆盖范围 |
|---|---|---|
| 01 | [总览与架构](01-overview.md) | App、Core、歌词链路、配置和数据文件 |
| 02 | [播放数据源与播放器支持](02-playback-source.md) | Apple Music、media-control、播放器选择和权限 |
| 03 | [封面链路](03-artwork.md) | 系统封面、缓存封面和取色 |
| 04 | [桌面悬浮歌词](04-desktop-overlay.md) | 悬浮窗口、逐字显示和样式 |
| 06 | [菜单栏：歌词、图标与菜单](06-menubar.md) | 菜单栏歌词和状态菜单 |
| 08 | [歌词同步引擎（App 侧）](08-lyrics-engine.md) | 缓存读取、LRC/YRC 解析和时间轴 |
| 09 | [歌词解析与匹配](09-lyrics-resolution.md) | 五源 Provider、Resolver、Matcher 和缓存写入 |
| 10 | [译文与罗马音](10-translation-romanization.md) | 候选附加字段和展示端注音 |
| 11 | [歌词管理窗口](11-lyrics-manager.md) | 列表、编辑、联网重搜和重新匹配 |
| 13 | [网页展示与中继](13-web-relay.md) | 外部网页功能与本仓库的边界 |
| 14 | [设置、配置与本地化](14-settings-config.md) | 设置页、偏好、备份和登录项 |
| 15 | [运行与部署](15-ops-background.md) | Swift 构建、打包、登录项和诊断 |

## 维护约定

功能行为变化时，同一次改动更新对应章节。文档只描述当前仓库仍存在的入口和类型；删除的实现不在现状文档中保留。
