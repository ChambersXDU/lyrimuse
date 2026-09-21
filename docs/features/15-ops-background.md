# 15. 运行与部署

## 构建

`lyrimuse/build.sh` 负责 Swift release 构建、组装 `.app`、复制资源、签名和可选重启 App。构建不依赖 Go，不生成第二个歌词进程，也不执行多架构歌词服务打包或版本一致性检查。

开发和 CI 的基本检查为：

```bash
swift build --package-path lyrimuse --product lyrimuse
swift run --package-path lyrimuse lyrimuse-selftest --quiet
bash -n lyrimuse/build.sh lyrimuse/package.sh
```

## 运行

App 通过 `SMAppService` 管理可选的登录启动。歌词搜索、缓存写入、歌词管理和两个歌词展示面都在同一个 Swift App 进程内，没有独立歌词服务或进程间协调。

运行日志和诊断沿用 App 现有日志路径；歌词 Provider 的错误只记录为本次搜索的源级失败，不会阻止其它源返回结果。删除缓存或歌词文件后，下一次播放或手动搜索会重新建立条目。

## 发布前检查

- 运行完整 selftest，并确认字符串和第三方许可证检查通过。
- 用 `build.sh --dest <目录> --no-restart` 构建 App，检查 bundle 中只有 Swift App、现有资源和必要的 media-control 工具。
- 用 `codesign --verify --deep --strict` 校验 bundle，并确认 App 启动后 Apple Music 换歌、悬浮歌词、菜单栏歌词和缓存重启恢复正常。
