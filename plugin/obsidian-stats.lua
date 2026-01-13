-- Prevent loading plugin twice
if vim.g.loaded_obsidian_stats == 1 then
	return
end
vim.g.loaded_obsidian_stats = 1

-- Create user command
vim.api.nvim_create_user_command("ObsidianStats", function()
	require("obsidian-stats").show_stats()
end, {})
