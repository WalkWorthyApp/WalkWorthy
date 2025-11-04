import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { Duration } from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import {
  NodejsFunction,
  NodejsFunctionProps,
} from 'aws-cdk-lib/aws-lambda-nodejs';
import * as apigwv2 from 'aws-cdk-lib/aws-apigatewayv2';
import * as apigwAuthorizers from 'aws-cdk-lib/aws-apigatewayv2-authorizers';
import * as apigwIntegrations from 'aws-cdk-lib/aws-apigatewayv2-integrations';
import * as scheduler from 'aws-cdk-lib/aws-scheduler';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as iam from 'aws-cdk-lib/aws-iam';

export class InfrastructureStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const enableJwtAuth = this.node.tryGetContext('enableJwtAuth') === 'true';
    let jwtAuthorizer: apigwAuthorizers.HttpJwtAuthorizer | undefined;
    if (enableJwtAuth) {
      const userPoolId = new cdk.CfnParameter(this, 'CognitoUserPoolId', {
        type: 'String',
        description:
          'User pool ID that issues JWTs for the WalkWorthy mobile app.',
      });

      const userPoolClientId = new cdk.CfnParameter(
        this,
        'CognitoUserPoolClientId',
        {
          type: 'String',
          description:
            'App client ID whose tokens authorize access to protected routes.',
        },
      );

      jwtAuthorizer = new apigwAuthorizers.HttpJwtAuthorizer(
        'WalkWorthyJwtAuthorizer',
        cdk.Fn.join('', [
          'https://cognito-idp.',
          this.region,
          '.amazonaws.com/',
          userPoolId.valueAsString,
        ]),
        {
          jwtAudience: [userPoolClientId.valueAsString],
        },
      );
    }

    const table = dynamodb.TableV2.fromTableName(
      this,
      'WalkWorthyTable',
      'walkworthy',
    );

    // Secret for OpenAI API key used by AgentKit (string secret)
    const openAiSecret = secretsmanager.Secret.fromSecretNameV2(
      this,
      'OpenAIApiKeySecret',
      'walkworthy/openai/api-key',
    );

    const bibleMcpBridgeFn = new NodejsFunction(this, 'BibleMcpBridgeFunction', {
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler',
      entry: path.join(__dirname, '../src/handlers/bible-mcp-bridge.ts'),
      memorySize: 256,
      timeout: Duration.seconds(5),
      bundling: {
        target: 'node20',
        minify: true,
      },
    });

    const schedulerDlq = new sqs.Queue(this, 'ScanSchedulerDlq', {
      queueName: 'walkworthy-scan-scheduler-dlq',
      retentionPeriod: Duration.days(14),
      visibilityTimeout: Duration.seconds(120),
      encryption: sqs.QueueEncryption.KMS_MANAGED,
    });

    const sharedLambdaProps: Omit<NodejsFunctionProps, 'entry'> = {
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: 'handler',
      memorySize: 256,
      timeout: Duration.seconds(10),
      bundling: {
        target: 'node20',
        minify: true,
      },
      environment: {
        TABLE_NAME: table.tableName,
        CANVAS_ALLOWED_HOSTS:
          this.node.tryGetContext('CANVAS_ALLOWED_HOSTS') ??
          process.env.CANVAS_ALLOWED_HOSTS ??
          '',
        // Bible MCP
        BIBLE_MCP_MODE: this.node.tryGetContext('BIBLE_MCP_MODE') ?? process.env.BIBLE_MCP_MODE ?? 'lambda',
        BIBLE_MCP_URL: this.node.tryGetContext('BIBLE_MCP_URL') ?? process.env.BIBLE_MCP_URL ?? '',
        BIBLE_MCP_DEFAULT_TRANSLATION: this.node.tryGetContext('BIBLE_MCP_DEFAULT_TRANSLATION') ?? process.env.BIBLE_MCP_DEFAULT_TRANSLATION ?? 'ESV',
        BIBLE_MCP_LAMBDA_ARN: bibleMcpBridgeFn.functionArn,
        // AgentKit
        OPENAI_MODEL: this.node.tryGetContext('OPENAI_MODEL') ?? process.env.OPENAI_MODEL ?? 'gpt-4.1',
        OPENAI_API_KEY_SECRET_NAME: openAiSecret.secretName,
        SCAN_EXCLUDED_VERSES:
          this.node.tryGetContext('SCAN_EXCLUDED_VERSES') ??
          process.env.SCAN_EXCLUDED_VERSES ??
          '["Philippians 4:6-7"]',
      },
    };

    const createHandler = (
      id: string,
      fileName: string,
      overrides?: Partial<NodejsFunctionProps>,
    ) => {
      const entry = path.join(__dirname, '../src/handlers', fileName);
      const baseEnvironment = sharedLambdaProps.environment ?? {};
      const overrideEnv = overrides?.environment ?? {};

      return new NodejsFunction(this, id, {
        ...sharedLambdaProps,
        ...overrides,
        entry,
        environment: {
          ...baseEnvironment,
          ...overrideEnv,
        },
        bundling: {
          ...sharedLambdaProps.bundling,
          ...(overrides?.bundling ?? {}),
        },
      });
    };

    const calendarLinkFn = createHandler(
      'CalendarLinkFunction',
      'calendar-link.ts',
      {
        timeout: Duration.seconds(30),
      },
    );
    const calendarAgendaFn = createHandler(
      'CalendarAgendaFunction',
      'calendar-agenda.ts',
    );
    const scanUserFn = createHandler('ScanUserFunction', 'scan-user.ts', {
      timeout: Duration.seconds(60),
    });
    const notifyUserFn = createHandler('NotifyUserFunction', 'notify-user.ts');
    const registerDeviceFn = createHandler(
      'RegisterDeviceFunction',
      'register-device.ts',
    );
    const userProfileFn = createHandler(
      'UserProfileFunction',
      'user-profile.ts',
    );
    const encouragementNextFn = createHandler(
      'EncouragementNextFunction',
      'encouragement-next.ts',
    );
    const weekdayScanFn = createHandler('WeekdayScanFunction', 'weekday-scan.ts', {
      timeout: Duration.seconds(60),
    });

    table.grantReadWriteData(calendarLinkFn);
    table.grantReadData(calendarAgendaFn);
    table.grantReadWriteData(scanUserFn);
    table.grantReadWriteData(notifyUserFn);
    table.grantReadWriteData(registerDeviceFn);
    table.grantReadWriteData(userProfileFn);
    table.grantReadWriteData(encouragementNextFn);
    table.grantReadWriteData(weekdayScanFn);

    // Allow scanUser to read OpenAI API key from Secrets Manager
    openAiSecret.grantRead(scanUserFn);
    openAiSecret.grantRead(weekdayScanFn);

    bibleMcpBridgeFn.grantInvoke(scanUserFn);
    bibleMcpBridgeFn.grantInvoke(weekdayScanFn);

    // If using a secret for OpenAI API key instead of env var, grant here.
    // Example: const openAiSecret = secretsmanager.Secret.fromSecretNameV2(this, 'OpenAIKey', 'walkworthy/openai/api-key');
    // openAiSecret.grantRead(scanUserFn);

    const httpApi = new apigwv2.HttpApi(this, 'WalkWorthyHttpApi', {
      apiName: 'walkworthy-api',
      corsPreflight: {
        allowOrigins: ['*'],
        allowMethods: [
          apigwv2.CorsHttpMethod.GET,
          apigwv2.CorsHttpMethod.POST,
          apigwv2.CorsHttpMethod.PUT,
          apigwv2.CorsHttpMethod.DELETE,
        ],
        allowHeaders: ['Authorization', 'Content-Type'],
      },
    });

    httpApi.addRoutes({
      path: '/user/calendar-link',
      methods: [
        apigwv2.HttpMethod.GET,
        apigwv2.HttpMethod.PUT,
        apigwv2.HttpMethod.DELETE,
      ],
      authorizer: jwtAuthorizer,
      integration: new apigwIntegrations.HttpLambdaIntegration(
        'CalendarLinkIntegration',
        calendarLinkFn,
      ),
    });

    httpApi.addRoutes({
      path: '/user/calendar-agenda',
      methods: [apigwv2.HttpMethod.GET],
      authorizer: jwtAuthorizer,
      integration: new apigwIntegrations.HttpLambdaIntegration(
        'CalendarAgendaIntegration',
        calendarAgendaFn,
      ),
    });

    httpApi.addRoutes({
      path: '/user/profile',
      methods: [apigwv2.HttpMethod.POST],
      authorizer: jwtAuthorizer,
      integration: new apigwIntegrations.HttpLambdaIntegration(
        'UserProfileIntegration',
        userProfileFn,
      ),
    });

    httpApi.addRoutes({
      path: '/scan/now',
      methods: [apigwv2.HttpMethod.POST],
      authorizer: jwtAuthorizer,
      integration: new apigwIntegrations.HttpLambdaIntegration(
        'ScanNowIntegration',
        scanUserFn,
      ),
    });

    httpApi.addRoutes({
      path: '/encouragement/next',
      methods: [apigwv2.HttpMethod.GET],
      authorizer: jwtAuthorizer,
      integration: new apigwIntegrations.HttpLambdaIntegration(
        'EncouragementNextIntegration',
        encouragementNextFn,
      ),
    });

    httpApi.addRoutes({
      path: '/device/register',
      methods: [apigwv2.HttpMethod.POST],
      authorizer: jwtAuthorizer,
      integration: new apigwIntegrations.HttpLambdaIntegration(
        'RegisterDeviceIntegration',
        registerDeviceFn,
      ),
    });

    httpApi.addRoutes({
      path: '/encouragement/notify',
      methods: [apigwv2.HttpMethod.POST],
      authorizer: jwtAuthorizer,
      integration: new apigwIntegrations.HttpLambdaIntegration(
        'NotifyUserIntegration',
        notifyUserFn,
      ),
    });

    const schedulerRole = new iam.Role(this, 'ScanSchedulerRole', {
      assumedBy: new iam.ServicePrincipal('scheduler.amazonaws.com'),
      description:
        'Role assumed by EventBridge Scheduler to invoke the scanUser function.',
    });

    scanUserFn.grantInvoke(schedulerRole);
    weekdayScanFn.grantInvoke(schedulerRole);
    schedulerDlq.grantSendMessages(schedulerRole);

    new scheduler.CfnSchedule(this, 'WeekdayScanSchedule', {
      name: 'walkworthy-weekday-scan',
      description:
        'Weekday 9am America/New_York scan to refresh Canvas data and prepare encouragements.',
      flexibleTimeWindow: {
        mode: 'FLEXIBLE',
        maximumWindowInMinutes: 10,
      },
      scheduleExpression: 'cron(0 9 ? * MON-FRI *)',
      scheduleExpressionTimezone: 'America/New_York',
      target: {
        arn: weekdayScanFn.functionArn,
        roleArn: schedulerRole.roleArn,
        deadLetterConfig: {
          arn: schedulerDlq.queueArn,
        },
        retryPolicy: {
          maximumEventAgeInSeconds: 3600,
          maximumRetryAttempts: 2,
        },
      },
    });

    new cdk.CfnOutput(this, 'TableName', {
      value: table.tableName,
    });

    new cdk.CfnOutput(this, 'HttpApiUrl', {
      value: httpApi.apiEndpoint,
    });

  }
}
