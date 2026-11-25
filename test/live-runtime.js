// Run after test/live-smoke.js --export-cutscene in the disposable local place.
import assert from 'node:assert/strict'
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { listStudios, studioTool, readResult } from '../studio/connection.js'

const studio = (await listStudios()).find(row =>
  row.name === 'Eclipse AI Smoke Test.rbxl' && row.persistedToCloud === false)
assert(studio, 'Open the disposable Eclipse AI Smoke Test.rbxl first.')
const execute = async code => readResult(await studioTool('execute_luau', {
  studio_id: studio.id, datamodel_type: 'Edit', code,
}))
const out = await execute(`
local root = game:GetService("ReplicatedStorage"):FindFirstChild("EclipseCutscenes")
local selected
for _, item in root and root:GetChildren() or {} do
  if item:GetAttribute("EclipseCutscene") == 2 then selected = item.Name end
end
return { name = selected }
`)
assert(out.name, 'Export a version 2 cutscene from the smoke fixture first.')
const client = new Client({ name: 'eclipse-integration-test', version: '1' })
await client.connect(new StdioClientTransport({
  command: process.execPath, args: ['server.js'],
  env: { ...process.env, ECLIPSE_STUDIO_TRANSPORT: '1' },
}))
async function tool(name, args, timeout = 20000) {
  const result = await client.callTool({ name, arguments: args }, undefined, { timeout })
  assert(!result.isError, result.content.map(block => block.text).join('\n'))
  return result
}
const json = async (name, args) => JSON.parse((await tool(name, args)).content[0].text)
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
let playing = false
let recording = false
try {
  await json('eclipse_select_studio', { studio_id: studio.id })
  const capabilities = await json('eclipse_capabilities', {})
  assert.equal(capabilities.Build, 'v1.0979')
  const frame = await tool('eclipse_capture_frame', { frame: 24 }, 30000)
  assert(frame.content.some(value => value.type === 'image'))
  console.log('PASS real MCP connection and exact-frame viewport image')
  await tool('eclipse_playtest', { start: true }, 35000)
  playing = true
  await wait(2000)
  await tool('eclipse_record_playtest', { start: true })
  recording = true
  await json('eclipse_run_export', { name: out.name, operation: 'play' })
  let status
  for (let n = 0; n < 15; n++) {
    await wait(450)
    status = await json('eclipse_run_export', { name: out.name, operation: 'status' })
    assert(!status.error, status.error)
    if (status.markers?.some(marker => marker.name === 'Impact' && marker.frame === 24)) break
  }
  assert(status.markers?.some(marker => marker.name === 'Impact' && marker.frame === 24), JSON.stringify(status))
  console.log('PASS scripted exported cutscene and observed Impact at frame 24', status.status)
  const recorded = await tool('eclipse_record_playtest', { start: false }, 30000)
  recording = false
  assert(recorded.content.length > 0)
  console.log('PASS Studio video recording completion')
  await json('eclipse_run_export', { name: out.name, operation: 'destroy' })
} finally {
  if (recording) await tool('eclipse_record_playtest', { start: false }).catch(() => {})
  if (playing) await tool('eclipse_playtest', { start: false }, 30000)
  await client.close()
}
process.exit()
