# UVFormatter

UVFormatter 是一个 macOS 菜单栏工具。选中完整的 JSON、JSONC、JSON5 或 XML，按全局快捷键，即可在当前位置加缩进和换行。格式化在本机完成。

## 使用

1. 下载 [GitHub Releases](https://github.com/edmondzhang/UVFormatter/releases) 中的应用 ZIP，解压并将 UVFormatter 放进「应用程序」。
2. 启动后从菜单栏打开设置，按提示授予「辅助功能」权限。返回设置页检查授权状态。
3. 在可编辑区域选中文本，按设置页显示的快捷键。无法安全写回且已成功完成格式化时，可手动复制结果。

设置页可更改快捷键、测试注册、登录时启动和检查更新。使用剪贴板的兼容路径会暂时写入剪贴板，剪贴板历史工具可能记录临时内容。

### JSON 方言与诊断记录

格式化器按输入内容识别严格 JSON、JSONC、JSON5。JSONC 支持 `//`、`/* ... */` 注释及常见尾逗号。JSON5 支持注释、非引号键、单引号字符串、扩展转义与扩展数字。格式化保留输入方言、注释、键顺序、数字与字符串源码。

语义确定的方言语法会直接格式化。歧义输入保持不变，并显示行列、错误原因和可能的修复候选。

本地诊断日志默认开启，仅记录解析异常以及 JSONC / JSON5 输入，并保存原始选区和解析诊断。日志可能含有密钥、令牌或个人信息，只保存在 `~/Library/Application Support/UVFormatter/diagnostics/diagnostics.jsonl`，不会上传。设置页可关闭记录、清理日志并打开目录。日志占用最多 100 MiB，达到上限后循环覆盖最早的记录。关闭记录只影响之后产生的事件，不会自动清理已存在的日志。

### 跨应用验收

在实际安装的钉钉普通聊天输入框、钉钉「发送代码片段」、微信聊天输入框和 VS Code 编辑区中分别验证下列操作，聊天测试使用示例数据。

- 用 `{"ok":true,"items":[1,2]}` 和 `<items><item>1</item><item>2</item></items>` 验证格式识别与原地替换。在选区前后放置其他文本并检查其内容，再用一次 `⌘Z` 检查宿主应用的撤销行为。
- 用不完整的 JSON、空选区、只读区域以及在格式化期间切换目标验证操作会安全结束。
- 预先复制一张图片或一段文本，测试格式化后的恢复。在操作期间新复制内容时，新内容应留在剪贴板。
- 注册已被另一个应用占用的组合，验证冲突提示与旧键位保留。各宿主应用里的快捷键响应需要逐个试按。

## 构建与测试

需要 Xcode。PR 和 `main` 分支的 GitHub Actions 在 Apple Silicon 和 Intel runner 上执行测试。

```sh
xcodebuild test -project UVFormatter.xcodeproj -scheme UVFormatter \
  -destination 'platform=macOS' -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO
```

## 发布

仓库的 GitHub Pages 发布源设为 **GitHub Actions**。启用 `release` 发布环境，并将该环境和 `github-pages` 的部署范围限制为受信的版本标签 `v*`。发布流程还会验证标签提交已进入 `main`。

| 配置 | 内容 |
| --- | --- |
| Repository variable `SPARKLE_PUBLIC_KEY` | Sparkle 更新公钥的 Base64 字符串 |
| `release` secret `DEVELOPER_ID_P12_BASE64` | 包含 Developer ID Application 证书和对应私钥的 PKCS#12 内容，Base64 编码 |
| `release` secret `DEVELOPER_ID_P12_PASSWORD` | PKCS#12 导出密码 |
| `release` secret `APPLE_NOTARY_KEY_P8` | App Store Connect 团队 API 密钥的 PEM 内容 |
| `release` secret `APPLE_NOTARY_KEY_ID` | 用于公证的团队 API 密钥 ID |
| `release` secret `APPLE_NOTARY_ISSUER_ID` | App Store Connect 团队 Issuer ID |
| `release` secret `SPARKLE_PRIVATE_KEY` | 与发布公钥匹配的 Sparkle 私钥导出内容 |

为经过测试的 `main` 提交创建并推送形如 `v1.2.3` 的正式标签。三个版本号分量各为 0 至 999，构建号由标签推导并随版本递增。签名流程构建 Universal App，公证并附加票据，再发布 ZIP 和更新元数据。更新清单从公开正式发行资产生成，上传 GitHub Pages。Release 已发布且 Pages 部署失败时，可重跑同一次工作流继续生成和部署清单。

发布后下载 ZIP，用 `spctl --assess --type execute --verbose=2` 和 `xcrun stapler validate` 验证解压后的 App。使用更新前的可发布版本检查更新，确认提示、签名校验、安装和重启。确认新应用保留快捷键配置，并复核辅助功能状态和原地替换。

需要停止分发某一版本时，可通过 GitHub Releases 将该版本撤下，再由可信且仍可用的正式标签重跑流程刷新清单。已安装受影响版本的用户可通过构建号更高的修复版恢复。
