# Feature Specification: JWT-Based Authentication

**Feature Branch**: `007-jwt-auth`  
**Created**: 2026-01-07  
**Status**: Draft  
**Input**: User description: "Add optional JWT-based authentication with token validation, claims extraction, and role-based authorization"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Enable Auth Feature in Template Generator (Priority: P1)

Template users need to optionally enable JWT authentication during project generation so they can start with working authentication infrastructure rather than implementing from scratch.

**Why this priority**: This is the entry point for the entire authentication feature. Without this, users can't access the auth functionality. It's the most critical element as it gates all other auth features.

**Independent Test**: Can be fully tested by running the template generator with the auth feature selected and verifying that the generated project includes auth dependencies, configuration, and example endpoint. Delivers immediate value: a working authenticated endpoint.

**Acceptance Scenarios**:

1. **Given** user runs the template generator, **When** user selects "yes" for auth feature, **Then** generated project includes `auth` feature flag in `Cargo.toml` with `jsonwebtoken` dependency
2. **Given** auth feature is enabled, **When** project is built, **Then** build succeeds without compilation errors
3. **Given** auth feature is enabled, **When** application starts, **Then** it loads JWKS configuration from environment variables without errors
4. **Given** auth feature is disabled, **When** project is built, **Then** auth code is not compiled (feature-gated)

---

### User Story 2 - Validate JWT Tokens and Extract Claims (Priority: P1)

API endpoint handlers need to validate incoming JWT tokens from Bearer headers and extract verified claims so protected endpoints can access authenticated user information.

**Why this priority**: This is the core security functionality. All protected endpoints depend on being able to validate tokens and extract claims. Without this, authorization cannot work.

**Independent Test**: Can be fully tested by creating an endpoint with `AuthUser` extractor, sending requests with valid/invalid tokens, and verifying claims are extracted correctly. Delivers value: protected endpoints that enforce authentication.

**Acceptance Scenarios**:

1. **Given** valid JWT token in Authorization header, **When** endpoint with `AuthUser` extractor is called, **Then** claims are extracted and endpoint receives user information
2. **Given** invalid JWT token signature, **When** endpoint is called, **Then** request returns 401 Unauthorized
3. **Given** missing Authorization header, **When** protected endpoint is called, **Then** request returns 401 Unauthorized
4. **Given** malformed token format (missing Bearer prefix), **When** protected endpoint is called, **Then** request returns 401 Unauthorized
5. **Given** expired token, **When** protected endpoint is called, **Then** request returns 401 Unauthorized

---

### User Story 3 - Support Multiple Identity Providers (Priority: P2)

Organizations use different identity providers (Keycloak, Auth0, custom), and the system must work with any JWKS-compliant provider via configurable JWKS URL.

**Why this priority**: High value for enterprise users avoiding vendor lock-in and supporting existing identity infrastructure. Can be built on top of core JWT validation, so not blocking other features.

**Independent Test**: Can be fully tested by configuring system with different JWKS URLs and verifying tokens from each provider are correctly validated. Delivers value: flexibility across identity providers.

**Acceptance Scenarios**:

1. **Given** JWKS URL points to Auth0 provider, **When** token from Auth0 is provided, **Then** token is validated using Auth0 keys
2. **Given** JWKS URL is changed to Keycloak, **When** application restarts, **Then** tokens are validated using Keycloak keys
3. **Given** JWKS URL is unreachable, **When** application starts, **Then** startup continues with cached keys or deferred validation
4. **Given** JWKS keys are updated at provider, **When** new token is provided, **Then** system uses updated keys automatically

---

### User Story 4 - Enforce Role-Based Authorization (Priority: P2)

Application developers need to restrict endpoints to specific user roles (e.g., "admin", "user", "viewer") so they can implement fine-grained access control without writing custom validation logic.

**Why this priority**: Important for application authorization patterns, but built on top of working JWT validation. Developers can implement custom authorization while waiting for role-based helpers.

**Independent Test**: Can be fully tested by creating endpoints with role requirements and verifying access is granted/denied based on token roles. Delivers value: reduced boilerplate for common authorization patterns.

**Acceptance Scenarios**:

1. **Given** endpoint requires "admin" role, **When** user with admin role calls endpoint, **Then** request succeeds
2. **Given** endpoint requires "admin" role, **When** user with "viewer" role calls endpoint, **Then** request returns 403 Forbidden
3. **Given** endpoint requires multiple roles: "admin" OR "moderator", **When** user has "moderator" role, **Then** request succeeds
4. **Given** token has no roles claim, **When** endpoint with role requirement is called, **Then** request returns 403 Forbidden

---

### User Story 5 - Provide Example Protected Endpoint (Priority: P2)

Template users need working example code showing how to create protected endpoints so they understand the pattern and can replicate it in their application.

**Why this priority**: Accelerates developer onboarding and provides reference implementation. Depends on core auth working first, but valuable for user experience.

**Independent Test**: Can be fully tested by accessing example endpoint and verifying it requires authentication and responds to valid tokens. Delivers value: concrete reference implementation.

**Acceptance Scenarios**:

1. **Given** example protected endpoint exists, **When** accessed without token, **Then** returns 401 Unauthorized
2. **Given** example protected endpoint exists, **When** accessed with valid token, **Then** returns 200 OK with user information from claims
3. **Given** example endpoint, **When** documentation is reviewed, **Then** code comments clearly explain JWT handling pattern

---

### Edge Cases

- What happens when JWKS endpoint returns invalid JSON or malformed response?
- How does the system handle very large JWT tokens (>16KB)?
- What happens when a token has claims in unexpected format (string instead of array for roles)?
- How does the system behave if JWKS keys rotation happens while a token validation is in progress?
- What happens when token uses an algorithm not supported by the JWKS endpoint configuration?
- How are partial claims handled (e.g., token has "sub" but missing "aud" for validation)?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST support optional `auth` feature flag that conditionally enables authentication functionality
- **FR-002**: System MUST validate JWT tokens using RS256 algorithm (standard for JWKS providers)
- **FR-003**: System MUST extract JWT claims from valid tokens and make them available to handlers via `AuthUser` extractor
- **FR-004**: System MUST support Bearer token format in Authorization header (`Authorization: Bearer <token>`)
- **FR-005**: System MUST fetch and cache JWKS keys from configurable JWKS URL for signature verification
- **FR-006**: System MUST validate token expiration time (exp claim)
- **FR-007**: System MUST validate token audience (aud claim) if configured
- **FR-008**: System MUST validate token issuer (iss claim) if configured
- **FR-009**: System MUST support extracting custom claims from JWT (user ID, email, roles, permissions)
- **FR-010**: System MUST provide role-based authorization helper that validates user has required role(s)
- **FR-011**: System MUST return 401 Unauthorized for missing or invalid tokens
- **FR-012**: System MUST return 403 Forbidden for valid tokens without required authorization (roles/scopes)
- **FR-013**: System MUST support configuration via environment variables with `APP__AUTH__` prefix
- **FR-014**: System MUST provide example protected endpoint demonstrating JWT validation and role checking
- **FR-015**: System MUST document expected JWT structure and claims format for integrating external identity providers

### Non-Functional Requirements *(mandatory per constitution)*

- **NFR-001**: All public async functions MUST use `#[instrument]` macro for tracing
- **NFR-002**: All authentication failures MUST be logged with context before returning 401/403 via `tracing::error!`
- **NFR-003**: All endpoints MUST emit Prometheus-compatible metrics for auth success/failure
- **NFR-004**: System MUST propagate B3 headers for distributed tracing through auth middleware
- **NFR-005**: Authentication configuration MUST support environment variable overrides with `APP__AUTH__` prefix
- **NFR-006**: Error handling MUST use custom `AuthError` type with `IntoResponse` implementation
- **NFR-007**: Cold startup time impact SHOULD be <200ms (JWKS fetching is non-blocking on startup)
- **NFR-008**: JWKS key caching MUST refresh at least every 24 hours to catch key rotations
- **NFR-009**: Token validation latency MUST be <10ms per request (cryptographic operations)
- **NFR-010**: System MUST not block request handling on JWKS refresh (use background task)

### Key Entities

- **JWT Token**: Signed JSON Web Token containing user claims, issued by identity provider
- **AuthUser**: Extractor struct containing extracted claims (sub, email, roles, custom claims)
- **JWKS Keys**: JSON Web Key Set from identity provider containing public keys for verification
- **Token Claims**: Standard (exp, iat, aud, iss, sub) and custom claims (roles, permissions, scopes)
- **Identity Provider**: External service issuing and managing JWT tokens (Keycloak, Auth0, etc.)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Template users can enable auth feature and generate a working project with 0 additional configuration code required
- **SC-002**: JWT token validation completes in <10ms per request, allowing system to handle 100+ authenticated requests per second
- **SC-003**: Developers can create protected endpoints requiring only 2-3 lines of code (extractor usage) with no custom auth logic
- **SC-004**: System correctly rejects 100% of invalid tokens (wrong signature, expired, missing claims) in unit tests
- **SC-005**: JWKS key refresh does not block any request handling or add measurable latency to user requests
- **SC-006**: Example endpoint documentation is clear enough that 90% of developers can implement similar endpoints without additional help
- **SC-007**: Cold start time with auth enabled is within 200ms of baseline Knative startup time

## Assumptions

- Identity providers implement standard JWKS endpoint compliant with RFC 7517
- Tokens use RS256 (RSA) signature algorithm (supported by Keycloak, Auth0, most major providers)
- Organizations have functioning identity provider already deployed (system integrates with existing infrastructure)
- Token claims follow standard JWT/OIDC patterns (not custom formats)
- JWKS keys are relatively stable (not rotating more frequently than hourly)
- Network latency to JWKS endpoint is <500ms (reasonable for cloud deployments)

## Dependencies & Integration Points

- **jsonwebtoken crate**: JWT validation and claims extraction
- **serde**: Claims deserialization from JWT payload
- **tracing**: Observability and structured logging
- **External JWKS endpoint**: From identity provider (Keycloak, Auth0, etc.)
- **Axum State**: Shared configuration for JWKS URL and validation settings
- **IntoResponse trait**: Error response formatting

## Out of Scope

- User registration or account management
- Token issuance or refresh token handling
- Multi-factor authentication (MFA)
- Social login integrations
- Session management or cookies
- Password reset flows
- User directory or profile storage
