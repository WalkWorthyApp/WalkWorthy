import { getFirestore } from 'firebase-admin/firestore';

export interface UserProfile {
  ageRange?: string;
  major?: string;
  gender?: string;
  hobbies?: string[];
  optInTailored?: boolean;
  translationPreference?: 'ESV' | 'KJV' | 'NIV' | 'NKJV' | 'NASB' | 'CSB' | 'NLT';
  updatedAt?: string;
}

interface CacheEntry {
  value: UserProfile | undefined;
  timestamp: number;
}

const DEFAULT_CACHE_TTL_MS = 10 * 60 * 1000; // 10 minutes
const MAX_CACHE_SIZE = 100;
const PROBABILISTIC_CLEANUP_RATE = 0.05; // ~5% of calls trigger full cleanup

const cache = new Map<string, CacheEntry>();
let cleanupTimerId: NodeJS.Timeout | undefined;

function getCacheTtlMs(): number {
  const ttlEnv = process.env.USER_PROFILE_CACHE_TTL_MS;
  if (!ttlEnv) return DEFAULT_CACHE_TTL_MS;
  const ttl = parseInt(ttlEnv, 10);
  return isNaN(ttl) || ttl <= 0 ? DEFAULT_CACHE_TTL_MS : ttl;
}

function isExpired(entry: CacheEntry): boolean {
  const now = Date.now();
  return now - entry.timestamp > getCacheTtlMs();
}

function evictOldestEntry(): void {
  let oldest: { key: string; timestamp: number } | null = null;
  for (const [key, entry] of cache.entries()) {
    if (!oldest || entry.timestamp < oldest.timestamp) {
      oldest = { key, timestamp: entry.timestamp };
    }
  }
  if (oldest) cache.delete(oldest.key);
}

function evictExpiredEntries(): void {
  const now = Date.now();
  const ttl = getCacheTtlMs();
  for (const [key, entry] of cache.entries()) {
    if (now - entry.timestamp > ttl) {
      cache.delete(key);
    }
  }
}

export async function getUserProfileOnce(sub: string): Promise<UserProfile | undefined> {
  // Probabilistic cleanup: run full expiration scan on ~5% of calls to avoid O(n) on every invocation
  if (Math.random() < PROBABILISTIC_CLEANUP_RATE) {
    evictExpiredEntries();
  }

  // Check cache for non-expired entry
  if (cache.has(sub)) {
    const entry = cache.get(sub);
    if (entry && !isExpired(entry)) {
      return entry.value;
    }
    // Entry is expired, remove it
    cache.delete(sub);
  }

  // Fetch from Firestore
  const db = getFirestore();
  const docRef = db.collection('users').doc(sub).collection('profile').doc('data');
  const docSnap = await docRef.get();
  const item = docSnap.exists ? (docSnap.data() as UserProfile) : undefined;

  // Enforce cache size limit with LRU eviction
  if (cache.size >= MAX_CACHE_SIZE) {
    evictOldestEntry();
  }

  // Store in cache with timestamp
  cache.set(sub, { value: item, timestamp: Date.now() });
  return item;
}

export function clearUserProfileCache(sub?: string) {
  if (sub) cache.delete(sub);
  else cache.clear();
}

/**
 * Start a periodic cleanup timer for long-lived environments (e.g., local dev, always-on servers).
 * Call this once at startup to enable background cache cleanup every 5 minutes.
 * Not needed for serverless (Lambda) since invocations are short-lived.
 */
export function startCleanupTimer(intervalMs: number = 5 * 60 * 1000): void {
  if (cleanupTimerId) return; // Already running
  cleanupTimerId = setInterval(() => {
    evictExpiredEntries();
  }, intervalMs);
  // Unref timer so it doesn't prevent process exit (important for Node.js)
  if (cleanupTimerId.unref) {
    cleanupTimerId.unref();
  }
}

/**
 * Stop the periodic cleanup timer.
 */
export function stopCleanupTimer(): void {
  if (cleanupTimerId) {
    clearInterval(cleanupTimerId);
    cleanupTimerId = undefined;
  }
}

