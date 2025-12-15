# Repository Guidelines

## Project Structure & Module Organization
This repo mixes APISIX gateway config, a Spring Boot sample, deployment manifests, and planning docs. `hello/` carries the Maven wrapper, Dockerfile, and Java sources under `src/main` and `src/test`, while `apisix/config.yaml` and `apisix/apisix.yaml` define the runtime gateway state. Use `docker-compose.yaml` for the local APISIX ↔ Spring Boot stack, `k8s/namespace.yaml`, `k8s/spring-boot/configmap.yaml`, and `k8s/elk/**` for cluster resources, and `plans/` for migration notes.

## Build, Test, and Development Commands
- `cd hello && ./mvnw clean package` compiles against Java 21 and emits `target/hello-0.0.1-SNAPSHOT.jar`.
- `cd hello && ./mvnw spring-boot:run` runs the API at `http://localhost:8080/api/hello` with dev-friendly reloads.
- `docker compose up --build` rebuilds the multi-stage image and starts APISIX on 9080 and the backend on 8081; add `-d` for detached runs.
- `kubectl apply -f k8s/namespace.yaml && kubectl apply -f k8s/elk && kubectl apply -f k8s/spring-boot` deploys the shipped manifests; mirror the command with `kubectl delete` to clean up.

## Coding Style & Naming Conventions
Stick to standard Spring conventions: 4-space indentation, package names such as `com.example.hello`, and PascalCase classes (`HelloController`). Keep HTTP paths under `/api/**` in controllers and map them via APISIX routes like `/sb/hello` in `apisix/apisix.yaml`. YAML manifests rely on two-space indentation, lowercase keys, and descriptive filenames; Dockerfile layers should remain minimal and run as the bundled `spring` user.

## Testing Guidelines
Tests live in `hello/src/test/java`, mirror the main package, and end with `*Tests` (e.g., `HelloApplicationTests`). Run `cd hello && ./mvnw test` for the full suite or scope with `-Dtest=ClassName`. Add controller-focused `@WebMvcTest` cases plus integration checks that hit `curl http://localhost:9080/sb/hello` once Docker Compose is up to confirm APISIX routing and Elasticsearch logging.

## Commit & Pull Request Guidelines
Existing history favors imperative subjects (“Add…”, “Fix…”) under 72 characters, so follow the same style and optionally prefix the touched area (`k8s:`, `apisix:`). Each PR should explain the behavior change, list the commands you executed (tests, compose, kubectl), and link to an issue or plan step. Include screenshots or curl output whenever you alter ingress paths, ports, or logging destinations so reviewers can validate the 9080→8081 flow.

## Security & Configuration Tips
Treat `k8s/elk/elasticsearch-secret.yaml` as a template—inject live credentials with `kubectl create secret` instead of committing them. Keep APISIX mounts limited to the two files under `apisix/`, rotate the `elastic` password before sharing environments, and preserve the non-root `spring` user in custom Docker layers.
