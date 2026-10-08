import { executeScript } from './host.mjs';

// This child process bounds crashes/CPU time; Node vm is NOT a security sandbox.
// The caller must trust installed third-party scripts.
process.once('message', payload => {
  let result;
  try { result = { ok: true, result: executeScript(payload, payload.timeoutMs ?? 18000) }; }
  catch (error) {
    const timeout = error.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT';
    result = { ok: false, error: { code: timeout ? 'SCRIPT_TIMEOUT' : error.code || 'SCRIPT_FAILED', message: error.message,
      status: timeout ? 504 : error.status || 502 } };
  }
  process.send?.(result, () => process.exit(0));
});
