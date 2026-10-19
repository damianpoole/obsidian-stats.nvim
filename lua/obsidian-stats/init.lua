local calendar = require("obsidian-stats.calendar")
local scanner = require("obsidian-stats.scan")

local M = {}
local current_popup

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
local HEATMAP_NAMESPACE = vim.api.nvim_create_namespace("obsidian-stats.heatmap")

local function ensure_heatmap_highlights()
	vim.api.nvim_set_hl(0, HEATMAP_GROUP_PREFIX .. "0", { link = "Comment", default = true })
	local palette = { "#9be9a8", "#40c463", "#30a14e", "#216e39" }
	for i, color in ipairs(palette) do
		vim.api.nvim_set_hl(0, HEATMAP_GROUP_PREFIX .. i, { fg = color, default = true })
	end
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

local function build_heatmap(notes, now, range_days, activity_source)
	local dates, counts = calendar.activity(notes, now, range_days, activity_source)

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

local function render_stats(result, sections, heatmap_config)
	local now = os.time()
	local summary = calendar.summarize(result.notes, now)
	local total_notes = tostring(#result.notes)
	local total_words = tostring(result.total_words)
	local days_since = summary.days_active
	local avg_per_day = summary.velocity
	local streak = summary.streak

	local heatmap_start_index
	local heatmap_highlights

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
		local heatmap_lines, highlights = build_heatmap(result.notes, now, range_days, activity_source)

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

		local tags = {}
		for tag, count in pairs(result.tags) do
			tags[#tags + 1] = { tag = tag, count = count }
		end
		table.sort(tags, function(a, b)
			if a.count == b.count then
				return a.tag < b.tag
			end
			return a.count > b.count
		end)
		for i = 1, math.min(3, #tags) do
			local tag = tags[i]
			table.insert(stats, string.format("    %-4s %s", tag.count .. "x", tag.tag))
		end
	end

	-- Auto-Sizing logic
	local max_width = 0
	for _, line in ipairs(stats) do
		if vim.fn.strdisplaywidth(line) > max_width then
			max_width = vim.fn.strdisplaywidth(line)
		end
	end
	local max_width_allowed = math.max(20, vim.o.columns - 4)
	local max_height_allowed = math.max(8, vim.o.lines - 4)
	local width = math.min(max_width + 4, max_width_allowed)
	local height = math.min(#stats + 2, max_height_allowed)

	local popup = require("nui.popup")({
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
	current_popup = popup
	vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, stats)
	if heatmap_start_index and heatmap_highlights then
		for _, highlight in ipairs(heatmap_highlights) do
			vim.api.nvim_buf_add_highlight(
				popup.bufnr,
				HEATMAP_NAMESPACE,
				highlight.group,
				heatmap_start_index + highlight.row - 2,
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
			if current_popup == popup then
				current_popup = nil
			end
		end
	end

	-- Keymaps to close the window
	vim.keymap.set("n", "q", close_popup, { buffer = popup.bufnr, silent = true })
	vim.keymap.set("n", "<esc>", close_popup, { buffer = popup.bufnr, silent = true })
end

local cancel_scan

function M.show_stats()
	if cancel_scan then
		cancel_scan()
	end
	if current_popup then
		current_popup:unmount()
		current_popup = nil
	end
	local vault_path = vim.fn.fnamemodify(vim.fn.expand(M.config.vault_path), ":p")
	local sections = vim.deepcopy(M.config.sections)
	local heatmap_config = vim.deepcopy(M.config.heatmap or {})
	vim.notify("Obsidian Stats: Scanning vault…", vim.log.levels.INFO)
	cancel_scan = scanner.scan(vault_path, function(err, result)
		cancel_scan = nil
		if err then
			vim.notify("Obsidian Stats: " .. err, vim.log.levels.ERROR)
			return
		end
		if result.skipped > 0 then
			vim.notify("Obsidian Stats: Skipped " .. result.skipped .. " unreadable or changed notes", vim.log.levels.WARN)
		end
		render_stats(result, sections, heatmap_config)
	end)
end

return M
