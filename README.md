# OMP History for Tern

在 Tern 左侧浏览当前 OMP 数据目录下所有项目的会话，按最近修改时间排列；点击会话在当前标签右侧分屏恢复。可按标题、目录或会话 ID 搜索；每页显示数量随侧边栏高度调整，底部可翻页并查看结果数量。

会话卡片的时间显示为“今天”“昨天”或完整日期时间，后面以 ` · ` 分隔工作目录名。

## 安装

需要 Tern、OMP 和 `python3`。在本目录执行：

```sh
tern plugin link .
```

侧边栏默认显示。使用命令面板中的 `OMP History: toggle sidebar` 或 `⌘⌥⇧H` 显示或隐藏；侧边栏内可搜索和刷新。索引每 30 秒自动刷新。

Tern 的 `tiles` 布局在一个标签已有多个面板时可能将新侧栏放到窗口外。若看不到侧栏，请将窗口布局切换为 `rail`；插件不会修改全局布局设置。

也可使用命令面板中的 `OMP History: search and resume` 搜索并恢复会话，不受侧边栏布局影响。

会话来自 `$PI_CODING_AGENT_DIR/sessions`；未设置时使用 `~/.omp/agent/sessions`。Tern 启动环境决定该变量的值。插件读取会话头部和文件修改时间，不读取或上传聊天正文。恢复会话时使用原始工作目录；若目录不存在，OMP 会报告启动错误。

开发时修改插件文件后 Tern 会自动重新加载。`tern plugin unlink omp-history` 可卸载链接。
