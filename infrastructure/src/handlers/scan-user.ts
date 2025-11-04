import type { APIGatewayProxyEventV2 } from 'aws-lambda';

import { getUserSub } from '../shared/auth';
import { json, internalError, unauthorized } from '../shared/http';
import { runScanForUser, CalendarLinkMissingError } from '../services/scan-runner';

export async function handler(event: APIGatewayProxyEventV2) {
  const sub = getUserSub(event);
  if (!sub) {
    console.warn('scan-user: unauthorized request', {
      requestId: event.requestContext.requestId,
    });
    return unauthorized();
  }

  console.log('scan-user: received scan request', {
    sub,
    requestId: event.requestContext.requestId,
  });
  try {
    const result = await runScanForUser(sub);

    console.log('scan-user: scan accepted', {
      sub,
      encouragementId: result.encouragementId,
      status: result.status,
    });
    return json(202, {
      message: 'Scan accepted',
      encouragementId: result.encouragementId,
      status: result.status,
    });
  } catch (error) {
    if (error instanceof CalendarLinkMissingError) {
      console.warn('scan-user: calendar link missing', {
        sub,
        status: error.status ?? 'MISSING',
      });
      return json(409, {
        message: error.message,
        status: error.status ?? 'MISSING',
      });
    }

    console.error('scan-user: scan failed', {
      sub,
      error,
    });
    return internalError();
  }
}
