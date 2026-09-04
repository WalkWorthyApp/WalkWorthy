/**
 * Identifies which backend build is actually serving traffic.
 *
 * WHY THIS EXISTS: `firebase deploy` skips functions whose uploaded source
 * hash is already on record — it reports "No changes detected" and leaves the
 * previously built containers running. That has bitten this project before
 * (see the April 2026 rate-limit deploy, where Cloud Build failed after the
 * source hash was recorded, so every later deploy silently skipped and
 * production kept running pre-rate-limit code).
 *
 * The failure is silent and the CLI reports success, so the only reliable
 * check is an observable marker in the running code. This value is attached to
 * the mood check-in log line: query Cloud Logging for `functionsRevision` and
 * you know exactly which build answered, rather than trusting the deploy
 * output.
 *
 * Bump this whenever backend behavior changes. Changing it also alters the
 * source hash, which is what forces a real rebuild rather than a skip.
 */
export const FUNCTIONS_REVISION = "2026-09-04-ai-safety-catalog-retry";
