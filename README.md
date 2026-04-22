# WalkWorthy

WalkWorthy is a Scripture-based encouragement app for students. It combines mood tracking with AI-generated, personalized verse-based encouragement. The project includes a SwiftUI iOS app and a Firebase Cloud Functions backend.

## What's Inside

- A **SwiftUI iOS app** with onboarding, authentication, mood check-ins (morning, midday, evening), AI-powered encouragement responses, mood history, and settings.
- A **Firebase Cloud Functions backend** (Node 24, TypeScript) with API endpoints, OpenAI Agents SDK integration, and a Firestore data layer.
- **Firestore security rules** and indexes for data access control.

## How It Works

1. Students sign up and complete a brief profile (name, school year, interests).
2. Throughout the day, they do mood check-ins — select a mood and answer a follow-up question.
3. The backend sends the mood context to an AI agent (OpenAI Agents SDK) that generates a personalized Scripture-based encouragement.
4. Encouragements include a message, verse reference, verse text, and translation.
5. Push notifications and mood history keep students engaged.

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
npm install          # Install dependencies
npm run build        # Compile TypeScript
npm run serve        # Build and start Firebase emulator
```

### Deployment

Push to `main` triggers the GitHub Actions pipeline (`.github/workflows/firebase-deploy.yml`), which deploys functions, Firestore rules, and indexes.

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
