# WalkWorthy

WalkWorthy pairs daily Canvas stressors with timely Scripture encouragements. The repository delivers both the iOS experience and the AWS CDK infrastructure outlined in the project architecture.

## Product Pillars
- End-to-end encouragement flow that blends Canvas task insights with spiritually supportive messaging delivered in-app.
- Modular mobile and infrastructure layers designed for iterative shipping and easy substitution of external services.

## Architecture Flow
- **iOS app** (SwiftUI) gathers profile inputs, authenticates with Amazon Cognito, collects each student’s Canvas calendar iCal feed, and requests encouragements on demand or through background reminders.
- **API Gateway HTTP API** fronts Lambda handlers that manage read-only calendar links, run daily scans, and surface encouragement content to the app.
- **Canvas integration** keeps the personal calendar feed in DynamoDB and scans upcoming assignments/events using `scan-user` with the iCal ingestion pipeline.
- **Bible MCP + AgentKit**: verse candidates flow through a lightweight bridge Lambda (`bible-mcp-bridge`) so `scan-user` and the weekday scheduler can invoke AgentKit models with contextual inputs.
- **DynamoDB single-table** design tracks user profiles, Canvas linkage, scan history, and pending encouragement payloads that the app fetches via `/encouragement/next`.
- **EventBridge Scheduler → Lambda** drives the weekday 9am scan (`weekday-scan`) which reuses the same path as on-demand scans, persists new encouragements, and queues notification work.
- **Notification lane** lets the backend mark encouragements ready and allows the app to POST device tokens so future push or local-notification plumbing can fan out.

The net effect is a pipeline where data flows from Canvas → DynamoDB → AgentKit → app, with Cognito-protected endpoints enforcing trust boundaries.

## Current Implementation Highlights
- **Mobile app (SwiftUI)**: onboarding, home scan dashboard, history, and settings views styled with the “liquid glass” treatment. Supports Cognito Hosted UI sign-in, Canvas OAuth linking, manual scans, local verse history, and notification reminders. Mock data remains available for design iteration.
- **Networking layer**: typed async clients hit `/scan/now`, `/encouragement/next`, `/user/profile`, `/user/calendar-link`, `/device/register`, and `/encouragement/notify`, automatically attaching Cognito tokens when available.
- **Infrastructure (AWS CDK TypeScript)**: deploys the HTTP API, Lambda handlers (`calendar-link`, `scan-user`, `weekday-scan`, `encouragement-next`, `notify-user`, `register-device`, `user-profile`, `bible-mcp-bridge`), DynamoDB table binding, EventBridge Scheduler with DLQ, and IAM policies for AgentKit access.
- **Data & workflow**: scans compute stress heuristics, fetch verse candidates via the Bible MCP bridge, ask AgentKit to craft the final encouragement, write the result to DynamoDB, and surface it to the client until acknowledged.

## Repository Tour
- `WalkWorthy/`: Xcode project and SwiftUI sources for the iOS client (e.g. `UI/Onboarding/TitleScreenView.swift`, auth/session management, mock payloads).
- `infrastructure/`: AWS CDK app (`infrastructure-stack.ts`) with Lambda handlers under `src/handlers/`.

## Working With The App
- Open `WalkWorthy/WalkWorthy.xcodeproj`, select the `WalkWorthy` target, and run on a simulator or device.
- Toggle between mock responses and live API usage by swapping the bundled configuration plist; no source changes are required.
- Sign in through the built-in Cognito Hosted UI, follow the in-app guide to paste your Canvas calendar feed, and use “Scan Now” to exercise the full backend loop.

## Deployment Notes
- Provision the backend by bootstrapping CDK and deploying the stack in `infrastructure/`.
- After deployment, plug the resulting API URL, Cognito settings, and Canvas domain into the app’s configuration bundle to run in live mode.
