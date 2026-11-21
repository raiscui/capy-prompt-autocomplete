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

## 当前对话的技能推荐

使用已有的本机调试启动入口（见下节）时，输入框获得焦点后，工具按当前线程读取 Capy 已加载的技能名称和说明。打开过技能菜单不是前提。建议模型在生成提示词的同一次请求中选择技能，通常一至两个；接受候选才会在草稿中填入它的引用。目录只在内存中按线程短暂缓存。目录读取不可用时，普通输入建议仍可使用。

与既有对话上下文一样，线程的技能名称与说明也会发给所配置的模型服务。工具不读取技能正文。

## 隐藏赞助广告

运行 `sh ./launch-capy-with-ad-hiding.sh --install`，会在 `~/Applications` 创建 `Capy (hide ads).app`。以后从这个入口启动 Capy，它会同时启动 Capy Prompts。广告卡出现时，Capy Prompts 会隐藏整张卡；普通聊天内容不受影响。

如果 Capy 已经以普通方式运行，先退出 Capy，再使用上述入口启动。启动入口使用本机 `127.0.0.1:9333` 调试端口；其他本机进程也可能通过该端口读取或控制 Capy，因此只应在信任本机其他进程的环境中使用。退出 Capy 后端口关闭。

## 开发验证

运行 `swift test --filter PipeLifecycleTests`，验证连接关闭、心跳失败和取消时的等待都能结束。

生成策略和候选筛选改编自 MIT 许可的 `omp-prompt-autocomplete`。本应用不需要安装或启动 OMP。
