/** Only fixed categories may cross the diagnostics boundary; never provider text. */
export function safeErrorMetadata(error: unknown): { errorKind: string } {
  if (error instanceof TypeError) return { errorKind: "TypeError" };
  if (error instanceof SyntaxError) return { errorKind: "SyntaxError" };
  if (error instanceof RangeError) return { errorKind: "RangeError" };
  if (error instanceof Error) return { errorKind: "Error" };
  return { errorKind: "UnknownError" };
}
