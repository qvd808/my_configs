// Run a required check and forward its real result through the normal workflow hooks.
// For clients that do not forward shell tool lifecycle events to the controller.
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { hook } from './runtime.mjs';
import { read, current } from './store.mjs';

const file = process.env.NVIM_WORKFLOW_FILE;
const command = process.argv[2];
if (!file || !command || process.argv.length !== 3) {
  throw new Error('Usage: node check.mjs "exact required check command" with NVIM_WORKFLOW_FILE set');
}
const state = read(file);
const unit = current(state);
if (unit.status !== 'running' || !unit.required_checks.includes(command)) {
  throw new Error('Only a required check of the running unit can be executed');
}
const id = randomUUID();
const input = { sessionId: state.session_id ?? ('check-' + id), toolName: 'bash', toolCallId: id, toolArgs: { command } };
const permission = hook(file, 'pre', input);
if (permission.permissionDecision === 'deny') throw new Error(permission.permissionDecisionReason);
const result = spawnSync('/bin/sh', ['-c', command], {
  cwd: state.cwd, encoding: 'utf8', timeout: 120000,
  env: { ...process.env, APPIMAGE_EXTRACT_AND_RUN: '1' },
});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
const latest = read(file);
if (latest.id !== state.id || current(latest).id !== unit.id || current(latest).attempt !== unit.attempt) {
  throw new Error('Work unit changed during check; result was not recorded');
}
if (result.error || result.status === null) {
  hook(file, 'failure', { ...input, error: result.error?.message ?? 'Check terminated by signal' });
  process.exitCode = 1;
} else {
  hook(file, 'post', { ...input, toolResult: {
    textResultForLlm: `<shellId: ${id} completed with exit code ${result.status}>`,
  } });
  process.exitCode = result.status;
}
