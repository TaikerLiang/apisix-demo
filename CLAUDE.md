# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an Apache APISIX API Gateway demo project with a Spring Boot backend service. The architecture consists of:
- **APISIX Gateway** (port 9080): Routes `/sb/hello` to the Spring Boot service
- **Spring Boot Service** (port 8081): Simple REST API at `/api/hello`

## Architecture

The system uses a containerized microservices architecture:

1. **hello/** - Spring Boot 4.0.0 application (Java 21)
   - Single REST endpoint: `GET /api/hello` returns "Hello from Spring Boot!"
   - Package structure: `com.example.hello.controller`

2. **apisix/** - Gateway configuration
   - Static YAML config (admin API disabled)
   - Route: `/sb/hello` → rewrites to `/api/hello` on springboot:8080
   - Uses roundrobin load balancing

3. **docker-compose.yaml** - Orchestrates all services
   - Services communicate via `apisix-net` bridge network
   - Spring Boot is referenced as `springboot` hostname internally

## Common Commands

### Building and Running

```bash
# Build the Spring Boot application (required before Docker)
cd hello
./mvnw clean package

# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# View logs
docker-compose logs -f [service-name]

# Rebuild and restart
docker-compose up -d --build
```

### Testing

```bash
# Run Spring Boot tests
cd hello
./mvnw test

# Test the gateway endpoint
curl http://localhost:9080/sb/hello

# Test Spring Boot directly
curl http://localhost:8081/api/hello
```

When you make a request to `http://localhost:9080/sb/hello`, you'll see logs from both services:

**APISIX log:**
```
149.154.167.220 - - [02/Dec/2025:02:59:04 +0000] localhost:9080 "GET /sb/hello HTTP/1.1" 200 23
```

**Spring Boot access log:**
```
172.18.0.3 - - [02/Dec/2025:02:59:04 +0000] "GET /api/hello HTTP/1.1" 200 23 26498
```

The Spring Boot access log pattern shows:
- `%h` - Remote host (IP address)
- `%t` - Timestamp
- `%r` - Request line (method, URI, protocol)
- `%s` - HTTP status code
- `%b` - Bytes sent
- `%D` - Time taken to process the request in milliseconds (26498 = ~26ms)

### Development Workflow

When modifying the Spring Boot service:
1. Make code changes in `hello/src/main/java/`
2. Run `./mvnw clean package` from `hello/` directory
3. Rebuild container: `docker-compose up -d --build springboot`

When modifying APISIX routes:
1. Edit `apisix/apisix.yaml`
2. Restart APISIX: `docker-compose restart apisix`

## ELK Integration

The system is configured to send logs to Elasticsearch for centralized logging:

### Spring Boot - JSON Structured Logging
- Uses `logstash-logback-encoder` for JSON output
- All logs are in JSON format, ready for Elasticsearch ingestion
- Configured in `src/main/resources/logback-spring.xml`
- Logs include: timestamp, level, logger, message, thread, service name

### APISIX - Elasticsearch Logger Plugin
- Configured with `elasticsearch-logger` plugin in `apisix/apisix.yaml`
- Sends request logs directly to Elasticsearch
- Index: `apisix-logs`
- Logs include: client_ip, request_time, method, URI, status, upstream details

### Configuration:
```yaml
# Current configuration expects Elasticsearch at:
endpoint_addr: "http://elasticsearch:9200"
index: "apisix-logs"
username: "elastic"
password: "changeme"  # Change this in production!
```

**Note:** The elasticsearch-logger plugin is configured but requires Elasticsearch to be running. You can:
1. Add Elasticsearch to `docker-compose.yaml`
2. Point to an external Elasticsearch instance
3. Disable the plugin if not using ELK (comment it out in `apisix/apisix.yaml`)

## Important Notes

- APISIX runs in standalone mode (data plane) without etcd; all configuration is in YAML files
- APISIX routes are defined in `apisix/apisix.yaml`, main config in `apisix/config.yaml`
- The Spring Boot service must be built with Maven before Docker Compose can run
- Services must communicate using Docker network hostnames (e.g., `springboot:8080`)
- Spring Boot uses JSON structured logging (Tomcat access logs are disabled in favor of application logs)
