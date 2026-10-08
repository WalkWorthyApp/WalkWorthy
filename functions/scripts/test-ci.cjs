// CI must run all integration tests, never silently skip them without Firestore.
const { spawnSync } = require('node:child_process');

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  console.error('FIRESTORE_EMULATOR_HOST is required. Run test:ci through firebase emulators:exec.');
  process.exit(1);
}
const result = spawnSync(process.execPath, ['--test', '--test-reporter=tap', 'lib/test/*.test.js'], {
  encoding: 'utf8',
  maxBuffer: 10 * 1024 * 1024,
});
process.stdout.write(result.stdout || '');
process.stderr.write(result.stderr || '');
if (result.error || result.status !== 0) process.exit(result.status || 1);
const skipped = result.stdout.match(/^# skipped (\d+)$/m);
if (!skipped || Number(skipped[1]) !== 0) {
  console.error('CI requires a complete test run with zero skipped tests.');
  process.exit(1);
}
