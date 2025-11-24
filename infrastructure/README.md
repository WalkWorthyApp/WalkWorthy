# WalkWorthy Infrastructure

The `infrastructure` package contains the AWS CDK project that deploys the WalkWorthy backend. It brings together the API surface, Lambda compute, data storage, event scheduling, and AgentKit/Bible MCP integration that power the mobile experience.

## Stack Snapshot
- API Gateway HTTP API with optional Cognito JWT authorization that fronts all mobile-facing routes.
- Node.js 20 Lambda functions (bundled with esbuild) for Canvas link management, user profile storage, scan orchestration, encouragement retrieval, device updates, notifications, and the Bible MCP bridge.
- Existing DynamoDB table `walkworthy` imported by name, providing single-table storage for user metadata, encouragements, scan history, and agenda snapshots.
- Secrets Manager integration for the OpenAI API key plus IAM grants that restrict access to the Lambdas that need it.
- EventBridge Scheduler job that kicks off weekday scans and pushes failures to an SQS dead-letter queue.

## Prerequisites
- Node.js 20+, npm, and an AWS account that has been CDK-bootstrapped.
- DynamoDB table `walkworthy` (partition key `pk`, sort key `sk`) already provisioned.
- Secrets Manager secret `walkworthy/openai/api-key` containing the AgentKit API key.
- IAM permissions capable of deploying CDK stacks (CloudFormation, IAM, Lambda, API Gateway, EventBridge, DynamoDB, Secrets Manager, SQS, Logs, SSM).

## Configuration Highlights
- Runtime behavior can be shaped through CDK context values or environment variables. Typical options include enabling/disabling Cognito auth, configuring allowed Canvas hosts, choosing MCP connection mode (lambda, http, stdio, disabled), overriding the OpenAI model, and fine-tuning verse exclusion lists.
- Default context (`cdk.json`) enables Cognito auth (`enableJwtAuth=true`). Supply the user pool and client IDs when deploying, or flip the flag to `false` for local testing without authentication.
- The Bible MCP bridge runs locally inside the stack by default; switch to an external endpoint by adjusting the MCP mode and URL/command settings.

## Deploying
1. `cd infrastructure`
2. `npm install`
3. Export `CDK_DEFAULT_ACCOUNT` and `CDK_DEFAULT_REGION` (or edit and source `cdk-env.sh`).
4. `npm run build` (or `npm run watch` while iterating).
5. `npx cdk synth` to review the CloudFormation template (optional).
6. `npx cdk deploy` with any required parameters (e.g., Cognito pool/client IDs when JWT auth is enabled).

Use `npx cdk diff` to inspect changes before redeploying.

## Development Tips
- All Lambda handlers share a common environment block (table name, Canvas allow-list, MCP configuration, OpenAI settings, verse exclusions) defined in `InfrastructureStack`.
- Helper modules under `src/shared`, `src/lib`, and `src/services` encapsulate Dynamo utilities, authentication helpers, calendar ingestion, stress heuristics, and the scan pipeline.
- Jest scaffolding is available (`npm run test`) for future unit tests, though none ship today.

## Canvas secret cleanup
- Migrate and delete legacy Secrets Manager entries (`walkworthy/canvas/user/*`) into DynamoDB:  
  `cd infrastructure && DRY_RUN=true AWS_REGION=<region> TABLE_NAME=walkworthy npm run migrate:canvas-secrets`  
  Remove `DRY_RUN=true` to execute. `RECOVERY_DAYS` controls delete recovery (set `0` to force delete without recovery); override `SECRET_PREFIX` if the naming convention differs. Requires Node 18+ and `ts-node` (already in dev deps); if your Node warns about the loader, this script runs via `ts-node --esm`.

## CI/CD Considerations
- Automated deployments must read the CDK bootstrap version parameter (`/cdk-bootstrap/hnb659fds/version`) and describe the bootstrap stack. Ensure the GitHub Actions role (or equivalent) carries those permissions alongside standard deployment access.
