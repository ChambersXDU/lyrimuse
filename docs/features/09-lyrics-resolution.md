# 09. 歌词解析与匹配

## 定位

歌词解析是 `LyrimuseCore` 中的一条直接 Swift 链路：`LyricsQuery` 进入五个无状态 Provider，`LyricsResolver` 并发收集 `LyricsCandidate`，`LyricsMatcher` 统一去重、评分和排序，App 将最佳结果写入缓存。

## 最小模型

```swift
struct LyricsQuery: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval?
}

struct LyricsCandidate: Sendable {
    let source: String
    let lyrics: String
    let translation: String?
    let romanization: String?
    let duration: TimeInterval?
}
```

Provider 只做 HTTP、协议解码和结果解析，不持有缓存、重试状态或跨源评分。

## 五个歌词源

1. LRCLIB：搜索接口直接返回 LRC 或纯文本。
2. 酷我：搜索歌曲后读取 LRC，并保留可用候选。
3. 网易云：搜索歌曲并读取 LRC、译文、罗马音和必要的逐字数据。
4. 酷狗：读取 LRC/KRC，保留 KRC 解密、解压和逐字时间转换。
5. QQ 音乐：使用 musicu 接口，保留 QRC/YRC 所需的 3DES、zlib 解码和逐字时间转换。

每个源的失败只影响该源。Resolver 等所有已启用的 Provider 返回后统一排序，不使用早返回状态机或源级熔断。

## Matcher 保留的规则

- 标题、歌手和专辑做大小写、空白、标点和常见版本词归一化。
- 处理 `feat.`、括号版本、Live、Remaster 等常见标题变化；多歌手按 credit 分隔符比较。
- 比较候选歌手、专辑和时长，时长差越小越有利。
- 拒绝无有效时间轴、只有署名行、歌词为空或明显不匹配的候选；检查最后时间戳是否合理。
- 对候选正文去重；相同歌词跨源出现时增加共识分。
- 逐字时间、译文、罗马音和封面等真实可用字段作为加分项，最终按总分稳定排序。

手动搜索和自动换歌使用同一个 Resolver/Matcher。设置页仍可以关闭某些源；默认源集合固定为上述五个。

## 缓存写入

`LyricsSearchService` 将最佳候选转换为现有 `EnrichCacheStore` 字段，保留来源、翻译、罗马音、YRC、封面和匹配摘要。重新匹配只重新搜索并直接走同一写入路径，不启动外部进程。
