local uv = vim.uv or vim.loop
local M = {}

-- Discover notes with fd's normal hidden/ignore rules, then read up to eight
-- files concurrently. No vault path or filename is ever interpreted by a shell.
-- Returns a cancellation function; completion always runs on Neovim's main loop.
function M.scan(vault_path, callback)
	local cancelled = false
	local job
	local function complete(err, result)
		vim.schedule(function()
			if not cancelled then
				callback(err, result)
			end
		end)
	end
	local function cancel()
		cancelled = true
		if job and job > 0 then
			vim.fn.jobstop(job)
		end
	end

	if vim.fn.isdirectory(vault_path) == 0 then
		complete("Vault path not found: " .. vault_path)
		return cancel
	end
	local executable = vim.fn.executable("fd") == 1 and "fd" or "fdfind"
	if vim.fn.executable(executable) == 0 then
		complete("Install fd (or fdfind) to discover Markdown notes")
		return cancel
	end

	local output, stderr = "", ""
	job = vim.fn.jobstart({ executable, "--type", "f", "--type", "l", "--extension", "md", "--print0", ".", vault_path }, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			-- Neovim represents stream NULs as newlines inside each item and
			-- splits real newlines into separate items. Preserve both in names.
			local parts = {}
			for i, part in ipairs(data) do
				parts[i] = part:gsub("\n", "\0")
			end
			output = table.concat(parts, "\n")
		end,
		on_stderr = function(_, data)
			stderr = table.concat(data, "\n")
		end,
		on_exit = function(_, code)
			job = nil
			if cancelled then
				return
			end
			if code ~= 0 then
				complete("fd failed: " .. (stderr ~= "" and stderr or tostring(code)))
				return
			end
			local paths = {}
			for path in output:gmatch("([^%z]+)%z") do
				paths[#paths + 1] = path
			end
			local result = { notes = {}, total_words = 0, tags = {}, skipped = 0 }
			local next_index, active = 1, 0
			local pump
			local function finished(note, words, tags)
				active = active - 1
				if note then
					result.notes[#result.notes + 1] = note
					result.total_words = result.total_words + words
					for tag, count in pairs(tags) do
						result.tags[tag] = (result.tags[tag] or 0) + count
					end
				else
					result.skipped = result.skipped + 1
				end
				pump()
			end
			local function read_note(path)
				uv.fs_stat(path, function(stat_err, stat)
					if cancelled then
						return
					end
					if stat_err or not stat or stat.type ~= "file" then
						finished()
						return
					end
					uv.fs_open(path, "r", 438, function(open_err, fd)
						if open_err then
							finished()
							return
						end
						local offset, words, tags, tag_tail, in_word = 0, 0, {}, "", false
						local function count_tags(text)
							for tag in text:gmatch("#[a-zA-Z0-9_-]+") do
								tags[tag] = (tags[tag] or 0) + 1
							end
						end
						local function close(ok)
							uv.fs_close(fd, function()
								if cancelled then
									return
									end
								if not ok then
									finished()
									return
								end
								count_tags(tag_tail)
								local modified = stat.mtime.sec
								local birth = stat.birthtime and stat.birthtime.sec
								-- Linux/filesystems without birthtime report zero or a
								-- negative value; ctime is not a creation timestamp.
								local created = birth and birth > 0 and birth or modified
								finished({ modified = modified, created = created }, words, tags)
							end)
						end
						local read_chunk
						read_chunk = function()
							if cancelled then
								close(false)
								return
							end
							uv.fs_read(fd, 65536, offset, function(read_err, data)
								if read_err or not data then
									close(false)
								elseif data == "" then
									close(true)
								else
									local _, count = data:gsub("%S+", "")
									words = words + count - (in_word and data:match("^%S") and 1 or 0)
									in_word = data:match("%S$") ~= nil
									local text = tag_tail .. data
									local body, tail = text:match("^(.-)(#[a-zA-Z0-9_-]*)$")
									count_tags(body or text)
									tag_tail = tail or ""
									offset = offset + #data
									read_chunk()
								end
							end)
						end
						read_chunk()
					end)
				end)
			end
			pump = function()
				if cancelled then
					return
				end
				while active < 8 and next_index <= #paths do
					local path = paths[next_index]
					next_index = next_index + 1
					active = active + 1
					read_note(path)
				end
				if active == 0 and next_index > #paths then
					complete(nil, result)
				end
			end
			pump()
		end,
	})
	if job <= 0 then
		complete("Could not start fd")
	end
	return cancel
end

return M
