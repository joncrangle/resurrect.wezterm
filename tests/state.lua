local wezterm = require("wezterm")
local root = assert(os.getenv("RESURRECT_TEST_ROOT"))
package.path = assert(os.getenv("RESURRECT_TEST_PLUGIN")) .. "/plugin/?.lua;" .. package.path

local manager = require("resurrect.state_manager")
local file_io = require("resurrect.file_io")
local results = {}
local events = {}
-- Observe the events at the same boundary used by config notification handlers.
wezterm.emit = function(event)
	table.insert(events, event)
end

local function test(name, run)
	events = {}
	manager.save_state_dir = root .. "/state"
	local ok, err = pcall(run)
	table.insert(results, { name = name, passed = ok, error = not ok and tostring(err) or nil })
end

local function encrypt()
	manager.set_encryption({
		enable = true,
		method = assert(os.getenv("RESURRECT_TEST_AGE")),
		private_key = root .. "/key.txt",
		public_key = assert(os.getenv("RESURRECT_TEST_RECIPIENT")),
	})
end

-- This directory is pre-created by the runner, independently of the plugin helper.
manager.save_state_dir = root .. "/state"
encrypt()

test("encrypted save/load preserves text and overwrites a previous save", function()
	local state = { workspace = "roundtrip", window_states = {}, text = "first\n\t'\\$\27[31m café" }
	manager.save_state(state)
	assert(manager.load_state(state.workspace, "workspace").text == state.text)
	state.text = string.rep("large scrollback\n", 12000)
	manager.save_state(state)
	assert(manager.load_state(state.workspace, "workspace").text == state.text)
end)

test("failed decryption does not crash workspace/window/tab restore", function()
	local state = manager.load_state("missing", "workspace")
	assert(state == nil, "failed load must return nil, not an unusable state")
	require("resurrect.workspace_state").restore_workspace(state)
	require("resurrect.window_state").restore_window(nil, state)
	require("resurrect.tab_state").restore_tab(nil, state, {})
end)

test("deleting a picker selection removes its saved file", function()
	manager.save_state({ workspace = "delete", window_states = {} })
	manager.delete_state("workspace/delete.json")
	local file = io.open(manager.save_state_dir .. "/workspace/delete.json", "rb")
	if file then
		file:close()
	end
	assert(file == nil, "selected state still exists")
end)

test("new absolute state directory supports encrypted saving", function()
	manager.change_state_save_dir(root .. "/new state's directory/")
	local state = { workspace = "new", window_states = {}, text = "new directory" }
	manager.save_state(state)
	local loaded = manager.load_state(state.workspace, "workspace")
	assert(loaded and loaded.text == state.text, "new state directory was not created")
end)

test("failed writes do not emit a successful save notification", function()
	file_io.encryption.enable = false
	file_io.write_state(root .. "/does-not-exist/state.json", {}, "workspace")
	for _, event in ipairs(events) do
		assert(event ~= "resurrect.file_io.write_state.finished", "failed save emitted a finished event")
	end
end)

test("formatted plaintext loads and malformed plaintext reports a load failure", function()
	file_io.encryption.enable = false
	local path = manager.save_state_dir .. "/workspace/broken.json"
	assert(file_io.write_file(path, '{\n  "workspace": "formatted",\n  "window_states": []\n}\n'))
	assert(manager.load_state("broken", "workspace").workspace == "formatted")
	assert(file_io.write_file(path, "{broken"))
	assert(manager.load_state("broken", "workspace") == nil)
end)

local report = assert(io.open(root .. "/results.json", "w"))
report:write(wezterm.json_encode(results))
report:close()
return { disable_default_key_bindings = true }
