import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

test('optional graphics capabilities, failures and workflow selection retain text', () => {
  const result = spawnSync('nvim', ['--headless', '-u', 'NONE', '-l', 'nvim/copilot-workflow/graphics.test.lua'], {
    encoding: 'utf8', timeout: 30000, env: { ...process.env, APPIMAGE_EXTRACT_AND_RUN: '1' },
  });
  assert.equal(result.status, 0, result.error?.message ?? result.stderr + result.stdout);
});
