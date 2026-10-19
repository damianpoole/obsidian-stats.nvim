local M = {}

function M.key(ts)
	return os.date("%Y-%m-%d", ts)
end

-- Construct local calendar dates instead of adding 86400 seconds: DST days
-- can be 23 or 25 hours long. Noon avoids transitions near local midnight.
function M.shift(ts, days)
	local date = os.date("*t", ts)
	return os.time({ year = date.year, month = date.month, day = date.day + days, hour = 12 })
end

function M.summarize(notes, now)
	local oldest = now
	local modified = {}
	for _, note in ipairs(notes) do
		oldest = math.min(oldest, note.created)
		modified[M.key(note.modified)] = true
	end
	local elapsed_days = math.floor((M.shift(now, 0) - M.shift(oldest, 0)) / 86400 + 0.5)
	local days = math.max(1, elapsed_days + 1)
	local streak, cursor = 0, now
	if not modified[M.key(cursor)] then
		cursor = M.shift(cursor, -1)
	end
	while modified[M.key(cursor)] do
		streak = streak + 1
		cursor = M.shift(cursor, -1)
	end
	return { days_active = days, streak = streak, velocity = string.format("%.2f", #notes / days) }
end

function M.activity(notes, now, days, source)
	local dates, counts = {}, {}
	for offset = 1 - days, 0 do
		local ts = M.shift(now, offset)
		dates[#dates + 1] = { key = M.key(ts), wday = os.date("*t", ts).wday }
		counts[M.key(ts)] = 0
	end
	for _, note in ipairs(notes) do
		local seen = {}
		local function add(ts)
			local key = M.key(ts)
			if counts[key] ~= nil and not seen[key] then
				counts[key] = counts[key] + 1
				seen[key] = true
			end
		end
		if source ~= "created" then
			add(note.modified)
		end
		if source == "created" or source == "both" then
			add(note.created)
		end
	end
	return dates, counts
end

return M
