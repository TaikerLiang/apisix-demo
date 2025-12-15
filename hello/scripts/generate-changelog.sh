#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
CHANGELOG_NAME="${1:-db.changelog-$(date +%Y%m%d%H%M%S).yaml}"
CHANGELOG_PATH="src/main/resources/db/changelog/${CHANGELOG_NAME}"

echo "Generating Liquibase changelog at ${CHANGELOG_PATH}"
cd "${PROJECT_ROOT}"
./mvnw liquibase:diff "-Dliquibase.diffChangeLogFile=${CHANGELOG_PATH}"
