# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Development Workflow

1. **Think and Plan First**: Read the codebase for relevant files and write a plan to `tasks/todo.md`
2. **Create Todo List**: The plan should have a list of todo items that you can check off as you complete them
3. **Verify Before Starting**: Check in with me to verify the plan before beginning work
4. **Execute and Track Progress**: Work on todo items, marking them as complete as you go
5. **High-Level Updates**: Provide high-level explanations of changes at each step, not detailed play-by-play
6. **Simplicity First**: Make every task and code change as simple as possible. Avoid massive or complex changes. Every change should impact as little code as possible. Everything is about simplicity.
7. **Document Review**: Add a review section to the `todo.md` file with a summary of changes and relevant information
8. **NO LAZINESS**: DO NOT BE LAZY. NEVER BE LAZY. If there is a bug, find the root cause and fix it properly. No temporary fixes. You are a senior developer.
9. **Minimal Impact**: Make all fixes and code changes as simple as humanly possible. They should only impact necessary code relevant to the task and nothing else. Your goal is to not introduce any bugs. It's all about simplicity.

## Project Overview

WalkWorthy is a Scripture-based encouragement app for students. It combines daily context with personalized encouragement. The project has two main parts: a SwiftUI iOS app and a Firebase Cloud Functions backend.

## Build & Run Commands

### Backend (Firebase Cloud Functions) — `functions/`

```bash
cd functions
npm install            # Install dependencies
npm run build          # Compile TypeScript (tsc)
npm run build:watch    # Watch mode compilation
npm run serve          # Run local Firebase emulator
npm run deploy         # Deploy functions to Firebase
npm run logs           # Tail production logs
```

### iOS App — `WalkWorthy/WalkWorthy/`

```bash
open WalkWorthy/WalkWorthy.xcodeproj   # Open in Xcode
# Build and run the "WalkWorthy" target via Xcode
# Requires GoogleService-Info.plist (not in git)
# API base URL configured in Config.plist
```

### Deployment

CI/CD via GitHub Actions (`.github/workflows/firebase-deploy.yml`) on push to `main`. Deploys functions, Firestore rules, and Firestore indexes.

## Architecture

### iOS App (`WalkWorthy/WalkWorthy/`)

- **SwiftUI** with Swift concurrency (`async/await`, `actor`, `@MainActor`)
- **`AppState`** — central `@MainActor ObservableObject`, source of truth for auth state, mood data, and profile. Published properties drive SwiftUI re-renders. User preferences are scoped by authenticated user ID in UserDefaults.
- **`FirebaseAuthSession`** — `actor` conforming to `BearerTokenProviding` protocol; provides ID tokens for API calls
- **`LiveAPIClient`** — implements `EncouragementAPI` protocol; handles bearer token injection, JSON encoding with ISO8601 dates, retry logic for cold starts
- **Error types** — domain-specific enums conforming to `LocalizedError` (`APIError`, `AuthError`, `MoodError`)
- **`import Combine` is required** in any file using `@Published` or `ObservableObject` — SwiftUI does not fully re-export Combine

### Backend (`functions/src/`)

- **Firebase Functions v2** (Node 24, TypeScript, strict mode)
- **API endpoints** in `api/`: `mood-checkin`, `user-profile`, `journal`, `daily-reflection`, `delete-account`
- **Auth middleware**: `requireAuth()` in `shared/auth.ts` verifies Firebase ID tokens
- **Firestore** — collections under `users/{userId}/`: `profile`, `moodCheckIns`, `moodSummaries`, `dailyReflections`, `journalEntries`
- **AI integration**: OpenAI AgentKit in `lib/mood-agent.ts` with Zod schema validation, PII guardrails, structured output
- **Secrets**: Google Secret Manager via `shared/secrets.ts` (never env vars for sensitive data)
- **Logging**: Use `logger` from `firebase-functions/v2` (not `console.log`)

### Key Security Patterns

- `redactSensitiveFields()` (`shared/redact.ts`) for safe logging — never log tokens/keys
- Firestore rules: client reads are owner-scoped, ALL client writes denied — writes go through Cloud Functions only
- Notifications are LOCAL-ONLY (scheduled on-device via `NotificationScheduler`); there is deliberately no server push / device-token storage
- `NODE_ENV === "development"` for detailed errors (secure-by-default)
- All user input validated with explicit validation functions before processing

### Firestore Document Patterns

- Deterministic document IDs prevent duplicates (e.g., `${date}_${checkInType}` for mood check-ins)
- Transactions for atomic read-then-write operations
- Existing document detection returns current data instead of duplicating

## TypeScript Best Practices

### Never use 'any' type for type declarations

Instead, use:
- Specific types or interfaces
- Generic types (`T`, etc.)
- Union types (`string | number`)
- `unknown` (when the type is truly unknown but needs type checking)
- Utility types (`Record<string, unknown>`, `Partial<T>`, etc.)

## Swift Best Practices

- DateFormatters must be `static` cached constants, never created inline in computed properties
- ISO date formatters need `locale = Locale(identifier: "en_US_POSIX")` for reliable parsing
- Use `#if DEBUG` for conditional logging
- Use `actor` for thread-safe shared state, `@MainActor` for UI state
