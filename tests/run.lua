vim.opt.rtp:prepend(vim.fn.getcwd())
local uv = vim.uv or vim.loop
local scanner = require("obsidian-stats.scan")
local calendar = require("obsidian-stats.calendar")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local count = 0

local function eq(expected, actual)
	assert(vim.deep_equal(expected, actual), "Expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

local function test(name, fn)
	fn()
	count = count + 1
	print("ok " .. count .. " - " .. name)
end

local function write(path, text)
	local fd = assert(uv.fs_open(path, "w", 420))
	assert(uv.fs_write(fd, text, 0))
	assert(uv.fs_close(fd))
end

local function scan(path)
	local done, err, result = false
	scanner.scan(path, function(e, r)
		assert(not done, "callback ran twice")
		done, err, result = true, e, r
	end)
	assert(not done, "scan must complete asynchronously")
	assert(vim.wait(10000, function()
		return done
	end, 10), "scan timed out")
	return err, result
end

local function date(year, month, day, hour)
	return os.time({ year = year, month = month, day = day, hour = hour or 12 })
end

local function run()
	test("empty vault has sensible zero statistics", function()
		local err, result = scan(root)
		assert(not err, err)
		eq(0, #result.notes)
		eq(0, result.total_words)
		eq({}, result.tags)
		eq({ days_active = 1, streak = 0, velocity = "0.00" }, calendar.summarize({}, os.time()))
	end)

	test("missing vault reports an error", function()
		local err, result = scan(root .. "/missing")
		assert(err:find("Vault path not found", 1, true))
		eq(nil, result)
	end)

	local vault = root .. "/vault's $(touch INJECTED); spaces"
	vim.fn.mkdir(vault, "p")
	write(vault .. "/note's\nname.md", "hello world #work #work\n#garden")
	write(vault .. "/second.md", "one\ttwo\r\nthree #garden")
	write(vault .. "/attachment.txt", "#attachment should not count")
	write(vault .. "/.hidden.md", "#hidden should not count")
	write(vault .. "/.ignore", "ignored.md\n")
	write(vault .. "/ignored.md", "#ignored should not count")
	vim.fn.mkdir(vault .. "/nested", "p")
	write(vault .. "/nested/empty.md", "")

	test("quoted/metacharacter paths and newline filenames are literal", function()
		local err, result = scan(vault)
		assert(not err, err)
		eq(3, #result.notes)
		eq(9, result.total_words)
		eq({ ["#work"] = 2, ["#garden"] = 2 }, result.tags)
		eq(0, result.skipped)
		eq(nil, uv.fs_stat("INJECTED"))
	end)

	test("chunk boundaries preserve words and tags", function()
		local path = root .. "/chunks"
		vim.fn.mkdir(path, "p")
		write(path .. "/long.md", string.rep(" ", 65533) .. "#split-tag one" .. string.rep("x", 140000) .. "\ntwo #end")
		local err, result = scan(path)
		assert(not err, err)
		eq(4, result.total_words)
		eq({ ["#split-tag"] = 1, ["#end"] = 1 }, result.tags)
	end)

	test("creation timestamp falls back to modification, never ctime", function()
		local original = uv.fs_stat
		uv.fs_stat = function(path, callback)
			return original(path, function(err, stat)
				if stat then
					stat.birthtime = { sec = 0 }
					stat.ctime = { sec = 1 }
				end
				callback(err, stat)
			end)
		end
		local ok, err = pcall(function()
			local scan_err, result = scan(vault)
			assert(not scan_err, scan_err)
			for _, note in ipairs(result.notes) do
				eq(note.modified, note.created)
			end
		end)
		uv.fs_stat = original
		assert(ok, err)
	end)

	test("read failures are counted without returning partial note data", function()
		local original = uv.fs_open
		uv.fs_open = function(_, _, _, callback)
			vim.schedule(function()
				callback("EACCES")
			end)
		end
		local ok, err = pcall(function()
			local scan_err, result = scan(vault)
			assert(not scan_err, scan_err)
			eq(3, result.skipped)
			eq(0, #result.notes)
			eq(0, result.total_words)
		end)
		uv.fs_open = original
		assert(ok, err)
	end)

	test("cancelled scans never publish stale results", function()
		local called = false
		local cancel = scanner.scan(vault, function()
			called = true
		end)
		cancel()
		vim.wait(100, function()
			return called
		end, 10)
		eq(false, called)
	end)

	test("missing fd reports an actionable error", function()
		local old_path = vim.env.PATH
		vim.env.PATH = root
		local ok, err = pcall(function()
			local scan_err = scan(vault)
			assert(scan_err:find("Install fd", 1, true))
		end)
		vim.env.PATH = old_path
		assert(ok, err)
	end)

	for _, transition in ipairs({ { 2026, 3, 30 }, { 2026, 10, 26 }, { 2027, 1, 1 }, { 2028, 3, 1 } }) do
		test("calendar dates and streak survive " .. table.concat(transition, "-"), function()
			local now = date(unpack(transition))
			local notes = {}
			for i = 0, 3 do
				local ts = calendar.shift(now, -i)
				notes[#notes + 1] = { modified = ts, created = ts }
			end
			local dates, counts = calendar.activity(notes, now, 4, "modified")
			eq(4, #dates)
			local keys = {}
			for _, d in ipairs(dates) do
				eq(1, counts[d.key])
				keys[d.key] = true
			end
			eq(4, vim.tbl_count(keys))
			eq(4, calendar.summarize(notes, now).streak)
			eq(4, calendar.summarize(notes, now).days_active)
		end)
	end

	test("streak may end yesterday, but cannot bridge a missing day", function()
		local now = date(2026, 10, 19)
		local notes = {}
		for _, i in ipairs({ 1, 2, 4 }) do
			local ts = calendar.shift(now, -i)
			notes[#notes + 1] = { modified = ts, created = ts }
		end
		eq(2, calendar.summarize(notes, now).streak)
		eq(0, calendar.summarize(notes, calendar.shift(now, 1)).streak)
	end)

	test("heatmap source selection, deduplication and date boundaries", function()
		local now = date(2026, 10, 19)
		local yesterday = calendar.shift(now, -1)
		local notes = {
			{ created = yesterday, modified = now },
			{ created = now, modified = now },
			{ created = calendar.shift(now, -3), modified = calendar.shift(now, 1) },
		}
		local _, both = calendar.activity(notes, now, 2, "both")
		eq({ ["2026-10-18"] = 1, ["2026-10-19"] = 2 }, both)
		local _, created = calendar.activity(notes, now, 2, "created")
		eq({ ["2026-10-18"] = 1, ["2026-10-19"] = 1 }, created)
		local _, modified = calendar.activity(notes, now, 2, "modified")
		eq({ ["2026-10-18"] = 0, ["2026-10-19"] = 2 }, modified)
	end)

	test("popup renders async results, options and close bindings", function()
		local mounted
		package.loaded["nui.popup"] = function(opts)
			local popup = { bufnr = vim.api.nvim_create_buf(false, true), opts = opts }
			function popup:mount()
				mounted = self
			end
			function popup:unmount()
				if vim.api.nvim_buf_is_valid(self.bufnr) then
					vim.api.nvim_buf_delete(self.bufnr, { force = true })
				end
			end
			return popup
		end
		local plugin = require("obsidian-stats")
		plugin.setup({ vault_path = vault, sections = { weekly_chart = false }, heatmap = { days = 7 } })
		plugin.show_stats()
		assert(vim.wait(10000, function()
			return mounted ~= nil
		end, 10))
		local lines = vim.api.nvim_buf_get_lines(mounted.bufnr, 0, -1, false)
		local text = table.concat(lines, "\n")
		assert(text:find("Total Notes:     3", 1, true))
		assert(text:find("Total Words:     9", 1, true))
		assert(not text:find("Heatmap", 1, true))
		eq(false, vim.api.nvim_buf_get_option(mounted.bufnr, "modifiable"))
		local old = mounted
		mounted = nil
		plugin.setup({ sections = { heatmap = true, tags = false } })
		plugin.show_stats()
		assert(not vim.api.nvim_buf_is_valid(old.bufnr))
		assert(vim.wait(10000, function()
			return mounted ~= nil
		end, 10))
		text = table.concat(vim.api.nvim_buf_get_lines(mounted.bufnr, 0, -1, false), "\n")
		assert(text:find("Contribution Heatmap (Last 7 Days)", 1, true))
		local marks = vim.api.nvim_buf_get_extmarks(
			mounted.bufnr, vim.api.nvim_create_namespace("obsidian-stats.heatmap"), 0, -1, { details = true }
		)
		local highlighted = 0
		local content = vim.api.nvim_buf_get_lines(mounted.bufnr, 0, -1, false)
		for _, mark in ipairs(marks) do
			if (mark[4].hl_group or ""):find("ObsidianStatsHeatmap", 1, true) then
				assert(content[mark[2] + 1]:sub(mark[3] + 1):find("■", 1, true) == 1,
					"heatmap highlight must begin on its cell")
				highlighted = highlighted + 1
			end
		end
		eq(7, highlighted)
		local maps = vim.api.nvim_buf_get_keymap(mounted.bufnr, "n")
		local closed = false
		for _, map in ipairs(maps) do
			if map.lhs == "q" then
				map.callback()
				closed = true
			end
		end
		assert(closed)
		assert(not vim.api.nvim_buf_is_valid(mounted.bufnr))
	end)
end

local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
else
	print("Passed " .. count .. " tests")
	vim.cmd("qa!")
end
