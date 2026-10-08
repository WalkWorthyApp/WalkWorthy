/**
 * Mood-based AI Agent for WalkWorthy
 *
 * This agent generates personalized, friend-like encouragement based on
 * the user's mood check-in responses. It selects relevant Bible verses
 * and provides conversational, warm support.
 */

import { Agent, run, setTracingDisabled } from "@openai/agents";
import { createProviderModel, type ProviderConsentCheck } from "./provider-model";
import { z } from "zod";
import Ajv from "ajv";
import { logger } from "firebase-functions/v2";
import { safeErrorMetadata } from "../shared/safe-logging";
import type {
  CheckInType,
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
  ENCOURAGEMENT_SAFETY_INSTRUCTIONS,
  type GenerationRunner,
} from "./model-config";
import {
  SCRIPTURE_CATALOG,
  SCRIPTURE_IDS,
  SCRIPTURE_SELECTION_GUIDE,
  resolveScripture,
} from "./scripture-catalog";
import { moderateText } from "./content-safety";

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
}

// ============================================================================
// Output Schema
// ============================================================================

const encouragementOutputSchema = z.object({
  message: z.string().max(500),
  verseId: z.enum(SCRIPTURE_IDS),
});

type AgentEncouragementOutput = z.infer<typeof encouragementOutputSchema>;

const encouragementJsonSchema = {
  type: "object",
  additionalProperties: false,
  required: ["message", "verseId"],
  properties: {
    message: { type: "string", maxLength: 500 },
    verseId: { type: "string", enum: SCRIPTURE_IDS },
  },
} as const;

// Ajv config: allErrors: true to collect all validation issues
// removeAdditional: false to prevent silent mutation of invalid responses
const ajv = new Ajv({ allErrors: true, removeAdditional: false });
const validateEncouragement = ajv.compile<AgentEncouragementOutput>(
  encouragementJsonSchema,
);

// ============================================================================
// System Prompt - Friend-like, Warm, Conversational
// ============================================================================

const MOOD_SYSTEM_PROMPT = `${ENCOURAGEMENT_SAFETY_INSTRUCTIONS}

## Your Personality
- Use a warm, supportive tone without pretending to be a person or therapist
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
  "verseId": "matthew_11_28"
}

For score=8, tags=["Grateful","Hopeful"], categories=["Faith"], morning, followUpScore=4:
{
  "message": "Love that energy! Starting the day with hope and gratitude is a gift - lean into it.",
  "verseId": "romans_15_13"
}

For score=5, tags=["Calm","Steady"], categories=["Tasks"], midday, followUpScore=3:
{
  "message": "A manageable day is worth something - not every day needs to be a mountaintop. Keep going.",
  "verseId": "psalm_46_1"
}

## Using the User Profile (SUBTLE CONTEXT ONLY)

You may receive a "profile" object with optional fields: ageRange, occupation, major, hobbies. Treat this as SILENT CONTEXT that quietly shapes your response — never as material to name or list back.

**DO:**
- Let ageRange, occupation/major, and hobbies inform your TONE, IMAGERY, and VERSE CHOICE. A verse about diligence hits differently for a grad student than for a retiree.
- Match life-stage vocabulary naturally: "exam season" or "before class" for students; "Monday morning" or "project deadline" for working professionals; "the week ahead" when unclear.
- Pick imagery that resonates with their world without announcing it (e.g., for someone with outdoor hobbies, a verse about God's creation may land more than one about city streets).

**DON'T:**
- Name-drop hobbies, major, occupation, or age. Never write "As a nursing student…", "I know you love reading…", or "Hey engineer,".
- List the user's profile back to them in any form.
- Mention that a profile or personalization exists.
- Refer to the user by an identity label or role.

**Contrast example** — profile: {ageRange: "18-24", major: "Nursing", hobbies: ["Music","Reading"]}, morning, score=3, tags=["Anxious"]:

BAD (name-dropping): "Hey nursing student, clinicals are tough. Maybe put on some music later."

GOOD (subtle): "Mornings before a heavy day can feel like the whole weight lands before you've even started. You don't have to carry all of it right now."

If the profile is null or empty, fall back to neutral, universally-applicable warmth.

## Scripture Catalog
Choose exactly one verseId from this reviewed catalog:
${SCRIPTURE_SELECTION_GUIDE}

## Output Requirements
- Output STRICT JSON matching the schema {message, verseId}
- No prose, explanations, or code fences - just the JSON object
- Never write or paraphrase a Bible quotation; the server supplies the reviewed text
- Keep the message under 500 characters, friendly and warm`;

// ============================================================================
// Agent Configuration
// ============================================================================

let cachedAgent: Agent<object, typeof encouragementOutputSchema> | undefined;
let cachedModel: string | undefined;
let cachedApiKey: string | undefined;

// ============================================================================
// Input Sanitization
// ============================================================================
// sanitizeProfile() and sanitizeText() live in ./profile-sanitize so the
// reflection agent can share the same sanitization logic.

// ============================================================================
// Agent Instance
// ============================================================================

/**
 * Create or retrieve a cached agent instance.
 *
 * The agent cache is keyed by both model and apiKey to prevent using
 * a stale client when the OpenAI credentials change.
 *
 * @param model - The OpenAI model to use (e.g., 'gpt-4o-mini')
 * @param apiKey - The OpenAI API key; must match across calls or agent is recreated
 * @returns The cached or newly created agent instance
 */
function ensureAgent(
  model: string,
  apiKey: string,
): Agent<object, typeof encouragementOutputSchema> {
  // Return cached agent only if both model and apiKey match
  if (
    cachedAgent &&
    cachedModel === model &&
    cachedApiKey === apiKey
  ) {
    return cachedAgent;
  }

  // Update cache with new model and apiKey
  cachedModel = model;
  cachedApiKey = apiKey;

  // Tracing includes inputs/outputs. Keep it disabled for both provider models.
  setTracingDisabled(true);

  cachedAgent = new Agent<object, typeof encouragementOutputSchema>({
    name: "WalkWorthyMoodAgent",
    instructions: MOOD_SYSTEM_PROMPT,
    model: createProviderModel(apiKey, model),
    modelSettings: {
      temperature: 0.4,
      topP: 1,
      maxTokens: 512,
      // Disable storage of the Responses API response object for this call.
      // This is separate from OpenAI abuse-monitoring logs and does not by
      // itself assert that the API project has Zero Data Retention approval.
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

/**
 * Returned when the user's own note is classified as a self-harm signal. The
 * model is deliberately not involved: a fixed, reviewed response is safer than
 * generated prose here.
 *
 * The encouragement is still a real encouragement. Help is OFFERED as a
 * separate resource card rather than replacing the response with a redirect —
 * a user who wrote something heavy still gets what they opened the app for.
 */
export const CRISIS_RESPONSE: AIEncouragementResponse = {
  message: "I'm glad you put that into words — that takes something. You don't have to carry it alone, and you don't have to have it sorted out today. WalkWorthy isn't a substitute for real help, so if you'd like to talk with someone, there's a free and confidential option here whenever you want it.",
  verseRef: SCRIPTURE_CATALOG.psalm_34_18.ref,
  verseText: SCRIPTURE_CATALOG.psalm_34_18.text,
  translation: "ESV",
  isGenerated: false,
  supportResource: {
    title: "Talk to someone now",
    body: "The 988 Suicide & Crisis Lifeline is free, confidential, and open 24/7. Outside the US, contact your local emergency services.",
    phone: "988",
    url: "https://988lifeline.org",
  },
};

/** Returned when the user's note is flagged for a non-self-harm category. */
export const BLOCKED_INPUT_RESPONSE: AIEncouragementResponse = {
  message: "I couldn't build an encouragement around that note, but your check-in is saved. You can edit the note and try again, or continue without one.",
  verseRef: SCRIPTURE_CATALOG.psalm_46_1.ref,
  verseText: SCRIPTURE_CATALOG.psalm_46_1.text,
  translation: "ESV",
  isGenerated: false,
};

/**
 * Returned when the MODEL's own output is flagged. This is a generation
 * failure, not a signal about the user — it must never surface a crisis
 * resource, or a user who wrote nothing concerning gets an unprompted
 * hotline referral.
 */
export const BLOCKED_OUTPUT_RESPONSE: AIEncouragementResponse = {
  message: "Today's encouragement didn't come through the way it should have, so here's a passage to sit with instead. Your check-in is saved.",
  verseRef: SCRIPTURE_CATALOG.psalm_46_1.ref,
  verseText: SCRIPTURE_CATALOG.psalm_46_1.text,
  translation: "ESV",
  isGenerated: false,
};

/** Screening failed; this expresses no assessment of the user's mental state. */
export const UNAVAILABLE_INPUT_RESPONSE: AIEncouragementResponse = {
  message: "Your check-in is saved. We could not prepare a written encouragement this time, so here is a passage to sit with instead. Try again in a little while.",
  verseRef: SCRIPTURE_CATALOG.psalm_46_1.ref,
  verseText: SCRIPTURE_CATALOG.psalm_46_1.text,
  translation: "ESV",
  isGenerated: false,
};

export async function runMoodAgent(
  input: MoodAgentInput,
  apiKey: string,
  checkConsent: ProviderConsentCheck,
  model: string = MOOD_MODEL,
  generate: GenerationRunner = async (serializedInput, signal) =>
    // Empty model output can otherwise trigger another SDK turn without a check.
    (await run(ensureAgent(model, apiKey), serializedInput, { signal, maxTurns: 1 })).finalOutput,
  beforeGeneration: () => Promise<void> = async () => {},
): Promise<AIEncouragementResponse> {
  logger.info("[MoodAgent] Starting encouragement");

  const { moodSpectrumData } = input;
  // Screen the entire normalized note; the generation budget must not hide
  // safety signals later in an accepted note.
  const normalizedNote = moodSpectrumData.note
    ? sanitizeText(moodSpectrumData.note, moodSpectrumData.note.length)
    : undefined;
  // Profile strings are sanitized and checked for echoes.
  const payload = {
    profile: sanitizeProfile(input.profile),
    checkInType: input.checkInType,
    moodScore: moodSpectrumData.moodScore,
    moodLevel: moodSpectrumData.moodLevel,
    emotionTags: moodSpectrumData.emotionTags.slice(0, 10).map((t) => sanitizeText(t, 30)),
    impactCategories: moodSpectrumData.impactCategories.slice(0, 10).map((c) => sanitizeText(c, 30)),
    followUpScore: moodSpectrumData.followUpScore,
    note: normalizedNote?.slice(0, 300),
  };

  await checkConsent();
  const inputSafety = await moderateText(normalizedNote, apiKey, "input");
  if (inputSafety === "crisis") {
    logger.info("[MoodAgent] Self-harm signal in note; returning fixed crisis response");
    return CRISIS_RESPONSE;
  }
  if (inputSafety === "block") return BLOCKED_INPUT_RESPONSE;
  if (inputSafety === "unavailable") return UNAVAILABLE_INPUT_RESPONSE;

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
    // Checks live outside provider catches: denial/read failure must stop work,
    // including when consent changes during backoff. Sent requests cannot be recalled.
    await checkConsent();
    // Admission/ownership errors must abort, not enter the model retry loop.
    // Fixed input-safety responses above never consume a generation attempt.
    await beforeGeneration();
    let parsed: AIEncouragementResponse;
    try {
      logger.info("[MoodAgent] Calling OpenAI agent...");
      const result = await withTimeout((signal) =>
        generate(serializedInput, signal),
      );
      logger.info("[MoodAgent] Agent returned response");
      parsed = parseEncouragement(result);
    } catch (err) {
      lastError = err;
      // Guardrail trips are deterministic — retrying will produce the same
      // output and waste quota. Rethrow immediately as a distinct error so
      // callers can surface a stable error code.
      if (isGuardrailTrip(err)) {
        logger.error("[MoodAgent] PII guardrail tripped; not retrying", { attempt: attempt + 1 });
        throw new GuardrailTripError();
      }
      logger.error("[MoodAgent] Attempt failed", {
        attempt: attempt + 1,
        ...safeErrorMetadata(err),
      });
      continue;
    }

    await checkConsent();
    // A flagged OUTPUT says the model misbehaved, not that the user is at risk.
    const outputSafety = await moderateText(parsed.message, apiKey, "output");
    if (outputSafety !== "allow") {
      logger.warn("[MoodAgent] Generated output flagged; returning neutral fallback", {
        decision: outputSafety,
      });
      return BLOCKED_OUTPUT_RESPONSE;
    }
    // Deterministic profile echoes fail without retrying generation.
    assertNoProfileEcho(parsed, collectProfileValues(payload.profile));
    return parsed;
  }

  throw lastError instanceof Error
    ? lastError
    : new Error("Agent failed after retries");
}

function parseEncouragement(
  candidate: unknown,
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
    logger.error("[MoodAgent] Output failed schema validation");
    throw new Error("Agent output failed schema validation");
  }

  const passage = resolveScripture(data.verseId as string);
  if (!passage) {
    throw new Error("Agent selected an unknown Scripture catalog ID");
  }

  return {
    message: data.message as string,
    verseRef: passage.ref,
    verseText: passage.text,
    translation: "ESV",
    isGenerated: true,
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
