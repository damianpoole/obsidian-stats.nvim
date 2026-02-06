local Popup = require("nui.popup")

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
		weekly_chart = true,
		tags = true,
	},
	heatmap = {
		-- "3_months" (default), "6_months", "9_months", or "1_year"
		range = "3_months",
		-- "modified" (default), "created", or "both"
		activity = "modified",
	},
}

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

local HEATMAP_LEVELS = 4
local HEATMAP_CHAR = "■"
local HEATMAP_GROUP_PREFIX = "ObsidianStatsHeatmap"

local function ensure_heatmap_highlights()
	vim.api.nvim_set_hl(0, HEATMAP_GROUP_PREFIX .. "0", { link = "Comment", default = true })
	local palette = { "#9be9a8", "#40c463", "#30a14e", "#216e39" }
	for i, color in ipairs(palette) do
		vim.api.nvim_set_hl(0, HEATMAP_GROUP_PREFIX .. i, { fg = color, default = true })
	end
end

local function day_start(ts)
	local t = os.date("*t", ts)
	return os.time({ year = t.year, month = t.month, day = t.day })
end

local function resolve_heatmap_days(range, override_days)
	if type(override_days) == "number" and override_days > 0 then
		return override_days, "Last " .. override_days .. " Days"
	end
	if type(range) == "number" and range > 0 then
		return range, "Last " .. range .. " Days"
	end
	if range == "3_months" then
		return 90, "Last 3 Months"
	end
	if range == "6_months" then
		return 180, "Last 6 Months"
	end
	if range == "9_months" then
		return 270, "Last 9 Months"
	end
	if range == "1_year" or range == "year" then
		return 365, "Last Year"
	end
	return 90, "Last 3 Months"
end

local function resolve_activity_source(source)
	if source == "created" or source == "creation" or source == "birth" then
		return "created"
	end
	if source == "both" or source == "all" then
		return "both"
	end
	return "modified"
end

local function build_heatmap(vault_path, range_days, activity_source)
	local today_start = day_start(os.time())
	local start_ts = today_start - ((range_days - 1) * 86400)
	local end_ts = today_start + 86399

	local counts = {}
	if activity_source == "both" then
		local activity_cmd = "fd -e md . '" .. vault_path .. "' -X stat -f '%m\t%B'"
		local activity_raw = vim.fn.system(activity_cmd)
		for line in activity_raw:gmatch("[^\r\n]+") do
			local mod_ts, birth_ts = line:match("^(%d+)%s+(%d+)")
			local seen = {}
			local function add_ts(ts)
				local t = tonumber(ts)
				if t and t > 0 and t >= start_ts and t <= end_ts then
					local date_key = os.date("%Y-%m-%d", t)
					if not seen[date_key] then
						counts[date_key] = (counts[date_key] or 0) + 1
						seen[date_key] = true
					end
				end
			end
			add_ts(mod_ts)
			add_ts(birth_ts)
		end
	else
		local stat_flag = activity_source == "created" and "%B" or "%m"
		local activity_cmd = "fd -e md . '" .. vault_path .. "' -X stat -f '" .. stat_flag .. "'"
		local activity_raw = vim.fn.system(activity_cmd)
		for ts in activity_raw:gmatch("[^\r\n]+") do
			local t = tonumber(ts)
			if t and t >= start_ts and t <= end_ts then
				local date_key = os.date("%Y-%m-%d", t)
				counts[date_key] = (counts[date_key] or 0) + 1
			end
		end
	end

	local dates = {}
	for i = 0, range_days - 1 do
		local day_ts = start_ts + (i * 86400)
		local dt = os.date("*t", day_ts)
		local date_key = os.date("%Y-%m-%d", day_ts)
		table.insert(dates, { key = date_key, wday = dt.wday })
	end

	local columns = {}
	local current_col = { nil, nil, nil, nil, nil, nil, nil }
	table.insert(columns, current_col)
	for i, date in ipairs(dates) do
		if i > 1 and date.wday == 1 then
			current_col = { nil, nil, nil, nil, nil, nil, nil }
			table.insert(columns, current_col)
		end
		current_col[date.wday] = { count = counts[date.key] or 0, date = date.key }
	end

	local max_count = 0
	for _, value in pairs(counts) do
		if value > max_count then
			max_count = value
		end
	end

	local lines = {}
	local highlights = {}
	local row_labels = { [2] = "Mon", [4] = "Wed", [6] = "Fri" }
	local month_prefix = "     "
	local month_line = month_prefix .. string.rep(" ", #columns * 2)
	local month_chars = {}
	for i = 1, #month_line do
		month_chars[i] = month_line:sub(i, i)
	end

	for col_index, column in ipairs(columns) do
		local month_label
		for row = 1, 7 do
			local cell = column[row]
			if cell and cell.date then
				local y, m, d = cell.date:match("(%d+)-(%d+)-(%d+)")
				if tonumber(d) == 1 then
					month_label = os.date("%b", os.time({ year = tonumber(y), month = tonumber(m), day = 1 }))
					break
				end
			end
		end

		if month_label then
			local start_pos = #month_prefix + ((col_index - 1) * 2) + 1
			for i = 1, #month_label do
				local pos = start_pos + i - 1
				if pos <= #month_chars then
					month_chars[pos] = month_label:sub(i, i)
				end
			end
		end
	end

	month_line = table.concat(month_chars)
	table.insert(lines, month_line)

	for row = 1, 7 do
		local label = row_labels[row] or ""
		local line = string.format(" %-3s ", label)
		for _, column in ipairs(columns) do
			local value = column[row]
			if value == nil then
				line = line .. "  "
			else
				local level = 0
				if value.count > 0 and max_count > 0 then
					level = math.ceil((value.count / max_count) * HEATMAP_LEVELS)
					if level < 1 then
						level = 1
					elseif level > HEATMAP_LEVELS then
						level = HEATMAP_LEVELS
					end
				end
				local start_col = #line
				line = line .. HEATMAP_CHAR .. " "
				table.insert(highlights, {
					row = row + 1,
					col = start_col,
					group = HEATMAP_GROUP_PREFIX .. level,
				})
			end
		end
		table.insert(lines, line)
	end

	return lines, highlights
end

function M.show_stats()
	-- Path to your vault
	local vault_path = vim.fn.expand(M.config.vault_path)
	local sections = M.config.sections
	local heatmap_config = M.config.heatmap or {}

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

	local heatmap_start_index
	local heatmap_highlights

	-- 4. Top 3 Tags (Stripping file paths to prevent window overflow)
	local tag_cmd = string.format(
		"rg -o '#[a-zA-Z0-9_-]+' %s | awk -F: '{print $NF}' | sort | uniq -c | sort -nr | head -3",
		vault_path
	)
	local top_tags = vim.fn.system(tag_cmd)

	-- Build the lines for the UI
	local separator = " -------------------"
	local stats = {
		"",
		"   Vault Statistics",
		separator,
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

	local show_heatmap = sections.heatmap
	if show_heatmap == nil then
		show_heatmap = sections.weekly_chart
	end

	if show_heatmap then
		local range_days, range_label = resolve_heatmap_days(heatmap_config.range, heatmap_config.days)
		local activity_source = resolve_activity_source(heatmap_config.activity)

		ensure_heatmap_highlights()
		local heatmap_lines, highlights = build_heatmap(vault_path, range_days, activity_source)

		if stats[#stats] ~= separator then
			table.insert(stats, "")
		end
		table.insert(stats, "   Contribution Heatmap (" .. range_label .. "):")
		heatmap_start_index = #stats + 1
		for _, line in ipairs(heatmap_lines) do
			table.insert(stats, line)
		end
		heatmap_highlights = highlights
	end

	if sections.tags then
		if stats[#stats] ~= separator then
			table.insert(stats, "")
		end
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
	local max_width_allowed = math.max(20, vim.o.columns - 4)
	local max_height_allowed = math.max(8, vim.o.lines - 4)
	local width = math.min(max_width + 4, max_width_allowed)
	local height = math.min(#stats + 2, max_height_allowed)

	local popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " Obsidian Stats ",
				top_align = "center",
				bottom = " q/esc to close ",
				bottom_align = "center",
			},
		},
		position = "50%",
		size = {
			width = width,
			height = height,
		},
	})

	popup:mount()
	vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, stats)
	if heatmap_start_index and heatmap_highlights then
		for _, highlight in ipairs(heatmap_highlights) do
			vim.api.nvim_buf_add_highlight(
				popup.bufnr,
				-1,
				highlight.group,
				heatmap_start_index + highlight.row - 1,
				highlight.col,
				highlight.col + #HEATMAP_CHAR
			)
		end
	end
	vim.api.nvim_buf_set_option(popup.bufnr, "modifiable", false)
	vim.api.nvim_buf_set_option(popup.bufnr, "bufhidden", "wipe")

	local function close_popup()
		if popup and popup.unmount then
			popup:unmount()
		end
	end

	-- Keymaps to close the window
	vim.keymap.set("n", "q", close_popup, { buffer = popup.bufnr, silent = true })
	vim.keymap.set("n", "<esc>", close_popup, { buffer = popup.bufnr, silent = true })
end

return M
