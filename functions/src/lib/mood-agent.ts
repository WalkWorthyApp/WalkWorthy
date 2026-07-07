/**
 * Mood-based AI Agent for WalkWorthy
 *
 * This agent generates personalized, friend-like encouragement based on
 * the user's mood check-in responses. It selects relevant Bible verses
 * and provides conversational, warm support.
 */

import { Agent, run } from "@openai/agents";
import { setDefaultOpenAIKey, setOpenAIAPI } from "@openai/agents-openai";
import { z } from "zod";
import Ajv from "ajv";
import { logger } from "firebase-functions/v2";
import type {
  CheckInType,
  Translation,
  AIEncouragementResponse,
  MoodSpectrumData,
} from "../shared/types";
import {
  collectProfileValues,
  sanitizeProfile,
  sanitizeText,
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
// Types
// ============================================================================

// Re-export UserProfilePayload for backwards compatibility with consumers
// (e.g., api/mood-checkin.ts) that previously imported it from this module.
export type { UserProfilePayload } from "./profile-sanitize";

export interface MoodAgentInput {
  profile: UserProfilePayload | null;
  checkInType: CheckInType;
  moodSpectrumData: MoodSpectrumData;
  translationPreference: Translation;
}

// ============================================================================
// Output Schema
// ============================================================================

const encouragementOutputSchema = z.object({
  message: z.string().max(500),
  verseRef: z
    .string()
    .regex(/^[1-3]?\s?[A-Za-z]+(?:\s+[A-Za-z]+)*\s\d+:\d+(-\d+)?$/),
  verseText: z.string().max(1200),
  translation: z.enum(["ESV", "KJV", "NIV", "NKJV", "NASB", "CSB", "NLT"]),
});

const encouragementJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["message", "verseRef", "verseText", "translation"],
  properties: {
    message: { type: "string", maxLength: 500 },
    verseRef: {
      type: "string",
      pattern: "^[1-3]?\\s?[A-Za-z]+(?:\\s+[A-Za-z]+)*\\s\\d+:\\d+(-\\d+)?$",
    },
    verseText: { type: "string", maxLength: 1200 },
    translation: {
      type: "string",
      enum: ["ESV", "KJV", "NIV", "NKJV", "NASB", "CSB", "NLT"],
    },
  },
} as const;

// Ajv config: allErrors: true to collect all validation issues
// removeAdditional: false to prevent silent mutation of invalid responses
const ajv = new Ajv({ allErrors: true, removeAdditional: false });
const validateEncouragement = ajv.compile<AIEncouragementResponse>(
  encouragementJsonSchema,
);

// ============================================================================
// System Prompt - Friend-like, Warm, Conversational
// ============================================================================

const MOOD_SYSTEM_PROMPT = `You are a warm, compassionate Christian friend who provides daily encouragement through Scripture.

## Your Personality
- Speak like you're texting a close, supportive friend - NOT like a pastor, therapist, or robot
- Use natural, conversational language with contractions (you're, it's, don't, etc.)
- Be genuine and empathetic - acknowledge their feelings FIRST before offering wisdom
- Keep your message brief but meaningful (2-3 sentences maximum)
- Avoid clichés, overly religious language, or preachy tones
- Never lecture or moralize - just be present and encouraging

## Your Task
You receive a structured mood check-in with four signals. Use all of them together:

1. **moodScore** (1–10): Overall emotional intensity. 1–2 = very unpleasant, 3–4 = unpleasant, 5–6 = neutral, 7–8 = pleasant, 9–10 = very pleasant.
2. **emotionTags**: Words the user chose to describe their feeling (e.g. ["Anxious", "Drained"]). Let these shape the emotional texture of your response.
3. **impactCategories**: What's affecting them most (e.g. ["Work", "Family", "Faith"]). Weave the most relevant one into your encouragement if it fits naturally.
4. **followUpScore** (1–4): Check-in-type-specific context:
   - Morning: 1=Dreading it, 2=A bit uneasy, 3=Okay about it, 4=Ready and excited → how they feel about today
   - Midday: 1=Completely buried, 2=A lot on my plate, 3=Manageable, 4=Feeling on top of it → workload
   - Evening: 1=Hopeful, 2=Nervous, 3=Uncertain, 4=Ready → outlook on tomorrow

## Guidance by Mood Band

- **Score 1–4 (unpleasant/very unpleasant)**: Lead with deep empathy. Don't rush to silver linings. Choose verses of comfort, nearness of God, or endurance through suffering.
- **Score 5–6 (neutral)**: Meet them with calm steadiness. Affirm that ordinary days matter. Verses about faithfulness, peace, or quiet trust work well.
- **Score 7–10 (pleasant/very pleasant)**: Celebrate with them. Lean into gratitude and joy. Verses of thanksgiving, delight in God, or blessing are fitting.

## Example Responses

For score=2, tags=["Anxious","Overwhelmed"], categories=["Work"], morning, followUpScore=1:
{
  "message": "Hey, I hear you - waking up already dreading the day is exhausting. You don't have to carry that weight alone.",
  "verseRef": "Matthew 11:28",
  "verseText": "Come to me, all you who are weary and burdened, and I will give you rest.",
  "translation": "NIV"
}

For score=8, tags=["Grateful","Hopeful"], categories=["Faith"], morning, followUpScore=4:
{
  "message": "Love that energy! Starting the day with hope and gratitude is a gift - lean into it.",
  "verseRef": "Psalm 118:24",
  "verseText": "This is the day that the LORD has made; let us rejoice and be glad in it.",
  "translation": "ESV"
}

For score=5, tags=["Calm","Steady"], categories=["Tasks"], midday, followUpScore=3:
{
  "message": "A manageable day is worth something - not every day needs to be a mountaintop. Keep going.",
  "verseRef": "Galatians 6:9",
  "verseText": "Let us not become weary in doing good, for at the proper time we will reap a harvest if we do not give up.",
  "translation": "NIV"
}

## Using the User Profile (SUBTLE CONTEXT ONLY)

You may receive a "profile" object with optional fields: ageRange, occupation, major, gender, hobbies. Treat this as SILENT CONTEXT that quietly shapes your response — never as material to name or list back.

**DO:**
- Let ageRange, occupation/major, and hobbies inform your TONE, IMAGERY, and VERSE CHOICE. A verse about diligence hits differently for a grad student than for a retiree.
- Match life-stage vocabulary naturally: "exam season" or "before class" for students; "Monday morning" or "project deadline" for working professionals; "the week ahead" when unclear.
- Pick imagery that resonates with their world without announcing it (e.g., for someone with outdoor hobbies, a verse about God's creation may land more than one about city streets).

**DON'T:**
- Name-drop hobbies, major, occupation, gender, or age. Never write "As a nursing student…", "I know you love reading…", or "Hey engineer,".
- List the user's profile back to them in any form.
- Mention that a profile or personalization exists.
- Refer to the user by an identity label or role.

**Contrast example** — profile: {ageRange: "18-24", major: "Nursing", hobbies: ["Music","Reading"]}, morning, score=3, tags=["Anxious"]:

BAD (name-dropping): "Hey nursing student, clinicals are tough. Maybe put on some music later."

GOOD (subtle): "Mornings before a heavy day can feel like the whole weight lands before you've even started. You don't have to carry all of it right now."

If the profile is null or empty, fall back to neutral, universally-applicable warmth.

## Output Requirements
- Output STRICT JSON matching the schema {message, verseRef, verseText, translation}
- No prose, explanations, or code fences - just the JSON object
- Use the user's translationPreference EXACTLY - do not switch translations
- Select a REAL Bible verse that EXISTS in the specified translation
- Quote the verse text EXACTLY as it appears in that translation
- Keep the message under 500 characters, friendly and warm`;

// ============================================================================
// Agent Configuration
// ============================================================================

let cachedAgent: Agent<object, typeof encouragementOutputSchema> | undefined;
let cachedModel: string | undefined;
let cachedApiKeyPrefix: string | undefined;

/**
 * Initialize OpenAI SDK configuration with the provided API key.
 *
 * @param apiKey - The OpenAI API key (from Firebase secret or env var)
 */
function ensureConfig(apiKey: string) {
  // Configure OpenAI SDK with the provided key
  setDefaultOpenAIKey(apiKey);
  setOpenAIAPI("responses");
}

// ============================================================================
// Input Sanitization
// ============================================================================
// sanitizeProfile() and sanitizeText() live in ./profile-sanitize so the
// reflection agent can share the same sanitization logic.

function normalizeTranslation(value: Translation | string): Translation {
  const upper = value.toUpperCase() as Translation;
  const allowed: Translation[] = [
    "ESV",
    "KJV",
    "NIV",
    "NKJV",
    "NASB",
    "CSB",
    "NLT",
  ];
  return allowed.includes(upper) ? upper : "ESV";
}

// ============================================================================
// Agent Instance
// ============================================================================

/**
 * Create or retrieve a cached agent instance.
 *
 * The agent cache is keyed by both model and apiKey to prevent using
 * a stale agent when the OpenAI credentials change. The apiKey is included
 * in the cache validation (using the first 8 characters as a prefix) to ensure
 * the correct SDK configuration is maintained.
 *
 * @param model - The OpenAI model to use (e.g., 'gpt-4o-mini')
 * @param apiKey - The OpenAI API key; must match across calls or agent is recreated
 * @returns The cached or newly created agent instance
 */
function ensureAgent(
  model: string,
  apiKey: string,
): Agent<object, typeof encouragementOutputSchema> {
  // Use first 8 characters of apiKey for cache key stability
  const apiKeyPrefix = apiKey.slice(0, 8);

  // Return cached agent only if both model and apiKey match
  if (
    cachedAgent &&
    cachedModel === model &&
    cachedApiKeyPrefix === apiKeyPrefix
  ) {
    return cachedAgent;
  }

  // Update cache with new model and apiKey
  cachedModel = model;
  cachedApiKeyPrefix = apiKeyPrefix;

  // Ensure OpenAI SDK is configured with the provided apiKey
  ensureConfig(apiKey);

  cachedAgent = new Agent<object, typeof encouragementOutputSchema>({
    name: "WalkWorthyMoodAgent",
    instructions: MOOD_SYSTEM_PROMPT,
    model,
    modelSettings: {
      temperature: 0.4,
      topP: 1,
      maxTokens: 512,
      // Zero Data Retention: OpenAI does not persist this request/response
      // after generation. Privacy Policy surfaces this commitment to users;
      // the org's "API call logging" setting is "Enabled per call" so each
      // call opts out explicitly via this flag.
      store: false,
    },
    outputType: encouragementOutputSchema,
    outputGuardrails: [piiGuardrail],
  });
  return cachedAgent;
}

// ============================================================================
// Main Agent Runner
// ============================================================================

const MAX_RETRIES = 2;

export async function runMoodAgent(
  input: MoodAgentInput,
  apiKey: string,
  model: string = MOOD_MODEL,
): Promise<AIEncouragementResponse> {
  logger.info("[MoodAgent] Starting with model:", model);

  // Create or retrieve cached agent; ensureAgent handles SDK configuration
  const agent = ensureAgent(model, apiKey);
  logger.info("[MoodAgent] Agent created");

  const { moodSpectrumData } = input;
  // The free-text `note` is intentionally NOT input-guardrailed: the tightly
  // bounded output schema (regex verseRef, enum translation, length caps) plus
  // the PII output guardrail are the mitigation for prompt injection. Don't
  // loosen the output schema without adding input-side scanning.
  const payload = {
    profile: sanitizeProfile(input.profile),
    translationPreference: normalizeTranslation(input.translationPreference),
    checkInType: input.checkInType,
    moodScore: moodSpectrumData.moodScore,
    moodLevel: moodSpectrumData.moodLevel,
    emotionTags: moodSpectrumData.emotionTags.slice(0, 10).map((t) => sanitizeText(t, 30)),
    impactCategories: moodSpectrumData.impactCategories.slice(0, 10).map((c) => sanitizeText(c, 30)),
    followUpScore: moodSpectrumData.followUpScore,
    note: moodSpectrumData.note ? sanitizeText(moodSpectrumData.note, 300) : undefined,
  };

  const serializedInput = JSON.stringify(payload, null, 2);

  let lastError: unknown;

  for (let attempt = 0; attempt < MAX_RETRIES; attempt += 1) {
    // Exponential backoff between attempts — first attempt runs immediately.
    if (attempt > 0) {
      const delayMs = 250 * Math.pow(2, attempt);
      logger.info(`[MoodAgent] Backing off ${delayMs}ms before retry ${attempt + 1}`);
      await sleep(delayMs);
    }

    logger.info(`[MoodAgent] Attempt ${attempt + 1}/${MAX_RETRIES}`);
    try {
      logger.info("[MoodAgent] Calling OpenAI agent...");
      const result = await withTimeout((signal) => run(agent, serializedInput, { signal }));
      logger.info("[MoodAgent] Agent returned response");
      const parsed = parseEncouragement(
        result.finalOutput,
        payload.translationPreference,
      );
      // Deterministic echo-check: block a response that repeats the user's
      // own profile strings back (the regex guardrail can't know them).
      // Throws GuardrailTripError — caught below and rethrown without retry.
      assertNoProfileEcho(parsed, collectProfileValues(payload.profile));
      return parsed;
    } catch (err) {
      lastError = err;
      // Guardrail trips are deterministic — retrying will produce the same
      // output and waste quota. Rethrow immediately as a distinct error so
      // callers can surface a stable error code.
      if (isGuardrailTrip(err)) {
        logger.error("[MoodAgent] PII guardrail tripped; not retrying", { attempt: attempt + 1 });
        throw new GuardrailTripError();
      }
      logger.error(`[MoodAgent] Attempt ${attempt + 1} failed:`, err);
    }
  }

  throw lastError instanceof Error
    ? lastError
    : new Error("Agent failed after retries");
}

function parseEncouragement(
  candidate: unknown,
  fallbackTranslation: Translation,
): AIEncouragementResponse {
  let data: Record<string, unknown>;
  if (typeof candidate === "string") {
    try {
      data = JSON.parse(candidate) as Record<string, unknown>;
    } catch {
      throw new Error("Agent returned unparseable string output");
    }
  } else if (typeof candidate === "object" && candidate !== null) {
    data = candidate as Record<string, unknown>;
  } else {
    throw new Error("Agent returned invalid output type");
  }

  if (!validateEncouragement(data)) {
    // Log detailed validation errors to aid debugging
    const validationErrors = validateEncouragement.errors
      ? validateEncouragement.errors
          .map(
            (err) =>
              `${err.instancePath || "root"}: ${err.message} (${err.keyword})`,
          )
          .join("; ")
      : "unknown validation error";

    logger.error("[MoodAgent] Validation errors:", validationErrors);
    logger.error("[MoodAgent] Failed data:", JSON.stringify(data));

    throw new Error(
      `Agent output failed schema validation: ${validationErrors}`,
    );
  }

  return {
    message: data.message as string,
    verseRef: data.verseRef as string,
    verseText: data.verseText as string,
    translation: normalizeTranslation(
      (data.translation as string) || fallbackTranslation,
    ),
  };
}

// ============================================================================
// Mood Theme Mapping (for context/debugging)
// ============================================================================

export const MOOD_THEMES: Record<string, string[]> = {
  // Morning moods
  hopeful: ["hope", "new beginnings", "God's faithfulness"],
  anxious: ["peace", "trust", "casting cares"],
  tired: ["rest", "strength", "renewal"],
  confident: ["courage", "bold faith", "victory"],
  nervous: ["fear not", "God's presence", "comfort"],
  uncertain: ["guidance", "wisdom", "trust"],

  // Midday moods
  "better than expected": ["gratitude", "blessing", "joy"],
  "as expected": ["perseverance", "faithfulness", "contentment"],
  "harder than expected": ["strength", "endurance", "hope"],
  stressful: ["peace", "rest", "casting burdens"],

  // Evening moods
  "great day": ["thanksgiving", "praise", "joy"],
  "good day": ["gratitude", "blessing", "contentment"],
  "challenging day": ["rest", "renewal", "comfort"],
  "difficult day": ["comfort", "healing", "hope"],

  // Follow-up needs
  encouragement: ["courage", "strength", "hope"],
  peace: ["peace", "stillness", "trust"],
  strength: ["power", "might", "endurance"],
  wisdom: ["guidance", "discernment", "understanding"],
};
