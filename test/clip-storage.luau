local roblox = require("@lune/roblox")
local storage = require("../plugin/ClipStorage")
local instance = roblox.Instance
local root = instance.new("DataModel")
local world = root:GetService("Workspace")
local server = root:GetService("ServerStorage")

local function make(class, name, parent)
	local value = instance.new(class)
	value.Name, value.Parent = name, parent
	return value
end

local rig = make("Model", "R15", world)
local aliases = make("ObjectValue", "AnimSaves", rig)
local linked = make("Folder", "Eclipse Animation Storage", server)
aliases.Value = linked
local external = make("KeyframeSequence", "Outside", linked)
local alias = make("ObjectValue", "Alias", aliases)
alias.Value = external
local inline = make("KeyframeSequence", "Inline", aliases)
local entries = storage.entries(rig, nil)
assert(#entries == 3)
assert(storage.resolve(entries, "Outside") == external)
assert(storage.resolve(entries, "Inline") == inline)
assert(storage.resolve(entries, "Alias") == external)
local replacement = make("KeyframeSequence", "Alias", nil)
storage.save(rig, replacement, instance)
assert(alias.Value == replacement and external.Parent == linked)
assert(storage.resolve(storage.entries(rig, nil), "Alias") == replacement)

local simple = make("Model", "Simple", world)
storage.save(simple, make("KeyframeSequence", "Walk", nil), instance)
assert(simple.AnimSaves.Walk:IsA("KeyframeSequence"))
local unrelated = make("Folder", "PreserveMe", simple.AnimSaves)
assert(not pcall(storage.save, simple, make("KeyframeSequence", "PreserveMe", nil), instance))
assert(unrelated.Parent == simple.AnimSaves)
print("Direct saves, linked containers, named aliases and conflicts passed")
