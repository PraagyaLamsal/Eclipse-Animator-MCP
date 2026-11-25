-- Adds the independently authored MCP bridge to the caller's private copy.
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")

local input, output = table.unpack(process.args)
assert(input and output and input ~= output, "Usage: lune run scripts/bundle.luau input.rbxm output.rbxm")
local roots = roblox.deserializeModel(fs.readFile(input))
assert(#roots == 1 and roots[1].Name == "Eclipse Animator" and roots[1]:IsA("Script"), "Unexpected Eclipse package")
local eclipse = roots[1]
local container = assert(eclipse:FindFirstChild("container"), "Eclipse container missing")

local function module(parent, name, source)
	assert(not parent:FindFirstChild(name), "Duplicate module " .. name)
	luau.compile(source)
	local item = roblox.Instance.new("ModuleScript")
	item.Name = name
	item.Source = source
	item.Parent = parent
	return item
end

local function patch(item, changes)
	local source = item.Source
	for _, change in changes do
		local first, last = string.find(source, change[1], 1, true)
		assert(first and not string.find(source, change[1], last + 1, true), "Unsupported source anchor in " .. item.Name)
		source = string.sub(source, 1, first - 1) .. change[2] .. string.sub(source, last + 1)
	end
	luau.compile(source)
	item.Source = source
end

assert(container.core.pluginShell.Source:find('ReleaseVersion = "v1.0979"', 1, true), "This bridge requires Eclipse Animator v1.0979")
module(container.core, "McpWire", fs.readFile("studio/Wire.luau"))
module(container.core, "McpCutscene", fs.readFile("studio/Cutscene.luau"))
local ext = assert(container.core:FindFirstChild("extensionApi"))
patch(ext, {
	{ "local api = {}", [[local api = {}
local mcp = require("McpCutscene")
local wire = require("McpWire")
local mcpActions
local refreshDepth = 0
local refreshPending = false]] },
	{ "local changeLimit = 256", [[for _, action in mcp.actions do
	table.insert(actions, action)
end
for action in mcp.edits do
	edits[action] = true
end
local changeLimit = 256]] },
	{ 'local property = tracks.is(motor) and motor.PropertyId or nil', [[local camera = require("cameraRig")
			local isCameraProperty = camera.isTransform(motor) or camera.isFov(motor)
			local property = if camera.isFov(motor) then "FieldOfView"
				elseif camera.isTransform(motor) then "CFrame"
				else tracks.is(motor) and motor.PropertyId or nil]] },
	{ 'or not request.Property and owner(motor) == request.Target', [[or (not request.Property or isCameraProperty) and owner(motor) == request.Target]] },
	{ '\t\tif tracks.is(motor) then\n\t\t\tassert(tracks.validate(motor, value)', [[		local camera = require("cameraRig")
		if camera.isFov(motor) then
			assert(type(value) == "number" or (request.Value == nil and typeof(value) == "CFrame"), "Camera FOV must be a number")
			assert(type(value) ~= "number" or value >= 1 and value <= 120, "Camera FOV must be between 1 and 120")
			cf = if type(value) == "number" then camera.encode(motor, value) else value
		elseif tracks.is(motor) then
			assert(tracks.validate(motor, value)]] },
	{ 'local result = {}\n\t\tfor _, def in tracks.catalog(rig) do', [[if require("cameraRig").isRig(rig) and onTimeline(rig) then
			enabled.CFrame, enabled.FieldOfView = true, true
		end
		local result = {}
		for _, def in tracks.catalog(rig) do]] },
	{ "local function refresh()\n", [[local function refresh()
	if refreshDepth > 0 then refreshPending = true return end
]] },
	{ "local function perform(action, request)\n", [[local function perform(action, request)
	if mcpActions and mcpActions[action] then return mcpActions[action](request) end
]] },
	{ "local entries, results = captured(function()\n\t\t\tlocal out = {}", [[refreshDepth += 1
		local okBatch, entries, results = pcall(captured, function()
			local out = {}]] },
	{ 'history.commitGroup(name, entries)\n\t\treturn { Name = name, Results = results }', [[refreshDepth -= 1
		if refreshDepth == 0 and refreshPending then
			refreshPending = false
			refresh()
		end
		if not okBatch then error(entries, 0) end
		history.commitGroup(name, entries)
		return { Name = name, Results = results }]] },
	{ 'if action == "EndBatch" then\n', [[if mcp.lifecycle[action] then
		return perform(action, request)
	end
	if action == "EndBatch" then
]] },
	{ 'if action == "GetHistoryState" then\n', [[if mcp.readOnly[action] then return perform(action, request) end
	if action == "GetHistoryState" then
]] },
	{ 'assert(not refs.State.Timeline:GetState().Playing, "Pause playback before editing")', [[if action == "Playback" or action == "SeekFrame" then return perform(action, request) end
	assert(not refs.State.Timeline:GetState().Playing, "Pause playback before editing")]] },
	{ "function api.invoke(action, request)\n", [[function api.invoke(action, request)
	if action == "McpRequest" then
		local decoded, value = pcall(wire.decode, request.Request or {})
		if not decoded then return { ok = false, error = tostring(value) } end
		return wire.encode(api.invoke(request.Action, value))
	end
]] },
	{ "refs = options\n\tlocal core", [[refs = options
	mcpActions = mcp.bind(refs, { rows = rows, target = target, identity = identity, refresh = refresh, setKey = function(request) return edit(request, false) end })
	local core]] },
	{ 'endpoint:SetAttribute("APIVersion", version)', [[endpoint:SetAttribute("APIVersion", version)
	endpoint:SetAttribute("McpVersion", 1)]] },
})

local keybinds = assert(container:FindFirstChild("keybinds", true))
patch(keybinds, {
	{ "keybinds.bind = bind", [[function keybinds.mcpList()
	local available = {}
	for action in actionCallbacks do table.insert(available, action) end
	table.sort(available)
	return available
end

function keybinds.mcpTrigger(action)
	assert(initialized and require("ui").isTransportActive(), "Eclipse command unavailable")
	local callback = assert(actionCallbacks[action], "Unknown Eclipse editor command")
	callback()
	return action
end

keybinds.bind = bind]] },
})

local scriptText = fs.readFile("plugin/EclipseAnimatorMCP.server.luau")
local legacy = module(eclipse, "EclipseClipBridge", "return function(plugin)\n" .. scriptText .. "\nend")
legacy:SetAttribute("EclipseBuiltInTransport", true)
module(legacy, "ClipStorage", fs.readFile("plugin/ClipStorage.luau"))
local kit = roblox.Instance.new("Folder")
kit.Name, kit.Parent = "R6", legacy
for _, file in fs.readDir("plugin/R6") do
	if file:sub(-5) == ".luau" then module(kit, file:sub(1, -6), fs.readFile("plugin/R6/" .. file)) end
end
patch(eclipse, {
	{ "require(script.container.core.launcher).start(plugin, script)", [[task.defer(function()
	local ok, issue = pcall(require(script.EclipseClipBridge), plugin)
	if not ok then warn("[Eclipse Clip MCP] " .. tostring(issue)) end
end)
require(script.container.core.launcher).start(plugin, script)]] },
})
eclipse:SetAttribute("EclipseMcpBundle", 1)
fs.writeFile(output, roblox.serializeModel(roots))
print(output)
