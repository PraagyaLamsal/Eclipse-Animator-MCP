local storage = {}

local function append(target, seen, container)
	if not container then return end
	for _, child in container:GetChildren() do
		local sequence = if child:IsA("ObjectValue") then child.Value else child
		if sequence and sequence:IsA("KeyframeSequence") and not seen[child] then
			seen[child] = true
			table.insert(target, { sequence = sequence, entry = child })
		end
	end
end

function storage.entries(rig, editorStore)
	local entries, seen = {}, {}
	local saves = rig:FindFirstChild("AnimSaves")
	append(entries, seen, saves)
	if saves and saves:IsA("ObjectValue") and saves.Value ~= saves then
		append(entries, seen, saves.Value)
	end
	append(entries, seen, rig)
	for _, link in editorStore and editorStore:GetChildren() or {} do
		if link:IsA("ObjectValue") and link.Value == rig then
			append(entries, seen, link)
		end
	end
	return entries
end

function storage.resolve(entries, name)
	local matched
	for _, entry in entries do
		if entry.entry.Name == name or entry.sequence.Name == name then
			assert(not matched or matched == entry.sequence, "Multiple animations match " .. name)
			matched = entry.sequence
		end
	end
	return matched
end

function storage.save(rig, sequence, instanceFactory)
	local saves = rig:FindFirstChild("AnimSaves")
	if not saves then
		saves = instanceFactory.new("Folder")
		saves.Name = "AnimSaves"
		saves.Parent = rig
	end
	local destination = saves
	local linked = saves:IsA("ObjectValue") and saves.Value
	local replacement
	for _, container in { saves, linked } do
		if container then
			for _, child in container:GetChildren() do
				if child.Name == sequence.Name then
					assert(not replacement, "Multiple saved entries match " .. sequence.Name)
					if child:IsA("ObjectValue") then
						assert(child.Value and child.Value:IsA("KeyframeSequence"), "Conflicting linked save type")
					else
						assert(child:IsA("KeyframeSequence"), "Conflicting save type")
					end
					replacement = child
				end
			end
		end
	end
	if replacement and replacement:IsA("ObjectValue") then
		-- The previous sequence can be shared by other rigs. Update just this alias.
		sequence.Parent = replacement.Parent
		replacement.Value = sequence
	else
		if replacement then destination = replacement.Parent end
		sequence.Parent = destination
		if replacement then replacement:Destroy() end
	end
end

return storage
