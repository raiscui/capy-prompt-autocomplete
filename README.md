# Capy Prompts

Capy Prompts 是 macOS 菜单栏工具。在 Capy Desktop 的对话输入框中停顿片刻，就能看到下一步建议或草稿续写。工具直接请求你配置的 OpenAI 兼容服务，可以单独启动和使用。

## 启动

在本目录运行 `./build-app.sh` 生成 `.build/Capy Prompts.app`。双击应用启动。本机构建可使用专用代码签名证书。将登录钥匙串中已受信任且带私钥的代码签名证书的 40 位指纹写入 `~/Library/Application Support/CapyPrompts/signing-identity.sha1`。脚本使用该身份签名，并核对完整指定要求（应用标识符 `local.capyprompts.companion` 和签名证书）及签名完整性。配置的证书不可用时构建会失败。未配置指纹的机器默认使用 ad-hoc，内容变化后可能需要重新授权。切换签名身份后，从 `/Applications` 正常启动应用，在“系统设置 → 隐私与安全性 → 辅助功能”授权一次；后续升级应沿用同一证书、标识符和安装路径。该权限用于输入建议，广告隐藏不依赖它。菜单栏的 `Capy ✎` 可以暂停建议或退出。

## 模型配置

在 `~/Library/Application Support/CapyPrompts/config.json` 指定服务与模型。以下是本机验收配置。

```json
{
  "baseURL": "http://127.0.0.1:3425/v1",
  "model": "auto/qwen3.8-flash",
  "reasoningEffort": "low"
}
```

需要鉴权时可以通过 `CAPY_PROMPT_API_KEY` 环境变量提供密钥。`CAPY_PROMPT_BASE_URL` 和 `CAPY_PROMPT_MODEL` 可覆盖文件中的地址与模型。修改配置后重启伴随工具。模型会接收光标前后的草稿和当前对话的部分内容。

## 使用

打开一个有聊天记录的 Capy 对话，点进消息输入框。空草稿显示下一步建议；输入内容并停顿时，工具改为续写。按 Control + Option + Space 打开完整候选，按 Control + Option + 1、2 或 3 将对应候选插入草稿。切换线程、编辑草稿或移动光标会使旧候选失效。回填直接向当前编辑器输入字符，换行使用 Shift + Return，不读取或写入系统剪贴板。

长候选会按浮窗宽度换行；超过可见高度时，可用滚轮或触控板查看末尾。按 Control + Option + Return 插入当前选中项的完整正文。模型因输出 token 达到上限而只返回半条候选时，工具会舍弃不完整部分。

## 剪贴板朗读

在任意应用中复制文本，按 ⌘F8 开始朗读。开始时会固定一份文本快照。再次按 ⌘F8 暂停，再按一次从暂停位置继续。⇧⌘F8 从头重播这份快照，即使剪贴板已经换了内容。要切换到新文本，在 `Capy ✎` 菜单选择“朗读新的剪贴板文本”。菜单也提供暂停、继续、重播、停止和当前状态。

朗读会先把剪贴板快照通过所配置的模型网关交给 SWE-2 Flash（`devin/swe-2-flash`）整理成讲稿，保留结论、限制和数字，用自然语言表达链接、路径和代码的含义。整理后的文字再交给阿里云合成语音。暂停、继续和从头重播复用本次讲稿；整理失败时会在菜单里显示错误。读取快照不会改写系统剪贴板。朗读可以在 Capy Desktop 关闭、输入建议暂停或未授予辅助功能权限时使用。

在上面的 `config.json` 中设置 `speechVoice`，例如 `"longanlingxin"`（龙安灵心）。应用从进程环境中的 `DASHSCOPE_API_KEY`、`YINO_QWEN_TOKEN_PLAN_KEY` 依次查找有效的 Token Plan 套餐密钥。通过 Finder 启动时通常不会继承终端环境变量，可将 `speechCredentialFile` 设为本机凭据文件的绝对路径，文件中使用 `YINO_QWEN_TOKEN_PLAN_KEY` 赋值。请仅允许你的账号读取该文件。

如果 F8 默认控制媒体播放，按住 Fn（🌐）再使用快捷键，或在系统键盘设置中启用标准功能键。如果组合键被其他应用占用，菜单会显示注册失败的组合键，仍可从菜单操作朗读。

安装或升级需要 macOS 13 或更新版本。使用 Swift 5.9 或更新工具链在本目录运行 `./build-app.sh`，退出正在运行的 Capy Prompts，将生成的 `.build/Capy Prompts.app` 复制到 `/Applications`，再启动安装好的应用。升级时沿用“启动”一节中的签名身份。

## 当前对话的技能推荐

使用已有的本机调试启动入口（见下节）时，输入框获得焦点后，工具按当前线程读取 Capy 已加载的技能名称和说明。打开过技能菜单不是前提。建议模型在生成提示词的同一次请求中选择技能，通常一至两个；接受候选才会在草稿中填入它的引用。目录只在内存中按线程短暂缓存。目录读取不可用时，普通输入建议仍可使用。

与既有对话上下文一样，线程的技能名称与说明也会发给所配置的模型服务。工具不读取技能正文。

## 隐藏赞助广告

运行 `sh ./launch-capy-with-ad-hiding.sh --install`，会在 `~/Applications` 创建 `Capy (hide ads).app`。以后从这个入口启动 Capy，它会同时启动 Capy Prompts。广告卡出现时，Capy Prompts 会隐藏整张卡；普通聊天内容不受影响。

如果 Capy 已经以普通方式运行，先退出 Capy，再使用上述入口启动。启动入口使用本机 `127.0.0.1:9333` 调试端口；其他本机进程也可能通过该端口读取或控制 Capy，因此只应在信任本机其他进程的环境中使用。退出 Capy 后端口关闭。

## 开发验证

运行 `swift test --filter PipeLifecycleTests`，验证连接关闭、心跳失败和取消时的等待都能结束。

生成策略和候选筛选改编自 MIT 许可的 `omp-prompt-autocomplete`。本应用不需要安装或启动 OMP。
