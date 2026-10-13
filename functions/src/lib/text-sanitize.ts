/**
 * Text sanitization for untrusted check-in strings sent to the AI agents.
 */

/**
 * General-purpose text sanitizer: strips HTML tags and URLs, collapses
 * whitespace, and truncates to `max` characters.
 */
export function sanitizeText(text: string, max = 400): string {
  const stripped = text
    .replace(/<[^>]+>/g, " ")
    .replace(/https?:\/\/\S+/gi, " ");
  return stripped.replace(/\s+/g, " ").trim().slice(0, max);
}
