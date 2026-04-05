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
    model: "gpt-4o-mini",
    modelSettings: { temperature: 0.6, topP: 1 },
    outputType: reflectionOutputSchema,
  });

  return cachedAgent;
}

// ============================================================================
// Input Builder
// ============================================================================

function buildPrompt(summaries: DailyMoodSummary[]): string {
  if (summaries.length === 0) {
    return JSON.stringify({ weekSummary: "No check-ins recorded this week." });
  }

  const entries = summaries.map((s) => ({
    date: s.date,
    sentiment: s.overallSentiment ?? "unknown",
    morning: s.morning?.primaryMood ?? null,
    midday: s.midday?.primaryMood ?? null,
    evening: s.evening?.primaryMood ?? null,
  }));

  return JSON.stringify({ weekSummary: entries }, null, 2);
}

// ============================================================================
// Export
// ============================================================================

export async function runReflectionAgent(
  summaries: DailyMoodSummary[],
  apiKey: string,
): Promise<string> {
  logger.info("[ReflectionAgent] Generating daily reflection", {
    summaryCount: summaries.length,
  });

  const agent = ensureAgent(apiKey);
  const input = buildPrompt(summaries);

  let lastError: unknown;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const result = await run(agent, input);
      const output = result.finalOutput;

      const raw =
        typeof output === "string"
          ? JSON.parse(output)
          : output;
      const parsed = reflectionOutputSchema.parse(raw);

      if (parsed.reflection.trim() === "") {
        throw new Error("Empty reflection returned");
      }

      return parsed.reflection.trim();
    } catch (err) {
      lastError = err;
      logger.error(`[ReflectionAgent] Attempt ${attempt + 1} failed:`, err);
    }
  }

  throw lastError instanceof Error
    ? lastError
    : new Error("ReflectionAgent failed after retries");
}
