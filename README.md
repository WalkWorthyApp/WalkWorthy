# WalkWorthy

WalkWorthy is a Scripture-based encouragement app for Christians. It combines mood tracking with AI-generated, personalized verse-based encouragement. The project includes a SwiftUI iOS app and a Firebase Cloud Functions backend.

## What's Inside

- A **SwiftUI iOS app** with onboarding, authentication, mood check-ins (morning, midday, evening), AI-powered encouragement responses, mood history, and settings.
- A **Firebase Cloud Functions backend** (Node 24, TypeScript) with API endpoints, OpenAI Agents SDK integration, and a Firestore data layer.
- **Firestore security rules** and indexes for data access control.

## How It Works

1. Users sign up and complete a brief profile (optional display name, age range, occupation or field of study, interests).
2. Throughout the day, they do mood check-ins — select a mood and answer a follow-up question.
3. With the user's explicit consent, the backend sends the mood context to an AI agent (OpenAI Agents SDK) that writes a personalized encouragement and selects a passage by ID.
4. Encouragements include a message plus a verse reference and text served from a reviewed server-side ESV catalog — the model never writes or transcribes the quotation itself.
5. Local, on-device reminders and mood history help users keep the habit. WalkWorthy sends no push notifications and stores no device tokens.

## Tech Stack

- **iOS**: SwiftUI, Swift concurrency (async/await, actor), Firebase SDK
- **Backend**: Firebase Functions v2, TypeScript (strict), OpenAI Agents SDK, Zod validation
- **Infrastructure**: Firebase Auth, Firestore, Google Cloud Secret Manager
- **CI/CD**: GitHub Actions deploys functions, Firestore rules, and indexes on push to `main`

## Getting Started

### iOS App

1. Open `WalkWorthy/WalkWorthy.xcodeproj` in Xcode.
2. Add `GoogleService-Info.plist` and `Config.plist` (not checked into git).
3. Build and run the **WalkWorthy** target on a simulator or device.

### Backend

```bash
cd functions
npm ci               # Install locked dependencies
npm run build        # Compile TypeScript
npm run serve        # Build and start Firebase emulator
```

### Deployment

Push to `main` triggers the GitHub Actions pipeline (`.github/workflows/firebase-deploy.yml`), which runs all backend tests with the Firestore emulator before deploying functions, Firestore rules/indexes, and Hosting.

To run the same test gate locally from the repository root (Node 24, Java 21,
Firebase CLI 15.29.0):

```bash
firebase emulators:exec --only firestore --project demo-walkworthy-compliance "npm --prefix functions run test:ci"
```

The CI runner rejects missing emulator configuration and skipped tests. Plain
`npm test` in `functions/` remains available for unit checks without Firestore.

Confirming account deletion starts device erasure immediately. A local intent
stores the UID, legacy ownership decision, and separate device/server completion
flags. Disk errors do not prevent the server request; startup and foreground retry
unfinished device cleanup even after Auth is gone. Pending accounts cannot
rehydrate content. The app exposes retry and sign-out from that state.
Reminder scheduling carries an account-session identity and unique operation IDs;
deletion/sign-out invalidate stale work, including adds completing after cleanup.
The API promises automatic recovery only after it confirms a durable server job;
unconfirmed acceptance requires retry or support. New consent withdrawals carry
an operation ID: fresh choices invalidate stale grants even when sharing is
already off, while retries reuse that choice's ID.

Consent reads have a separate 300/hour per-user allowance for foreground refreshes
and grant preflights; grants retain a 30/hour allowance. Withdrawal bypasses both.
Quota checks deny access on database failure, returning 503 with a short retry
hint. Only genuine quota exhaustion returns 429; deletion barriers return 403.

Account deletion uses a durable pending record and a lease shared by client
requests and `retryAccountDeletions`. The scheduled function retries up to ten
due jobs every fifteen minutes. Client cleanup attempts remain limited to three
per hour; scheduled recovery continues independently. Pending records do not
expire. Completed records contain only deletion state and a seven-day TTL.
Deploy the scheduled function along with the HTTP endpoints and verify its
Cloud Scheduler job and recovery logs before release. No retry worker is
operational merely because it exists in source.

## Project Structure

```
WalkWorthy/WalkWorthy/       iOS app source (SwiftUI)
functions/src/               Cloud Functions backend
  api/                       API endpoints
  lib/                       AI agent logic
  shared/                    Auth, crypto, types, utilities
.github/workflows/           CI/CD pipeline
```

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/moodCheckIn` | Submit a mood check-in, get AI encouragement |
| `GET` | `/moodCheckIn` | Today's latest check-in or pending info |
| `GET` | `/moodCheckIn?history=N` | Mood history for the past N days |
| `GET` | `/user-profile` | Get profile |
| `PUT` | `/user-profile` | Create or replace profile |
| `PATCH` | `/user-profile` | Partially update profile |
| `DELETE` | `/user-profile` | Delete profile |

All endpoints require a valid Firebase Auth ID token in the `Authorization` header.
