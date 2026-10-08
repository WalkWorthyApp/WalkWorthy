/**
 * Minimal OpenAI Moderations API wrapper for user-authored notes and generated
 * prose. It never logs or includes the classified text in thrown errors.
 *
 * An outage is a distinct result, never an approval or an inference about the
 * user. Callers keep encouragement available through human-written fallbacks.
 */

import { logger } from "firebase-functions/v2";
import { safeErrorMetadata } from "../shared/safe-logging";

export type ContentSafetyDecision = "allow" | "crisis" | "block" | "unavailable";

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
      !result.categories || typeof result.categories !== "object" ||
      Array.isArray(result.categories)) {
    throw new Error("Moderation returned an invalid result");
  }

  const categories = result.categories as Record<string, unknown>;
  if (SELF_HARM_CATEGORIES.some((name) => categories[name] === true)) {
    return "crisis";
  }
  if (result.flagged === true) {
    return "block";
  }
  if (result.flagged === false &&
      SELF_HARM_CATEGORIES.every((name) => categories[name] === false) &&
      Object.entries(categories).every(([name, value]) =>
        value === false ||
        // The provider schema permits null only for these two categories.
        (value === null && (name === "illicit" || name === "illicit/violent")))) {
    return "allow";
  }
  throw new Error("Moderation omitted the flagged decision");
}

/**
 * Classifies `input`, or returns "unavailable" if screening cannot complete.
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
    logger.warn("[ContentSafety] Moderation unavailable; using fixed content", {
      stage,
      ...safeErrorMetadata(err),
    });
    return "unavailable";
  } finally {
    clearTimeout(timeout);
  }
}
