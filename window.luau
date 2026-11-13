-- OMP 会话历史侧边栏：每个活动标签页使用一个原生画布面板。
local TITLE = "OMP History"
local DEFAULT_PAGE_SIZE = 8
local tern_executable = tern.getenv("TERN_EXE")
if not tern_executable or tern_executable == "" then
	local app_executable = "/Applications/Tern.app/Contents/MacOS/tern"
	tern_executable = if tern.runtime.os == "macos" and tern.fs.exists(app_executable) then app_executable else "tern"
end
local rows = {}
local filtered = {}
local query = ""
local panes = {}
local loading = false
local sizing = false
local next_size_check = 0
local error_text = nil
local opening = false

-- 转义传给终端 shell 的单个参数。
local function shell_quote(value)
	return "'" .. string.gsub(value, "'", "'\\''") .. "'"
end

-- 为每个侧边栏保留独立的页码与可见行数。
local function pane_state(pane)
	if not pane then return { page = 1, size = DEFAULT_PAGE_SIZE } end
	if not panes[pane] then panes[pane] = { page = 1, size = DEFAULT_PAGE_SIZE } end
	return panes[pane]
end

-- 对搜索条件应用过滤，保留原始时间排序。
local function filter_rows()
	filtered = {}
	local needle = string.lower(query)
	for _, row in rows do
		local haystack = string.lower(row.title .. " " .. row.cwd .. " " .. row.id)
		if needle == "" or string.find(haystack, needle, 1, true) then
			table.insert(filtered, row)
		end
	end
end

-- 构建当前窗格的会话卡片和固定在底部的分页栏。
local function view(pane)
	local ui = tern.ui
	local state = pane_state(pane)
	local pages = math.max(1, math.ceil(#filtered / state.size))
	state.page = math.max(1, math.min(state.page, pages))
	local cards = {}
	if error_text then
		table.insert(cards, ui.text("读取失败：" .. error_text))
	elseif loading and #rows == 0 then
		table.insert(cards, ui.text("正在读取会话…"))
	elseif #filtered == 0 then
		table.insert(cards, ui.text(if query == "" then "没有保存的会话" else "没有匹配的会话"))
	end
	local first = (state.page - 1) * state.size + 1
	local last = math.min(state.page * state.size, #filtered)
	local now = os.time()
	local today = os.date("%Y-%m-%d", now)
	-- 取昨天中午，避免夏令时切换导致跨日判断偏差。
	local yesterday = os.date("%Y-%m-%d", now - (tonumber(os.date("%H", now)) + 12) * 3600)
	for i = first, last do
		local row = filtered[i]
		local title = string.gsub(row.title, "[%c]+", " ")
		local cwd = if row.cwd ~= "" then (string.match(row.cwd, "([^/]+)/*$") or row.cwd) else "未知目录"
		local day = os.date("%Y-%m-%d", row.updated)
		local date = if day == today then "今天" elseif day == yesterday then "昨天" else os.date("%Y-%m-%d %H:%M", row.updated)
		table.insert(cards, ui.el("button", {
			key = "chat_" .. row.id,
			class = "omp-history-card",
			title = title,
			actions = { click = "chat:" .. row.id },
		}, {
			ui.el("div", { class = "omp-history-title", text = title }),
			ui.el("div", { class = "omp-history-meta", text = date .. " · " .. cwd }),
		}))
	end
	local main = ui.node("col", { gap = "none" }, {
		ui.node("row", { gap = "sm", justify = "end" }, {
			ui.button("", { icon = "search", title = "搜索", size = "sm", actions = { click = "search" } }),
			ui.button("", { icon = "repeat", title = "刷新", size = "sm", actions = { click = "refresh" } }),
		}),
		ui.el("div", { class = "omp-history-list" }, cards),
	})
	local dock = ui.node("col", { gap = "none" }, {
		ui.el("div", { class = "omp-history-footer" }, {
			ui.node("row", { gap = "xs" }, {
				ui.button("", { icon = "arrow-left", title = "上一页", size = "sm", disabled = state.page == 1, actions = { click = "prev" } }),
				ui.text(state.page .. " / " .. pages),
				ui.button("", { icon = "arrow-right", title = "下一页", size = "sm", disabled = state.page == pages, actions = { click = "next" } }),
			}),
			ui.el("div", { class = "omp-history-count", text = tostring(#filtered) .. " 个会话" }),
		}),
	})
	return main, dock
end

-- 将当前列表同步到插件拥有的所有侧边栏。
local function redraw(cx)
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			local main, dock = view(canvas.pane)
			cx.canvas:set(canvas.pane, { view = main, dock = dock })
		end
	end
end

-- 从 Tern 的窗格网格高度计算每页数量，尺寸变化时保留当前首条会话。
local function update_sizes(cx)
	if sizing then return end
	local owned = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then owned[canvas.pane] = true end
	end
	if not next(owned) then return end
	sizing = true
	tern.process.run({ tern_executable, "ls", "--json" }, { timeout_ms = 5000 }, function(result, next_cx)
		sizing = false
		if not next_cx or result.status ~= 0 then return end
		local ok, data = pcall(tern.json.decode, result.stdout)
		if not ok or type(data) ~= "table" or type(data.sessions) ~= "table" then return end
		local changed = false
		for _, session in data.sessions do
			for _, tab in session.tabs or {} do
				for _, block in tab.blocks or {} do
					if owned[block.id] and type(block.rows) == "number" and block.rows > 0 then
						local state = pane_state(block.id)
						local size = math.max(1, math.min(300, math.floor((block.rows - 4) / 3)))
						if size ~= state.size then
							local first = (state.page - 1) * state.size
							state.page = math.floor(first / size) + 1
							state.size = size
							changed = true
						end
					end
				end
			end
		end
		if changed then redraw(next_cx) end
	end)
end

-- 在后台读取索引，避免大目录扫描阻塞 Tern 窗口。
local function refresh(cx)
	if loading then return end
	loading = true
	tern.process.run({ "python3", tern.plugin.dir .. "/sessions.py" }, { timeout_ms = 30000 }, function(result, next_cx)
		loading = false
		if not next_cx then return end
		if result.status ~= 0 then
			error_text = if result.stderr ~= "" then result.stderr else "索引程序运行失败"
		else
			local ok, data = pcall(tern.json.decode, result.stdout)
			if ok and type(data) == "table" then
				rows = data
				error_text = nil
				filter_rows()
			else
				error_text = "索引结果无效"
			end
		end
		redraw(next_cx)
	end)
	redraw(cx)
end

-- 为当前标签页挂载侧边栏，已有面板时保留现有布局。
local function ensure_sidebar(cx)
	if tern.kv.get("visible") == false or opening then return end
	local focused = cx.session:focused()
	local tab = if focused then cx.session:tab_of(focused) else nil
	if not tab then return end
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and cx.session:tab_of(canvas.pane) == tab then return end
	end
	opening = true
	local main, dock = view()
	local pane, err = cx.canvas:open({
		title = TITLE,
		about = "浏览、搜索并恢复本地 OMP 会话。",
		view = main,
		dock = dock,
		how = "beside",
		target = focused,
		dir = "left",
		ratio = 0.25,
		focus = false,
	})
	opening = false
	if not pane then cx:toast("error", "无法打开 OMP 历史侧边栏", tostring(err)) end
end

-- 找到当前标签最右侧的实际内容窗格，避免把侧边栏再次拆开。
local function rightmost(tree, sidebar)
	if not tree then return nil end
	if tree.pane then return if tree.pane ~= sidebar then tree.pane else nil end
	return rightmost(tree[2], sidebar) or rightmost(tree[1], sidebar)
end

-- 根据会话文件和原工作目录在当前标签右侧分屏恢复会话。
local function open_chat(cx, row, sidebar)
	local origin = sidebar or cx.session:focused()
	local tab = if origin then cx.session:tab_of(origin) else nil
	local layout = if tab then cx.session:layout(tab) else nil
	local target = if layout then rightmost(layout.root, sidebar) else nil
	local launch = { command = "omp --resume " .. shell_quote(row.path) }
	if row.cwd ~= "" then launch.cwd = row.cwd end
	if not target or not cx.layout:split(target, "right", launch) then
		cx:toast("error", "无法恢复会话", row.title)
	end
end

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= tern.plugin.id then return nil end
	local id = string.match(ev.act, "^chat:(.+)$")
	if id then
		for _, row in rows do
			if row.id == id then
				open_chat(cx, row, ev.pane)
				break
			end
		end
	elseif ev.act == "search" then
		cx:prompt({ value = query, placeholder = "搜索标题、目录或会话 ID", action = "search" }):next(function(value, err, next_cx)
			if not next_cx then return end
			if err then next_cx:toast("error", "搜索失败", err) return end
			if value ~= nil then
				query = value
				for _, state in panes do state.page = 1 end
				filter_rows()
				redraw(next_cx)
			end
		end)
	elseif ev.act == "refresh" then
		refresh(cx)
	elseif ev.act == "prev" then
		local state = pane_state(ev.pane)
		state.page = math.max(1, state.page - 1)
		redraw(cx)
	elseif ev.act == "next" then
		local state = pane_state(ev.pane)
		state.page = math.min(math.max(1, math.ceil(#filtered / state.size)), state.page + 1)
		redraw(cx)
	else
		return nil
	end
	return true
end)

tern.command({
	id = "browse",
	title = "OMP History: search and resume",
	icon = "history",
	run = function(cx)
		if #rows == 0 then
			cx:toast("info", if loading then "正在读取 OMP 会话" else "没有可用的 OMP 会话", error_text)
			return
		end
		local items = {}
		for _, row in rows do
			table.insert(items, { label = row.title, detail = row.cwd, row = row })
		end
		cx:pick({ items = items, placeholder = "搜索 OMP 会话", action = "resume" }):next(function(item, err, next_cx)
			if not next_cx then return end
			if err then
				next_cx:toast("error", "无法选择 OMP 会话", err)
			elseif item then
				open_chat(next_cx, item.row)
			end
		end)
	end,
})

tern.command({
	id = "toggle",
	title = "OMP History: toggle sidebar",
	icon = "history",
	run = function(cx)
		local visible = tern.kv.get("visible") == false
		tern.kv.set("visible", visible)
		if visible then
			ensure_sidebar(cx)
			refresh(cx)
		else
			for _, canvas in cx.canvas:list() do
				if canvas.owner == tern.plugin.id and canvas.title == TITLE then
					cx.layout:close(canvas.pane)
				end
			end
		end
	end,
})
tern.bind("cmd+alt+shift+h", "plugin.omp-history.toggle")

-- 定期在新标签上挂载面板，并清理只剩侧边栏的标签。
local function tick(cx)
	tern.timer(1000, tick)
	if not cx then return end
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == TITLE then
			local tab = cx.session:tab_of(canvas.pane)
			local count = 0
			for _, pane in cx.session:panes() do
				if pane.tab == tab then count += 1 end
			end
			if tab and count == 1 then cx.layout:close(canvas.pane) end
		end
	end
	ensure_sidebar(cx)
	if tern.now() >= next_size_check then
		next_size_check = tern.now() + 2000
		update_sizes(cx)
	end
end

tern.on("pane_closed", function(ev)
	panes[ev.pane] = nil
end)

-- 定期刷新历史，手动刷新和搜索不必等待定时器。
local function refresh_tick(cx)
	tern.timer(30000, refresh_tick)
	if cx then refresh(cx) end
end

tern.on("window_start", function(cx)
	ensure_sidebar(cx)
	refresh(cx)
end)
-- 插件重载不会重新触发 window_start，需要主动恢复索引。
tern.timer(100, function(cx)
	if cx then refresh(cx) end
end)
tern.timer(1000, tick)
tern.timer(30000, refresh_tick)
