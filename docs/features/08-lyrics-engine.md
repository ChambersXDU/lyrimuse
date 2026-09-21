# 08. 歌词同步引擎（App 侧消费链）

## 定位

`LyricsSyncEngine` 只负责把缓存中的 LRC/YRC 转成当前播放位置的展示行。它不请求网络，也不负责决定哪一个歌词源胜出。

## 缓存读取

`EnrichCacheReader` 读取 `lyrimuse-enrich-cache.json` 和 `lyrics/` 下的歌词文件，并提供按歌手、歌名、专辑查询的统一入口。`EnrichCacheStore` 是 Swift 侧唯一写入者：搜索成功、手动编辑、删除和人工标记都直接更新同一份缓存，再刷新 reader。

缓存中的主要字段包括 `lyrics`、`lyrics_tr`、`lyrics_roma`、`lyrics_yrc`、`duration`、`lyrics_source`、`cover_url` 和人工编辑标记。歌词文件用于保留可编辑正文，JSON 用于条目元信息和决策摘要。

## 同步与展示

- `LyricsSyncEngine` 解析 LRC 行时间和 YRC 逐字时间，在当前播放位置选择主行、上一行和下一行。
- 时间轴偏移按全局、播放器和单曲三层设置计算，偏移值不改变原始缓存内容。
- 悬浮歌词使用逐字渐变或整行高亮；菜单栏使用同一解析结果的纯文本行。
- 译文和罗马音是可选副行，缺少缓存字段时由展示端已有的注音逻辑处理。

## 缓存刷新

播放换歌、搜索写入、歌词管理编辑和 App 启动都会刷新 reader。当前不使用文件监听、后台进程状态或跨进程合并；App 自己写入后立即拥有最新值。
