import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'

const nativeCommand = '/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP'
let connection
let selectedStudio

export function selectStudio(id) {
  selectedStudio = id
}

export function currentStudio() {
  if (!selectedStudio) throw new Error('Select a Studio ID with eclipse_select_studio first.')
  return selectedStudio
}

export function studioOptions() {
  if (process.env.ECLIPSE_STUDIO_COMMAND) return { command: process.env.ECLIPSE_STUDIO_COMMAND, args: [] }
  if (process.platform === 'win32') {
    return { command: 'cmd.exe', args: ['/c', String.raw`%LOCALAPPDATA%\Roblox\mcp.bat`] }
  }
  if (process.platform === 'darwin') return { command: nativeCommand, args: [] }
  throw new Error('Set ECLIPSE_STUDIO_COMMAND to your Roblox Studio MCP executable.')
}

async function connect() {
  if (!connection) {
    const client = new Client({ name: 'eclipse-animator-native', version: '1.0.0' })
    const transport = new StdioClientTransport({ ...studioOptions(), stderr: 'ignore' })
    client.onclose = () => { connection = undefined }
    connection = client.connect(transport).then(() => client).catch(error => {
      connection = undefined
      throw error
    })
  }
  return connection
}

function getText(result) {
  return (result.content ?? []).filter(block => block.type === 'text').map(block => block.text).join('\n')
}

export async function studioTool(name, args, timeout = 120_000) {
  const client = await connect()
  const result = await client.callTool({ name, arguments: args }, undefined, { timeout })
  if (result.isError) throw new Error(getText(result) || 'Roblox Studio tool failed.')
  return result
}

export function readResult(result) {
  if (result.structuredContent) return result.structuredContent
  const output = getText(result)
  try { return JSON.parse(output) } catch {
    throw new Error(output || 'Roblox Studio returned no result.')
  }
}

export async function listStudios() {
  const result = readResult(await studioTool('list_roblox_studios', {}))
  return Array.isArray(result) ? result : result.studios ?? result.places ?? []
}

export function luauLiteral(data) {
  const json = JSON.stringify(data)
  if (!json || Buffer.byteLength(json) > 2_000_000) throw new Error('Studio request exceeds the maximum payload.')
  let level = ''
  while (json.includes(']' + level + ']')) level += '='
  return '[' + level + '[' + json + ']' + level + ']'
}

const nativeDispatch = `
local registry = game:GetService("CoreGui"):FindFirstChild("EclipseAnimatorAPI")
assert(registry, "Eclipse editor API unavailable. Load the Eclipse Animator AI bundle in this Studio window.")
local candidates = {}
for _, child in registry:GetChildren() do
  if child:IsA("BindableFunction") and child:GetAttribute("APIVersion") == 6
    and (payload.endpoint == nil or child.Name == payload.endpoint) then
    table.insert(candidates, child)
  end
end
assert(#candidates == 1, "Expected one Eclipse API v6 endpoint. Close duplicate Eclipse builds or specify the endpoint.")
local endpoint = candidates[1]
if payload.action == "GetInfo" then
  local response = endpoint:Invoke("GetInfo", {})
  response.Endpoint = endpoint.Name
  response.McpVersion = endpoint:GetAttribute("McpVersion") or 0
  return http:JSONEncode(response)
end
assert(endpoint:GetAttribute("McpVersion") == 1, "This operation requires the Eclipse Animator AI bundle")
return http:JSONEncode(endpoint:Invoke("McpRequest", { Action = payload.action, Request = payload.request }))
`

export function studioCode(payload, mode = 'native') {
  const header = 'local http = game:GetService("HttpService")\nlocal payload = http:JSONDecode(' + luauLiteral(payload) + ')\n'
  if (mode === 'clip') {
    return header + `
local endpoint = game:GetService("CoreGui"):FindFirstChild("EclipseAnimatorClipAPI")
assert(endpoint and endpoint:IsA("BindableFunction"), "The clip bridge is unavailable in this Studio window")
return http:JSONEncode(endpoint:Invoke(payload.action, payload.request))
`
  }
  return header + nativeDispatch
}

async function execute(studioId, code, timeout) {
  const result = readResult(await studioTool('execute_luau', {
    studio_id: studioId,
    datamodel_type: 'Edit',
    code
  }, timeout))
  const payload = typeof result === 'string' ? JSON.parse(result) : result
  if (payload.ok !== true) throw new Error(payload.error ?? 'Eclipse did not return a successful result.')
  return payload
}

export async function callNative(studioId, action, request = {}, endpoint) {
  const payload = await execute(studioId ?? currentStudio(), studioCode({ action, request, endpoint }))
  if (action === 'GetInfo') {
    return { ...payload.result, endpoint: payload.Endpoint, mcpVersion: payload.McpVersion }
  }
  return payload.result
}

export async function callClip(action, request, seconds = 30) {
  const studioId = currentStudio()
  const response = await execute(studioId, studioCode({ action, request }, 'clip'), seconds * 1000)
  return response.result
}
