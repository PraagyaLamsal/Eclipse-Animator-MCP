local cutscene = {}
local load = require(script.Parent.Parent.requireModule)
local wire = require(script.Parent.McpWire)
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local panels = {
	AnimationLayers = { "animationLayers", "open" },
	Blender = { "blenderImport", "open" },
	CameraPreview = { "cameraPreview", "open" },
	GreasePencil = { "greasePencil", "toggle" },
	GraphEditor = { "graphEditor", "open" },
	IK = { "ikPanel", "open" },
	Collaboration = { "liveSession", "open" },
	ModuleExporter = { "moduleExporter", "open" },
	MotionPaths = { "motionPaths", "open" },
	Physics = { "physicsWindow", "open" },
	PoseSliders = { "poseSliders", "open" },
	ReferenceVideo = { "videoWindow", "open" },
}

cutscene.lifecycle = { OpenProject = true, ListProjects = true, ProjectInfo = true, BlenderCommand = true, VideoCommand = true, ReadPreferences = true }
cutscene.readOnly = {
	ListKeys = true, ListEvents = true, ListLayers = true, ListIK = true, ListEditorFeatures = true,
}
cutscene.edits = {
	DeleteKey = true, SetCurve = true, SetTimeline = true, PutEvent = true, DeleteEvent = true,
	SetIK = true, KeyIKControl = true, SetPoleFollow = true, FilterRotation = true, KeyCamera = true,
	SetParenting = true, ApplyMotionPath = true, RetimeKeys = true, CreateScreenEffect = true,
}
cutscene.actions = {
	"OpenProject", "ListProjects", "ProjectInfo", "SaveProject", "ExportProject", "ListEditorFeatures",
	"ListKeys", "DeleteKey", "SetCurve", "FilterRotation", "SetTimeline", "SeekFrame", "Playback",
	"CreateCamera", "CameraView", "KeyCamera", "ListEvents", "PutEvent", "DeleteEvent",
	"ListLayers", "EditLayer", "ListIK", "SetIK", "KeyIKControl", "SetPoleFollow",
	"OpenPanel", "EditorCommand", "BlenderCommand", "VideoCommand", "SelectTargets",
	"SetParenting", "ApplyMotionPath", "SelectKeys", "RetimeKeys", "CreateScreenEffect", "ReadPreferences", "SetPreferences",
}

local function finite(value)
	return type(value) == "number" and math.abs(value) < math.huge
end

local function integer(value, label, minimum, maximum)
	assert(finite(value) and value % 1 == 0 and value >= minimum and value <= maximum, "Invalid " .. label)
	return value
end

local function name(value, fallback)
	if value == nil then return fallback end
	assert(type(value) == "string" and #value > 0 and #value <= 128 and not value:find("[%c]"), "Invalid name")
	return value
end

local function limit(value, fallback)
	return integer(value or fallback, "limit", 1, 500)
end

function cutscene.bind(refs, access)
	local state = refs.State
	local project = load("project")
	local export = load("export")
	local events = load("events")
	local layers = load("layers")
	local channels = load("channelEasing")
	local graph = load("graphCurves")
	local history = load("history")
	local camera = load("cameraRig")
	local limbs = load("limbIk")
	local preview = load("rigPreview")
	local actions = {}

	local function rig(value)
		local target = preview.localOf(access.target(value))
		assert(table.find(state.getAllRigs(), target), "Target rig is outside the active project")
		return target
	end

	local function track(request)
		access.target(request.Target)
		local rows = access.rows(request)
		assert(#rows == 1, "Use ListTracks and select one Target and optional Property")
		return rows[1].motor
	end

	local function keyAt(request)
		local timeline = state.Timeline
		local motor = track(request)
		local frame = integer(request.Frame, "frame", 0, 1000000)
		local bucket = timeline:GetMotorKeyframeBucket(motor)
		assert(bucket and bucket[frame], "No key at the requested frame")
		return timeline, motor, bucket, bucket[frame]
	end

	local function changeKey(timeline, motor, description, callback)
		assert(not motor:GetAttribute("EclipseDisabled") and not layers.active(timeline:GetState(), motor).locked, "Track or layer is locked")
		local layer = layers.active(timeline:GetState(), motor)
		local before = timeline:_snapshotMotorBucket(motor)
		local function restore(snapshot)
			layers.history(layer.id, function() timeline:_restoreMotorBucket(motor, snapshot) end)
			access.refresh()
		end
		local ok, message = pcall(callback)
		if not ok then restore(before); error(message, 0) end
		local after = timeline:_snapshotMotorBucket(motor)
		history.record(function() restore(before) end, function() restore(after) end, description)
		access.refresh()
	end

	local function seek(frame)
		local timeline = state.Timeline
		frame = integer(frame, "frame", 0, 1000000)
		assert(frame <= math.max(timeline:GetMaxFrame(), timeline:GetLastKeyframeFrame() or 0), "Frame lies outside the timeline")
		local raw = timeline:GetState()
		raw.Playing = false
		raw.CurrentTime = timeline:FrameToTime(frame)
		timeline:UpdatePlayhead()
		for _, item in state.getAllRigs() do
			timeline:ApplyPoseAtTime(item, raw.CurrentTime)
			state.Rig:UpdateBonesFollowRig(item)
		end
		load("eventPlayback").scrub(timeline, raw.CurrentTime)
		return raw
	end

	function actions.ProjectInfo()
		local active = refs.Active()
		local response = { Active = active, Saved = state.currentProjectSaved == true, Project = state.currentProjectSave }
		if active and state.Timeline then
			local timeline = state.Timeline
			local raw = timeline:GetState()
			response.FPS, response.Frame = raw.FPS, timeline:TimeToFrame(raw.CurrentTime)
			response.EndFrame, response.LastKey = timeline:GetMaxFrame(), timeline:GetLastKeyframeFrame()
			response.Playing, response.Rigs = raw.Playing, state.getAllRigs()
			response.Kind = export.documentKind()
		end
		return response
	end

	function actions.ListProjects(request)
		local root = load("root").get("EclipseAnimator_Saves", false)
		local result, maximum = {}, limit(request.Limit, 100)
		for _, entry in root and root:GetChildren() or {} do
			if entry:IsA("Folder") or entry:IsA("KeyframeSequence") then table.insert(result, entry) end
			if #result == maximum then break end
		end
		return result
	end

	function actions.OpenProject(request)
		assert(not state.LoadingProject, "Eclipse is loading a project")
		local active = refs.Active()
		if active and state.currentProjectSaved == false then
			assert(request.SaveCurrent == true, "Save current work before opening another project")
			assert(refs.Save(true, nil, true), "Current project could not be saved")
		end
		refs.ScreenGui.Enabled = true
		if request.Sequence then
			assert(request.Sequence:IsA("KeyframeSequence"), "Sequence must be a KeyframeSequence")
			assert(project.openProjectFromKeyframeSequence(access.target(request.Rig), request.Sequence) ~= false, "Could not open clip")
		elseif request.Target then
			local saves = load("root").get("EclipseAnimator_Saves", false)
			assert(saves and request.Target.Parent == saves, "Target must be a saved Eclipse project from ListProjects")
			assert(refs.OpenSave(request.Target) ~= false, "Could not open project")
		else
			project.openEmptyProject(nil)
			if request.Name then project.setProjectName(name(request.Name)) end
			if request.Rig then assert(refs.AddRig(access.target(request.Rig)), "Could not add the rig") end
		end
		assert(refs.Active(), "Eclipse did not enter the timeline")
		return actions.ProjectInfo()
	end

	function actions.SaveProject(request)
		local saved = refs.Save(request.RawOnly ~= false, name(request.Name), true)
		assert(saved, "Eclipse did not save the project")
		return { Project = saved }
	end

	function actions.ExportProject(request)
		if request.Kind == "Animations" then return export.exportCurrentAnimation({ showResults = false }) end
		if request.Kind == "Cutscene" then
			local package = load("package")
			local outputName = name(request.Name, "Eclipse Cutscene")
			assert(#outputName <= 80, "Cutscene export name must be at most 80 characters")
			local mode = request.Mode or "Scripting"
			assert(mode == "Scripting" or mode == "Button", "Mode must be Scripting or Button")
			local cameraMode = request.CameraMode or (request.Camera and "Authored" or "Game")
			assert(table.find({ "Authored", "Game", "Studio" }, cameraMode), "Unknown camera mode")
			local selected = request.Camera and rig(request.Camera)
			assert(cameraMode ~= "Authored" or selected and camera.isRig(selected), "Select an authored camera")
			local dependencies = {}
			for index, object in request.Dependencies or {} do
				assert(index <= 128 and typeof(object) == "Instance" and
					(object:IsDescendantOf(workspace) or object:IsDescendantOf(ReplicatedStorage)), "Invalid cutscene dependency")
				table.insert(dependencies, object)
			end
			local options = {
				Name = outputName, LastFrame = integer(request.EndFrame or state.Timeline:GetMaxFrame(), "end frame", 1, 1000000),
				Mode = mode, CameraMode = cameraMode, Camera = selected,
				ButtonLabel = name(request.ButtonLabel, outputName), Dependencies = dependencies,
			}
			local existing = ReplicatedStorage:FindFirstChild("EclipseCutscenes")
			assert(not existing or not existing:FindFirstChild(outputName), "Cutscene export name already exists")
			local exportRefs = setmetatable({ Archive = export.buildProjectArchive }, { __index = refs })
			local root, launcher
			local ok, issue = pcall(function()
				load("bake").withExportLock(exportRefs, options, function()
					root, launcher = package.build(exportRefs, options)
					package.install(root, launcher)
				end)
			end)
			if not ok then
				if root then root:Destroy() end
				if launcher then launcher:Destroy() end
				error(issue, 0)
			end
			return { Cutscene = root, Mode = mode, CameraMode = cameraMode, EndFrame = options.LastFrame }
		end
		assert(request.Kind == nil or request.Kind == "Archive", "Kind must be Archive, Animations, or Cutscene")
		local destination = request.Parent or ServerStorage
		assert(destination == ServerStorage or destination:IsDescendantOf(ServerStorage)
			or destination == ReplicatedStorage or destination:IsDescendantOf(ReplicatedStorage),
			"Archive destination must be in ServerStorage or ReplicatedStorage")
		local outputName = name(request.Name, "Eclipse Cutscene Archive")
		assert(not destination:FindFirstChild(outputName), "Archive name already exists")
		local archive = export.buildProjectArchive()
		archive.Name, archive.Parent = outputName, destination
		return { Archive = archive, RigCount = #archive.Rigs:GetChildren() }
	end

	function actions.ListKeys(request)
		local timeline, result = state.Timeline, {}
		local first = integer(request.First or 0, "first frame", 0, 1000000)
		local last = integer(request.Last or 1000000, "last frame", first, 1000000)
		local maximum = limit(request.Limit, 128)
		for _, row in access.rows(request) do
			local bucket = timeline:GetMotorKeyframeBucket(row.motor)
			local frames = {}
			for frame in bucket or {} do
				if type(frame) == "number" and frame >= first and frame <= last then table.insert(frames, frame) end
			end
			table.sort(frames)
			local keys = {}
			for index, frame in frames do
				if index > maximum then break end
				local key = bucket[frame]
				table.insert(keys, {
					Frame = frame, Value = if camera.isFov(row.motor) then camera.decode(row.motor, key.C0)
						elseif load("properties").is(row.motor) then load("properties").decode(row.motor, key.C0, key.PropertyValue) else key.C0,
					Easing = key.EasingStyle, Direction = key.EasingDirection, Bezier = key.BezierPoints,
					Channels = if request.IncludeChannels then key.GraphCurves else nil,
					World = key.WorldCFrame, Disabled = key.Disabled == true,
				})
			end
			table.insert(result, { Target = access.identity(row.motor), Property = row.property,
				Keys = keys, Total = #frames, NextFrame = frames[maximum + 1] })
			if #result == 128 then break end
		end
		return result
	end

	function actions.DeleteKey(request)
		local timeline, motor, _, key = keyAt(request)
		changeKey(timeline, motor, "MCP delete key", function() timeline:DeleteKeyframe(key) end)
		return { Frame = request.Frame }
	end

	function actions.SetCurve(request)
		local timeline, motor, bucket, key = keyAt(request)
		local points, id = request.Bezier, request.Channel
		if points ~= nil then
			assert(type(points) == "table" and #points == 4, "Bezier must contain x1,y1,x2,y2")
			for _, value in points do assert(finite(value) and math.abs(value) <= 20, "Invalid Bezier coordinate") end
			assert(points[1] >= 0 and points[1] <= 1 and points[3] >= 0 and points[3] <= 1, "Bezier X must be in [0,1]")
		end
		local handle = request.HandleType
		if handle then
			assert(table.find({ "Automatic", "AutoClamped", "Vector", "Free", "Aligned" }, handle), "Invalid handle type")
		end
		local function tangent(value)
			assert(type(value) == "table" and #value == 2 and finite(value[1]) and finite(value[2]), "Tangent must contain time and value offsets")
			return table.clone(value)
		end
		local incoming = request.In and tangent(request.In)
		local outgoing = request.Out and tangent(request.Out)
		local function configure(draft)
			if points then draft.EasingStyle, draft.BezierPoints, draft.MoonEasing = "Bezier", points, nil end
			if handle then draft.HandleType = handle end
		end
		changeKey(timeline, motor, "MCP edit curve", function()
			if id then
				channels.edit(key, id, configure, bucket)
			else
				channels.editAll(key, configure, bucket)
			end
			if incoming or outgoing then
				local point = assert(id and key.GraphCurves and key.GraphCurves[id], "Tangents require a graph channel from ListKeys")
				point.HandleType = handle or "Free"
				point.BlenderHandles = nil
				if incoming then point.In = incoming end
				if outgoing then point.Out = outgoing end
				channels.graphChanged(key, id)
			end
			graph.invalidate(bucket)
		end)
		return { Frame = request.Frame, Channel = id }
	end

	function actions.FilterRotation(request)
		local timeline, motor = state.Timeline, track(request)
		local bucket = assert(timeline:GetMotorKeyframeBucket(motor), "Track has no keys")
		changeKey(timeline, motor, "MCP filter rotation", function() graph.filterRotation(bucket) end)
		return { Target = request.Target }
	end

	function actions.SetTimeline(request)
		local timeline = state.Timeline
		local raw = timeline:GetState()
		local finish = request.EndFrame and integer(request.EndFrame, "end frame", 1, 1000000)
		local start = request.StartFrame and integer(request.StartFrame, "start frame", 0,
			(finish or timeline:GetMaxFrame()) - 1)
		assert(request.Loop == nil or type(request.Loop) == "boolean", "Loop must be a boolean")
		if finish then
			assert(finish >= (timeline:GetLastKeyframeFrame() or 0), "End frame precedes the final authored key or cue")
			assert((start or raw.PlaybackStartFrame or 0) < finish, "End frame precedes the playback start")
		end
		local old = { start = raw.PlaybackStartFrame or 0, finish = timeline:GetMaxFrame(), loop = timeline:IsLooping(), fps = raw.FPS }
		if request.FPS then assert(timeline:SetFPS(integer(request.FPS, "FPS", 1, 240), true), "Unsupported FPS") end
		if finish then
			load("rawState").Config.Length = finish / raw.FPS
			timeline:RefreshTimelineScale()
		end
		if start then raw.PlaybackStartFrame = start end
		if request.Loop ~= nil then timeline:SetLooping(request.Loop) end
		local current = { start = raw.PlaybackStartFrame or 0, finish = timeline:GetMaxFrame(), loop = timeline:IsLooping(), fps = raw.FPS }
		local function apply(settings)
			local config = load("rawState").Config
			timeline:SetFPS(settings.fps, true)
			config.Length = settings.finish / raw.FPS
			raw.PlaybackStartFrame = settings.start
			timeline:SetLooping(settings.loop)
			timeline:RefreshTimelineScale()
			state.currentProjectSaved = false
		end
		if old.start ~= current.start or old.finish ~= current.finish or old.loop ~= current.loop or old.fps ~= current.fps then
			history.record(function() apply(old) end, function() apply(current) end, "MCP playback range")
			state.currentProjectSaved = false
		end
		return actions.ProjectInfo()
	end

	function actions.SeekFrame(request)
		local raw = seek(request.Frame)
		local result = { Frame = request.Frame, Time = raw.CurrentTime, FPS = raw.FPS, Samples = {} }
		for index, item in request.Samples or {} do
			assert(index <= 64, "At most 64 samples")
			local object = preview.localOf(access.target(item))
			local frame = if object:IsA("Bone") then object.TransformedWorldCFrame
				elseif object:IsA("Model") then object:GetPivot()
				elseif object:IsA("BasePart") then object.CFrame else nil
			table.insert(result.Samples, { Target = item, CFrame = frame })
		end
		return result
	end

	function actions.Playback(request)
		if request.Play == false then
			project.stopAllAnimations()
		else
			assert(state.Timeline:StartPlayback(true), "Eclipse could not start playback")
		end
		return actions.ProjectInfo()
	end

	function actions.CreateCamera(request)
		local frame = request.CFrame or workspace.CurrentCamera.CFrame
		assert(typeof(frame) == "CFrame", "CFrame must be a Roblox CFrame")
		local label = name(request.Name, camera.nextName(state.getAllRigs()))
		local fov = request.FOV
		assert(fov == nil or finite(fov) and fov >= 1 and fov <= 120, "FOV must be between 1 and 120")
		local model = camera.create(camera.authoredFromView(frame, fov), label)
		if fov then model.FieldOfView.default.Value = fov end
		model.Parent = workspace
		local ok, result = pcall(refs.AddRig, model, { AllowDuplicateName = true })
		if not ok or not result then
			model:Destroy()
			error(if ok then "Could not add camera to timeline" else result, 0)
		end
		local actual = preview.localOf(model)
		return { Camera = actual, Properties = { "CFrame", "FieldOfView" } }
	end

	function actions.CameraView(request)
		local model = rig(request.Target)
		assert(camera.isRig(model), "Choose an Eclipse camera rig")
		if request.Frame then seek(request.Frame) end
		local frame, fov = camera.renderFrame(model, nil, request.Unshaken == true, state.Timeline:GetState().CurrentTime)
		if request.Apply then
			workspace.CurrentCamera.CFrame, workspace.CurrentCamera.FieldOfView = frame, fov
		end
		return { CFrame = frame, FOV = fov, CameraPosition = frame.Position, LookAt = frame.Position + frame.LookVector }
	end

	function actions.KeyCamera(request)
		local model = rig(request.Target)
		assert(camera.isRig(model), "Choose an Eclipse camera rig")
		local frame = integer(request.Frame, "frame", 0, 1000000)
		assert(request.View or request.FOV, "Provide View or FOV")
		local clipCamera = model
		local result = {}
		if request.View then
			assert(typeof(request.View) == "CFrame", "View must be a world CFrame")
			local motor = camera.motor(model, "CamPart")
			local desired = camera.authoredFromView(request.View, request.FOV)
			local value = motor.Part0.CFrame:ToObjectSpace(desired) * motor.C1
			result.CFrame = access.setKey({ Target = clipCamera, Property = "CFrame", Frame = frame, Value = value, Easing = request.Easing })
		end
		if request.FOV then
			assert(finite(request.FOV) and request.FOV >= 1 and request.FOV <= 120, "Invalid camera FOV")
			result.FOV = access.setKey({ Target = clipCamera, Property = "FieldOfView", Frame = frame, Value = request.FOV, Easing = request.Easing })
		end
		return result
	end

	function actions.ListEvents(request)
		local result = {}
		local first, last = request.First or 0, request.Last or 1000000
		local maximum = limit(request.Limit, 100)
		for owner, eventTrack in events.all() do
			if not request.Rig or owner == rig(request.Rig) then
				for _, event in events.snapshot(eventTrack).Events do
					if event.Frame >= first and event.Frame <= last then
						table.insert(result, { Rig = preview.original(owner), Event = event })
					end
				end
			end
		end
		table.sort(result, function(a, b)
			return a.Event.Frame < b.Event.Frame or a.Event.Frame == b.Event.Frame and a.Event.Id < b.Event.Id
		end)
		while #result > maximum do table.remove(result) end
		return result
	end

	local function encodePath(object)
		local path = wire.encode(access.target(object))["$instance"]
		assert(path and path[1] == "Workspace", "VFX target must be in Workspace")
		local quoted = {}
		for _, segment in path do table.insert(quoted, string.format("%q", segment)) end
		return table.concat(quoted, ",")
	end

	function actions.PutEvent(request)
		local owner = rig(request.Rig)
		local frame = integer(request.Frame, "event frame", 0, 1000000)
		local duration = request.Duration and integer(request.Duration, "event duration", 0, 1000000)
		local requestedName = name(request.Name)
		assert(request.Enabled == nil or type(request.Enabled) == "boolean", "Enabled must be a boolean")
		assert(request.Speed == nil or finite(request.Speed) and request.Speed > 0, "Invalid event speed")
		local emits, sounds, subtitles
		if request.Emits then
			local clipboard = load("clipboardRows")
			local rows = {}
			for _, row in request.Emits do
				local target = preview.localOf(access.target(row.Target))
				local path = assert(clipboard.path(owner, target), "Native emitter must be below the selected event rig")
				table.insert(rows, { Mode = row.Mode or "Exact", Path = path, Action = row.Action or "Emit", Count = row.Count })
			end
			emits = clipboard.copy(rows)
			assert(#emits == #rows, "Invalid native emission row")
		end
		if request.Sounds then sounds = load("soundData").copy(request.Sounds) end
		if request.Subtitle then subtitles = load("subtitleData").copy(request.Subtitle) end
		local startCode, endCode = request.CodeBegin, request.CodeEnd
		for _, code in { startCode or "", endCode or "" } do assert(type(code) == "string" and #code <= 12000, "Invalid event code") end
		if request.Sine then
			assert(not startCode, "Use either Sine or CodeBegin for this event")
			assert(ReplicatedStorage:FindFirstChild("SineVFX"), "Install the SineVFX client runtime in ReplicatedStorage first")
			local method = request.Sine.Mode or "emit"
			assert(table.find({ "emit", "enable", "disable" }, method), "Unknown SineVFX cue mode")
			local targetPath = encodePath(request.Sine.Target)
			local code = 'local target = game\nfor _, name in {' .. targetPath
				.. '} do\n target = target:FindFirstChild(name)\n if not target then return end\nend\n'
			local call = 'require(game:GetService("ReplicatedStorage"):WaitForChild("SineVFX")).'
			startCode = code .. call .. method .. "(target)"
			if method == "enable" and duration and duration > 0 and not endCode then endCode = code .. call .. "disable(target)" end
		end
		local eventTrack = events.get(owner)
		local before = events.snapshot(eventTrack)
		local event = request.Id and assert(eventTrack.Events[request.Id], "Event ID not found") or nil
		local eventName = requestedName or (event and event.Name) or "Event"
		local proposed = events.nextFrame(eventTrack, frame, event and event.Id)
		assert(proposed == frame, "Selected frame already contains a cue on this track")
		event = event or {
			Id = HttpService:GenerateGUID(false), Sounds = {}, Name = eventName, Speed = 1,
			Duration = 0, Enabled = true, CodeBegin = "", CodeEnd = "", Parameter = "",
		}
		event.Frame, event.Duration, event.Name = frame, duration or event.Duration, eventName
		if request.Enabled ~= nil then event.Enabled = request.Enabled end
		if request.Speed then event.Speed = events.normalizeSpeed(request.Speed) end
		if request.Markers then events.setMarkers(event, request.Markers) end
		if emits then event.Emits = emits end
		if sounds then event.Sounds = sounds end
		if subtitles then event.Subtitle = subtitles end
		if startCode then event.CodeBegin = startCode end
		if endCode then event.CodeEnd = endCode end
		eventTrack.Events[event.Id] = event
		eventTrack.Enabled = true
		events.changed(eventTrack)
		state.Timeline:RecordEventEdit(eventTrack, before, "MCP event " .. eventName)
		state.Timeline:RefreshEventRows()
		return { Id = event.Id, Frame = event.Frame, Name = event.Name, Duration = event.Duration }
	end

	function actions.DeleteEvent(request)
		local id = assert(request.Id, "Event ID is required")
		local removed = state.Timeline:DeleteEvent(events.get(rig(request.Rig)), id)
		assert(removed, "Event ID not found")
		return { Id = id }
	end

	function actions.ListLayers(request)
		local raw = state.Timeline:GetState()
		local owner = if request.Rig then rig(request.Rig) else state.currentRig
		local stack = owner and layers.stack(raw, owner)
		local result = {}
		local data = layers.ensure(raw)
		for _, layer in stack or {} do
			table.insert(result, { Id = layer.id, Name = layer.name, Weight = layer.weight, Mode = layer.mode,
				Locked = layer.locked, Muted = layer.muted, Solo = layer.solo, Active = layer.id == (data.activeByRig[owner] or "base") })
		end
		return result
	end

	function actions.EditLayer(request)
		local action = request.Operation
		if request.Rig then layers.setMaster(rig(request.Rig)) end
		if action == "Add" then layers.add()
		elseif action == "Select" then layers.select(assert(request.Id, "Layer ID required"))
		elseif action == "Remove" then layers.remove(assert(request.Id, "Layer ID required"))
		elseif action == "Duplicate" then layers.duplicate(assert(request.Id, "Layer ID required"))
		elseif action == "Move" then
			assert(request.Direction == 1 or request.Direction == -1, "Direction must be -1 or 1")
			layers.move(assert(request.Id, "Layer ID required"), request.Direction)
		elseif action == "Change" then
			assert(table.find({ "name", "weight", "mode", "locked", "muted", "solo" }, request.Field), "Unknown layer property")
			layers.change(assert(request.Id, "Layer ID required"), request.Field, request.Value)
		else error("Unknown layer operation", 0) end
		return actions.ListLayers(request)
	end

	function actions.ListIK(request)
		local owner = rig(request.Rig)
		local result, time = {}, state.Timeline:GetState().CurrentTime
		for _, chain in limbs.getRig(owner).chains do
			local data = limbs.state(chain, time)
			table.insert(result, { Target = access.identity(chain.owner), Kind = chain.kind, Limb = chain.limb,
				Enabled = limbs.isEnabled(chain.owner, time), Effector = data and data.target,
				Pole = data and data.pole, PoleFollowsTarget = data and data.poleFollowsTarget })
		end
		return result
	end

	local function chainAt(request)
		local owner, motor = rig(request.Rig), track(request)
		local chain = assert(limbs.chain(owner, motor), "Target has no Eclipse IK chain")
		local raw = seek(request.Frame or state.Timeline:TimeToFrame(state.Timeline:GetState().CurrentTime))
		return owner, chain, raw
	end

	function actions.SetIK(request)
		assert(type(request.Enabled) == "boolean", "Enabled must be a boolean")
		local owner, chain, raw = chainAt(request)
		if limbs.isEnabled(chain.owner, raw.CurrentTime) ~= request.Enabled then
			state.Timeline:SwitchIKAtCurrentTime(chain.owner, owner)
		end
		assert(limbs.isEnabled(chain.owner, raw.CurrentTime) == request.Enabled, "Could not change IK state")
		return { Enabled = request.Enabled, Frame = state.Timeline:TimeToFrame(raw.CurrentTime) }
	end

	function actions.SetPoleFollow(request)
		assert(type(request.Enabled) == "boolean", "Enabled must be a boolean")
		local owner, chain, raw = chainAt(request)
		local control = assert(limbs.state(chain, raw.CurrentTime), "Enable IK first")
		if (control.poleFollowsTarget == true) ~= request.Enabled then
			state.Timeline:SwitchPoleFollowAtCurrentTime(chain.owner, owner)
		end
		local updated = assert(limbs.state(chain, raw.CurrentTime), "IK state unavailable")
		assert((updated.poleFollowsTarget == true) == request.Enabled, "Could not change IK pole follow")
		return { Enabled = request.Enabled }
	end

	function actions.KeyIKControl(request)
		local kind = request.Control
		assert(table.find({ "target", "pole", "roll", "root" }, kind), "Unknown IK control")
		assert(typeof(request.Value) == "CFrame", "Value must be a world CFrame")
		local _, chain, raw = chainAt(request)
		assert(limbs.isEnabled(chain.owner, raw.CurrentTime), "Enable IK first")
		local motor = assert(limbs.controlMotor(chain, kind), "Control is unavailable for this rig")
		local timeline = state.Timeline
		local frame = timeline:TimeToFrame(raw.CurrentTime)
		changeKey(timeline, motor, "MCP key IK " .. kind, function()
			limbs.setControl(chain, kind, request.Value)
			timeline:RecordKeyframeForMotorAtCurrentTime(motor.Part1, motor, motor.C0, { Frame = frame }, state.UIHelpers.SanitizeName)
			assert(timeline:GetMotorKeyframeBucket(motor)[frame], "IK key was not recorded")
		end)
		return { Frame = frame, Control = kind }
	end

	function actions.SetParenting(request)
		local owner, timeline = rig(request.Rig), state.Timeline
		local frame = integer(request.Frame, "frame", 0, 1000000)
		local destination = request.Parent and access.target(request.Parent)
		if request.Mode == "CameraAttachment" then
			assert(camera.isRig(owner), "Choose an Eclipse camera")
			load("targets").setCameraAttachment(owner, destination and preview.localOf(destination), frame)
		elseif request.Mode == "ChildOf" then
			load("targets").setChild(track(request), owner, destination, frame, request.World == true)
		else
			assert(request.Mode == "LocalSpace" and type(request.Parented) == "boolean", "Unknown parenting mode")
			local motor = track(request)
			local raw = seek(frame)
			if timeline:IsParentedAtTime(motor, raw.CurrentTime) ~= request.Parented then
				timeline:SwitchParentingAtCurrentTime(motor, owner)
			end
			assert(timeline:IsParentedAtTime(motor, raw.CurrentTime) == request.Parented, "Could not change parent space")
		end
		return { Frame = frame, Mode = request.Mode }
	end

	function actions.ApplyMotionPath(request)
		local motor = track(request)
		local first = integer(request.First, "first frame", 0, 1000000)
		local last = integer(request.Last, "last frame", first + 1, 1000000)
		local step = integer(request.Step or 1, "step", 1, 1000000)
		assert(type(request.Points) == "table" and #request.Points >= 2 and #request.Points <= 2048, "Expected 2–2048 world positions")
		for _, p in request.Points do assert(typeof(p) == "Vector3", "Motion path points must be Vector3 values") end
		load("greasePencil").apply(motor, request.Points, first, last, step, request.Offset == true, request.Easing)
		return { First = first, Last = last, Step = step }
	end

	function actions.SelectKeys(request)
		assert(type(request.Keys) == "table" and #request.Keys > 0 and #request.Keys <= 1000, "Expected 1–1000 key selectors")
		local keys = {}
		for _, item in request.Keys do
			local _, _, _, key = keyAt(item)
			table.insert(keys, key)
		end
		state.Timeline:SetSelectedKeyframes(keys)
		return { Count = #keys }
	end

	function actions.RetimeKeys(request)
		local delta = integer(request.Delta, "frame offset", -1000000, 1000000)
		local result = actions.SelectKeys(request)
		assert(state.Timeline:NudgeSelectedKeyframes(delta), "No selected keys could move")
		return { Count = result.Count, RequestedDelta = delta }
	end

	function actions.CreateScreenEffect(request)
		local effects = load("effects")
		local kind = request.Kind
		local start = integer(request.StartFrame, "start frame", 0, 1000000)
		local fps = state.Timeline:GetState().FPS
		local cameraId
		if request.Camera then
			local selected = rig(request.Camera)
			for _, option in effects.cameras() do
				if option.rig == selected then cameraId = option.id break end
			end
			assert(cameraId, "Target is not an Eclipse camera")
		end
		local result
		if kind == "Impact Frames" then
			result = effects.createImpact(request.Frames, start)
		elseif kind == "Camera Shake" then
			result = effects.createShake(request.Strength, request.Speed, start, request.Duration, cameraId, request.Envelope)
		elseif kind == "Afterimage" then
			local settings = table.clone(request.Settings or {})
			settings.StartFrame = start
			result = effects.create({ kind = kind, name = name(request.Name, kind), target = access.target(request.Target), settings = settings })
		else
			assert(table.find({ "Letterbox", "Vignette", "Screen Cover" }, kind), "Unknown screen effect")
			local value = load("model").defaults(kind, start, fps)
			for _, field in { "duration", "fadeIn", "fadeOut", "opacity", "color", "color2", "gradient", "gradientRotation",
				"width", "heightScale", "depth", "images", "style", "easeIn", "easeOut" } do
				if request.Settings and request.Settings[field] ~= nil then value[field] = request.Settings[field] end
			end
			value.cameraId, value.name = cameraId, name(request.Name, value.name)
			result = effects.create(value)
		end
		return { Effect = result, Kind = kind, StartFrame = start }
	end

	function actions.ReadPreferences(request)
		local settings = load("preferences")
		local defaults = settings.defaults()
		local values = {}
		for _, key in request.Keys or {} do assert(defaults[key] ~= nil, "Unknown preference " .. tostring(key)) end
		if request.Keys then
			for _, key in request.Keys do values[key] = settings.get(key) end
		else
			for key in defaults do values[key] = settings.get(key) end
		end
		return { Values = values, Defaults = if request.IncludeDefaults then defaults else nil }
	end

	function actions.SetPreferences(request)
		local settings = load("preferences")
		local defaults = settings.defaults()
		assert(type(request.Changes) == "table" and next(request.Changes), "Changes are required")
		local keys = {}
		for key in request.Changes do
			assert(defaults[key] ~= nil and not settings.unavailableReason(key), "Unknown or unavailable preference " .. tostring(key))
			table.insert(keys, key)
		end
		assert(settings.setMany(request.Changes), "Eclipse could not apply preference changes")
		return actions.ReadPreferences({ Keys = keys })
	end

	function actions.OpenPanel(request)
		local entry = assert(panels[request.Panel], "Unknown Eclipse panel")
		local module = load(entry[1])
		assert(type(module[entry[2]]) == "function", "Panel is unavailable in this build")
		module[entry[2]]()
		return { Panel = request.Panel }
	end

	function actions.EditorCommand(request)
		return { Executed = load("keybinds").mcpTrigger(request.Command) }
	end

	function actions.SelectTargets(request)
		local selection = {}
		for index, target in request.Targets or {} do
			assert(index <= 128, "At most 128 targets")
			table.insert(selection, access.target(target))
		end
		game:GetService("Selection"):Set(selection)
		return { Count = #selection }
	end

	function actions.ListEditorFeatures()
		local names = {}
		for key in panels do table.insert(names, key) end
		table.sort(names)
		return { Panels = names, Commands = load("keybinds").mcpList(), Actions = cutscene.actions }
	end

	function actions.BlenderCommand(request)
		local bridge = load("blenderBridge")
		local command = request.Command
		if command == "Status" then return bridge.status() end
		local handlers = { Connect = bridge.connect, Pull = bridge.pull, Push = bridge.push, Disconnect = bridge.disconnect }
		assert(handlers[command], "Unknown Blender operation")()
		return bridge.status()
	end

	function actions.VideoCommand(request)
		local video = load("bridge")
		if request.Command == "Retry" then video.retry()
		elseif request.Command == "Enable" then video.setEnabled(true)
		elseif request.Command == "Disable" then video.setEnabled(false)
		else assert(request.Command == "Status", "Unknown reference-video operation") end
		return video.status()
	end

	return actions
end

return cutscene
