import fs from 'node:fs/promises'
import { z } from 'zod'
import { callNative, currentStudio, listStudios, selectStudio, studioTool, luauLiteral, readResult } from './connection.js'

const nativeActions = [
  'GetInfo', 'Add', 'AddObject', 'ListTracks', 'ListProperties', 'Select', 'SetKeyframe', 'SetEasing',
  'GetCurrentFrame', 'GetCurrentTime', 'GetFPS', 'Batch', 'BeginBatch', 'EndBatch', 'HistoryRecord',
  'RevertChanges', 'CreateFolder', 'RenameFolder', 'GetFolder', 'ListFolders', 'MoveToFolder', 'MoveToParent',
  'GetTimelineParent', 'ListTimelineChildren', 'Undo', 'Redo', 'GetHistoryState', 'SetExpanded', 'ForwardInput'
]
const expandedActions = [
  'OpenProject', 'ListProjects', 'ProjectInfo', 'SaveProject', 'ExportProject', 'ListEditorFeatures', 'ListKeys',
  'DeleteKey', 'SetCurve', 'FilterRotation', 'SetTimeline', 'SeekFrame', 'Playback', 'CreateCamera', 'CameraView', 'KeyCamera',
  'ListEvents', 'PutEvent', 'DeleteEvent', 'ListLayers', 'EditLayer', 'ListIK', 'SetIK', 'KeyIKControl',
  'SetPoleFollow', 'OpenPanel', 'EditorCommand', 'BlenderCommand', 'VideoCommand', 'SelectTargets',
  'SetParenting', 'ApplyMotionPath', 'SelectKeys', 'RetimeKeys', 'CreateScreenEffect', 'ReadPreferences', 'SetPreferences'
]
export const actionNames = [...nativeActions, ...expandedActions]
export const batchActions = [
  'Add', 'AddObject', 'SetKeyframe', 'SetEasing', 'CreateFolder', 'RenameFolder', 'MoveToFolder', 'MoveToParent',
  'DeleteKey', 'SetCurve', 'SetTimeline', 'PutEvent', 'DeleteEvent', 'SetIK',
  'KeyIKControl', 'SetPoleFollow', 'FilterRotation', 'KeyCamera', 'SetParenting', 'ApplyMotionPath', 'RetimeKeys', 'CreateScreenEffect'
]

const studioId = z.string().min(1).optional().describe('Exact Roblox Studio ID from eclipse_list_studios. Defaults to the selected studio.')
const endpoint = z.string().min(1).optional().describe('Exact Eclipse endpoint name if multiple copies exist in this Studio window.')
const instancePath = z.union([z.string().min(1), z.array(z.string().min(1)).min(1).max(128), z.object({ $ref: z.string().min(1) })])
const request = z.record(z.string(), z.unknown())
const frame = z.number().int().min(0).max(1000000)
const shotGuide = new URL('../studio/recreate-workflow.md', import.meta.url)

const asResult = result => ({ content: [{ type: 'text', text: JSON.stringify(result ?? null) }] })
const target = path => (typeof path === 'object' && '$ref' in path ? path : { $instance: path })

export function registerStudioTools(server) {
  const readOnly = { readOnlyHint: true, openWorldHint: false }
  const edit = { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  server.registerTool('eclipse_list_studios', {
    title: 'List Roblox Studio windows',
    description: 'List Studio windows and IDs before picking the intended place. The active Eclipse project belongs to one Studio window.',
    annotations: readOnly,
  }, async () => asResult(await listStudios()))

  server.registerTool('eclipse_select_studio', {
    title: 'Pin the target Studio window',
    annotations: edit,
    description: 'Pin one connected Studio ID for this MCP session, including the inherited clip and retargeting tools.',
    inputSchema: { studio_id: z.string().min(1) },
  }, async ({ studio_id }) => {
    const studios = await listStudios()
    const selected = studios.find(item => [item.studio_id, item.studioId, item.id].includes(studio_id))
    if (!selected) throw new Error('Studio ID is not connected. Call eclipse_list_studios.')
    selectStudio(studio_id)
    return asResult(selected)
  })

  server.registerTool('eclipse_capabilities', {
    title: 'Read Eclipse build and API capabilities',
    description: 'Verify the exact API build, patched bridge version, and list of available native actions. Read before editing.',
    inputSchema: { studio_id: studioId, endpoint },
    annotations: readOnly,
  }, async ({ studio_id, endpoint }) => asResult(await callNative(studio_id, 'GetInfo', {}, endpoint)))

  server.registerTool('eclipse_action', {
    title: 'Invoke a native Eclipse timeline action',
    annotations: edit,
    description: 'Open and save projects, read keys and layers, inspect IK, edit poses and curves, create camera rigs, play or seek, edit cues, control supported EditorCommands, and export. Read eclipse://recreate-workflow for exact request fields. Instance values are {"$instance":["Workspace","Object"]}. CFrames use {"$type":"CFrame","values":[x,y,z,...9 rotation components]} or 3 translation components.',
    inputSchema: { studio_id: studioId, endpoint, action: z.enum(actionNames), request: request.optional() },
  }, async ({ studio_id, endpoint, action, request }) => asResult(await callNative(studio_id, action, request, endpoint)))

  server.registerTool('eclipse_batch', {
    title: 'Batch live Eclipse timeline edits',
    annotations: edit,
    description: 'Apply 1–1000 Eclipse timeline edits in a single native undo group. Use for pose, keyframe, timing, curve, event and IK changes in the same open project. Requests use typed instance and CFrame values.',
    inputSchema: {
      studio_id: studioId,
      endpoint,
      name: z.string().min(1).max(128),
      edits: z.array(z.object({ action: z.enum(batchActions), request })).min(1).max(1000),
    },
  }, async ({ studio_id, endpoint, name, edits }) => asResult(await callNative(studio_id, 'Batch', {
    Name: name,
    Actions: edits.map(edit => ({ Action: edit.action, Request: edit.request })),
  }, endpoint)))

  server.registerTool('eclipse_capture_frame', {
    title: 'Render an exact Eclipse frame',
    annotations: edit,
    description: 'Seek an Eclipse timeline frame, optionally apply an animated Eclipse camera and FOV, and return a Studio viewport image. Reuse the same camera and frame for texture audition A/B comparisons.',
    inputSchema: { studio_id: studioId, endpoint, frame, camera: instancePath.optional() },
  }, async ({ studio_id, endpoint, frame, camera }) => {
    const id = studio_id ?? currentStudio()
    if (camera) {
      await callNative(id, 'CameraView', { Target: target(camera), Frame: frame, Apply: true }, endpoint)
    } else {
      await callNative(id, 'SeekFrame', { Frame: frame }, endpoint)
    }
    return await studioTool('screen_capture', { studio_id: id, capture_id: 'eclipse-frame-' + frame })
  })

  server.registerTool('eclipse_playtest', {
    title: 'Start or stop the selected Studio playtest',
    annotations: edit,
    description: 'Start an already configured cutscene runtime in a Play session, or stop the session. Edit-mode Eclipse UI playback is controlled by the Playback action.',
    inputSchema: { studio_id: studioId, start: z.boolean() },
  }, async ({ studio_id, start }) => await studioTool('start_stop_play', {
    studio_id: studio_id ?? currentStudio(), is_start: start,
  }))

  server.registerTool('eclipse_record_playtest', {
    title: 'Record the cutscene inside a playtest',
    annotations: edit,
    description: 'Start or stop Studio video capture in the active client or server playtest. Run the shot through its real activation path during the recording.',
    inputSchema: { studio_id: studioId, start: z.boolean(), context: z.enum(['Client', 'Server']).default('Client') },
  }, async ({ studio_id, start, context }) => await studioTool('video_capture', {
    studio_id: studio_id ?? currentStudio(), is_start: start, datamodel_type: context,
  }))

  server.registerTool('eclipse_run_export', {
    title: 'Run an exported cutscene in a Studio playtest',
    description: 'Drive an Eclipse cutscene through its real client runtime. Start Play first. Use play to begin, status to read marker frames, seek to inspect, and stop or destroy to clean up.',
    annotations: edit,
    inputSchema: {
      studio_id: studioId,
      name: z.string().min(1).max(80),
      operation: z.enum(['play', 'pause', 'seek', 'stop', 'destroy', 'status']),
      seconds: z.number().min(0).optional(),
      loop: z.boolean().optional(),
    },
  }, async ({ studio_id, name, operation, seconds, loop }) => {
    const id = studio_id ?? currentStudio()
    const input = luauLiteral({ name, operation, seconds, loop })
    const code = `
local http = game:GetService("HttpService")
local request = http:JSONDecode(${input})
local root = game:GetService("ReplicatedStorage"):FindFirstChild("EclipseCutscenes")
assert(root, "No exported Eclipse cutscenes")
local module = root:FindFirstChild(request.name)
assert(module and module:IsA("ModuleScript") and module:GetAttribute("EclipseCutscene") == 2, "Exported cutscene not found")
shared.EclipseMcpPlaytest = shared.EclipseMcpPlaytest or {}
local runs = shared.EclipseMcpPlaytest
local record = runs[module]
if request.operation == "play" then
  if not record then
    local player = require(module).new({ Loop = request.loop })
    record = { player = player, markers = {} }
    player.MarkerReached:Connect(function(name, parameter, frame)
      table.insert(record.markers, { name = name, parameter = parameter, frame = frame })
      if #record.markers > 200 then table.remove(record.markers, 1) end
    end)
    player.Failed:Connect(function(message) record.error = tostring(message) end)
    runs[module] = record
  end
  local active = record
  task.spawn(function()
    local ok, issue = pcall(active.player.Play, active.player)
    if not ok then active.error = tostring(issue) end
  end)
elseif request.operation ~= "status" then
  assert(record, "Start the cutscene first")
  if request.operation == "pause" then record.player:Pause()
  elseif request.operation == "stop" then record.player:Stop()
  elseif request.operation == "seek" then record.player:Seek(assert(request.seconds, "seconds are required"))
  else record.player:Destroy(); runs[module] = nil; record = nil end
end
local player = record and record.player
return http:JSONEncode({
  name = request.name, status = player and player.Status or "Idle",
  time = player and player.Time, frame = player and player.Frame,
  duration = player and player.Duration, markers = record and record.markers,
  error = record and record.error,
})
`
    const response = readResult(await studioTool('execute_luau', {
      studio_id: id, datamodel_type: 'Client', code,
    }))
    return asResult(typeof response === 'string' ? JSON.parse(response) : response)
  })

  server.registerResource('eclipse-workflow', 'eclipse://recreate-workflow', {
    title: 'Eclipse cutscene authoring and Replicate Anything integration',
    mimeType: 'text/markdown',
  }, async uri => ({
    contents: [{ uri: uri.href, mimeType: 'text/markdown', text: await fs.readFile(shotGuide, 'utf8') }],
  }))

  server.registerPrompt('recreate_eclipse_cutscene', {
    title: 'Recreate an authorized Roblox cutscene',
    description: 'Use reference beats, vault auditions, the live Eclipse timeline, and verified Roblox captures.',
    argsSchema: { reference: z.string(), target: z.string() },
  }, async ({ reference, target: place }) => ({
    messages: [{
      role: 'user',
      content: {
        type: 'text',
        text: `Study ${reference} and recreate the authorized cutscene in ${place}. Follow Replicate Anything and read eclipse://recreate-workflow. Pin the exact Studio ID, inspect the player rig, audition 10–20 distinct textures per major effect per round, and iterate from equivalent edit-frame and actual playtest captures. Preserve the editable Eclipse project and report remaining visual differences.`
      },
    }],
  }))
}
