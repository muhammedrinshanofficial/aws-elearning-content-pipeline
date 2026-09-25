# --- VPC ---
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name    = "${var.project_name}-vpc"
    Project = var.project_name
  }
}

# --- Public subnet (for ECS Fargate worker - needs internet to pull from ECR) ---
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block               = "10.0.1.0/24"
  map_public_ip_on_launch  = true
  availability_zone        = "${var.aws_region}a"

  tags = {
    Name    = "${var.project_name}-public-subnet"
    Project = var.project_name
  }
}

# --- Internet Gateway + routing, so the public subnet can reach the internet ---
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project_name}-igw"
    Project = var.project_name
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project_name}-public-rt"
    Project = var.project_name
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# --- Security group for the ECS preprocessing worker ---
# Zero inbound rules: nothing can initiate a connection to it from
# outside. Outbound-only, so it can pull its image from ECR and call
# other AWS APIs, despite sitting in a public subnet.
resource "aws_security_group" "ecs_worker" {
  name        = "${var.project_name}-ecs-worker-sg"
  description = "Zero inbound - outbound only, for the ECS preprocessing worker"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-ecs-worker-sg"
    Project = var.project_name
  }
}

# --- Free VPC Gateway Endpoints for S3 and DynamoDB ---
# Avoids routing S3/DynamoDB traffic through a NAT Gateway (which
# costs money) - gateway endpoints are free.
resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = [aws_route_table.public.id]

  tags = {
    Name    = "${var.project_name}-s3-endpoint"
    Project = var.project_name
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.aws_region}.dynamodb"
  route_table_ids = [aws_route_table.public.id]

  tags = {
    Name    = "${var.project_name}-dynamodb-endpoint"
    Project = var.project_name
  }
}

# --- S3 bucket: raw instructor-uploaded video ---
resource "aws_s3_bucket" "raw_video" {
  bucket = "${var.project_name}-raw-video-${var.unique_suffix}"

  tags = {
    Name    = "${var.project_name}-raw-video"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "raw_video" {
  bucket                  = aws_s3_bucket.raw_video.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw_video" {
  bucket = aws_s3_bucket.raw_video.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- S3 bucket: processed output (transcript JSON, PDF study notes) ---
resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${var.unique_suffix}"

  tags = {
    Name    = "${var.project_name}-processed"
    Project = var.project_name
  }
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket                  = aws_s3_bucket.processed.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- S3 bucket: static frontend web app ---
# NOT blocked from public access - this one needs to serve files
# publicly via CloudFront later. Left plain for now; CloudFront +
# Origin Access Control gets wired in a later step.
resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-${var.unique_suffix}"

  tags = {
    Name    = "${var.project_name}-frontend"
    Project = var.project_name
  }
}

# --- DynamoDB table: course/video metadata ---
resource "aws_dynamodb_table" "course_metadata" {
  name         = "${var.project_name}-course-metadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "video_id"

  attribute {
    name = "video_id"
    type = "S"
  }

  tags = {
    Name    = "${var.project_name}-course-metadata"
    Project = var.project_name
  }
}

# --- ECS Task Execution Role ---
# Used by ECS itself (not your app code) to pull the image from ECR
# and write logs to CloudWatch. AWS provides a managed policy for
# this exact purpose - no need to write it by hand.
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- ECS Task Role ---
# Used by YOUR CODE running inside the container (not ECS itself) -
# whatever the preprocessing worker needs to actually do its job,
# e.g. read/write S3. Intentionally empty of permissions for now -
# will attach specific policies once the worker code is written and
# we know exactly what it touches.
resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

# --- Lambda Execution Role (base) ---
# Shared starting point for pipeline Lambda functions (dispatcher,
# PDF generator, notification handler, etc). Basic CloudWatch Logs
# permission only for now - each function gets its specific
# permissions (S3, DynamoDB, Step Functions StartExecution, etc.)
# attached when that function is actually built.
resource "aws_iam_role" "lambda_execution" {
  name = "${var.project_name}-lambda-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- Step Functions Execution Role ---
# Used by the state machine itself to invoke each pipeline stage
# (ECS RunTask, Transcribe Lambda, Bedrock Lambda, PDF Lambda).
resource "aws_iam_role" "step_functions_execution" {
  name = "${var.project_name}-step-functions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
    }]
  })

  tags = { Project = var.project_name }
}

# --- ECR repository for the preprocessing worker image ---
resource "aws_ecr_repository" "preprocessing_worker" {
  name                 = "${var.project_name}-preprocessing-worker"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Project = var.project_name }
}

# --- ECS Cluster ---
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  tags = { Project = var.project_name }
}

# --- CloudWatch Log Group for the worker's container logs ---
resource "aws_cloudwatch_log_group" "preprocessing_worker" {
  name              = "/ecs/${var.project_name}-preprocessing-worker"
  retention_in_days = 14

  tags = { Project = var.project_name }
}

# --- ECS Task Definition ---
# Not an aws_ecs_service - this task is launched on-demand per video
# by Step Functions' RunTask integration, not run as a
# continuously-running service.
resource "aws_ecs_task_definition" "preprocessing_worker" {
  family                   = "${var.project_name}-preprocessing-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn             = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "preprocessing-worker"
      image     = "${aws_ecr_repository.preprocessing_worker.repository_url}:latest"
      essential = true
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.preprocessing_worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  tags = { Project = var.project_name }
}

# --- Step Functions: the pipeline itself ---
# Preprocess/validate (ECS) -> Transcribe -> generate study notes
# (Bedrock) -> render PDF. Each stage below is a real AWS integration.
resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/vendedlogs/states/${var.project_name}-pipeline"
  retention_in_days = 14

  tags = { Project = var.project_name }
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = "${var.project_name}-pipeline"
  role_arn = aws_iam_role.step_functions_execution.arn

  definition = jsonencode({
    Comment = "E-Learning pipeline: preprocess (ECS) -> transcribe -> generate study notes (Bedrock) -> render PDF"
    StartAt = "PreprocessValidate"
    States = {
      PreprocessValidate = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          LaunchType     = "FARGATE"
          Cluster        = aws_ecs_cluster.main.arn
          TaskDefinition = aws_ecs_task_definition.preprocessing_worker.arn
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = [aws_subnet.public.id]
              SecurityGroups = [aws_security_group.ecs_worker.id]
              AssignPublicIp = "ENABLED"
            }
          }
        }
        ResultPath = "$.ecsResult"
        Next       = "TranscribeAudio"
      }
      TranscribeAudio = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters = {
          FunctionName = aws_lambda_function.submit_transcribe_job.arn
          Payload = {
            "TaskToken.$"     = "$$.Task.Token"
            "input_key.$"     = "$.input_key"
            "language_code.$" = "$.language_code"
          }
        }
                TimeoutSeconds = 3600
        ResultPath = "$.transcribeResult"
        Next = "GenerateStudyNotes"
      }
                  GenerateStudyNotes = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.generate_study_notes.arn
          "Payload.$"  = "$"
        }
        ResultSelector = {
          "notes.$" = "$.Payload.notes"
        }
        ResultPath = "$.studyNotesResult"
        Next = "RenderPdf"
      }
            RenderPdf = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.render_pdf.arn
          "Payload.$"  = "$"
        }
        ResultPath = "$.renderPdfResult"
        End        = true
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = true
    level                   = "ALL"
  }

  tags = { Project = var.project_name }
}

# Step Functions needs explicit permission to write execution logs —
# there's no AWS-managed policy for this specific purpose, so it's inline.
resource "aws_iam_role_policy" "step_functions_logging" {
  name = "${var.project_name}-sfn-logging"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogDelivery",
        "logs:GetLogDelivery",
        "logs:UpdateLogDelivery",
        "logs:DeleteLogDelivery",
        "logs:ListLogDeliveries",
        "logs:PutResourcePolicy",
        "logs:DescribeResourcePolicies",
        "logs:DescribeLogGroups"
      ]
      Resource = "*"
    }]
  })
}

# --- IAM: lets Step Functions actually launch and monitor the ECS task ---
resource "aws_iam_role_policy" "step_functions_ecs" {
  name = "${var.project_name}-sfn-ecs-runtask"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecs:RunTask", "ecs:StopTask", "ecs:DescribeTasks"]
        Resource = "*"
      },
      {
        # Step Functions has to be allowed to hand these two roles to ECS -
        # without this, RunTask fails even though the roles themselves exist.
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = [
          aws_iam_role.ecs_task.arn,
          aws_iam_role.ecs_task_execution.arn
        ]
      },
      {
        # The .sync integration manages an EventBridge rule behind the
        # scenes to detect when the ECS task stops - this is what lets
        # Step Functions "wait" for it instead of just firing and forgetting.
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- Lets any Lambda on the shared role signal Step Functions back ---
# Needed by handle_transcribe_completion (the only remaining
# waitForTaskToken stage) to call SendTaskSuccess/Failure. Previously
# a leftover from when MediaConvert also needed this permission.
resource "aws_iam_role_policy" "lambda_step_functions_callback" {
  name = "${var.project_name}-lambda-step-functions-callback"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["states:SendTaskSuccess", "states:SendTaskFailure"]
      Resource = "*"
    }]
  })
}

# --- Extra permissions for lambda_execution role: Transcribe ---
# Transcribe has no separate service role of its own - it
# just uses the permissions of whichever caller (this Lambda's role)
# invokes StartTranscriptionJob. So this grants read on raw_video
# (input) and write on processed (transcript output), plus the
# Transcribe API actions themselves.
resource "aws_iam_role_policy" "lambda_transcribe" {
  name = "${var.project_name}-lambda-transcribe"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["transcribe:StartTranscriptionJob", "transcribe:GetTranscriptionJob"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.raw_video.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.processed.arn}/*"
      }
    ]
  })
}

# --- DynamoDB table: maps Transcribe job names to Step Functions task tokens ---
# Transcribe job names are far shorter than a Step Functions task
# token, so the token can't be
# attached to the job directly. Stored here instead, keyed by job name,
# looked up when the completion Lambda fires.
resource "aws_dynamodb_table" "transcribe_tokens" {
  name         = "${var.project_name}-transcribe-tokens"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_name"

  attribute {
    name = "job_name"
    type = "S"
  }

  tags = { Project = var.project_name }
}

# --- Let the Lambdas read/write the Transcribe token table ---
resource "aws_iam_role_policy" "lambda_transcribe_token_table" {
  name = "${var.project_name}-lambda-transcribe-token-table"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem"]
      Resource = aws_dynamodb_table.transcribe_tokens.arn
    }]
  })
}

# --- Lambda: submits the Transcribe job ---
# Invoked by Step Functions with .waitForTaskToken. Starts the
# transcription job (with multi-language identification enabled),
# stashes the task token in DynamoDB keyed by job name, then returns -
# Step Functions stays paused until the completion Lambda fires.
resource "aws_lambda_function" "submit_transcribe_job" {
  function_name = "${var.project_name}-submit-transcribe-job"
  role          = aws_iam_role.lambda_execution.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30
  filename      = "${path.module}/../../lambdas/submit_transcribe_job.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/submit_transcribe_job.zip")

  environment {
    variables = {
      INPUT_BUCKET  = aws_s3_bucket.raw_video.bucket
      OUTPUT_BUCKET = aws_s3_bucket.processed.bucket
      TOKEN_TABLE   = aws_dynamodb_table.transcribe_tokens.name
    }
  }
}

# --- Lambda: handles Transcribe job completion ---
# Triggered by an EventBridge rule whenever a
# Transcribe job finishes. Pulls the task token back out of DynamoDB
# using the job name and wakes the paused Step Functions execution.
resource "aws_lambda_function" "handle_transcribe_completion" {
  function_name = "${var.project_name}-handle-transcribe-completion"
  role          = aws_iam_role.lambda_execution.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 10
  filename      = "${path.module}/../../lambdas/handle_transcribe_completion.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/handle_transcribe_completion.zip")

  environment {
    variables = {
      TOKEN_TABLE = aws_dynamodb_table.transcribe_tokens.name
    }
  }
}

# --- EventBridge rule: watches for Transcribe job completion ---
# AWS automatically emits an event whenever a Transcribe job changes
# state. This rule catches COMPLETED and FAILED specifically, and
# routes them to the completion Lambda.
resource "aws_cloudwatch_event_rule" "transcribe_state_change" {
  name = "${var.project_name}-transcribe-state-change"

  event_pattern = jsonencode({
    source      = ["aws.transcribe"]
    detail-type = ["Transcribe Job State Change"]
    detail      = { TranscriptionJobStatus = ["COMPLETED", "FAILED"] }
  })
}

# --- Wire the rule to the completion Lambda ---
resource "aws_cloudwatch_event_target" "transcribe_completion_lambda" {
  rule = aws_cloudwatch_event_rule.transcribe_state_change.name
  arn  = aws_lambda_function.handle_transcribe_completion.arn
}

# --- Let EventBridge actually invoke the Lambda ---
# Without this, the rule can fire but EventBridge isn't authorized to
# actually call the Lambda when it does.
resource "aws_lambda_permission" "eventbridge_invoke_transcribe_completion" {
  statement_id  = "AllowEventBridgeInvokeTranscribe"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.handle_transcribe_completion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.transcribe_state_change.arn
}

# --- Let Step Functions invoke the Transcribe submit Lambda ---
resource "aws_iam_role_policy" "step_functions_lambda_transcribe" {
  name = "${var.project_name}-sfn-lambda-invoke-transcribe"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.submit_transcribe_job.arn
    }]
  })
}

# --- Extra permissions for lambda_execution role: Bedrock ---
# Lets the study-notes Lambda call Claude via Bedrock's Converse API.
# Note: bedrock:InvokeModel is the correct/only permission needed here -
# there's no separate "bedrock:Converse" IAM action; AWS authorizes the
# Converse API through InvokeModel even though the operation name differs.
resource "aws_iam_role_policy" "lambda_bedrock" {
  name = "${var.project_name}-lambda-bedrock"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.processed.arn}/*"
      }
    ]
  })
}

# --- Lambda: generates study notes via Bedrock ---
# Called directly by Step Functions (plain Task, not waitForTaskToken) -
# Bedrock's Converse API is synchronous, so no wait-and-callback pattern
# is needed here, unlike Transcribe. Fetches the transcript
# from processed/transcripts/, sends it to Claude, returns the notes text.
resource "aws_lambda_function" "generate_study_notes" {
  function_name = "${var.project_name}-generate-study-notes"
  role          = aws_iam_role.lambda_execution.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60
  filename      = "${path.module}/../../lambdas/generate_study_notes.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/generate_study_notes.zip")

  environment {
    variables = {
      MODEL_ID          = "us.anthropic.claude-sonnet-4-6"
      PROCESSED_BUCKET  = aws_s3_bucket.processed.bucket
    }
  }
}

# --- Let Step Functions invoke the study-notes Lambda ---
resource "aws_iam_role_policy" "step_functions_lambda_bedrock" {
  name = "${var.project_name}-sfn-lambda-invoke-bedrock"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.generate_study_notes.arn
    }]
  })
}

# --- Lambda: renders study notes into a PDF and uploads it ---
# Called directly by Step Functions (plain Task, same as GenerateStudyNotes) -
# parses the Markdown-structured notes text, builds a PDF with fpdf2, and
# uploads it to processed/study-notes/. This is the final stage of the
# pipeline.
resource "aws_lambda_function" "render_pdf" {
  function_name = "${var.project_name}-render-pdf"
  role          = aws_iam_role.lambda_execution.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30
  filename      = "${path.module}/../../lambdas/render_pdf.zip"
  source_code_hash = filebase64sha256("${path.module}/../../lambdas/render_pdf.zip")

  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.processed.bucket
    }
  }
}

# --- Let Step Functions invoke the render_pdf Lambda ---
resource "aws_iam_role_policy" "step_functions_lambda_pdf" {
  name = "${var.project_name}-sfn-lambda-invoke-pdf"
  role = aws_iam_role.step_functions_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.render_pdf.arn
    }]
  })
}