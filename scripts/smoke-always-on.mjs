// In-container check that the BUNDLED @louisremi/dsh-always-on, running on the
// image's OWN Harness filesystem stack and tools, does what it promises and
// refuses what the session's sandbox mode forbids. Run by scripts/smoke.sh
// through `docker exec -i ... node`:
//
//   node --input-type=module - < scripts/smoke-always-on.mjs
//
// It imports the plugin's route handlers from the seeded web profile and the
// Harness's dsh-fs-sandbox / dsh-api-workspace-files from the dsh install,
// wires them as the Harness does, and works over a scratch directory in
// $DSH_HOME (or $SMOKE_DIR; never /tmp: workspace-write deliberately grants
// temp areas). Checks for routes a plugin version does not ship yet are
// skipped by feature detection (save.file: all versions; create/rename/delete
// file: >= 0.4.0; folders, trash, restore, zip: >= 0.5.0). Prints one line
// per check; exits non-zero on the first failure.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import { pathToFileURL } from 'node:url';

const home = process.env.DSH_HOME ?? '/home/node/.dsh';
const dshModules = process.env.DSH_MODULES ?? '/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai';
const plugin = realpathSync(process.env.ALWAYS_ON_DIR ?? join(home, 'profiles/web/node_modules/@louisremi/dsh-always-on'));
const load = (path) => import(pathToFileURL(path).href);
/** A dist module of the plugin, or {} when this version does not ship it. */
const loadPlugin = async (name) => (existsSync(join(plugin, 'dist', name)) ? load(join(plugin, 'dist', name)) : {});

const version = JSON.parse(readFileSync(join(plugin, 'package.json'), 'utf8')).version;
const { handleSave } = await loadPlugin('save-route.js');
const { handleCreateFile, handleCreateFolder } = await loadPlugin('create-route.js');
const routes = await loadPlugin('entry-route.js');
const folders = await loadPlugin('folder-route.js');
const { Context } = await load(join(dshModules, 'cordis/lib/index.js'));
const { SandboxedFileSystem } = await load(join(dshModules, 'dsh-fs-sandbox/lib/index.js'));
const { WorkspaceFiles } = await load(join(dshModules, 'dsh-api-workspace-files/lib/index.js'));

const base = realpathSync(mkdtempSync(join(process.env.SMOKE_DIR ?? home, '.smoke-always-on-')));
// workspace-write grants saves in the temp areas, so an "outside" folder there
// is not outside: refuse to run rather than report a false failure.
for (const temp of new Set(['/tmp', tmpdir()].map((t) => realpathSync(t)))) {
  if (!relative(temp, base).startsWith('..')) {
    rmSync(base, { recursive: true, force: true });
    throw new Error(`the scratch dir ${base} is inside the temp area ${temp}; set SMOKE_DIR elsewhere`);
  }
}
let skipped = 0;
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
    const workspaceFiles = new WorkspaceFiles(ctx, {
      maxBytes: 2 << 20,
      maxFileBytes: 32 << 20,
      maxLines: 5000,
      maxEntries: 2000,
      // Required from dsh 0.2.2-rc.2; ignored before.
      search: { maxResults: 512, maxEntries: 100000, graceMs: 3000, timeoutMs: 30000, stderrMaxBytes: 65536 },
    });
    return {
      fs,
      sandboxPolicy: policy,
      workspaceFiles,
      sessions: { get: (id) => (id === 's' ? { id } : undefined) },
      get: () => undefined,
      // What the download routes read besides fs (unused by the checks here).
      sessionQuery: { readEvent: async () => Promise.reject(new Error('unused')) },
      workspaceChanges: { summary: () => undefined },
    };
  };
  const post = async (handle, mode, route, body) => {
    const res = await handle(
      host(mode),
      new Request(`http://x/api/${route}`, { method: 'POST', body: JSON.stringify({ sessionId: 's', ...body }) }),
    );
    return { status: res.status, body: await res.json().catch(() => undefined) };
  };
  const save = async (mode, body) => (await post(handleSave, mode, 'save.file', body)).status;
  const check = async (name, fn) => {
    await fn();
    console.log(`ok   dsh-always-on@${version}: ${name}`);
  };
  /** Run `fn` only when every handler exists in this plugin version. */
  const checkIf = async (handlers, name, fn) => {
    if (handlers.every((h) => typeof h === 'function')) return check(name, fn);
    skipped++;
    console.log(`skip dsh-always-on@${version}: ${name} (not in this version)`);
  };

  // --- save.file (every version) ---------------------------------------------
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

  // --- create / rename / delete a file (>= 0.4.0) ---------------------------
  const { handleRenameFile, handleDeleteFile, handleRenameFolder, handleDeleteFolder, handleRestore } = routes;
  const W = 'workspace-write';

  await checkIf([handleCreateFile, handleCreateFolder], 'New file / New folder: created in the workspace, never replace, refused outside or read-only', async () => {
    assert.equal((await post(handleCreateFile, W, 'create.file', { directory: workspace, name: 'sub/new.txt' })).status, 201);
    assert.equal(readFileSync(join(workspace, 'sub/new.txt'), 'utf8'), '');
    assert.equal((await post(handleCreateFile, W, 'create.file', { directory: workspace, name: 'a.txt' })).status, 409);
    assert.equal(readFileSync(file, 'utf8'), 'changed elsewhere, longer');
    assert.equal((await post(handleCreateFolder, W, 'create.folder', { directory: workspace, name: 'made' })).status, 201);
    assert.ok(statSync(join(workspace, 'made')).isDirectory());
    assert.equal((await post(handleCreateFile, W, 'create.file', { directory: outside, name: 'x.txt' })).status, 403);
    assert.equal((await post(handleCreateFolder, 'read-only', 'create.folder', { directory: workspace, name: 'ro' })).status, 403);
    assert.ok(!existsSync(join(outside, 'x.txt')) && !existsSync(join(workspace, 'ro')));
  });

  await checkIf([handleRenameFile], 'Rename a file: moves it, never replaces, refused outside, through a symlink or read-only', async () => {
    writeFileSync(join(workspace, 'r.txt'), 'r');
    assert.equal((await post(handleRenameFile, W, 'rename.file', { path: join(workspace, 'r.txt'), destination: 'r2.txt' })).status, 200);
    assert.equal(readFileSync(join(workspace, 'r2.txt'), 'utf8'), 'r');
    assert.equal((await post(handleRenameFile, W, 'rename.file', { path: join(workspace, 'r2.txt'), destination: 'a.txt' })).status, 409);
    assert.equal(readFileSync(file, 'utf8'), 'changed elsewhere, longer');
    assert.equal((await post(handleRenameFile, W, 'rename.file', { path: join(workspace, 'r2.txt'), destination: join(outside, 'r.txt') })).status, 403);
    assert.equal((await post(handleRenameFile, W, 'rename.file', { path: join(workspace, 'escape.txt'), destination: 'e.txt' })).status, 403);
    assert.equal((await post(handleRenameFile, 'read-only', 'rename.file', { path: join(workspace, 'r2.txt'), destination: 'r3.txt' })).status, 403);
    assert.ok(existsSync(join(workspace, 'r2.txt')) && !existsSync(join(outside, 'r.txt')));
  });

  // 0.4.0 deletes for good; 0.5.0 moves to the trash and answers a restore token.
  await checkIf([handleDeleteFile], 'Delete a file: gone from its place, refused outside, through a symlink or read-only', async () => {
    writeFileSync(join(workspace, 'd.txt'), 'd');
    assert.equal((await post(handleDeleteFile, 'read-only', 'delete.file', { path: join(workspace, 'd.txt') })).status, 403);
    assert.equal((await post(handleDeleteFile, W, 'delete.file', { path: join(outside, 'secret.txt') })).status, 403);
    assert.equal((await post(handleDeleteFile, W, 'delete.file', { path: join(workspace, 'escape.txt') })).status, 403);
    assert.equal(readFileSync(join(outside, 'secret.txt'), 'utf8'), 'secret');
    assert.equal((await post(handleDeleteFile, W, 'delete.file', { path: join(workspace, 'd.txt') })).status, 200);
    assert.ok(!existsSync(join(workspace, 'd.txt')));
  });

  // --- folders, trash and restore (>= 0.5.0) ---------------------------------
  const trash = join(workspace, '.tmp', 'deleted');
  await checkIf([handleRenameFolder], "Rename a folder with the image's GNU mv: moves the tree, never replaces even an empty folder", async () => {
    mkdirSync(join(workspace, 'f1/inner'), { recursive: true });
    writeFileSync(join(workspace, 'f1/inner/b.txt'), 'b');
    mkdirSync(join(workspace, 'empty'));
    assert.equal((await post(handleRenameFolder, W, 'rename.folder', { path: join(workspace, 'f1'), destination: 'empty' })).status, 409);
    assert.deepEqual(readdirSync(join(workspace, 'empty')), []);
    const moved = await post(handleRenameFolder, W, 'rename.folder', { path: join(workspace, 'f1'), destination: 'p/f2' });
    assert.equal(moved.status, 200, JSON.stringify(moved.body));
    assert.equal(readFileSync(join(workspace, 'p/f2/inner/b.txt'), 'utf8'), 'b');
    assert.ok(!existsSync(join(workspace, 'f1')));
    assert.equal((await post(handleRenameFolder, W, 'rename.folder', { path: join(workspace, 'p'), destination: 'p/f2/x' })).status, 400);
    assert.equal((await post(handleRenameFolder, W, 'rename.folder', { path: join(workspace, 'p'), destination: join(outside, 'p') })).status, 403);
    assert.equal((await post(handleRenameFolder, W, 'rename.folder', { path: workspace, destination: join(base, 'ws2') })).status, 403);
  });

  await checkIf([handleDeleteFolder, handleRestore], 'Delete a folder to .tmp/deleted/, restore it with its token; the trash and the root are protected', async () => {
    const del = await post(handleDeleteFolder, W, 'delete.folder', { path: join(workspace, 'p') });
    assert.equal(del.status, 200, JSON.stringify(del.body));
    assert.ok(!existsSync(join(workspace, 'p')));
    assert.ok(del.body.trashedPath.startsWith(`${trash}/`), del.body.trashedPath);
    assert.equal(readFileSync(join(del.body.trashedPath, 'f2/inner/b.txt'), 'utf8'), 'b');
    // The token is the session's only: another session gets a 404.
    assert.equal((await post(handleRestore, W, 'restore.entry', { sessionId: 'other', restoreToken: del.body.restoreToken })).status, 404);
    const back = await post(handleRestore, W, 'restore.entry', { restoreToken: del.body.restoreToken });
    assert.equal(back.status, 200, JSON.stringify(back.body));
    assert.equal(readFileSync(join(workspace, 'p/f2/inner/b.txt'), 'utf8'), 'b');
    assert.equal((await post(handleRestore, W, 'restore.entry', { restoreToken: del.body.restoreToken })).status, 404, 'single use');
    // A deleted file goes to the trash too, and can be restored.
    writeFileSync(join(workspace, 't.txt'), 't');
    const gone = await post(handleDeleteFile, W, 'delete.file', { path: join(workspace, 't.txt') });
    assert.equal(gone.status, 200);
    assert.equal(readFileSync(gone.body.trashedPath, 'utf8'), 't');
    assert.equal((await post(handleRestore, W, 'restore.entry', { restoreToken: gone.body.restoreToken })).status, 200);
    assert.equal(readFileSync(join(workspace, 't.txt'), 'utf8'), 't');
    // The trash, a folder holding it, and the workspace root cannot be deleted.
    assert.equal((await post(handleDeleteFolder, W, 'delete.folder', { path: trash })).status, 403);
    assert.equal((await post(handleDeleteFolder, W, 'delete.folder', { path: join(workspace, '.tmp') })).status, 403);
    assert.equal((await post(handleDeleteFolder, W, 'delete.folder', { path: workspace })).status, 403);
    assert.equal((await post(handleDeleteFolder, 'read-only', 'delete.folder', { path: join(workspace, 'p') })).status, 403);
    assert.ok(existsSync(join(workspace, 'p')));
  });

  const { handleDownloadFolder, handleFolderSummary } = folders;
  await checkIf([handleDownloadFolder, handleFolderSummary], 'Download a folder as .zip: a valid archive (unzip -t), symlinks left out and listed', async () => {
    const dir = join(workspace, 'z');
    mkdirSync(join(dir, 'inner'), { recursive: true });
    writeFileSync(join(dir, 'héllo.txt'), 'ünïcode');
    writeFileSync(join(dir, 'inner/big.bin'), Buffer.alloc(1 << 20, 7));
    symlinkSync(join(outside, 'secret.txt'), join(dir, 'leak'));
    const get = (handle) =>
      handle(host(W), new Request(`http://x/api/x?path=${encodeURIComponent(dir)}`));
    const summary = await (await get(handleFolderSummary)).json();
    assert.equal(summary.files, 2);
    assert.equal(summary.downloadable, true);
    const res = await get(handleDownloadFolder);
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'application/zip');
    const zip = join(base, 'z.zip');
    writeFileSync(zip, Buffer.from(await res.arrayBuffer()));
    execFileSync('unzip', ['-tq', zip], { stdio: 'pipe' });
    const listing = execFileSync('unzip', ['-Z1', zip], { encoding: 'utf8' }).split('\n');
    for (const name of ['z/héllo.txt', 'z/inner/big.bin', 'z/DOWNLOAD-SKIPPED.txt']) assert.ok(listing.includes(name), `${name} in ${listing}`);
    assert.ok(!listing.includes('z/leak'), 'the symlink is left out');
    assert.equal(execFileSync('unzip', ['-p', zip, 'z/héllo.txt'], { encoding: 'utf8' }), 'ünïcode');
  });

  if (skipped > 0) console.log(`note dsh-always-on@${version}: ${skipped} check(s) skipped, the pinned version predates them`);
} finally {
  rmSync(base, { recursive: true, force: true });
}
