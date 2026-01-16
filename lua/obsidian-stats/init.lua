local M = {}

M.config = {
	-- Default path, can be overridden in setup()
	vault_path = "~/vaults/second-brain",
	sections = {
		total_notes = true,
		total_words = true,
		days_active = true,
		velocity = true,
		streak = true,
		top_tags = true,
		weekly_chart = true,
		tags = true,
	},
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

function M.show_stats()
	-- Path to your vault
	local vault_path = vim.fn.expand(M.config.vault_path)
	local sections = M.config.sections

	-- Ensure vault path exists
	if vim.fn.isdirectory(vault_path) == 0 then
		vim.notify("Obsidian Stats: Vault path not found: " .. vault_path, vim.log.levels.ERROR)
		return
	end

	-- 1. Total Notes
	local total_notes_raw = vim.fn.system("fd -e md . '" .. vault_path .. "' | wc -l")
	local total_notes = total_notes_raw:gsub("%s+", "")
	local total_notes_num = tonumber(total_notes) or 0

	-- 2. Word Count (macOS/BSD awk sum)
	local total_words =
		vim.fn.system("fd -e md . '" .. vault_path .. "' -x wc -w | awk '{s+=$1} END {print s}'"):gsub("%s+", "")
	if total_words == "" then
		total_words = "0"
	end

	-- 3. Velocity (macOS 'stat -f %B' logic)
	-- Note: This command assumes macOS/BSD 'stat'.
	local oldest_file_ts =
		vim.fn.system("fd -e md . '" .. vault_path .. "' -X stat -f %B | sort -n | head -1"):gsub("%s+", "")
	local start_time = tonumber(oldest_file_ts)

	if not start_time or start_time == 0 then
		local fallback =
			vim.fn.system("fd -e md . '" .. vault_path .. "' -X stat -f %m | sort -n | head -1"):gsub("%s+", "")
		start_time = tonumber(fallback) or os.time()
	end

	local seconds_active = os.time() - start_time
	local days_since = math.max(1, math.ceil(seconds_active / 86400))
	local avg_per_day = string.format("%.2f", total_notes_num / days_since)

	-- 3b. Streak Calculation
	-- Get unique list of modification dates (YYYY-MM-DD), sorted newest first
	local date_list_cmd = "fd -e md . '" .. vault_path .. "' -X stat -f '%Sm' -t '%Y-%m-%d' | sort -ur"
	local date_list_raw = vim.fn.system(date_list_cmd)

	local streak = 0
	local today = os.date("%Y-%m-%d")
	local yesterday = os.date("%Y-%m-%d", os.time() - 86400)

	local dates = {}
	for date in date_list_raw:gmatch("[^\r\n]+") do
		table.insert(dates, date)
	end

	if #dates > 0 then
		-- If the newest note isn't from today or yesterday, the streak is 0
		if dates[1] == today or dates[1] == yesterday then
			streak = 1
			for i = 1, #dates - 1 do
				-- Convert current and next date to timestamps to check if they are 1 day apart
				local y1, m1, d1 = dates[i]:match("(%d+)-(%d+)-(%d+)")
				local y2, m2, d2 = dates[i + 1]:match("(%d+)-(%d+)-(%d+)")

				local t1 = os.time({ year = y1, month = m1, day = d1 })
				local t2 = os.time({ year = y2, month = m2, day = d2 })

				if (t1 - t2) <= 90000 then -- approx 1 day in seconds (allowing for slight overlap)
					streak = streak + 1
				else
					break
				end
			end
		end
	end

	-- 3c. Weekly Activity (Last 7 Days)
	local activity_cmd = "fd -e md . '" .. vault_path .. "' -X stat -f '%B'"
	local activity_raw = vim.fn.system(activity_cmd)

	local day_stats = {}
	local today_ts = os.time()
	local max_count = 0

	-- Initialize last 7 days
	for i = 6, 0, -1 do
		local d = today_ts - (i * 86400)
		local date_key = os.date("%Y-%m-%d", d)
		local label = os.date("%a", d):sub(1, 1)
		table.insert(day_stats, { date = date_key, label = label, count = 0 })
	end

	-- Populate counts
	for ts in activity_raw:gmatch("[^\r\n]+") do
		local t = tonumber(ts)
		if t then
			local date_str = os.date("%Y-%m-%d", t)
			for _, day in ipairs(day_stats) do
				if day.date == date_str then
					day.count = day.count + 1
					if day.count > max_count then
						max_count = day.count
					end
					break
				end
			end
		end
	end

	-- Generate Chart (Fixed height of 5 lines)
	local graph_height = 5
	local chart_lines = {}
	for h = graph_height, 1, -1 do
		local line = "    "
		for _, day in ipairs(day_stats) do
			local bar_height = 0
			if max_count > 0 then
				if max_count <= graph_height then
					bar_height = day.count
				else
					bar_height = math.floor((day.count / max_count) * graph_height + 0.5)
					-- Ensure at least 1 block if count > 0
					if day.count > 0 and bar_height == 0 then
						bar_height = 1
					end
				end
			end

			if bar_height >= h then
				line = line .. "█ "
			else
				line = line .. "  " -- space for alignment
			end
		end
		table.insert(chart_lines, line)
	end

	-- X-axis labels
	local x_axis = "    "
	for _, day in ipairs(day_stats) do
		x_axis = x_axis .. day.label .. " "
	end

	-- 4. Top 3 Tags (Stripping file paths to prevent window overflow)
	local tag_cmd = string.format(
		"rg -o '#[a-zA-Z0-9_-]+' %s | awk -F: '{print $NF}' | sort | uniq -c | sort -nr | head -3",
		vault_path
	)
	local top_tags = vim.fn.system(tag_cmd)

	-- Build the lines for the UI
	local stats = {
		"",
		"   Vault Statistics",
		" -------------------",
	}

	if sections.total_notes then
		table.insert(stats, " 󰠮  Total Notes:     " .. total_notes)
	end

	if sections.total_words then
		table.insert(stats, " 󰓗  Total Words:     " .. total_words)
	end

	if sections.days_active then
		table.insert(stats, " 󰃭  Days Active:     " .. days_since)
	end

	if sections.velocity then
		table.insert(stats, " 󰄾  Velocity:        " .. avg_per_day .. " notes/day")
	end

	if sections.streak then
		table.insert(stats, " 󱓞  Current Streak:  " .. streak .. " days")
	end

	if sections.weekly_chart then
		table.insert(stats, "")
		table.insert(stats, "   Weekly Activity:")

		for _, line in ipairs(chart_lines) do
			table.insert(stats, line)
		end
		table.insert(stats, x_axis)
	end

	if sections.tags then
		table.insert(stats, "")
		table.insert(stats, " 󰓹  Top Tags:")

		-- Parse and format the tags
		for line in top_tags:gmatch("[^\r\n]+") do
			local count, tag = line:match("%s*(%d+)%s*(#.*)")
			if count and tag then
				table.insert(stats, string.format("    %-4s %s", count .. "x", tag))
			end
		end
	end

	-- Auto-Sizing logic
	local max_width = 0
	for _, line in ipairs(stats) do
		if #line > max_width then
			max_width = #line
		end
	end
	local width = max_width + 4
	local height = #stats + 2

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, stats)

	vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = (vim.o.columns - width) / 2,
		row = (vim.o.lines - height) / 2,
		style = "minimal",
		border = "rounded",
		title = " Obsidian Stats ",
		title_pos = "center",
	})

	-- Keymaps to close the window
	vim.keymap.set("n", "q", "<cmd>q<cr>", { buffer = buf, silent = true })
	vim.keymap.set("n", "<esc>", "<cmd>q<cr>", { buffer = buf, silent = true })
end

return M
