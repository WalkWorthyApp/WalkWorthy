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
  AgeRange,
  Gender,
  CheckInType,
  Translation,
  AIEncouragementResponse,
  MoodSpectrumData,
} from "../shared/types";
import { validateAgeRange, validateGender } from "../shared/types";

// ============================================================================
// Types
// ============================================================================

export interface UserProfilePayload {
  /** SENSITIVE: Optional major/field of study (for students). Can identify users when combined with other profile data. */
  major?: string;
  /** SENSITIVE: Optional occupation/job title (for non-students). Can identify users when combined with other profile data. */
  occupation?: string;
  /** SENSITIVE: Gender is PII; must be one of the predefined gender options */
  gender?: Gender;
  /** SENSITIVE: Age range is PII; must be one of the predefined ranges */
  ageRange?: AgeRange;
  hobbies?: string[];
  optInTailored?: boolean;
}

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
// PII Guardrail
// ============================================================================

const PII_REGEX =
  /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|https?:\/\/\S+|(AKIA|ASI|SK|PK)[A-Z0-9]{16,}/gi;

const piiGuardrail = {
  name: "pii_filter",
  execute: async (args: { agentOutput: AIEncouragementResponse }) => {
    const text = JSON.stringify(args.agentOutput);
    const triggered = PII_REGEX.test(text);
    PII_REGEX.lastIndex = 0;
    return {
      tripwireTriggered: triggered,
      outputInfo: triggered ? { reason: "Sensitive data detected" } : undefined,
    };
  },
};

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

function sanitize(text: string, max = 400): string {
  const stripped = text
    .replace(/<[^>]+>/g, " ")
    .replace(/https?:\/\/\S+/gi, " ");
  return stripped.replace(/\s+/g, " ").trim().slice(0, max);
}

function sanitizeProfile(
  profile: UserProfilePayload | null | undefined,
): UserProfilePayload | null {
  if (!profile) return null;

  // Validate sensitive enum fields to prevent invalid data being passed to AI
  const validGender = profile.gender
    ? validateGender(profile.gender)
    : undefined;
  const validAgeRange = profile.ageRange
    ? validateAgeRange(profile.ageRange)
    : undefined;

  return {
    major: profile.major ? sanitize(profile.major, 120) : undefined,
    occupation: profile.occupation
      ? sanitize(profile.occupation, 120)
      : undefined,
    gender: validGender,
    ageRange: validAgeRange,
    hobbies: profile.hobbies?.slice(0, 6).map((h) => sanitize(h, 40)),
    optInTailored: Boolean(profile.optInTailored),
  };
}

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
  model = "gpt-4.1-nano",
): Promise<AIEncouragementResponse> {
  logger.info("[MoodAgent] Starting with model:", model);

  // Create or retrieve cached agent; ensureAgent handles SDK configuration
  const agent = ensureAgent(model, apiKey);
  logger.info("[MoodAgent] Agent created");

  const { moodSpectrumData } = input;
  const payload = {
    profile: sanitizeProfile(input.profile),
    translationPreference: normalizeTranslation(input.translationPreference),
    checkInType: input.checkInType,
    moodScore: moodSpectrumData.moodScore,
    moodLevel: moodSpectrumData.moodLevel,
    emotionTags: moodSpectrumData.emotionTags.slice(0, 10).map((t) => sanitize(t, 30)),
    impactCategories: moodSpectrumData.impactCategories.slice(0, 10).map((c) => sanitize(c, 30)),
    followUpScore: moodSpectrumData.followUpScore,
    note: moodSpectrumData.note ? sanitize(moodSpectrumData.note, 300) : undefined,
  };

  const serializedInput = JSON.stringify(payload, null, 2);

  let lastError: unknown;

  for (let attempt = 0; attempt < MAX_RETRIES; attempt += 1) {
    logger.info(`[MoodAgent] Attempt ${attempt + 1}/${MAX_RETRIES}`);
    try {
      logger.info("[MoodAgent] Calling OpenAI agent...");
      const result = await run(agent, serializedInput);
      logger.info("[MoodAgent] Agent returned response");
      return parseEncouragement(
        result.finalOutput,
        payload.translationPreference,
      );
    } catch (err) {
      lastError = err;
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
