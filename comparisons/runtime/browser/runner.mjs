import {spawn} from 'node:child_process';

const outputLimit = 2048;

function append(output, chunk) {
  return (output + chunk.toString('utf8')).slice(0, outputLimit);
}

function terminateGroup(pid, signal) {
  try {
    process.kill(-pid, signal);
    return true;
  } catch {
    return false;
  }
}

function reapGroup(pid, value, finish) {
  if (process.platform === 'win32' || !terminateGroup(pid, 'SIGTERM')) {
    finish(value);
    return;
  }
  setTimeout(() => {
    terminateGroup(pid, 'SIGKILL');
    finish({...value, runnerCleanup: 'process-group-signalled'});
  }, 250);
}

export function runBounded(command, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? 10000;
  return new Promise((resolveRun) => {
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let settled = false;
    let killTimer;
    const child = spawn(command, args, {
      detached: process.platform !== 'win32',
      env: options.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const finish = (value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      clearTimeout(killTimer);
      resolveRun(value);
    };
    child.stdout.on('data', (chunk) => { stdout = append(stdout, chunk); });
    child.stderr.on('data', (chunk) => { stderr = append(stderr, chunk); });
    child.on('error', () => finish({status: 'error', code: 'PROBE_SPAWN_FAILED'}));
    child.on('close', (code) => {
      if (timedOut) {
        return;
      }
      let result;
      try {
        result = JSON.parse(stdout);
      } catch {
        reapGroup(child.pid, {status: 'error', code: 'PROBE_PROTOCOL_ERROR'}, finish);
        return;
      }
      if (!result || typeof result !== 'object' || typeof result.status !== 'string') {
        reapGroup(child.pid, {status: 'error', code: 'PROBE_PROTOCOL_ERROR'}, finish);
        return;
      }
      if (code !== 0 && result.status === 'ok') {
        reapGroup(child.pid, {status: 'error', code: 'PROBE_PROTOCOL_ERROR'}, finish);
        return;
      }
      reapGroup(child.pid, result, finish);
    });
    const timeout = setTimeout(() => {
      timedOut = true;
      if (process.platform === 'win32') child.kill('SIGTERM');
      else terminateGroup(child.pid, 'SIGTERM');
      killTimer = setTimeout(() => {
        if (process.platform === 'win32') child.kill('SIGKILL');
        else terminateGroup(child.pid, 'SIGKILL');
        finish({status: 'error', code: 'TIMEOUT', cleanup: 'process-group-signalled'});
      }, 250);
    }, timeoutMs);
  });
}
