import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { RuntimeError } from './errors.mjs';

const workerPath = fileURLToPath(new URL('./worker.mjs', import.meta.url));

export function runScript(payload, { timeoutMs = 20000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = fork(workerPath, [], { windowsHide: true,
      execArgv: ['--max-old-space-size=192'], stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
    let complete = false;
    let outputBytes = 0;
    const finish = (error, result) => {
      if (complete) return;
      complete = true;
      clearTimeout(timer);
      child.kill();
      if (error) reject(error); else resolve(result);
    };
    const timer = setTimeout(() => finish(new RuntimeError('SCRIPT_TIMEOUT', 'Extension script exceeded its execution deadline.', 504)), timeoutMs);
    const capOutput = chunk => {
      outputBytes += chunk.length;
      if (outputBytes > 1024 * 1024) finish(new RuntimeError('EXECUTION_LIMIT', 'Extension process output limit exceeded.'));
    };
    child.stdout.on('data', capOutput);
    child.stderr.on('data', capOutput);
    child.once('error', error => finish(new RuntimeError('WORKER_FAILED', error.message, 500)));
    child.once('exit', (code, signal) => {
      if (!complete) finish(new RuntimeError('WORKER_FAILED', `Extension process exited (${code ?? signal}).`, 502));
    });
    child.once('message', message => {
      if (!message?.ok) finish(new RuntimeError(message?.error?.code || 'SCRIPT_FAILED', message?.error?.message || 'Execution failed.', message?.error?.status || 502));
      else finish(null, message.result);
    });
    child.send({ ...payload, timeoutMs: Math.max(1, Math.min(18000, timeoutMs - 200)) });
  });
}
