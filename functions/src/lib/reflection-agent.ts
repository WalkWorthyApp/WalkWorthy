/**
 * Daily Reflection AI Agent for WalkWorthy
 *
 * Generates a short, devotional-style reflection prompt for Christian students
 * based on their mood pattern over the past week.
 */

import { Agent, run, setTracingDisabled } from "@openai/agents";
import { createProviderModel, type ProviderConsentCheck } from "./provider-model";
import { z } from "zod";
import { logger } from "firebase-functions/v2";
import { safeErrorMetadata } from "../shared/safe-logging";
import type { DailyMoodSummary } from "../shared/types";
import {
  MOOD_MODEL,
  MOOD_MODEL_REASONING,
  GuardrailTripError,
  isGuardrailTrip,
  piiGuardrail,
  sleep,
  withTimeout,
  ENCOURAGEMENT_SAFETY_INSTRUCTIONS,
  type GenerationRunner,
} from "./model-config";
import { moderateText } from "./content-safety";

// ============================================================================
// Output Schema
// ============================================================================

const reflectionOutputSchema = z.object({
  reflection: z.string().max(600),
});

// ============================================================================
// System Prompt
// ============================================================================

const REFLECTION_SYSTEM_PROMPT = `${ENCOURAGEMENT_SAFETY_INSTRUCTIONS}
Write a warm daily devotional reflection for a Christian student.

## Your Task
Given a summary of the student's mood check-ins over the past week, write a short reflection prompt (2–3 sentences) that:
1. Acknowledges the emotional tone of their week with genuine empathy
2. Gently invites them to look for God's presence or faithfulness in their experience
3. Ends with a brief reflective question or thought to sit with

## Tone
- Conversational and warm, without pretending to be a person or therapist
- Scripture-adjacent in spirit without quoting specific verses (encouragements elsewhere in the app handle that)
- Specific enough to feel personal, not generic enough to feel like a form letter

## Output
Return a single JSON object: { "reflection": "your 2-3 sentence reflection here" }
No prose, code fences, or explanations outside the JSON.`;

// ============================================================================
// Agent Cache
// ============================================================================

let cachedAgent: Agent<object, typeof reflectionOutputSchema> | undefined;
let cachedApiKey: string | undefined;

function ensureAgent(apiKey: string): Agent<object, typeof reflectionOutputSchema> {
  if (cachedAgent && cachedApiKey === apiKey) return cachedAgent;

  setTracingDisabled(true);
  cachedApiKey = apiKey;

  cachedAgent = new Agent<object, typeof reflectionOutputSchema>({
    name: "WalkWorthyReflectionAgent",
    instructions: REFLECTION_SYSTEM_PROMPT,
    model: createProviderModel(apiKey, MOOD_MODEL),
    // Disable storage of the Responses API response object for this call.
    // Provider abuse-monitoring retention remains governed by the API project.
    modelSettings: { reasoning: MOOD_MODEL_REASONING, maxTokens: 256, store: false },
    outputType: reflectionOutputSchema,
    outputGuardrails: [piiGuardrail],
  });

  return cachedAgent;
}

// ============================================================================
// Input Builder
// ============================================================================

function buildPrompt(summaries: DailyMoodSummary[]): string {
  const weekSummary =
    summaries.length === 0
      ? "No check-ins recorded this week."
      : summaries.map((s) => ({
          date: s.date,
          sentiment: s.overallSentiment ?? "unknown",
          morning: s.morning?.moodLevel ?? null,
          midday: s.midday?.moodLevel ?? null,
          evening: s.evening?.moodLevel ?? null,
        }));

  return JSON.stringify({ weekSummary }, null, 2);
}

// ============================================================================
// Export
// ============================================================================

export interface ReflectionAgentResult {
  reflection: string;
  isGenerated: boolean;
}

export const FIXED_REFLECTION: ReflectionAgentResult = {
  reflection: "Whatever this week has held, you can make room for a quiet moment today. What is one small kindness you could offer yourself or someone around you?",
  isGenerated: false,
};

export async function runReflectionAgent(
  summaries: DailyMoodSummary[],
  apiKey: string,
  checkConsent: ProviderConsentCheck,
  generate: GenerationRunner = async (input, signal) =>
    // Every new model attempt must return through the consent check below.
    (await run(ensureAgent(apiKey), input, { signal, maxTurns: 1 })).finalOutput,
  beforeGeneration?: () => Promise<void>,
): Promise<ReflectionAgentResult> {
  logger.info("[ReflectionAgent] Generating daily reflection", {
    summaryCount: summaries.length,
  });

  const MAX_RETRIES = 2;
  const input = buildPrompt(summaries);
  let lastError: unknown;
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    // Exponential backoff between attempts — first attempt runs immediately.
    if (attempt > 0) {
      const delayMs = 250 * Math.pow(2, attempt);
      logger.info(`[ReflectionAgent] Backing off ${delayMs}ms before retry ${attempt + 1}`);
      await sleep(delayMs);
    }

    // Do not catch authorization/read failures as retryable provider failures.
    await checkConsent();
    // Lets the caller record that provider work has started; sent requests
    // cannot be recalled, so their budget must never be refunded.
    if (beforeGeneration) await beforeGeneration();
    let reflection: string;
    try {
      const result = await withTimeout((signal) =>
        generate(input, signal),
      );
      const output = result;

      const raw =
        typeof output === "string"
          ? JSON.parse(output)
          : output;
      const parsed = reflectionOutputSchema.parse(raw);

      if (parsed.reflection.trim() === "") {
        throw new Error("Empty reflection returned");
      }

      reflection = parsed.reflection.trim();
    } catch (err) {
      lastError = err;
      if (isGuardrailTrip(err)) {
        logger.error("[ReflectionAgent] PII guardrail tripped; not retrying", { attempt: attempt + 1 });
        throw new GuardrailTripError();
      }
      logger.error("[ReflectionAgent] Attempt failed", {
        attempt: attempt + 1,
        ...safeErrorMetadata(err),
      });
      continue;
    }

    // Output moderation is another provider request; recheck consent first.
    await checkConsent();
    const outputSafety = await moderateText(reflection, apiKey, "output");
    if (outputSafety !== "allow") return FIXED_REFLECTION;
    return { reflection, isGenerated: true };
  }

  throw lastError instanceof Error
    ? lastError
    : new Error("ReflectionAgent failed after retries");
}
