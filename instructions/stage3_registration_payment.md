# Stage 3: Registration & Payment System

## Overview
Enable registration and payment for published workshops. Members can register and pay with differential pricing (member vs non-member).

## Context & Clarifications

### Key Design Decisions
- **Database naming**: `club_activities` schema to distinguish from existing beginners workshop
- **Frontend terminology**: "workshops" for user-facing elements
- **API pattern**: Mutation-only endpoints (use Supabase client for queries)
- **Data access**: Kysely for all mutations, Supabase client for queries

### Answered Questions
1. **Refund Policy Granularity**: Per workshop, default to 3 days before the workshop
2. **Capacity Management**: Hard capacity limits only (no waitlists)
3. **Recurring Workshops**: No recurring workshop support needed
4. **Member Verification**: Private workshops require members to be signed in, so authentication determines member status
5. **Workshop Categories**: No categories/tags needed
6. **Notification Preferences**: No preferences needed - members will get emails and/or discord notifications
7. **Payment Methods**: Multiple payment methods supported
8. **Cancellation Policies**: Same policy for all workshop types

### Workshop Access & Pricing
- **Public workshops**: Accessible at `(public)/workshops/[id]`, non-member pricing unless authenticated
- **Private workshops**: Accessible at `dashboard/workshops/[id]`, requires authentication (member pricing)
- **Member verification**: Authentication status determines pricing eligibility

## Database Changes

### `club_activity_registrations` table
- Link to existing `club_activities` table
- User tracking:
  - For members, link with the user_profiles table via the supabase user id (so auth.users.id = user_profiles.supabase_user_id)
  - For non members, ie for public workshops, create en external_users table that will collect basic contact info (first name, last name, email, phone number) and link to the club_activity_registrations table
- Payment tracking fields
- Registration status enum (pending, confirmed, cancelled)
- Timestamp tracking for registration

### Additional Database Requirements:
- Hard capacity validation functions (no waitlists)
- Payment tracking integration with Stripe via payment intents, no product needed
- Registration status management
- Capacity enforcement before registration

## API Endpoints
- `POST /api/workshops/[id]/register` - Registration with payment
- `DELETE /api/workshops/[id]/register` - Cancel registration
- `POST /api/workshops/[id]/payments/create-intent` - Stripe payment intent

### API Implementation Guidelines
- **Pattern consistency**: Follow existing endpoint patterns exactly
- **Security pattern**: Use roles: `['admin', 'president', 'beginners_coordinator']` for admin endpoints, authenticated users for registration
- **Response format**: Always return `{success: true, [resource]: updatedRecord}`
- **Error handling**: Use Sentry integration and error mapping patterns
- **Business logic**: Validate capacity before registration, handle pricing logic
- **Database transactions**: Use `executeWithRLS()` wrapper for all mutations

## Frontend

### Registration Pages
- **Public workshops**: Frontend url `(public)/workshops/[id]`
- **Private workshops**: Frontend url `dashboard/workshops/[id]` (requires authentication)

### Pricing Logic
- **Private workshops**: Member pricing (requires sign-in)
- **Public workshops**: Non-member pricing unless authenticated

### Registration Features
- Registration flow with Stripe Elements (multiple payment methods)
- Registration confirmation pages
- Registration status in member dashboard

### Frontend Guidelines
- Use Svelte 5 syntax exclusively
- ALWAYS use svelte-shadcn components first, resort to tailwind 4 custom styles if components do not suffice
- Implement proper error handling and loading states
- Use TanStack Query for data fetching and caching
- Component naming: kebab-case (e.g., `workshop-registration.svelte`)

## Stripe Integration

### Payment Features
- Payment intents for workshops (multiple payment methods supported)
- Webhook handling for payment confirmations
- Metadata tracking for registrations

### Stripe Implementation Guidelines
- Follow existing Stripe patterns in the codebase
- Use existing webhook infrastructure
- Implement proper error handling for payment failures
- Store payment intent IDs for tracking

## Tests
- Payment flow end-to-end tests
- Registration capacity validation
- Member vs non-member pricing tests

### Testing Requirements
- **Test Driven Development**: All code MUST be covered by tests
- **E2E Testing**: Use unique test data with timestamps and random suffixes
- **Authentication**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (supabase:start, supabase:functions:serve, dev)
- **Response format**: API responses follow `{success: true, [resource]: data}` pattern
- **Payment testing**: Test Stripe integration with test payment methods

## Security Requirements
- All mutations through Kysely with RLS enforcement
- Role-based access control throughout
- Stripe webhook signature verification
- Input validation with Valibot schemas
- Secure handling of payment information

## Performance Considerations
- Database indexes on frequently queried fields
- TanStack Query for efficient data fetching and caching
- Optimistic updates for better UX
- Proper error handling for payment timeouts

## Success Criteria
- Members can register for workshops with proper capacity validation
- Payment flow works correctly with multiple payment methods
- Pricing logic correctly differentiates between member and non-member rates
- Registration status is properly tracked and displayed
- Stripe webhook integration handles payment confirmations
- Hard capacity limits are enforced (no waitlists)
- RLS policies prevent unauthorized access
- All mutations use Kysely with `executeWithRLS()`
- Frontend follows existing component patterns
- Comprehensive test coverage for all functionality
