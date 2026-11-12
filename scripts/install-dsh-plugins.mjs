#!/usr/bin/env node
// Build the image's seed `web` profile (run by the Dockerfile as `node`).
//
//   node install-dsh-plugins.mjs <tools/dsh-plugins/package.json>
//
// 1. Pin the pnpm store inside the Harness home (storeDir in the profile's
//    pnpm-workspace.yaml), so later `dsh plugin add` runs, and the Plugins
//    page, keep using the store that was seeded with the profile.
// 2. For every plugin, check its DSH peer ranges against the runtime exactly
//    as dsh does (semver, prereleases included). An incompatible plugin that
//    starts disabled gets an exact-version exemption; an incompatible enabled
//    plugin fails the build. (Granted below with `dsh plugin allow-version
//    ... --accept-risk`, dsh's own name for the exemption.)
// 3. Install everything with dsh's own `dsh plugin --profile web add`.
// 4. Deselect the plugins that start disabled (they stay installed).
// 5. Assert the result.
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, existsSync, appendFileSync } from 'node:fs'
import { join } from 'node:path'
import { createRequire } from 'node:module'

// `semver` comes from dsh's own tree (dsh-app-boot declares it), not from the
// private copy npm bundles under /usr/local/lib/node_modules/npm, which npm is
// free to move or drop. DSH_MODULES is the Dockerfile ARG that already points
// into dsh's modules; two levels up is the `@deepseek-ai/dsh` package itself.
const dshModules = process.env.DSH_MODULES
  ?? '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai'
const semver = createRequire(join(dshModules, '..', '..', 'package.json'))('semver')

const listPath = process.argv[2]
if (!listPath) throw new Error('usage: install-dsh-plugins.mjs <plugins package.json>')
const list = JSON.parse(readFileSync(listPath, 'utf8'))
const plugins = Object.entries(list.dependencies ?? {})
const enabled = new Set(list.dshPlugins?.enabled ?? [])
const home = process.env.DSH_HOME
if (!home) throw new Error('DSH_HOME must be set')
const profile = join(home, 'profiles', 'web')
const store = join(home, 'pnpm-store')

const fail = (message) => { console.error(`PLUGIN GUARD: ${message}`); process.exit(1) }
const dsh = (...args) => execFileSync('dsh', args, { stdio: ['ignore', 'inherit', 'inherit'] })
const runtime = execFileSync('dsh', ['--version'], { encoding: 'utf8' }).trim()

if (plugins.length === 0) fail('no plugins listed')
for (const name of enabled) if (!list.dependencies[name]) fail(`enabled plugin ${name} is not listed in dependencies`)
for (const [name, version] of plugins) if (!semver.valid(version)) fail(`${name}: '${version}' is not an exact version`)

// 1. Initialize the profile (any harmless pnpm command does), then pin the store.
dsh('plugin', '--profile', 'web', 'config', 'get', 'store-dir')
const workspace = join(profile, 'pnpm-workspace.yaml')
if (!existsSync(workspace)) fail(`${workspace} was not created by dsh plugin`)
if (/^storeDir:/m.test(readFileSync(workspace, 'utf8'))) fail(`${workspace} already sets storeDir`)
appendFileSync(workspace, `# Pinned by deepseek-harness-augmented: the store lives in the Harness home.\nstoreDir: ${store}\n`)

// 2. Compatibility, as dsh's own admission check computes it.
const exemptions = []
for (const [name, version] of plugins) {
  const peers = JSON.parse(execFileSync('npm', ['view', `${name}@${version}`, 'peerDependencies', '--json'],
    { encoding: 'utf8', cwd: profile }) || '{}') ?? {}
  const bad = Object.entries(peers).filter(([peer, range]) =>
    (peer === '@deepseek-ai/dsh' || peer.startsWith('@deepseek-ai/dsh-'))
    && (range.trim() === '' || !semver.satisfies(runtime, range, { includePrerelease: true })))
  if (bad.length === 0) continue
  const detail = bad.map(([peer, range]) => `${peer}@"${range}"`).join(', ')
  if (enabled.has(name)) fail(`${name}@${version} is enabled by default but incompatible with dsh ${runtime}: ${detail}`)
  console.log(`PLUGIN NOTICE: ${name}@${version} declares DSH peers that exclude ${runtime} (${detail}); it ships disabled with an exact-version exemption`)
  dsh('plugin', '--profile', 'web', 'allow-version', `${name}@${version}`, '--dsh-version', runtime, '--accept-risk')
  exemptions.push(`${name}@${version}`)
}

// 3. Install.
dsh('plugin', '--profile', 'web', 'add', ...plugins.map(([name, version]) => `${name}@${version}`))

// 4. Deselect the disabled ones; keep every other bundle in its order.
const manifestPath = join(profile, 'package.json')
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
const bundles = manifest.dsh?.profile?.bundles
if (!Array.isArray(bundles)) fail(`${manifestPath} has no dsh.profile.bundles`)
manifest.dsh.profile.bundles = bundles.filter((name) => !list.dependencies[name] || enabled.has(name))
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n')

// The container owns the dsh lifecycle (tini -> entrypoint -> dsh): the
// market's one-click restart would stop the container instead (upstream's
// -market image sets the same). The profile patch is the user's layer, so they
// can drop this. While the market is deselected dsh logs one harmless
// `patch: entry "dsh-market" not found` line per boot.
const patchPath = join(profile, 'cordis.patch.yml')
const patch = readFileSync(patchPath, 'utf8')
if (list.dependencies.dshmarket) {
  if (!/^\[\]\s*$/m.test(patch)) fail(`${patchPath} is not the empty template dsh writes`)
  writeFileSync(patchPath, patch.replace(/^\[\]\s*$/m, [
    '# Seeded by deepseek-harness-augmented. The container owns the Harness',
    '# lifecycle, so the market\'s one-click restart is off (restart the container',
    '# instead). Harmless "entry not found" warning while dshmarket is switched off.',
    '- id: dsh-market',
    '  config:',
    '    allowRestart: false',
    '',
  ].join('\n')))
}

// 5. Assert.
const after = JSON.parse(readFileSync(manifestPath, 'utf8'))
for (const [name, version] of plugins) {
  if (after.dependencies?.[name] !== version) fail(`${manifestPath} does not pin ${name}@${version}`)
  const installed = JSON.parse(readFileSync(join(profile, 'node_modules', name, 'package.json'), 'utf8'))
  if (installed.version !== version) fail(`${name}: installed ${installed.version}, expected ${version}`)
  if (!installed.dsh?.bundle?.patch) fail(`${name} is not a dsh bundle`)
  if (after.dsh.profile.bundles.includes(name) !== enabled.has(name)) fail(`${name} selection is not ${enabled.has(name) ? 'enabled' : 'disabled'}`)
}
for (const base of ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-web-app']) {
  if (!after.dsh.profile.bundles.includes(base)) fail(`template bundle ${base} missing from the seed profile`)
}
if (!readFileSync(join(profile, 'node_modules', '.modules.yaml'), 'utf8').includes(`storeDir: ${store}`)) {
  fail(`profile node_modules is not linked to ${store}`)
}
console.log(`seed web profile ready (dsh ${runtime}): bundles=${JSON.stringify(after.dsh.profile.bundles)} exemptions=${JSON.stringify(exemptions)}`)
