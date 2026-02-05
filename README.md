# LiteLLM Proxy Local Setup

## Prerequisites

- Docker and Docker Compose installed
- AWS credentials with Bedrock access

## Quick Start

1. Export AWS credentials in your terminal:

```bash
export AWS_ACCESS_KEY_ID=your_access_key
export AWS_SECRET_ACCESS_KEY=your_secret_key
export AWS_DEFAULT_REGION=us-west-2
export AWS_SESSION_TOKEN=your_session_token  # if using temporary credentials
```

2. Create logs directory:

```bash
mkdir -p ./logs
```

3. Start the proxy:

```bash
docker-compose up -d
```

4. Check health:

```bash
curl http://localhost:8000/health
```

## Available Models

| Model Name | Bedrock Model ID |
|------------|------------------|
| claude-sonnet-4-5 | anthropic.claude-sonnet-4-5-20250929-v1:0 |
| claude-haiku-4-5 | anthropic.claude-haiku-4-5-20251001-v1:0 |
| claude-opus-4-5 | anthropic.claude-opus-4-5-20251101-v1:0 |

## Testing

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

## Configuration

- **Config file**: `litellm_config.yaml`
- **Logs**: `./logs/litellm.log` (JSON format, includes success and failure)
- **Port**: 8000 (host) -> 4000 (container)

## Logs

View logs:

```bash
# Docker logs
docker logs litellm-proxy

# Application logs
cat ./logs/litellm.log

# Filter failures
cat ./logs/litellm.log | jq 'select(.status == "failure")'
```

## Troubleshooting

### Check if AWS credentials are valid

1. Shell into the container:

```bash
docker exec -it litellm-proxy /bin/sh
```

2. Run Python to verify credentials:

```python
import boto3
sts = boto3.client('sts')
try:
    sts.get_caller_identity()
    print("Credentials are valid.")
except Exception as e:
    print(f"Credentials are NOT valid: {e}")
```

### Common Issues

- **Container exits immediately**: Check `docker logs litellm-proxy` for errors
- **AWS auth errors**: Ensure AWS_SESSION_TOKEN is set if using temporary credentials
- **Port conflict**: Change the host port in `docker-compose.yml` if 8000 is in use

## Stop the Proxy

```bash
docker-compose down
```
