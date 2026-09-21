# 发版流程 checklist

本文只记录当前 Swift App 仍适用的发版步骤。

## 本地验证

```bash
swift build -c release --package-path lyrimuse --product lyrimuse
swift build -c release --package-path lyrimuse --product lyrimuse-selftest
swift run -c release --package-path lyrimuse lyrimuse-selftest --quiet
bash -n lyrimuse/build.sh lyrimuse/package.sh
python3 lyrimuse/scripts/check_strings_parity.py
python3 lyrimuse/scripts/check_third_party_licenses.py
git diff --check
```

需要验证安装产物时运行 `lyrimuse/build.sh --dest <目录> --no-restart`，再检查签名、资源和架构。最终 App 只包含 Swift 主程序和仍在使用的资源。

## 发布

在通过检查的提交上创建版本标签，推送提交和标签，随后检查 CI、Apple Silicon/Intel 产物和发布说明。提交前确认 `git status --short` 只包含预期文件。
