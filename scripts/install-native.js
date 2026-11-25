import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url))
const source = process.argv[2]
const home = os.homedir()
const serverName = 'eclipse-animator-native'
const serverFile = path.join(root, 'server.js')
const env = { ECLIPSE_STUDIO_TRANSPORT: '1' }
const entry = { command: process.execPath, args: [serverFile], env }
const mac = process.platform === 'darwin'
const windows = process.platform === 'win32'
const stamp = new Date().toISOString().replaceAll(':', '-')

function writeJson(file, data) {
  const temporary = file + '.eclipse-tmp'
  try {
    const mode = existsSync(file) ? statSync(file).mode & 0o777 : 0o600
    writeFileSync(temporary, JSON.stringify(data, null, 2) + '\n', { mode })
    renameSync(temporary, file)
  } catch (error) {
    throw new Error('Could not write ' + file, { cause: error })
  }
}

function addDesktop(directory) {
  if (!existsSync(directory)) return
  const file = path.join(directory, 'claude_desktop_config.json')
  const config = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {}
  const prior = config.mcpServers?.[serverName]
  if (JSON.stringify(prior) === JSON.stringify(entry)) {
    console.log('Claude Desktop already registered')
    return
  }
  if (existsSync(file)) copyFileSync(file, file + '.eclipse-backup-' + stamp)
  config.mcpServers = { ...config.mcpServers, [serverName]: entry }
  writeJson(file, config)
  const installed = JSON.parse(readFileSync(file, 'utf8')).mcpServers[serverName]
  if (installed.args[0] !== serverFile) throw new Error('Claude Desktop registration readback failed.')
  console.log('Registered Claude Desktop')
}

function checkCommand(command) {
  try { execFileSync(command, ['--version'], { stdio: 'ignore' }); return true } catch { return false }
}

function addCli(command, profile) {
  const launchEnv = { ...process.env, ...(profile ? { CLAUDE_CONFIG_DIR: profile } : {}) }
  const options = { env: launchEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }
  const isClaude = command === 'claude'
  let prior = ''
  try { prior = execFileSync(command, ['mcp', 'get', serverName], options) } catch {}
  const label = isClaude ? 'Claude Code ' + (profile ? path.basename(profile) : 'default') : 'Codex'
  if (prior.includes(serverFile)) {
    console.log(label + ' already registered')
    return
  }
  if (prior.trim()) {
    console.log(label + ' already has an entry under this name. Preserved its configuration.')
    process.exitCode = 1
    return
  }
  const flags = isClaude ? ['--scope', 'user', '--env', 'ECLIPSE_STUDIO_TRANSPORT=1'] : ['--env', 'ECLIPSE_STUDIO_TRANSPORT=1']
  const backupCandidates = isClaude
    ? [path.join(profile ?? home, '.claude.json'), ...(!profile ? [path.join(home, '.claude', '.claude.json')] : [])]
    : [path.join(process.env.CODEX_CONFIG_DIR || path.join(home, '.codex'), 'config.toml')]
  for (const file of backupCandidates) {
    if (existsSync(file)) copyFileSync(file, file + '.eclipse-backup-' + stamp)
  }
  execFileSync(command, ['mcp', 'add', serverName, ...flags, '--', process.execPath, serverFile], options)
  console.log('Registered ' + label)
}

if (source) {
  if (!mac && !windows) throw new Error('Unsupported Studio plugin destination.')
  const directory = windows
    ? path.join(process.env.LOCALAPPDATA, 'Roblox', 'Plugins')
    : path.join(home, 'Documents', 'Roblox', 'Plugins')
  const destination = path.join(directory, 'Eclipse Animator AI v1.0979.rbxm')
  mkdirSync(directory, { recursive: true })
  if (existsSync(destination) && !readFileSync(destination).equals(readFileSync(source))) {
    const backups = path.join(root, 'local-backups')
    mkdirSync(backups, { recursive: true })
    copyFileSync(destination, path.join(backups, 'Eclipse Animator AI v1.0979.' + stamp + '.rbxm'))
  }
  if (path.resolve(source) !== destination) copyFileSync(source, destination)
  console.log('Installed the single Studio plugin')
}

if (mac) addDesktop(path.join(home, 'Library', 'Application Support', 'Claude'))
if (windows) addDesktop(path.join(process.env.APPDATA, 'Claude'))
if (checkCommand('claude')) {
  addCli('claude')
  if (process.env.ECLIPSE_CLAUDE_PROFILE && existsSync(process.env.ECLIPSE_CLAUDE_PROFILE)) addCli('claude', process.env.ECLIPSE_CLAUDE_PROFILE)
}
if (checkCommand('codex')) addCli('codex')
console.log('Restart existing AI sessions to load the new server registration.')
