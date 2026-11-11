// In-container check that the BUNDLED @louisremi/dsh-always-on, running on the
// image's OWN Harness filesystem stack, refuses writes the session's sandbox
// mode forbids. Run by scripts/smoke.sh through `docker exec -i ... node`:
//
//   node --input-type=module - < scripts/smoke-always-on.mjs
//
// It imports the plugin's save handler from the seeded web profile and the
// Harness's dsh-fs-sandbox / dsh-api-workspace-files from the dsh install, wires
// them as the Harness does, and saves over a scratch directory in $DSH_HOME
// (or $SMOKE_DIR; never /tmp: workspace-write deliberately grants temp areas). Prints one
// line per check; exits non-zero on the first failure.
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, statSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const home = process.env.DSH_HOME ?? '/home/node/.dsh';
const dshModules = process.env.DSH_MODULES ?? '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai';
const plugin = realpathSync(process.env.ALWAYS_ON_DIR ?? join(home, 'profiles/web/node_modules/@louisremi/dsh-always-on'));
const load = (path) => import(pathToFileURL(path).href);

const version = JSON.parse(readFileSync(join(plugin, 'package.json'), 'utf8')).version;
const { handleSave } = await load(join(plugin, 'dist/save-route.js'));
const { Context } = await load(join(dshModules, 'cordis/lib/index.js'));
const { SandboxedFileSystem } = await load(join(dshModules, 'dsh-fs-sandbox/lib/index.js'));
const { WorkspaceFiles } = await load(join(dshModules, 'dsh-api-workspace-files/lib/index.js'));

const base = realpathSync(mkdtempSync(join(process.env.SMOKE_DIR ?? home, '.smoke-always-on-')));
try {
  const workspace = join(base, 'workspace');
  const outside = join(base, 'outside');
  mkdirSync(workspace);
  mkdirSync(outside);
  writeFileSync(join(outside, 'secret.txt'), 'secret');
  symlinkSync(join(outside, 'secret.txt'), join(workspace, 'escape.txt'));

  const host = (mode) => {
    const policy = {
      defaultMode: mode,
      workspaceRoot: workspace,
      resolve: ({ session }) => ({ mode, workspaceRoot: workspace, sessionId: session.id }),
    };
    const ctx = new Context();
    ctx.provide('sandboxPolicy', policy);
    const fs = new SandboxedFileSystem(ctx, { cwd: workspace, diffBasisMaxBytes: 1 << 20 });
    const workspaceFiles = new WorkspaceFiles(ctx, { maxBytes: 2 << 20, maxFileBytes: 32 << 20, maxLines: 5000, maxEntries: 2000 });
    return { fs, sandboxPolicy: policy, workspaceFiles, sessions: { get: (id) => (id === 's' ? { id } : undefined) }, get: () => undefined };
  };
  const save = async (mode, body) =>
    (await handleSave(host(mode), new Request('http://x/api/save.file', { method: 'POST', body: JSON.stringify({ sessionId: 's', ...body }) }))).status;
  const check = async (name, fn) => {
    await fn();
    console.log(`ok   dsh-always-on@${version}: ${name}`);
  };

  const file = join(workspace, 'a.txt');
  writeFileSync(file, 'one\r\n');
  const versionOf = async (path) =>
    (await host('workspace-write').workspaceFiles.stat({ sessionId: 's', workspaceRoot: workspace }, path, AbortSignal.timeout(5000))).version;

  await check('workspace-write saves inside the workspace (version-checked, atomic)', async () => {
    assert.equal(await save('workspace-write', { path: 'a.txt', content: 'two\r\n', expectedVersion: await versionOf('a.txt') }), 200);
    assert.equal(readFileSync(file, 'utf8'), 'two\r\n');
  });
  await check('a stale version is refused (409)', async () => {
    const stale = await versionOf('a.txt');
    writeFileSync(file, 'changed elsewhere, longer');
    assert.equal(await save('workspace-write', { path: 'a.txt', content: 'x', expectedVersion: stale }), 409);
    assert.equal(readFileSync(file, 'utf8'), 'changed elsewhere, longer');
  });
  await check('read-only refuses every save (403)', async () => {
    assert.equal(await save('read-only', { path: 'a.txt', content: 'x', force: true }), 403);
    assert.equal(readFileSync(file, 'utf8'), 'changed elsewhere, longer');
  });
  await check('workspace-write refuses paths outside the workspace and symlink escapes', async () => {
    assert.equal(await save('workspace-write', { path: join(outside, 'secret.txt'), content: 'x', force: true }), 403);
    const viaLink = await save('workspace-write', { path: 'escape.txt', content: 'x', force: true });
    assert.ok(viaLink === 403 || viaLink === 404, `escape.txt: ${viaLink}`);
    assert.equal(readFileSync(join(outside, 'secret.txt'), 'utf8'), 'secret');
  });
  await check('directories are never written', async () => {
    assert.equal(await save('workspace-write', { path: workspace, content: 'x', force: true }), 403);
    assert.ok(statSync(workspace).isDirectory());
  });
} finally {
  rmSync(base, { recursive: true, force: true });
}
