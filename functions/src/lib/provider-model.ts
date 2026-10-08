import OpenAI from "openai";
import { OpenAIResponsesModel } from "@openai/agents-openai";

/** Request-scoped authorization; never store this callback in a cached agent. */
export type ProviderConsentCheck = () => Promise<void>;

/** Application retries recheck consent; transparent SDK retries cannot do so. */
export function createProviderModel(apiKey: string, model: string): OpenAIResponsesModel {
  return new OpenAIResponsesModel(new OpenAI({ apiKey, maxRetries: 0 }), model);
}
