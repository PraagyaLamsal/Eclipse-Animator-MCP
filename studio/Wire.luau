local wire = {}
local ids = setmetatable({}, { __mode = "k" })
local objects = setmetatable({}, { __mode = "v" })
local serial = 0

local function reference(value)
	if not ids[value] then
		serial += 1
		local id = tostring(serial)
		ids[value], objects[id] = id, value
	end
	return ids[value]
end

local function pathOf(value)
	local result = {}
	while value and value ~= game do
		table.insert(result, 1, value.Name)
		value = value.Parent
	end
	if value ~= game then return nil end
	return result
end

function wire.resolve(path)
	if typeof(path) == "Instance" then return path end
	if type(path) == "string" then
		local parts = {}
		for name in string.gmatch(path, "[^.]+") do table.insert(parts, name) end
		path = parts
	end
	assert(type(path) == "table" and #path > 0 and #path <= 128, "Expected an instance path")
	local current = game
	for index, name in path do
		assert(type(name) == "string" and name ~= "", "Invalid instance name")
		if index == 1 and string.lower(name) == "game" then continue end
		local found
		for _, child in current:GetChildren() do
			if child.Name == name then
				assert(not found, "Ambiguous instance path at " .. name)
				found = child
			end
		end
		assert(found, "Instance path not found at " .. name)
		current = found
	end
	return current
end

local constructors = {
	CFrame = { CFrame.new, { [3] = true, [12] = true } },
	Vector2 = { Vector2.new, { [2] = true } },
	Vector3 = { Vector3.new, { [3] = true } },
	Color3 = { Color3.new, { [3] = true } },
	NumberRange = { NumberRange.new, { [1] = true, [2] = true } },
	UDim = { UDim.new, { [2] = true } },
	UDim2 = { UDim2.new, { [4] = true } },
}

function wire.decode(value, depth)
	if type(value) ~= "table" then return value end
	depth = depth or 0
	assert(depth <= 24, "Request is too deeply nested")
	if value["$ref"] ~= nil then
		local object = objects[tostring(value["$ref"])]
		assert(object and object:IsDescendantOf(game), "Stale Eclipse instance reference. Read the current tracks again.")
		return object
	end
	if value["$instance"] ~= nil then return wire.resolve(value["$instance"]) end
	if value["$type"] then
		local kind, values = value["$type"], value.values
		if kind == "Enum" then
			assert(type(value.enum) == "string" and type(value.name) == "string", "Expected an enum and item name")
			return assert(Enum[value.enum][value.name], "Unknown enum value")
		end
		if kind == "BrickColor" then
			assert(type(value.name) == "string", "Expected a BrickColor name")
			return BrickColor.new(value.name)
		elseif kind == "NumberSequence" or kind == "ColorSequence" then
			assert(type(values) == "table" and #values >= 2 and #values <= 20, "Expected 2–20 keypoints")
			local points = {}
			for _, point in values do
				assert(type(point) == "table" and type(point[1]) == "number", "Invalid sequence point")
				if kind == "NumberSequence" then
					table.insert(points, NumberSequenceKeypoint.new(point[1], point[2], point[3] or 0))
				else
					table.insert(points, ColorSequenceKeypoint.new(point[1], Color3.new(point[2], point[3], point[4])))
				end
			end
			return if kind == "NumberSequence" then NumberSequence.new(points) else ColorSequence.new(points)
		end
		local entry = constructors[kind]
		assert(entry and type(values) == "table" and entry[2][#values], "Invalid components for " .. tostring(kind))
		for _, n in values do assert(type(n) == "number" and math.abs(n) < math.huge, "Expected finite components") end
		return entry[1](table.unpack(values))
	end
	local output = {}
	for key, item in value do output[key] = wire.decode(item, depth + 1) end
	return output
end

function wire.encode(value, depth, seen)
	depth = depth or 0
	if depth > 18 then return nil end
	local kind = typeof(value)
	if kind == "Instance" then
		return { ["$instance"] = pathOf(value), ["$ref"] = reference(value), name = value.Name, class = value.ClassName }
	elseif kind == "CFrame" then
		return { ["$type"] = kind, values = { value:GetComponents() } }
	elseif kind == "Vector3" or kind == "Color3" then
		local values = if kind == "Color3" then { value.R, value.G, value.B } else { value.X, value.Y, value.Z }
		return { ["$type"] = kind, values = values }
	elseif kind == "Vector2" or kind == "NumberRange" or kind == "UDim" then
		local values = if kind == "Vector2" then { value.X, value.Y }
			elseif kind == "NumberRange" then { value.Min, value.Max } else { value.Scale, value.Offset }
		return { ["$type"] = kind, values = values }
	elseif kind == "UDim2" then
		return { ["$type"] = kind, values = { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset } }
	elseif kind == "BrickColor" then
		return { ["$type"] = kind, name = value.Name }
	elseif kind == "NumberSequence" or kind == "ColorSequence" then
		local points = {}
		for _, point in value.Keypoints do
			table.insert(points, if kind == "NumberSequence" then { point.Time, point.Value, point.Envelope }
				else { point.Time, point.Value.R, point.Value.G, point.Value.B })
		end
		return { ["$type"] = kind, values = points }
	elseif kind == "EnumItem" then
		return { ["$type"] = "Enum", enum = tostring(value.EnumType), name = value.Name }
	elseif kind == "number" then
		return if math.abs(value) < math.huge then value else nil
	elseif kind == "string" or kind == "boolean" then
		return value
	elseif kind == "table" then
		seen = seen or {}
		if seen[value] then return nil end
		seen[value] = true
		local output = {}
		local length = #value
		local array = length > 0
		for key in value do
			if type(key) ~= "number" or key < 1 or key > length or key % 1 ~= 0 then array = false break end
		end
		for key, item in value do
			if type(key) == "string" or type(key) == "number" then
				local safe = if array then key else tostring(key)
				output[safe] = wire.encode(item, depth + 1, seen)
			end
		end
		seen[value] = nil
		return output
	end
	return nil
end

return wire
