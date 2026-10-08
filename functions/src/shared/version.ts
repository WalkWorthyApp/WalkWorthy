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
 * check is an observable marker in the running code. EVERY endpoint logs this
 * on invocation as `revision`: query Cloud Logging and you know exactly which
 * build answered each function, rather than trusting the deploy output. It is
 * logged everywhere and not just on one endpoint because functions are skipped
 * individually — one endpoint reporting the new build proves nothing about the
 * other five.
 *
 * Bump this whenever backend behavior changes. Changing it also alters the
 * source hash, which is what forces a real rebuild rather than a skip.
 */
export const FUNCTIONS_REVISION = "2026-09-10-moderation-consent-limits";
