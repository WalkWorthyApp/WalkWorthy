import { Request, Response } from "express";
import { logger } from "firebase-functions/v2";
import http from "http";
import { getAuthInstance, getAppCheckInstance } from "./firebase";
import { DecodedIdToken } from "firebase-admin/auth";

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
export async function verifyAuthToken(
  req: Request
): Promise<DecodedIdToken | null> {
  const authHeader = req.headers.authorization;

  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    logger.warn("Auth header missing or malformed", {
      hasHeader: !!authHeader,
      startsWithBearer: authHeader?.startsWith("Bearer "),
    });
    return null;
  }

  const idToken = authHeader.split("Bearer ")[1];
  if (!idToken) {
    return null;
  }

  try {
    const auth = getAuthInstance();
    const decodedToken = await auth.verifyIdToken(idToken);
    return decodedToken;
  } catch (error) {
    logger.warn("Auth token verification failed", {
      error: error instanceof Error ? error.message : "Unknown error",
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
    errorResponse(res, 401, "Valid authentication required");
    return null;
  }

  // Email/password accounts must verify their address before using the API.
  // Federated providers (e.g. Sign in with Apple) verify emails upstream, so
  // only the "password" provider is gated here.
  if (
    decodedToken.firebase.sign_in_provider === "password" &&
    decodedToken.email_verified !== true
  ) {
    logger.info("Rejecting unverified email/password account", {
      userId: decodedToken.uid,
    });
    errorResponse(
      res,
      403,
      "Email verification required",
      undefined,
      "EMAIL_UNVERIFIED"
    );
    return null;
  }

  // Attach user info to request
  const authReq = req as AuthenticatedRequest;
  authReq.user = decodedToken;
  authReq.userId = decodedToken.uid;

  return authReq;
}

/**
 * Verify Firebase App Check token from X-Firebase-AppCheck header.
 *
 * @param req - Express request object
 * @param res - Express response object
 * @returns true if valid, false if rejected (response already sent)
 */
export async function verifyAppCheck(
  req: Request,
  res: Response
): Promise<boolean> {
  const token = req.headers['x-firebase-appcheck'];
  if (!token || typeof token !== 'string') {
    errorResponse(res, 401, 'Missing App Check token');
    return false;
  }

  try {
    const appCheck = getAppCheckInstance();
    await appCheck.verifyToken(token);
    return true;
  } catch (error) {
    logger.warn('App Check verification failed', {
      error: error instanceof Error ? error.message : 'Unknown error',
    });
    errorResponse(res, 401, 'Invalid App Check token');
    return false;
  }
}

/**
 * Machine-readable error codes the iOS client can branch on.
 */
export type ApiErrorCode = "EMAIL_UNVERIFIED";

/**
 * Standard error response format
 */
export function errorResponse(
  res: Response,
  status: number,
  message: string,
  details?: unknown,
  code?: ApiErrorCode
) {
  const response: {
    error: string;
    message: string;
    details?: unknown;
    code?: ApiErrorCode;
  } = {
    error:
      http.STATUS_CODES[status] ||
      (status >= 500 ? "Internal Server Error" : "Error"),
    message,
  };

  if (code) {
    response.code = code;
  }

  if (details && process.env.NODE_ENV === "development") {
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
