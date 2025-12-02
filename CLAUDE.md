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

### Development Workflow

When modifying the Spring Boot service:
1. Make code changes in `hello/src/main/java/`
2. Run `./mvnw clean package` from `hello/` directory
3. Rebuild container: `docker-compose up -d --build springboot`

When modifying APISIX routes:
1. Edit `apisix/config.yaml`
2. Restart APISIX: `docker-compose restart apisix`

## Important Notes

- The Dockerfile references `todolist-0.0.1-SNAPSHOT.jar` but pom.xml builds `hello-0.0.1-SNAPSHOT.jar` - there's a naming mismatch
- APISIX admin API is disabled; all configuration is in `apisix/config.yaml`
- The Spring Boot service must be built with Maven before Docker Compose can run
- Services must communicate using Docker network hostnames (e.g., `springboot:8080`)
