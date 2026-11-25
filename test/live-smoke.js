// Run only in the dedicated local Eclipse AI smoke place.
import assert from 'node:assert/strict'
import { callNative, listStudios, studioTool, readResult, selectStudio, callClip } from '../studio/connection.js'

const studio = (await listStudios()).find(row =>
  row.name === 'Eclipse AI Smoke Test.rbxl' && row.persistedToCloud === false)
assert(studio, 'Open the disposable Eclipse AI Smoke Test.rbxl first.')
selectStudio(studio.id)
const id = studio.id
const act = (a, r) => callNative(id, a, r)
const target = name => ({ $instance: name })
const cf = values => ({ $type: 'CFrame', values })
const execute = async code => readResult(await studioTool('execute_luau', { studio_id: id, datamodel_type: 'Edit', code }))
const prefix = 'Smoke' + Date.now().toString().slice(-6)
const results = []
async function verify(label, fn) {
  try {
    const value = await fn()
    results.push([label, true])
    console.log('PASS', label, value === undefined ? '' : JSON.stringify(value).slice(0, 620))
    return value
  } catch (error) {
    results.push([label, false])
    console.log('FAIL', label, error.message)
    return undefined
  }
}

await verify('attached build and two MCP endpoints', async () => {
  const cap = await act('GetInfo')
  assert.equal(cap.Build, 'v1.0979')
  assert.equal(cap.mcpVersion, 1)
  assert.ok(cap.Actions.includes('KeyCamera'))
  await callClip('list_rigs', {})
  return { build: cap.Build, actions: cap.Actions.length }
})
const rig = target('Workspace.McpR15Fixture')
const emitter = target(['Workspace','McpR15Fixture','RightHand','SmokeImpact'])
await verify('R15 fixture and native emitter', () => execute(`
local rig = workspace:FindFirstChild("McpR15Fixture")
if not rig then
  rig = game:GetService("Players"):CreateHumanoidModelFromDescriptionAsync(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
  rig.Name, rig.Parent = "McpR15Fixture", workspace
  rig:PivotTo(CFrame.new(0, 4, 0))
end
if not rig.RightHand:FindFirstChild("SmokeImpact") then
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name, emitter.Enabled, emitter.Parent = "SmokeImpact", false, rig.RightHand
end
return { parts = #rig:GetDescendants() }
`))
await verify('open real timeline and set exact range', async () => {
  await act('OpenProject', { Name: prefix, Rig: rig, SaveCurrent: true })
  const info = await act('SetTimeline', { FPS: 30, EndFrame: 60, Loop: false })
  assert.equal(info.EndFrame, 60)
  assert.equal(info.FPS, 30)
  return { endFrame: info.EndFrame, fps: info.FPS }
})
const tracks = await act('ListTracks')
const arm = tracks.find(row => row.Target.name === 'RightShoulder' && !row.Property)?.Target
assert(arm, 'Native shoulder track is missing.')
await verify('batched pose, easing, key reading, rollback and deletion', async () => {
  const actions = [0, 9, 18].map(Frame => ({ Action: 'SetKeyframe', Request: {
    Target: arm, Frame, Easing: { Style: 'Cubic', Direction: 'InOut' },
  } }))
  await act('Batch', { Name: 'Smoke body pose', Actions: actions })
  let keys = await act('ListKeys', { Target: arm, IncludeChannels: true })
  assert.deepEqual(keys[0].Keys.map(key => key.Frame), [0,9,18])
  await assert.rejects(act('Batch', { Name: 'Rollback case', Actions: [ {
    Action: 'SetKeyframe', Request: { Target: arm, Frame: 15 },
  }, {
    Action: 'SetKeyframe', Request: { Target: arm, Frame: 16, Value: 8 },
  } ] }), /Batch step 2/)
  keys = await act('ListKeys', { Target: arm })
  assert.deepEqual(keys[0].Keys.map(key => key.Frame), [0,9,18])
  await act('DeleteKey', { Target: arm, Frame: 9 })
  await act('Undo')
  keys = await act('ListKeys', { Target: arm })
  assert.deepEqual(keys[0].Keys.map(key => key.Frame), [0,9,18])
})
const camera = await verify('create camera, animate world view and FOV, and read curves', async () => {
  const created = await act('CreateCamera', { Name: prefix + ' Camera', CFrame: cf([0,6,12]), FOV: 52 })
  const ref = created.Camera
  const keys = [0,30].map((Frame, index) => ({ Action: 'KeyCamera', Request: {
    Target: ref, Frame, View: cf([index * 2,6,12-index*2]), FOV: index === 0 ? 52 : 64,
    Easing: { Style: 'Cubic', Direction: 'InOut' },
  } }))
  await act('Batch', { Name: 'Smoke camera', Actions: keys })
  await act('SetCurve', { Target: ref, Property: 'CFrame', Frame: 0, Bezier: [.25,.1,.75,.9] })
  const poses = await act('ListKeys', { Target: ref, Property: 'CFrame', IncludeChannels: true })
  assert.deepEqual(poses[0].Keys[0].Bezier, [.25,.1,.75,.9])
  const view = await act('CameraView', { Target: ref, Frame: 30, Apply: true })
  assert.ok(Math.abs(view.FOV - 64) < 0.1)
  assert.ok(Math.abs(view.CameraPosition.values[0] - 2) < 0.1)
  return ref
})
await verify('Eclipse R15 IK toggle and control key', async () => {
  const wrist = (await act('ListIK', { Rig: rig })).find(chain => chain.Target.name === 'RightWrist')
  await act('SetIK', { Rig: rig, Target: wrist.Target, Frame: 12, Enabled: true })
  const posed = (await act('ListIK', { Rig: rig })).find(chain => chain.Target.name === 'RightWrist')
  assert.equal(posed.Enabled, true)
  return act('KeyIKControl', { Rig: rig, Target: posed.Target, Frame: 12, Control: 'target', Value: posed.Effector })
})
await verify('native emit cue with marker, exact seek and world sample', async () => {
  const event = await act('PutEvent', { Rig: rig, Frame: 24, Name: 'Impact',
    Emits: [{ Target: emitter, Count: 15 }], Markers: [{ Name: 'Impact', Parameter: 'smoke' }] })
  const events = await act('ListEvents', { Rig: rig })
  const recorded = events.find(row => row.Event.Id === event.Id)?.Event
  assert.equal(recorded.Emits[0].Count, 15)
  assert.equal(recorded.Markers[0].Name, 'Impact')
  const seek = await act('SeekFrame', { Frame: 24, Samples: [rig] })
  assert.equal(seek.Time, .8)
  assert.equal(seek.Samples.length, 1)
  return { frame: recorded.Frame, emitCount: recorded.Emits[0].Count }
})
await verify('save, archive, and reopen Eclipse project', async () => {
  const saved = await act('SaveProject', { Name: prefix + ' Saved' })
  const archive = await act('ExportProject', { Kind: 'Archive', Name: prefix + ' Archive' })
  assert.ok(archive.RigCount >= 1)
  await act('OpenProject', { Target: saved.Project, SaveCurrent: true })
  const cues = await act('ListEvents', { Rig: rig })
  assert.ok(cues.some(row => row.Event.Name === 'Impact'))
})
if (process.argv.includes('--export-cutscene')) {
  await verify('export executable native cutscene package', async () => {
    const newestCamera = (await act('ProjectInfo')).Rigs.find(candidate =>
      candidate.name.includes('Camera'))
    const out = await act('ExportProject', { Kind: 'Cutscene', Name: prefix + ' Cutscene',
      EndFrame: 36, Mode: 'Scripting', Camera: newestCamera || camera })
    assert.ok(out.Cutscene?.$instance?.includes('EclipseCutscenes'))
    return out
  })
}
console.log(results.filter(([, ok]) => ok).length + '/' + results.length + ' live checks passed')
process.exit(results.every(([, ok]) => ok) ? 0 : 1)
