local wezterm = require("wezterm")
local root = assert(os.getenv("RESURRECT_TEST_ROOT"))
package.path = assert(os.getenv("RESURRECT_TEST_PLUGIN")) .. "/plugin/?.lua;" .. package.path
local manager = require("resurrect.state_manager")
local workspace = require("resurrect.workspace_state")

manager.save_state_dir = root .. "/state"
manager.set_encryption({
	enable = true,
	method = assert(os.getenv("RESURRECT_TEST_AGE")),
	private_key = root .. "/key.txt",
	public_key = assert(os.getenv("RESURRECT_TEST_RECIPIENT")),
})

wezterm.on("gui-startup", function()
	local tab, pane, window = wezterm.mux.spawn_window({
		workspace = "resurrect-original",
		cwd = root,
		width = 100,
		height = 30,
	})
	tab:set_title("split")
	pane:split({ direction = "Right", size = 0.5, cwd = root })
	local second = window:spawn_tab({ cwd = root })
	second:set_title("second")
	wezterm.mux.set_active_workspace("resurrect-original")
	wezterm.time.call_after(0.5, function()
		pane:send_text("resurrect-scrollback-probe\n")
		wezterm.time.call_after(0.5, function()
			local ok, err = pcall(function()
				assert(
					pane:get_lines_as_text(pane:get_dimensions().scrollback_rows)
						:find("resurrect-scrollback-probe", 1, true),
					"original scrollback not ready"
				)
				assert(manager.save_state(workspace.get_workspace_state()))
				local state = assert(manager.load_state("resurrect-original", "workspace"))
				state.workspace = "resurrect-restored"
				workspace.restore_workspace(state, {
					spawn_in_workspace = true,
					relative = true,
					restore_text = true,
					on_pane_restore = require("resurrect.tab_state").default_on_pane_restore,
				})
				local restored = {}
				for _, win in ipairs(wezterm.mux.all_windows()) do
					if win:get_workspace() == "resurrect-restored" then
						table.insert(restored, win)
					end
				end
				assert(#restored == 1, "expected one restored window")
				local tabs = restored[1]:tabs()
				assert(#tabs == 2, "expected two restored tabs")
				assert(#tabs[1]:panes() == 2, "expected two panes in the first restored tab")
				assert(#tabs[2]:panes() == 1, "expected one pane in the second restored tab")
				assert(tabs[1]:get_title() == "split" and tabs[2]:get_title() == "second", "tab titles changed")
				local restored_pane = tabs[1]:panes()[1]
				assert(
					restored_pane
						:get_lines_as_text(restored_pane:get_dimensions().scrollback_rows)
						:find("resurrect-scrollback-probe", 1, true),
					"scrollback missing"
				)
				assert(manager.delete_state("workspace/resurrect-original.json"))
			end)
			local report = assert(io.open(root .. "/workspace-results.json", "w"))
			report:write(wezterm.json_encode({ passed = ok, error = not ok and tostring(err) or nil }))
			report:close()
		end)
	end)
end)

return {
	default_prog = { "/bin/cat" },
	window_close_confirmation = "NeverPrompt",
	check_for_updates = false,
}
