import { logger } from 'firebase-functions/v2';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { getAuthInstance, getDb } from '../shared/firebase';
import { retryPendingAccountDeletions } from '../shared/account-deletion';
import { FUNCTIONS_REVISION } from '../shared/version';

export const retryAccountDeletions = onSchedule({
  schedule: 'every 15 minutes', timeoutSeconds: 540, maxInstances: 1,
}, async () => {
  logger.info('Account deletion recovery invoked', {revision: FUNCTIONS_REVISION});
  const counts = await retryPendingAccountDeletions(getDb(), getAuthInstance());
  // No identifiers, user content, or provider errors in recovery logs.
  if (counts.failed > 0) logger.error('Account deletion recovery needs another attempt', counts);
  else if (counts.completed > 0) logger.info('Account deletion recovery completed', counts);
});
