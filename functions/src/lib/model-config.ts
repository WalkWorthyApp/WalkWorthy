/**
 * Shared OpenAI model configuration for all WalkWorthy agents.
 *
 * Centralizing the model constant here makes future upgrades (e.g., swapping
 * to a newer model) a one-line change instead of hunting across agent files.
 */

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
