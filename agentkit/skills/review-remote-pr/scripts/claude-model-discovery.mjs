#!/usr/bin/env node
// Optional metadata-only model discovery through Claude Code's public Agent SDK.
const installHint = 'Install the optional SDK in an operator-controlled SDK directory with: npm install --ignore-scripts --no-save --package-lock=false --prefix "$HOME/.local/share/agentkit-claude-sdk" @anthropic-ai/claude-agent-sdk; then pass --sdk-dir "$HOME/.local/share/agentkit-claude-sdk"';
const efforts = values => values.filter(x => typeof x === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,30}$/.test(x));
const modelError = /model_not_found|unknown model|invalid model|model not found|model does not exist|model is not supported|model is unavailable|unsupported effort|effort level is not supported/i;

function fail(message) {
  process.stderr.write(`Claude model discovery unavailable: ${message}\n`);
  process.exitCode = 1;
}

function errorClass(error) {
  const name = String(error?.name ?? 'Error');
  return /^[A-Za-z][A-Za-z0-9]{0,39}$/.test(name) ? name : 'Error';
}

async function loadSdk(sdkDir) {
  const { createRequire } = await import('node:module');
  const { realpath } = await import('node:fs/promises');
  const { dirname, isAbsolute, join, relative, sep } = await import('node:path');
  const { fileURLToPath, pathToFileURL } = await import('node:url');
  const helperDir = dirname(fileURLToPath(import.meta.url));
  const root = await realpath(sdkDir || helperDir);
  const requireFromRoot = createRequire(pathToFileURL(join(root, 'package.json')));
  const resolved = await realpath(requireFromRoot.resolve('@anthropic-ai/claude-agent-sdk'));
  const rel = relative(root, resolved);
  if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    const error = new Error('SDK module is outside its authorized directory');
    error.code = 'ERR_AGENTKIT_SDK_OUTSIDE_ROOT';
    throw error;
  }
  return import(pathToFileURL(resolved));
}

async function* pendingPrompt() {
  await new Promise(() => {});
}

async function main(args) {
  const mode = args[0];
  let errorText = '';
  let claudePath = '';
  let sdkDir = '';
  for (let i = 1; i < args.length; i++) {
    if (args[i] === '--claude' && args[i + 1]) claudePath = args[++i];
    else if (args[i] === '--sdk-dir' && args[i + 1]) sdkDir = args[++i];
    else if (mode === '--for-error' && !errorText) errorText = args[i];
    else {
      process.stderr.write('Usage: node claude-model-discovery.mjs --list-models [--claude PATH] [--sdk-dir DIR]\n');
      process.exitCode = 2;
      return;
    }
  }
  if (mode !== '--list-models' && (mode !== '--for-error' || !errorText)) {
    process.stderr.write('Usage: node claude-model-discovery.mjs --list-models [--claude PATH] [--sdk-dir DIR]\n');
    process.exitCode = 2;
    return;
  }
  if (mode === '--for-error' && !modelError.test(errorText)) return;

  let sdk;
  try {
    sdk = await loadSdk(sdkDir);
  } catch (error) {
    if (error?.code === 'ERR_AGENTKIT_SDK_OUTSIDE_ROOT') {
      fail(`the SDK package resolves outside its authorized directory. ${installHint}`);
    } else {
      fail(`the optional Agent SDK is unavailable in its authorized directory (${errorClass(error)}). ${installHint}`);
    }
    return;
  }

  let query;
  let workdir;
  let deadline;
  const abortController = new AbortController();
  try {
    const { mkdtemp, chmod } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    workdir = await mkdtemp(join(tmpdir(), 'agentkit-claude-models-'));
    await chmod(workdir, 0o700);
    query = sdk.query({
      prompt: pendingPrompt(),
      options: {
        tools: [], plugins: [], mcpServers: {}, settingSources: [], permissionMode: 'dontAsk',
        cwd: workdir, ...(claudePath ? { pathToClaudeCodeExecutable: claudePath } : {}),
        extraArgs: { 'safe-mode': null, 'no-session-persistence': null,
          'strict-mcp-config': null, 'no-chrome': null },
        abortController,
      },
    });
    const models = await Promise.race([
      query.supportedModels(),
      new Promise((_, reject) => {
        deadline = setTimeout(() => {
          abortController.abort();
          reject(new Error('Timeout'));
        }, 30000);
      }),
    ]);
    const rows = [];
    if (Array.isArray(models)) for (const model of models) {
      if (typeof model?.value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/.test(model.value)) continue;
      const supported = efforts(Array.isArray(model.supportedEffortLevels) ? model.supportedEffortLevels : []);
      const effort = model.supportsEffort === false ? 'effort unsupported'
        : supported.length ? `effort: ${supported.join(', ')}`
          : model.supportsEffort === true ? 'effort levels unavailable' : 'effort support unavailable';
      const name = typeof model.displayName === 'string'
        ? ` (${model.displayName.replace(/[\x00-\x1f\x7f]/g, ' ').replace(/\s+/g, ' ').slice(0, 100)})` : '';
      rows.push(`  ${model.value}${name} — ${effort}`);
    }
    if (rows.length === 0) {
      fail('the initialized Claude Code session returned no valid model IDs');
      return;
    }
    process.stdout.write('Model selectors reported by this Claude Code session (may be aliases; metadata only; no prompt submitted):\n');
    process.stdout.write(`${rows.join('\n')}\n`);
    process.stdout.write('This list may omit full model IDs. Canonical IDs: https://platform.claude.com/docs/en/about-claude/models/choosing-a-model\n');
    process.stdout.write('GET /v1/models lists API models with separate Anthropic API authentication; it does not establish Claude Code availability.\n');
  } catch (error) {
    fail(`the Claude Code session could not report models (${errorClass(error)}); check Claude Code login, then run node ${process.argv[1]} --list-models --sdk-dir DIR`);
  } finally {
    clearTimeout(deadline);
    query?.close();
    if (workdir) {
      const { rm } = await import('node:fs/promises');
      await rm(workdir, { recursive: true, force: true });
    }
  }
}

await main(process.argv.slice(2));
