.PHONY: api-gen

# Regenerate both sides of the API contract toolchain:
#   1. Phoenix controller stubs from OpenAPI spec (mix gen.controllers)
#   2. TypeScript API client from OpenAPI spec (@hey-api/openapi-ts)
#
# Fails fast: if either step exits non-zero, make stops immediately.

api-gen:
	cd apps/phoenix && mix gen.controllers
	pnpm --filter @dhc/api-client api:generate