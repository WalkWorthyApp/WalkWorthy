import { onRequest, HttpsOptions } from 'firebase-functions/v2/https';
import { logger } from 'firebase-functions/v2';
import { getDb, COLLECTIONS, initializeFirebase } from '../shared/firebase';
import { requireAuth, errorResponse, successResponse } from '../shared/auth';

// Initialize Firebase on module load
initializeFirebase();

const httpsOptions: HttpsOptions = {
  cors: true,
  maxInstances: 10,
  invoker: 'public', // Allow unauthenticated HTTP access (auth handled in code)
};

interface EncouragementData {
  id: string;
  ref: string;
  text: string;
  encouragement: string;
  translation: string;
  createdAt: string;
  expiresAt: string;
}

/**
 * Encouragement Next API
 *
 * GET /encouragement-next - Get the latest valid encouragement for the user
 *
 * Returns the most recent encouragement that hasn't expired.
 * If no valid encouragement exists, returns null.
 */
export const encouragementNext = onRequest(httpsOptions, async (req, res) => {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return errorResponse(res, 405, `Method ${req.method} not allowed`);
  }

  // Authenticate request
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  try {
    const now = new Date().toISOString();

    // Query for the most recent non-expired encouragement
    const encouragementsRef = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('encouragements');

    const querySnapshot = await encouragementsRef
      .where('expiresAt', '>', now)
      .orderBy('expiresAt', 'asc')  // Order by expiresAt to match the where clause
      .orderBy('createdAt', 'desc')  // Then by creation time
      .limit(1)
      .get();

    if (querySnapshot.empty) {
      logger.info('No valid encouragement found', { userId });
      // Response format must match iOS NextResponse model
      return successResponse(res, {
        shouldNotify: false,
        payload: null,
        metadata: null,
      });
    }

    const doc = querySnapshot.docs[0];
    const data = doc.data() as EncouragementData;

    logger.info('Encouragement retrieved', {
      userId,
      encouragementId: data.id,
      ref: data.ref,
    });

    // Response format must match iOS NextResponse model
    return successResponse(res, {
      shouldNotify: true,
      payload: {
        id: data.id,
        ref: data.ref,
        text: data.text,
        encouragement: data.encouragement,
        translation: data.translation,
        expiresAt: data.expiresAt,
      },
      metadata: {
        encouragementId: data.id,
        status: 'SUCCESS',
        plannerCount: null,
        stressfulCount: null,
        candidateCount: null,
        tags: null,
        errorMessage: null,
      },
    });
  } catch (error) {
    logger.error('Failed to retrieve encouragement', {
      userId,
      error: error instanceof Error ? error.message : 'Unknown error',
    });
    return errorResponse(res, 500, 'Internal server error');
  }
});

/**
 * Encouragement History API
 *
 * GET /encouragement-history - Get recent encouragements for the user
 *
 * Query params:
 * - limit: Number of items to return (default: 10, max: 50)
 */
export const encouragementHistory = onRequest(httpsOptions, async (req, res) => {
  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return errorResponse(res, 405, `Method ${req.method} not allowed`);
  }

  // Authenticate request
  const authReq = await requireAuth(req, res);
  if (!authReq) return;

  const { userId } = authReq;
  const db = getDb();

  try {
    // Parse limit from query params
    let limit = 10;
    if (req.query.limit) {
      const parsed = parseInt(String(req.query.limit), 10);
      if (!isNaN(parsed) && parsed > 0 && parsed <= 50) {
        limit = parsed;
      }
    }

    const encouragementsRef = db
      .collection(COLLECTIONS.users)
      .doc(userId)
      .collection('encouragements');

    const querySnapshot = await encouragementsRef
      .orderBy('createdAt', 'desc')
      .limit(limit)
      .get();

    const encouragements = querySnapshot.docs.map((doc) => {
      const data = doc.data() as EncouragementData;
      return {
        id: data.id,
        ref: data.ref,
        text: data.text,
        encouragement: data.encouragement,
        translation: data.translation,
        createdAt: data.createdAt,
        expiresAt: data.expiresAt,
        expired: new Date(data.expiresAt) < new Date(),
      };
    });

    logger.info('Encouragement history retrieved', {
      userId,
      count: encouragements.length,
    });

    return successResponse(res, { encouragements });
  } catch (error) {
    logger.error('Failed to retrieve encouragement history', {
      userId,
      error: error instanceof Error ? error.message : 'Unknown error',
    });
    return errorResponse(res, 500, 'Internal server error');
  }
});
