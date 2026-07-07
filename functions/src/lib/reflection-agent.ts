/**
 * Daily Reflection AI Agent for WalkWorthy
 *
 * Generates a short, devotional-style reflection prompt for Christian students
 * based on their mood pattern over the past week.
 */

import { Agent, run } from "@openai/agents";
import { setDefaultOpenAIKey, setOpenAIAPI } from "@openai/agents-openai";
import { z } from "zod";
import { logger } from "firebase-functions/v2";
import type { DailyMoodSummary } from "../shared/types";
import {
  collectProfileValues,
  sanitizeProfile,
  type UserProfilePayload,
} from "./profile-sanitize";
import {
  MOOD_MODEL,
  GuardrailTripError,
  assertNoProfileEcho,
  isGuardrailTrip,
  piiGuardrail,
  sleep,
  withTimeout,
} from "./model-config";

// ============================================================================
// Output Schema
// ============================================================================

const reflectionOutputSchema = z.object({
  reflection: z.string().max(600),
});

// ============================================================================
// System Prompt
// ============================================================================

const REFLECTION_SYSTEM_PROMPT = `You are a warm, faith-grounded friend writing a daily devotional reflection for a Christian student.

## Your Task
Given a summary of the student's mood check-ins over the past week, write a short reflection prompt (2–3 sentences) that:
1. Acknowledges the emotional tone of their week with genuine empathy
2. Gently invites them to look for God's presence or faithfulness in their experience
3. Ends with a brief reflective question or thought to sit with

## Tone
- Conversational and warm — like a trusted friend, not a pastor or therapist
- Scripture-adjacent in spirit without quoting specific verses (encouragements elsewhere in the app handle that)
- Specific enough to feel personal, not generic enough to feel like a form letter

## Using the User Profile (SUBTLE CONTEXT ONLY)
You may receive a "profile" object with optional fields: ageRange, occupation, major, gender, hobbies. Treat this as SILENT CONTEXT that shapes TONE and IMAGERY — never as material to name or list back.

**DO:**
- Let ageRange, occupation/major, and hobbies inform your word choice and the season-of-life texture of your reflection (e.g., "a week of long study hours" vs. "a week of meeting after meeting").
- Choose resonant imagery without announcing it.

**DON'T:**
- Name-drop hobbies, major, occupation, gender, or age.
- List the user's profile back to them.
- Refer to the user by an identity label ("Hey engineer,", "As a student…").

If the profile is null or empty, fall back to neutral, universally-applicable warmth.

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

  setDefaultOpenAIKey(apiKey);
  setOpenAIAPI("responses");
  cachedApiKey = apiKey;

  cachedAgent = new Agent<object, typeof reflectionOutputSchema>({
    name: "WalkWorthyReflectionAgent",
    instructions: REFLECTION_SYSTEM_PROMPT,
    model: MOOD_MODEL,
    // Zero Data Retention — see mood-agent.ts for rationale. OpenAI does not
    // persist the request/response after generation; privacy-policy claim.
    modelSettings: { temperature: 0.6, topP: 1, maxTokens: 256, store: false },
    outputType: reflectionOutputSchema,
    outputGuardrails: [piiGuardrail],
  });

  return cachedAgent;
}

// ============================================================================
// Input Builder
// ============================================================================

function buildPrompt(
  summaries: DailyMoodSummary[],
  profile: UserProfilePayload | null,
): string {
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

  return JSON.stringify(
    { profile: sanitizeProfile(profile), weekSummary },
    null,
    2,
  );
}

// ============================================================================
// Export
// ============================================================================

export async function runReflectionAgent(
  summaries: DailyMoodSummary[],
  apiKey: string,
  profile: UserProfilePayload | null = null,
): Promise<string> {
  logger.info("[ReflectionAgent] Generating daily reflection", {
    summaryCount: summaries.length,
    hasProfile: profile !== null,
  });

  const agent = ensureAgent(apiKey);
  const input = buildPrompt(summaries, profile);

  const MAX_RETRIES = 2;
  let lastError: unknown;
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    // Exponential backoff between attempts — first attempt runs immediately.
    if (attempt > 0) {
      const delayMs = 250 * Math.pow(2, attempt);
      logger.info(`[ReflectionAgent] Backing off ${delayMs}ms before retry ${attempt + 1}`);
      await sleep(delayMs);
    }

    try {
      const result = await withTimeout((signal) => run(agent, input, { signal }));
      const output = result.finalOutput;

      const raw =
        typeof output === "string"
          ? JSON.parse(output)
          : output;
      const parsed = reflectionOutputSchema.parse(raw);

      if (parsed.reflection.trim() === "") {
        throw new Error("Empty reflection returned");
      }

      const reflection = parsed.reflection.trim();
      // Deterministic echo-check: block a reflection that repeats the user's
      // own profile strings back. Checked against the sanitized profile —
      // the same values buildPrompt() sent to the model. Throws
      // GuardrailTripError — caught below and rethrown without retry.
      assertNoProfileEcho(reflection, collectProfileValues(sanitizeProfile(profile)));
      return reflection;
    } catch (err) {
      lastError = err;
      if (isGuardrailTrip(err)) {
        logger.error("[ReflectionAgent] PII guardrail tripped; not retrying", { attempt: attempt + 1 });
        throw new GuardrailTripError();
      }
      logger.error(`[ReflectionAgent] Attempt ${attempt + 1} failed:`, err);
    }
  }

  throw lastError instanceof Error
    ? lastError
    : new Error("ReflectionAgent failed after retries");
}
