local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")
local pub = {}

---@alias fmt_fun fun(label: string): string
---@alias fuzzy_load_opts {title: string, description: string, fuzzy_description: string, is_fuzzy: boolean,
---ignore_workspaces: boolean, ignore_tabs: boolean, ignore_windows: boolean, fmt_window: fmt_fun, fmt_workspace: fmt_fun,
---fmt_tab: fmt_fun, fmt_date: fmt_fun, show_state_with_date: boolean, date_format: string }

---Returns default fuzzy loading options
---@return fuzzy_load_opts
function pub.get_default_fuzzy_load_opts()
	return {
		title = "Load State",
		description = "Select State to Load and press Enter = accept, Esc = cancel, / = filter",
		fuzzy_description = "Search State to Load: ",
		is_fuzzy = true,
		ignore_workspaces = false,
		ignore_windows = false,
		ignore_tabs = false,
		date_format = "%d-%m-%Y %H:%M:%S",
		show_state_with_date = false,
		fmt_date = function(date)
			return wezterm.format({
				{ Foreground = { AnsiColor = "White" } },
				{ Text = date },
			})
		end,
		fmt_workspace = function(label)
			return wezterm.format({
				{ Foreground = { AnsiColor = "Green" } },
				{ Text = "󱂬 : " .. label:gsub("%.json$", "") },
			})
		end,
		fmt_window = function(label)
			return wezterm.format({
				{ Foreground = { AnsiColor = "Yellow" } },
				{ Text = " : " .. label:gsub("%.json$", "") },
			})
		end,
		fmt_tab = function(label)
			return wezterm.format({
				{ Foreground = { AnsiColor = "Red" } },
				{ Text = "󰓩 : " .. label:gsub("%.json$", "") },
			})
		end,
	}
end

---A fuzzy finder to restore saved state
---@param window MuxWindow
---@param pane Pane
---@param callback fun(id: string, label: string, save_state_dir: string)
---@param opts fuzzy_load_opts?
function pub.fuzzy_load(window, pane, callback, opts)
	wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.start", window, pane)
	local state_files = {}

	if opts == nil then
		opts = pub.get_default_fuzzy_load_opts()
	else
		-- Merge user opts with defaults
		local default_opts = pub.get_default_fuzzy_load_opts()
		for k, v in pairs(default_opts) do
			if opts[k] == nil then
				opts[k] = v
			end
		end
	end

	local folder = require("resurrect.state_manager").save_state_dir

	-- Helper function to escape pattern special characters
	if not utils.escape_pattern then
		utils.escape_pattern = function(str)
			return str:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
		end
	end

	-- Find all JSON files for all types in their respective folders
	local function find_all_json_files()
		local all_files = {
			workspace = {},
			window = {},
			tab = {},
		}

		-- Process each type folder separately but in one function call
		local types = { "workspace", "window", "tab" }
		for _, type in ipairs(types) do
			local base_path = folder .. utils.separator .. type
			local cmd

			if utils.is_mac then
				-- macOS recursive find command for JSON files
				cmd = 'find "' .. base_path .. '" -type f -name "*.json" -print0 | xargs -0 stat -f "%m %N"'

				-- Execute the command and capture stdout
				local handle = io.popen(cmd)
				if handle == nil then
					wezterm.log_info("DEBUG: Could not open process for " .. type)
					goto continue
				end

				local stdout = handle:read("*a")
				handle:close()

				if stdout and stdout ~= "" then
					-- Parse the stdout
					for line in stdout:gmatch("[^\n]+") do
						local epoch, file = line:match("%s*(%d+)%s+(.+)")
						if epoch and file then
							-- Extract the filename relative to the type folder
							local path_pattern = utils.escape_pattern(base_path)
							local _, end_pos = file:find(path_pattern)

							local relative_path
							if end_pos then
								-- Skip the separator character
								relative_path = file:sub(end_pos + 2)
							else
								-- Fallback if pattern match fails
								relative_path = file:match("[^/\\]+%.json$")
							end

							if relative_path then
								table.insert(all_files[type], {
									relative_path = relative_path,
									epoch = tonumber(epoch),
								})
							end
						end
					end
				end
			elseif utils.is_windows then
				-- For Windows, use VBS for better performance
				local temp_vbs = os.tmpname() .. ".vbs"
				local temp_out = os.tmpname() .. ".txt"

				local vbs_script = string.format(
					[[
                    Set fso = CreateObject("Scripting.FileSystemObject")
                    Set outFile = fso.CreateTextFile("%s", True)
                    
                    Sub ProcessFolder(folderPath)
                        On Error Resume Next
                        Set folder = fso.GetFolder(folderPath)
                        If Err.Number <> 0 Then
                            Exit Sub
                        End If
                        
                        ' Process files in current folder
                        For Each file in folder.Files
                            If LCase(fso.GetExtensionName(file.Name)) = "json" Then
                                epoch = DateDiff("s", "01/01/1970 00:00:00", file.DateLastModified)
                                outFile.WriteLine(epoch & " " & file.Path)
                            End If
                        Next
                        
                        ' Process subfolders recursively
                        For Each subFolder in folder.SubFolders
                            ProcessFolder(subFolder.Path)
                        Next
                    End Sub
                    
                    ProcessFolder("%s")
                    outFile.Close
                ]],
					temp_out:gsub("\\", "\\\\"),
					base_path:gsub("\\", "\\\\")
				)

				-- Create a second VBS script that will run the first one invisibly
				local launcher_vbs = os.tmpname() .. "_launcher.vbs"
				local launcher_script = string.format(
					[[
                    Set WshShell = CreateObject("WScript.Shell")
                    WshShell.Run "wscript.exe //nologo %s", 0, True
                ]],
					temp_vbs
				)

				-- Write the scripts
				local handle = io.open(temp_vbs, "w")
				if handle == nil then
					wezterm.log_info("DEBUG: Could not create temporary Windows process for " .. type)
					goto continue
				end
				handle:write(vbs_script)
				handle:close()

				handle = io.open(launcher_vbs, "w")
				if handle == nil then
					wezterm.log_info("DEBUG: Could not create launcher script for " .. type)
					goto continue
				end
				handle:write(launcher_script)
				handle:close()

				-- Execute using launcher (completely hidden)
				os.execute("wscript.exe //nologo " .. launcher_vbs)

				-- Read results
				handle = io.open(temp_out, "r")
				if handle == nil then
					wezterm.log_info("DEBUG: Could not open temporary Windows process output for " .. type)
					goto continue
				end

				local stdout = handle:read("*a")
				handle:close()

				-- Clean up temp files
				os.remove(temp_vbs)
				os.remove(launcher_vbs)
				os.remove(temp_out)

				if stdout and stdout ~= "" then
					-- Parse the stdout
					for line in stdout:gmatch("[^\n]+") do
						local epoch, file = line:match("%s*(%d+)%s+(.+)")
						if epoch and file then
							-- Extract the filename relative to the type folder
							local path_pattern = utils.escape_pattern(base_path)
							local _, end_pos = file:find(path_pattern)

							local relative_path
							if end_pos then
								-- Skip the separator character
								relative_path = file:sub(end_pos + 2)
							else
								-- Fallback if pattern match fails
								relative_path = file:match("[^/\\]+%.json$")
							end

							if relative_path then
								table.insert(all_files[type], {
									relative_path = relative_path,
									epoch = tonumber(epoch),
								})
							end
						end
					end
				end
			else
				-- Linux optimized recursive find command for JSON files
				cmd = string.format(
					'find "$(realpath %q)" -type f -name "*.json" -printf "%%T@ %%p\\n" | awk \'{split($1, a, "."); print a[1], $2}\'',
					base_path
				)

				-- Execute the command and capture stdout
				local handle = io.popen(cmd)
				if handle == nil then
					wezterm.log_info("DEBUG: Could not open process for " .. type)
					goto continue
				end

				local stdout = handle:read("*a")
				handle:close()

				if stdout and stdout ~= "" then
					-- Parse the stdout
					for line in stdout:gmatch("[^\n]+") do
						local epoch, file = line:match("%s*(%d+)%s+(.+)")
						if epoch and file then
							-- Extract the filename relative to the type folder
							local path_pattern = utils.escape_pattern(base_path)
							local _, end_pos = file:find(path_pattern)

							local relative_path
							if end_pos then
								-- Skip the separator character
								relative_path = file:sub(end_pos + 2)
							else
								-- Fallback if pattern match fails
								relative_path = file:match("[^/\\]+%.json$")
							end

							if relative_path then
								table.insert(all_files[type], {
									relative_path = relative_path,
									epoch = tonumber(epoch),
								})
							end
						end
					end
				end
			end

			::continue::
		end

		return all_files
	end

	local function process_files()
		-- Get all files in one go
		local all_files = find_all_json_files()
		wezterm.log_info("DEBUG: all_files = " .. wezterm.json_encode(all_files))

		local files = {}
		local max_length = 0

		-- Process files for each type in order
		local types = { "workspace", "window", "tab" }
		for _, type in ipairs(types) do
			local include = not opts[string.format("ignore_%ss", type)]
			if include and all_files[type] then
				local fmt = opts[string.format("fmt_%s", type)]

				for _, file_data in ipairs(all_files[type]) do
					-- Extract filename without extension for label formatting
					local filename = file_data.relative_path
					local display_name = filename:gsub("%.json$", "")

					-- Store the maximum length for padding calculations
					max_length = math.max(max_length, #display_name)

					table.insert(files, {
						id = type .. utils.separator .. filename,
						filename = display_name, -- Store without extension for display
						raw_filename = filename, -- Store original for ID
						epoch = file_data.epoch,
						fmt = fmt,
						type = type,
					})
				end
			end
		end

		wezterm.log_info("DEBUG: files = " .. wezterm.json_encode(files))

		-- Format and add files to state_files list
		for _, file in ipairs(files) do
			local label = ""

			if opts.show_state_with_date then
				local padding = " "
				if #file.filename < max_length then
					padding = padding .. string.rep(".", max_length - #file.filename - 1) .. " "
				end

				if file.fmt then
					label = file.fmt(file.filename .. padding)
				else
					label = file.filename .. padding
				end

				-- Only format the date when we need to display it
				local date = os.date(opts.date_format, file.epoch)
				if opts.fmt_date then
					label = label .. " " .. opts.fmt_date(date)
				else
					label = label .. " " .. date
				end
			else
				if file.fmt then
					label = file.fmt(file.filename)
				else
					label = file.filename
				end
			end

			table.insert(state_files, { id = file.id, label = label })
		end

		wezterm.log_info("DEBUG: state_files = " .. wezterm.json_encode(state_files))
	end

	-- Process all files
	process_files()

	window:perform_action(
		wezterm.action.InputSelector({
			action = wezterm.action_callback(function(_, _, id, label)
				if id and label then
					callback(id, label, require("resurrect.state_manager").save_state_dir)
				end
				wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.finished", window, pane)
			end),
			title = opts.title,
			description = opts.description,
			fuzzy_description = opts.fuzzy_description,
			choices = state_files,
			fuzzy = opts.is_fuzzy,
		}),
		pane
	)
end

-- ---A fuzzy finder to restore saved state
-- ---@param window MuxWindow
-- ---@param pane Pane
-- ---@param callback fun(id: string, label: string, save_state_dir: string)
-- ---@param opts fuzzy_load_opts?
-- function pub.fuzzy_load(window, pane, callback, opts)
-- 	wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.start", window, pane)
-- 	local state_files = {}
--
-- 	if opts == nil then
-- 		opts = pub.get_default_fuzzy_load_opts()
-- 	else
-- 		-- Merge user opts with defaults
-- 		local default_opts = pub.get_default_fuzzy_load_opts()
-- 		for k, v in pairs(default_opts) do
-- 			if opts[k] == nil then
-- 				opts[k] = v
-- 			end
-- 		end
-- 	end
--
-- 	local folder = require("resurrect.state_manager").save_state_dir
--
-- 	local function def_insert_choices(type, fmt)
-- 		for _, file in ipairs(wezterm.glob("*", folder .. utils.separator .. type)) do
-- 			local label
-- 			local id = type .. utils.separator .. file
--
-- 			if fmt then
-- 				label = fmt(file)
-- 			else
-- 				label = file
-- 			end
-- 			table.insert(state_files, { id = id, label = label })
-- 		end
-- 	end
--
-- 	local function get_files_for_windows(type)
-- 		local path = folder .. type
-- 		-- Use a temporary VBS script for better performance
-- 		local temp_vbs = os.tmpname() .. ".vbs"
-- 		local temp_out = os.tmpname() .. ".txt"
--
-- 		local vbs_script = string.format(
-- 			[[
--             Set fso = CreateObject("Scripting.FileSystemObject")
--             Set folder = fso.GetFolder("%s")
--             Set outFile = fso.CreateTextFile("%s", True)
--
--             For Each file in folder.Files
--                 If Left(file.Name, 1) <> "." Then
--                     epoch = DateDiff("s", "01/01/1970 00:00:00", file.DateLastModified)
--                     outFile.WriteLine(epoch & " " & file.Path)
--                 End If
--             Next
--
--             outFile.Close
--         ]],
-- 			path:gsub("\\", "\\\\"),
-- 			temp_out:gsub("\\", "\\\\")
-- 		)
--
-- 		-- Write and execute the script invisibly
-- 		local handle = io.open(temp_vbs, "w")
-- 		if handle == nil then
-- 			wezterm.emit("resurrect.error", "Could not create temporary Windows process")
-- 			return ""
-- 		end
--
-- 		handle:write(vbs_script)
-- 		handle:close()
--
-- 		-- Execute without showing window
-- 		os.execute("wscript.exe /nologo " .. temp_vbs .. " >nul 2>&1")
--
-- 		-- Read results
-- 		handle = io.open(temp_out, "r")
-- 		if handle == nil then
-- 			wezterm.emit("resurrect.error", "Could not open temporary Windows process output")
-- 			return ""
-- 		end
--
-- 		local stdout = handle:read("*a")
-- 		if stdout == nil then
-- 			wezterm.emit("resurrect.error", "The Windows process had no output")
-- 			return ""
-- 		end
--
-- 		handle:close()
--
-- 		-- Clean up temp files
-- 		os.remove(temp_vbs)
-- 		os.remove(temp_out)
--
-- 		return stdout
-- 	end
--
-- 	local function execute(type)
-- 		-- Command-line recipe based on OS
-- 		local path = folder .. type
-- 		local cmd
-- 		if utils.is_mac then
-- 			cmd = 'stat -f "%m %N" "' .. path .. '"/*'
-- 		else -- last option: Linux-like
-- 			cmd = string.format(
-- 				'find "$(realpath %q)" -maxdepth 1 -type f -not -name ".*" -printf "%%T@ %%p\\n" | awk \'{split($1, a, "."); print a[1], $2}\'',
-- 				path
-- 			)
-- 		end
--
-- 		-- Execute the command and capture stdout
-- 		local handle = io.popen(cmd)
-- 		if handle == nil then
-- 			wezterm.emit("resurrect.error", "Could not open process: " .. cmd)
-- 			return ""
-- 		end
--
-- 		local stdout = handle:read("*a")
-- 		if stdout == nil then
-- 			wezterm.emit("resurrect.error", "No output when running: " .. cmd)
-- 			return ""
-- 		end
--
-- 		handle:close()
-- 		return stdout
-- 	end
--
-- 	local function insert_choices()
-- 		local files = {}
-- 		local max_length = 0
--
-- 		-- collect all the included files
-- 		local types = { "workspace", "window", "tab" }
-- 		for _, type in ipairs(types) do
-- 			local include = not opts[string.format("ignore_%ss", type)]
-- 			if include then
-- 				local fmt = opts[string.format("fmt_%s", type)]
--
-- 				local stdout = ""
-- 				if utils.is_windows then
-- 					stdout = get_files_for_windows(type)
-- 				else
-- 					stdout = execute(type)
-- 				end
--
-- 				if stdout == "" then
-- 					def_insert_choices(type, fmt)
-- 				else
-- 					-- Parse the stdout and construct the file table
-- 					for line in stdout:gmatch("[^\n]+") do
-- 						local epoch, file = line:match("%s*(%d+)%s+(.+)")
-- 						if epoch and file then
-- 							local filename, ext = file:match("^.*" .. utils.separator .. "(.+)%.(.*)$")
-- 							if filename ~= nil and filename ~= "" then
-- 								local date = os.date(opts.date_format, tonumber(epoch))
-- 								max_length = math.max(max_length, #filename)
-- 								table.insert(files, {
-- 									id = type .. utils.separator .. filename .. "." .. ext,
-- 									filename = filename,
-- 									date = date,
-- 									fmt = fmt,
-- 								})
-- 							end
-- 						end
-- 					end
-- 				end
-- 			end
-- 		end
--
-- 		for _, file in ipairs(files) do
-- 			local padding = " "
-- 			if #file.filename < max_length then
-- 				padding = padding .. string.rep(".", max_length - #file.filename - 1) .. padding
-- 			end
-- 			local label = ""
-- 			if file.fmt then
-- 				label = file.fmt(file.filename .. padding)
-- 			else
-- 				label = file.filename .. padding
-- 			end
-- 			if opts.fmt_date then
-- 				label = label .. " " .. opts.fmt_date(file.date)
-- 			else
-- 				label = label .. " " .. file.date
-- 			end
-- 			table.insert(state_files, { id = file.id, label = label })
-- 		end
-- 	end
--
-- 	if opts.show_state_with_date then
-- 		insert_choices()
-- 	else
-- 		if not opts.ignore_workspaces then
-- 			def_insert_choices("workspace", opts.fmt_workspace)
-- 		end
--
-- 		if not opts.ignore_windows then
-- 			def_insert_choices("window", opts.fmt_window)
-- 		end
--
-- 		if not opts.ignore_tabs then
-- 			def_insert_choices("tab", opts.fmt_tab)
-- 		end
-- 	end
--
-- 	window:perform_action(
-- 		wezterm.action.InputSelector({
-- 			action = wezterm.action_callback(function(_, _, id, label)
-- 				if id and label then
-- 					callback(id, label, require("resurrect.state_manager").save_state_dir)
-- 				end
-- 				wezterm.emit("resurrect.fuzzy_loader.fuzzy_load.finished", window, pane)
-- 			end),
-- 			title = opts.title,
-- 			description = opts.description,
-- 			fuzzy_description = opts.fuzzy_description,
-- 			choices = state_files,
-- 			fuzzy = opts.is_fuzzy,
-- 		}),
-- 		pane
-- 	)
-- end

return pub
