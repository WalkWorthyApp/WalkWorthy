/**
 * WalkWorthy Firebase Cloud Functions
 *
 * This module exports all Cloud Functions for the WalkWorthy backend:
 * - HTTP endpoints for API access
 */

import { setGlobalOptions } from 'firebase-functions/v2';

// Set global options for all v2 functions
// maxInstances helps control costs by limiting concurrent executions
setGlobalOptions({ maxInstances: 10 });

// ============================================================================
// HTTP API Endpoints
// ============================================================================

// User Profile - CRUD operations for user profile data
export { userProfile } from './api/user-profile';

// Mood Check-in - Submit mood check-ins and get AI encouragement
export { moodCheckIn } from './api/mood-checkin';

// Daily Reflection - AI-generated devotional prompt cached once per day
export { dailyReflection } from './api/daily-reflection';

// Journal - CRUD operations for user journal entries
export { journal } from './api/journal';
