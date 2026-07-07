/**
 * Shared OpenAI model configuration for all WalkWorthy agents.
 *
 * Centralizing the model constant here makes future upgrades (e.g., swapping
 * to a newer model) a one-line change instead of hunting across agent files.
 */

import { logger } from "firebase-functions/v2";

/** Default model used by mood-agent and reflection-agent. */
export const MOOD_MODEL = "gpt-4.1-nano" as const;

/** Per-agent request timeout in milliseconds. */
export const AGENT_TIMEOUT_MS = 15000;

/**
 * Error thrown when an agent call exceeds AGENT_TIMEOUT_MS.
 * Distinct class so callers (or future retry logic) can discriminate timeouts
 * from other failure modes.
 */
export class AgentTimeoutError extends Error {
  constructor(message = "Agent call timed out") {
    super(message);
    this.name = "AgentTimeoutError";
  }
}

/**
 * Error thrown when the PII output guardrail trips. Deterministic — callers
 * MUST NOT retry.
 */
export class GuardrailTripError extends Error {
  constructor(message = "PII guardrail triggered on agent output") {
    super(message);
    this.name = "GuardrailTripError";
  }
}

// ============================================================================
// PII Guardrail
// ============================================================================

// Phone pattern: optional country code, then phone-like 3-3-4 digit grouping.
// The mandatory 3-digit groups keep it from matching verse references
// ("Philippians 4:6-7") and ISO dates/timestamps ("2026-07-05T18:00:00Z"),
// whose digit runs are 1-2 or 4 digits — see guardrails.test.ts.
const PII_REGEX =
  /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|https?:\/\/\S+|(AKIA|ASI|SK|PK)[A-Z0-9]{16,}|(?:\+?\d{1,3}[-. ]?)?\(?\d{3}\)?[-. ]?\d{3}[-. ]?\d{4}/gi;

/**
 * Returns true when `text` contains an email address, URL, credential-shaped
 * string, or phone number. Exported for unit testing; the guardrail below is
 * the production consumer.
 */
export function containsPii(text: string): boolean {
  const triggered = PII_REGEX.test(text);
  PII_REGEX.lastIndex = 0;
  return triggered;
}

/**
 * Output guardrail that trips when agent output contains email addresses,
 * URLs, phone numbers, or credential-shaped strings. Shared by mood-agent
 * and reflection-agent — `agentOutput` is `unknown` so it works with any
 * output schema; the check just scans the serialized output.
 */
export const piiGuardrail = {
  name: "pii_filter",
  execute: async (args: { agentOutput: unknown }) => {
    const triggered = containsPii(JSON.stringify(args.agentOutput));
    return {
      tripwireTriggered: triggered,
      outputInfo: triggered ? { reason: "Sensitive data detected" } : undefined,
    };
  },
};

/**
 * Throws GuardrailTripError when the serialized agent output contains any of
 * the user's profile values verbatim (case-insensitive whole-word match).
 * Complements the regex guardrail above, which cannot know user-specific
 * strings like occupation or hobbies. Values shorter than 4 characters are
 * skipped to avoid tripping on incidental substrings. Never logs the matched
 * values themselves — only counts and lengths.
 */
export function assertNoProfileEcho(
  output: unknown,
  profileValues: readonly string[],
): void {
  const haystack = JSON.stringify(output ?? null);
  const matchedLengths: number[] = [];
  for (const value of profileValues) {
    if (typeof value !== "string") continue;
    const needle = value.trim();
    if (needle.length < 4) continue;
    // Whole-word match so e.g. gender "Male" can't trip on "female" and a
    // value can't match inside an unrelated longer word. \b only works
    // against word-character edges, so skip it where the value starts/ends
    // with symbols (e.g. "C++ (competitive)").
    const escaped = needle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const lead = /^\w/.test(needle) ? "\\b" : "";
    const trail = /\w$/.test(needle) ? "\\b" : "";
    if (new RegExp(`${lead}${escaped}${trail}`, "i").test(haystack)) {
      matchedLengths.push(needle.length);
    }
  }
  if (matchedLengths.length > 0) {
    logger.warn("Profile echo detected in agent output; blocking response", {
      matchedCount: matchedLengths.length,
      matchedLengths,
    });
    throw new GuardrailTripError("Agent output echoed profile data");
  }
}

/**
 * Sleep for the given number of milliseconds.
 */
export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Races an agent run against a timeout, aborting the underlying OpenAI call
 * when the timeout fires so we don't burn quota on work nobody's waiting for.
 *
 * The caller passes a factory `makeRun(signal)` that threads the `AbortSignal`
 * into `run(agent, input, { signal })`. If the timeout fires first, the
 * controller aborts and the SDK stops the in-flight request; the returned
 * promise rejects with `AgentTimeoutError` regardless.
 */
export function withTimeout<T>(
  makeRun: (signal: AbortSignal) => Promise<T>,
  ms: number = AGENT_TIMEOUT_MS,
): Promise<T> {
  const controller = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new AgentTimeoutError(`Agent call timed out after ${ms}ms`));
    }, ms);
    // Don't keep the event loop alive just for this timer
    if (typeof (timer as NodeJS.Timeout).unref === "function") (timer as NodeJS.Timeout).unref();
  });
  return Promise.race([makeRun(controller.signal), timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

/**
 * Detects whether an error came from the agent output guardrail tripping.
 * The @openai/agents SDK throws `OutputGuardrailTripwireTriggered` where
 * `tripwireTriggered` lives on `err.result.tripwireTriggered` — we check that
 * first, and fall back to error name/message matching for defensive coverage.
 */
export function isGuardrailTrip(err: unknown): boolean {
  if (!err) return false;
  if (err instanceof GuardrailTripError) return true;
  const anyErr = err as { result?: { tripwireTriggered?: unknown }; name?: string; message?: string };
  if (anyErr?.result?.tripwireTriggered === true) return true;
  const name = typeof anyErr?.name === "string" ? anyErr.name : "";
  if (/OutputGuardrail/i.test(name)) return true;
  const msg = typeof anyErr?.message === "string" ? anyErr.message.toLowerCase() : "";
  return msg.includes("guardrail") && msg.includes("trip");
}
