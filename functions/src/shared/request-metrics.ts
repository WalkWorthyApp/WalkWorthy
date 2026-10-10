/**
 * Request-scoped latency and token metrics, logged once per request.
 *
 * Keys are code constants and values are numbers only, so nothing a user
 * typed or stored can reach the log line built from `summary()`.
 */

/** The parts of an Agents SDK `Usage` this module reads. */
export interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  inputTokensDetails: Array<Record<string, number>>;
}

export class RequestMetrics {
  private readonly startedAt = performance.now();
  private readonly values: Record<string, number> = {};

  /** Runs `work` and adds its duration to `${stage}Ms`, even when it throws. */
  async time<T>(stage: string, work: () => Promise<T>): Promise<T> {
    const began = performance.now();
    try {
      return await work();
    } finally {
      this.add(`${stage}Ms`, performance.now() - began);
    }
  }

  add(key: string, amount = 1): void {
    this.values[key] = (this.values[key] ?? 0) + amount;
  }

  recordTokenUsage(usage: TokenUsage): void {
    this.add("inputTokens", usage.inputTokens);
    this.add("cachedInputTokens", usage.inputTokensDetails
      .reduce((sum, details) => sum + (details.cached_tokens ?? 0), 0));
    this.add("outputTokens", usage.outputTokens);
  }

  summary(): Record<string, number> {
    const rounded: Record<string, number> = {};
    for (const [key, value] of Object.entries(this.values)) rounded[key] = Math.round(value);
    rounded.totalMs = Math.round(performance.now() - this.startedAt);
    return rounded;
  }
}
