# UVFormatter 产品需求与实施方案（待确认）

## 产品需求

UVFormatter 是 macOS 菜单栏应用。用户在可编辑文本控件里选中完整的 JSON 或 XML 后，按一个全局快捷键，应用自动识别格式，加缩进和换行，再原地替换选区。格式化在本机完成，应用仅在用户触发时读取选区，不保存文本历史，也不将文本写入日志或发送到网络。

- 格式化保留 JSON 键顺序、数字和字符串的原始写法。XML 保留正文空白、混合内容和 `xml:space` 的语义。默认建议使用两个空格缩进。
- 空选区、语法错误和处理中目标变化时，给出提示并保留原文。已读到文本且格式化成功，但无法安全写回时，提供用户主动点击的「复制结果」。
- 设置页提供快捷键录入、注册冲突检测、恢复默认和试按入口。新键位注册失败时保留原配置。应用内的实际冲突通过目标编辑器实测确认。
- 权限页显示辅助功能授权状态，提供系统设置入口、复查和示例文本测试。菜单栏提供设置、退出和检查更新入口，登录时启动由用户开启。
- App 支持手动检查更新和可选的自动检查。检测到新版后由用户确认安装。

## 建议实现

使用 Swift 与 AppKit，建议最低支持 macOS 14，发行包同时包含 Apple Silicon 和 Intel 架构。菜单栏进程注册全局快捷键，触发时才读取前台应用、窗口与编辑控件。优先使用辅助功能 API 直接处理选区。剪贴板兼容路径确认取得本次复制的内容，写回前复核焦点，并在可核对时复核选区。无法可靠定位写回目标时转为手动复制。恢复剪贴板前检查是否已有更新，保留用户或其他程序新写入的内容。

将格式校验与排版放在独立模块。JSON 按原始词法内容排版，避免数值重新序列化与键重排。XML 排版保守处理文本节点与混合内容，禁用外部实体解析。设置只存快捷键和应用偏好，临时处理结果只保留在内存中。

## 文件与执行顺序

| 顺序 | 文件与职责 | 验证 |
| --- | --- | --- |
| 1 | `AGENTS.md` 记录项目约定，`UVFormatter.xcodeproj/project.pbxproj` 定义工程、目标和版本配置，`UVFormatter/Info.plist` 定义应用标识和更新配置 | 本地与 CI 都能构建 |
| 2 | `UVFormatter/Formatter.swift` 实现校验和保真排版，`UVFormatterTests/FormatterTests.swift` 覆盖格式与边界 | JSON 原始字面量、XML 混合内容、空选区与非法输入 |
| 3 | `UVFormatter/AppDelegate.swift` 管理菜单栏生命周期，`UVFormatter/HotKey.swift` 注册与更新快捷键，`UVFormatter/SelectionFormatter.swift` 处理选区与剪贴板，`UVFormatter/SettingsWindow.swift` 承载设置和权限状态 | 快捷键冲突、权限变更、选区替换与剪贴板恢复 |
| 4 | `.github/workflows/ci.yml` 执行 PR 检查，`.github/workflows/release.yml` 构建发行包并发布，版本更新清单 `appcast.xml` 由发布流程生成到 GitHub Pages，`README.md` 记录使用和发布方式 | 下载产物、验证签名和公证、从旧版本检查并安装新版 |

## GitHub 发布与回退

建议使用公开个人仓 `edmondzhang/UVFormatter`。GitHub Actions 在 PR 上运行构建与测试。版本标签触发 Universal 包构建，使用 Developer ID Application 签名并完成 Apple 公证，再用 Sparkle 签署更新包。先验证 GitHub Release 安装包可下载，再更新 GitHub Pages 上的 `appcast.xml`。发布密钥只进入受限的 GitHub Actions Secrets，发布任务与来自 Fork 的 PR 检查隔离。该工具仅在更新时访问发布站点。

如果更新包发布后发现问题，可先撤回更新清单中的该版本以停止推送。已安装的用户通过带有更高构建号的修复版恢复。发布前保留上一版安装包，并核对签名身份、Bundle ID 和升级后的权限状态。

## 验收与待确认

- 在钉钉普通聊天输入框、钉钉「发送代码片段」、微信聊天输入框和 VS Code 编辑区上分别验收 JSON、XML、选区边界和一次 `⌘Z` 恢复。测试文本使用示例数据，聊天内容只留在编辑框内。
- 验证权限被拒绝后能重新检查，快捷键冲突时保留旧设置，切换焦点时不会把结果写到别处。无法安全写回时可手动复制结果。
- 在下载后的真实安装包上验证 Gatekeeper，并用两个不同构建号验证 Sparkle 检测和安装的完整链路。
- 已观察到本机安装了 Xcode，GitHub CLI 当前登录 `edmondzhang`。本机钥匙串检测到 Apple Development 签名身份，未检测到 Developer ID Application 签名身份。待确认为所选 ADP 团队生成或导入可用的发行签名身份，并配置公证和更新签名凭据。
