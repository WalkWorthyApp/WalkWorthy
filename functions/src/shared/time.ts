export function nowIso(): string {
  return new Date().toISOString();
}

export function futureEpochSeconds(hoursFromNow: number): number {
  const now = Date.now();
  const msAhead = hoursFromNow * 60 * 60 * 1000;
  return Math.floor((now + msAhead) / 1000);
}
