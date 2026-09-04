/**
 * Minimal OpenAI Moderations API wrapper for user-authored notes and generated
 * prose. It never logs or includes the classified text in thrown errors.
 *
 * AVAILABILITY POSTURE: this classifier fails OPEN. A moderation outage,
 * timeout, or malformed payload must not take the check-in feature offline —
 * that trades a rare safety improvement for a common, total loss of service.
 * We fail closed only on a decision we actually received. Failing open lands
 * on the pre-existing behavior (no input screening, output guardrails still
 * run) and is logged so outages are visible in Cloud Logging.
 */

import { logger } from "firebase-functions/v2";

export type ContentSafetyDecision = "allow" | "crisis" | "block";

const SELF_HARM_CATEGORIES = [
  "self-harm",
  "self-harm/intent",
  "self-harm/instructions",
] as const;

interface ModerationResultShape {
  flagged?: unknown;
  categories?: unknown;
}

/** Pure result parser, exported for deterministic tests. */
export function classifyModerationResult(
  candidate: unknown,
): ContentSafetyDecision {
  if (!candidate || typeof candidate !== "object") {
    throw new Error("Moderation returned an invalid response");
  }

  const results = (candidate as {results?: unknown}).results;
  if (!Array.isArray(results) || results.length === 0) {
    throw new Error("Moderation returned no results");
  }

  const result = results[0] as ModerationResultShape;
  if (!result || typeof result !== "object" ||
      !result.categories || typeof result.categories !== "object") {
    throw new Error("Moderation returned an invalid result");
  }

  const categories = result.categories as Record<string, unknown>;
  if (SELF_HARM_CATEGORIES.some((name) => categories[name] === true)) {
    return "crisis";
  }
  if (result.flagged === true) {
    return "block";
  }
  if (result.flagged === false) {
    return "allow";
  }
  throw new Error("Moderation omitted the flagged decision");
}

/**
 * Classifies `input`, or returns "allow" if the classifier is unreachable.
 *
 * `stage` identifies the call site ("input" | "output") in logs only — it
 * never carries user content.
 */
export async function moderateText(
  input: string | undefined,
  apiKey: string,
  stage: "input" | "output" = "input",
): Promise<ContentSafetyDecision> {
  if (!input || input.trim() === "") return "allow";

  const requestController = new AbortController();
  const timeout = setTimeout(() => requestController.abort(), 8_000);
  try {
    const response = await fetch("https://api.openai.com/v1/moderations", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "omni-moderation-latest",
        input,
      }),
      signal: requestController.signal,
    });

    if (!response.ok) {
      throw new Error(`Moderation request failed with status ${response.status}`);
    }
    return classifyModerationResult(await response.json());
  } catch (err) {
    // Fail open — see the availability note at the top of this file. Log the
    // error name only; never the classified text or the raw provider error.
    logger.warn("[ContentSafety] Moderation unavailable; allowing content", {
      stage,
      errorName: err instanceof Error ? err.name : "UnknownError",
    });
    return "allow";
  } finally {
    clearTimeout(timeout);
  }
}
