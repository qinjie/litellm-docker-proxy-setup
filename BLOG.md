# Use AWS Bedrock Claude Models with Your Favorite Tools via LiteLLM Proxy

> **Note:** this article walks through the original setup, which passes AWS credentials
> in as environment variables and needs the container recreated after every refresh.
> This repo's `docker-compose.yml` no longer works that way: it reads `~/.env.aws` while
> running, and AWS credentials in the environment would stop that. Follow
> [README.md](README.md) for this repo.

**Blurb:** Have AWS Bedrock access but your tools expect OpenAI's API format? Can't use public LLM APIs due to company restrictions? This quick guide shows you how to set up a local LiteLLM proxy that lets you use Bedrock's Claude models with any OpenAI-compatible application—while keeping your data securely within AWS.

---

## The Problem

You have access to AWS Bedrock and want to use Claude models, but:

- **Your company restricts access to public LLM APIs** (like Anthropic, OpenAI) due to data security policies
- **Your favorite tools** (VS Code extensions, IDEs, AI assistants) expect OpenAI's API format
- **You work with sensitive data** that shouldn't leave your AWS environment
- **You want to use Claude across multiple applications** without managing different API integrations

## The Quick Solution

Set up a local LiteLLM proxy that:

1. **Translates** OpenAI API calls to AWS Bedrock format
2. **Connects** all your tools through one unified interface
3. **Keeps your data in AWS**—never sends it to public LLM providers
4. **Works with any OpenAI-compatible app**—VS Code, Continue.dev, Cursor, custom scripts, etc.

### Why This Matters

- ✅ **Data stays in AWS**: Your code, documents, and queries never leave your AWS account
- ✅ **Use your existing tools**: No need to rebuild integrations or change workflows
- ✅ **One setup for everything**: Connect multiple applications through a single proxy
- ✅ **Team sharing ready**: Deploy on a server and your whole team can use it
- ✅ **Built-in observability**: Request logging, caching, and budget controls included

This is a **quick DIY setup for developers**. If you need an enterprise-wide deployment with authentication, load balancing, and database persistence, you'll want to extend this basic setup.

## How It Works

Simple architecture:

```text
Your Apps/Tools → LiteLLM Proxy (localhost:8000) → AWS Bedrock Claude
  (OpenAI API)      [Translation Layer]           (Your AWS Account)
```

Data stays in your AWS account. When you query Claude through Bedrock, AWS processes it within your infrastructure—it doesn't get sent to Anthropic's public API.


## Prerequisites

Before you begin, ensure you have:

- Docker and Docker Compose installed on your system
- An AWS account with access to AWS Bedrock
- AWS credentials configured with Bedrock permissions

## Step 1: Set Up the Project

1. Create a new directory for your LiteLLM setup:

```bash
mkdir litellm-local-proxy-setup
cd litellm-local-proxy-setup
```

2. Create the logs directory where LiteLLM will store request logs:

```bash
mkdir -p ./logs
```

## Step 2: Create Configuration Files

1. Create `docker-compose.yml` to define the LiteLLM container:

```yaml

services:
  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    container_name: litellm-proxy
    restart: unless-stopped
    ports:
      - "8000:4000"
    environment:
      - AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
      - AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
      - AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
      - AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
      - AWS_REGION_NAME=${AWS_DEFAULT_REGION}
    volumes:
      - ./litellm_config.yaml:/app/config.yaml:ro
      - ./logs:/app/logs
    command: --config /app/config.yaml --port 4000
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
```

2. Create `litellm_config.yaml` to configure available models and settings:

```yaml
model_list:
  - model_name: claude-sonnet-4-5
    litellm_params:
      model: bedrock/global.anthropic.claude-sonnet-4-5-20250929-v1:0
      aws_region_name: us-west-2
  - model_name: claude-haiku-4-5
    litellm_params:
      model: bedrock/global.anthropic.claude-haiku-4-5-20251001-v1:0
      aws_region_name: us-west-2
  - model_name: claude-opus-4-5
    litellm_params:
      model: bedrock/global.anthropic.claude-opus-4-5-20251101-v1:0
      aws_region_name: us-west-2
  - model_name: cohere.embed-v4
    litellm_params:
      model: bedrock/global.cohere.embed-v4:0
      aws_region_name: us-west-2

litellm_settings:
  drop_params: true
  cache: true
  cache_params:
    type: local
    ttl: 3600
    default_max_size: 1000

  max_budget: 500
  budget_duration: 1mo
  max_internal_user_budget: 500
  internal_user_budget_duration: "1mo"

  success_callback: ["json"]
  failure_callback: ["json"]
  json_logs:
    log_file_path: /app/logs/litellm.log

general_settings:
  master_key: # [Optional] Set to require API key authentication
```

This configuration:

- Exposes 3 Claude chat models and 1 Cohere embedding model with simplified names
- Sets up in-memory caching for repeated requests
- Logs all requests locally in JSON for monitoring

## Step 3: Configure AWS Credentials

1. Export your AWS credentials in your terminal. If using permanent credentials:

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_DEFAULT_REGION=us-west-2
```

If using temporary credentials (e.g., from AWS SSO), export session token too.

```bash
export AWS_SESSION_TOKEN=your_session_token
```

## Step 4: Verify AWS Access

1. Before starting the proxy, verify your AWS credentials have Bedrock access:

```bash
aws sts get-caller-identity
```

This should return your AWS user ID and account number.

2. List available Bedrock models to confirm access:

```bash
aws bedrock list-inference-profiles | grep inferenceProfileArn | grep global.anthropic
```

3. Update the model ID in the `litellm_config.yaml` file if they are different from above listing.

## Step 5: Start the LiteLLM Proxy

1. Start the proxy with Docker Compose:

```bash
docker-compose up -d
```

2. Check that the container is running:

```bash
docker ps | grep litellm-proxy
```

3. Verify the proxy is healthy:

```bash
curl http://localhost:8000/health
```

You should receive a response like:

```json
{"status":"healthy"}
```

## Step 6: Test the Proxy

1. Test the proxy with a simple chat completion request:

```bash
curl --location 'http://localhost:8000/chat/completions' \
--header 'Content-Type: application/json' \
--data '{
  "model": "claude-sonnet-4-5",
  "messages": [
    {
      "role": "user",
      "content": "Hello, what model are you?"
    }
  ]
}'
```

You should receive a response from Claude Sonnet 4.5 identifying itself.

## Step 7: Integrate with Applications

Now that your proxy is running, you can point any OpenAI-compatible application to it:

### Example: Configure Claude Code with Your Local Proxy

If you have Claude Code installed, you can configure it to use your local LiteLLM proxy instead of the Claude API:

```bash
# Set environment variables for Claude Code
export ANTHROPIC_BASE_URL=http://localhost:8000
export ANTHROPIC_MODEL=claude-sonnet-4-5
export ANTHROPIC_SMALL_FAST_MODEL=claude-haiku-4-5
```

### Example: Use with Python OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000",
    api_key="dummy-key"  # LiteLLM doesn't require a key by default
)

response = client.chat.completions.create(
    model="claude-sonnet-4-5",
    messages=[
        {"role": "user", "content": "Explain quantum computing in simple terms"}
    ]
)

print(response.choices[0].message.content)
```

## Advanced Configuration

### Enable API Key Authentication

To secure your proxy, uncomment and set a master key in `litellm_config.yaml`:

```yaml
general_settings:
  master_key: sk-your-secret-key-here
```

Then include it in your requests:

```bash
curl --location 'http://localhost:8000/chat/completions' \
--header 'Authorization: Bearer sk-your-secret-key-here' \
--header 'Content-Type: application/json' \
--data '{...}'
```


### Add More Models

To add additional Bedrock models, extend the `model_list` in `litellm_config.yaml`:

```yaml
model_list:
  - model_name: claude-3-5-sonnet
    litellm_params:
      model: bedrock/anthropic.claude-3-5-sonnet-20241022-v2:0
      aws_region_name: us-west-2
```

## Summary

This guide shows you how to quickly set up a local LiteLLM proxy that lets you use AWS Bedrock's Claude models with any OpenAI-compatible tool. With just Docker Compose and two config files, you get:

- Claude Sonnet, Haiku, and Opus accessible via OpenAI API format
- Your data stays in AWS (satisfies most company security policies)
- One endpoint for all your AI tools
- Built-in logging, caching, and budget controls

**Perfect for:**

- Developers at companies that block public LLM APIs
- Teams wanting to share AWS Bedrock access
- Anyone working with sensitive data that shouldn't leave AWS
- People tired of managing different API integrations
