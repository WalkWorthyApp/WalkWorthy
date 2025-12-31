import { Request, Response } from 'express';
import { logger } from 'firebase-functions/v2';
import http from 'http';
import { getAuthInstance } from './firebase';
import { DecodedIdToken } from 'firebase-admin/auth';

/**
 * Authenticated request with verified user info
 */
export interface AuthenticatedRequest extends Request {
  user: DecodedIdToken;
  userId: string;
}

/**
 * Extract and verify Firebase ID token from Authorization header.
 *
 * @param req - Express request object
 * @returns Decoded token if valid, null otherwise
 */
export async function verifyAuthToken(req: Request): Promise<DecodedIdToken | null> {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    logger.warn('Auth header missing or malformed', {
      hasHeader: !!authHeader,
      startsWithBearer: authHeader?.startsWith('Bearer '),
    });
    return null;
  }

  const idToken = authHeader.split('Bearer ')[1];
  if (!idToken) {
    return null;
  }

  try {
    const auth = getAuthInstance();
    const decodedToken = await auth.verifyIdToken(idToken);
    return decodedToken;
  } catch (error) {
    logger.warn('Auth token verification failed', {
      error: error instanceof Error ? error.message : 'Unknown error',
    });
    return null;
  }
}

/**
 * Middleware-style authentication for Firebase Functions.
 * Returns authenticated request or sends 401 response.
 *
 * @param req - Express request
 * @param res - Express response
 * @returns AuthenticatedRequest if valid, null if unauthorized (response already sent)
 */
export async function requireAuth(
  req: Request,
  res: Response
): Promise<AuthenticatedRequest | null> {
  const decodedToken = await verifyAuthToken(req);

  if (!decodedToken) {
    res.status(401).json({ error: 'Unauthorized', message: 'Valid authentication required' });
    return null;
  }

  // Attach user info to request
  const authReq = req as AuthenticatedRequest;
  authReq.user = decodedToken;
  authReq.userId = decodedToken.uid;

  return authReq;
}

/**
 * Standard error response format
 */
export function errorResponse(res: Response, status: number, message: string, details?: unknown) {
  const response: { error: string; message: string; details?: unknown } = {
    error: http.STATUS_CODES[status] || (status >= 500 ? 'Internal Server Error' : 'Error'),
    message,
  };

  if (details && process.env.NODE_ENV !== 'production') {
    response.details = details;
  }

  res.status(status).json(response);
}

/**
 * Standard success response format
 */
export function successResponse<T>(res: Response, data: T, status = 200) {
  res.status(status).json(data);
}
