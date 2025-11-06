# WalkWorthy

WalkWorthy combines daily Canvas context with Scripture-based encouragement. This repository houses the SwiftUI iOS experience, the supporting AWS infrastructure, and the agent pipeline that produces the final messages.

## What’s Inside
- A SwiftUI mobile app that guides students through onboarding, sign-in, calendar linking, viewing encouragements, and reviewing agenda/history information.
- An AWS CDK project that provisions the API layer, Lambda functions, data storage, and scheduled jobs the app depends on.
- Shared logic for translating Canvas data into stress insights, sourcing verse candidates, and selecting a final encouragement with guardrails.

## How It Works
1. Students connect their Canvas read-only calendar feed and share a few optional profile preferences.
2. On-demand or scheduled scans pull upcoming items, assess stress signals, gather verse options through the Bible MCP bridge, and task AgentKit with choosing the best fit.
3. The resulting encouragement is stored for mobile consumption, surfaced in the app, and optionally delivered through background refresh and notifications.

## Key Capabilities
- Live-only runtime wired to the production API stack with environment-driven configuration.
- Cognito-backed authentication flow with secure token handling and automatic request signing.
- Background refresh, agenda snapshots, and notification scheduling designed for daily use.
- Guarded agent execution that enforces strict output schemas, filters sensitive content, and validates chosen verses against the provided candidates.

## Getting Started (App)
1. Open `WalkWorthy/WalkWorthy.xcodeproj` in Xcode.
2. Ensure the required environment overrides (e.g., `API_BASE_URL`, Cognito domain/client IDs, redirect URIs) are set for the live stack.
3. Run the `WalkWorthy` target on a simulator or device.
4. Sign in through the Hosted UI, paste your Canvas calendar link, and use “Scan Now” to view the full flow.

## Deployment Snapshot
- The CDK stack imports the existing `walkworthy` DynamoDB table and the `walkworthy/openai/api-key` secret, provisions the HTTP API plus Lambda functions, and schedules weekday scans.
- `enableJwtAuth` is on by default; pass Cognito pool and client IDs at deploy time or disable the flag for unauthenticated development.
- Additional behavior (allowed Canvas hosts, MCP mode, OpenAI model, excluded verses, etc.) is configurable through CDK context or environment variables.
- CI/CD automation requires access to the CDK bootstrap resources and typical CloudFormation/IAM/Lambda permissions.

Explore the `prompts/` directory for deeper architectural context and future roadmap notes.
