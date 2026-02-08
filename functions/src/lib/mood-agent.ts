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
  primaryMood: string;
  followUpResponse: string;
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
  encouragementJsonSchema
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
Based on the user's mood check-in, you will:
1. Acknowledge how they're feeling with genuine empathy
2. Share ONE relevant Bible verse that speaks to their emotional state
3. Provide brief, friend-like encouragement

## Mood Context Guide

### Morning Check-ins (How they feel about today):
- hopeful → Affirm their hope, encourage confidence in God's plans
- anxious → Validate the anxiety, offer verses about peace and trust
- tired → Acknowledge weariness, share verses about rest and renewal
- confident → Celebrate with them, reinforce trust in God's strength
- nervous → Normalize nerves, provide comfort and assurance
- uncertain → Meet them in the unknown, offer verses about guidance

### Midday Check-ins (How the day is going):
- better than expected → Share in their joy, encourage gratitude
- as expected → Affirm steady faithfulness, encourage perseverance
- harder than expected → Validate the struggle, offer strength
- stressful → Acknowledge the weight, provide peace and rest

### Evening Check-ins (How the day went):
- great day → Celebrate with thanksgiving
- good day → Affirm contentment and gratitude
- challenging day → Comfort and encourage rest
- difficult day → Deep compassion, healing, and hope for tomorrow

### Follow-up Context:
- Morning "lots on plate": yes/no/somewhat → Adjust tone based on workload
- Midday "what would help": encouragement/peace/strength/wisdom → Match the verse theme
- Evening "about tomorrow": hopeful/nervous/uncertain/ready → End with forward-looking encouragement

## Example Responses

For "anxious" morning mood:
{
  "message": "Hey, I hear you - mornings can feel heavy when anxiety creeps in. You're not facing today alone.",
  "verseRef": "Philippians 4:6-7",
  "verseText": "Do not be anxious about anything, but in every situation, by prayer and petition, with thanksgiving, present your requests to God. And the peace of God, which transcends all understanding, will guard your hearts and your minds in Christ Jesus.",
  "translation": "NIV"
}

For "difficult day" evening mood:
{
  "message": "I'm sorry today was rough. Some days just hit different, and it's okay to feel that. Rest well tonight - tomorrow's a fresh start.",
  "verseRef": "Lamentations 3:22-23",
  "verseText": "Because of the LORD's great love we are not consumed, for his compassions never fail. They are new every morning; great is your faithfulness.",
  "translation": "NIV"
}

For "stressful" midday needing "peace":
{
  "message": "Sounds like it's been one of those days. Take a breath - you've made it this far, and there's grace for the rest.",
  "verseRef": "John 14:27",
  "verseText": "Peace I leave with you; my peace I give you. I do not give to you as the world gives. Do not let your hearts be troubled and do not be afraid.",
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
  profile: UserProfilePayload | null | undefined
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
  apiKey: string
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
      temperature: 0.4, // Slightly higher for more natural, varied responses
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
  model = process.env.OPENAI_MODEL || "gpt-4o-mini"
): Promise<AIEncouragementResponse> {
  logger.info("[MoodAgent] Starting with model:", model);

  // Create or retrieve cached agent; ensureAgent handles SDK configuration
  const agent = ensureAgent(model, apiKey);
  logger.info("[MoodAgent] Agent created");

  const payload = {
    profile: sanitizeProfile(input.profile),
    translationPreference: normalizeTranslation(input.translationPreference),
    checkInType: input.checkInType,
    primaryMood: sanitize(input.primaryMood, 50),
    followUpResponse: sanitize(input.followUpResponse, 50),
  };

  const serializedInput = JSON.stringify(payload, null, 2);

  let lastError: unknown;

  for (let attempt = 0; attempt < MAX_RETRIES; attempt += 1) {
    logger.info(`[MoodAgent] Attempt ${attempt + 1}/${MAX_RETRIES}`);
    try {
      logger.info("[MoodAgent] Calling OpenAI agent...");
      const result = await run(agent, serializedInput);
      logger.info("[MoodAgent] Agent returned response");
      return parseEncouragement(result.finalOutput, payload.translationPreference);
    } catch (err) {
      lastError = err;
      logger.error(`[MoodAgent] Attempt ${attempt + 1} failed:`, err);
    }
  }

  throw lastError instanceof Error ? lastError : new Error("Agent failed after retries");
}

function parseEncouragement(
  candidate: unknown,
  fallbackTranslation: Translation
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
              `${err.instancePath || "root"}: ${err.message} (${err.keyword})`
          )
          .join("; ")
      : "unknown validation error";

    logger.error("[MoodAgent] Validation errors:", validationErrors);
    logger.error("[MoodAgent] Failed data:", JSON.stringify(data));

    throw new Error(`Agent output failed schema validation: ${validationErrors}`);
  }

  return {
    message: data.message as string,
    verseRef: data.verseRef as string,
    verseText: data.verseText as string,
    translation: normalizeTranslation(
      (data.translation as string) || fallbackTranslation
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
