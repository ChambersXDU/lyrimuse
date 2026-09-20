# 发版流程 checklist

本文只记录当前仓库仍然适用的发版步骤；发布前以本次提交中的源码、资源和打包脚本为准。

## 一、准备发布内容

* [ ] 根据 `git diff <上一个 tag>..HEAD` 整理 `RELEASE_NOTES_v<版本>.md`，只写用户可感知的变化。
* [ ] 同步检查根目录的 README、`llms.txt`、`docs/` 和打包说明，确保功能描述与当前应用一致。
* [ ] 确认版本号在 Swift App、collector、`build.sh` 和发布说明中一致。

## 二、本地验证
* [ ] `swift build -c release --product lyrimuse`
* [ ] `swift build -c release --product lyrimuse-selftest`
* [ ] `swift run -c release lyrimuse-selftest --quiet`
* [ ] `(cd lyrimuse-collector && gofmt -l . && go test ./...)`
* [ ] `bash -n lyrimuse/build.sh lyrimuse/package.sh`
* [ ] `git diff --check`

如果要验证可安装产物，再运行 `lyrimuse/build.sh --dest <目录>`，检查 `.app` 内的 App、collector、翻译 helper、罗马化 helper 和资源文件均存在，再执行 `lyrimuse/package.sh` 生成压缩包和校验文件。

## 三、发布
* [ ] 在已验证的提交上创建带注释的版本标签：`git tag -a v<版本> <commit> -F RELEASE_NOTES_v<版本>.md`
* [ ] 推送提交和标签：`git push origin <分支>`、`git push origin v<版本>`
* [ ] 确认 CI 构建成功，并检查 Apple Silicon 与 Intel 产物、校验文件和 GitHub Release 说明。
* [ ] 更新 Homebrew cask 与 `packaging/macports/` 中的版本、源码校验和及文件大小。
* [ ] 发布后在一台干净环境安装产物，确认首次启动、播放器读取、歌词显示、设置保存和 collector 重启均正常。

## 四、提交前后检查
* [ ] `git status --short` 只包含预期文件。
* [ ] 发布提交已包含源码、测试、资源、本地化和文档的同步变更。
* [ ] 发布完成后记录版本号、提交哈希和 CI 运行结果，便于回溯。
