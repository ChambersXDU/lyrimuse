# 02. 播放数据源与播放器支持

## 定位

`LocalPlaybackSource` 负责取得当前曲目、播放状态、位置和封面，并在曲目变化时通知歌词搜索。歌词搜索不依赖播放器的歌词接口；播放器只提供歌名、歌手、专辑和时长。

## 支持的播放器

| 播放器 | 状态读取 | 备注 |
|---|---|---|
| Apple Music | AppleScript/JXA | 位置精度最高，也是默认歌词自动触发路径 |
| QQ 音乐 | `media-control` | 系统 Now Playing |
| 网易云音乐 | `media-control` | 系统 Now Playing |
| 酷狗音乐 | `media-control` | 系统 Now Playing |
| Spotify | `media-control` | 系统 Now Playing |
| 自动识别 | `media-control` | 按受信任播放器集合选择 |

## 行为

- 曲目变化时，App 先读取已有缓存；未命中则由 `LyricsSearchService` 创建 `LyricsQuery` 并调用 `LyricsResolver`。
- 当前曲目的 `duration` 会传给 Matcher，用于区分同名版本；空标题或非歌曲状态不会搜索。
- Apple Music 的自动化权限仍由设置页管理；其它播放器依赖系统 Now Playing 权限和 `media-control`。
- 播放位置更新、时间轴偏移和歌词展示继续由 `LyricsSyncEngine`、悬浮窗口和菜单栏组件处理，与搜索源解耦。

## 设置

播放器选择、受信任播放器、Apple Music 自动化权限和歌词来源位于现有设置页。歌词来源只影响 Resolver 查询的五个 Swift Provider，不改变播放器状态读取。
