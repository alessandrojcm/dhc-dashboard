# Stage 4: Attendee Management & Refund System

## Overview
Complete attendee lifecycle management. Coordinators can manage attendees, handle refunds, mark attendance.

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

### Capacity & Registration
- **Hard capacity limits**: No waitlist system - when full, registration closes
- **Refund policy**: Configurable per workshop, defaults to 3 days before event
- **Payment methods**: Multiple payment methods supported (not just SEPA debit)

## Database Changes

### Refund tracking table
- Link to existing `club_activity_registrations` table
- Refund amount and reason tracking
- Refund status enum (pending, processed, failed)
- Timestamp tracking for refund requests and processing

### Attendance tracking fields
- Add attendance status to `club_activity_registrations`
- Attendance confirmation timestamp
- Attendance notes/comments

### Additional Database Requirements:
- Refund policy enforcement logic
- Attendance tracking integration
- Refund eligibility validation functions

## API Endpoints
- `POST /api/workshops/[id]/refunds` - Process refunds
- `PUT /api/workshops/[id]/attendance` - Mark attendance
- Attendee list via Supabase client

### API Implementation Guidelines
- **Pattern consistency**: Follow existing endpoint patterns exactly
- **Security pattern**: Use roles: `['admin', 'president', 'beginners_coordinator']` for coordinator endpoints
- **Response format**: Always return `{success: true, [resource]: updatedRecord}`
- **Error handling**: Use Sentry integration and error mapping patterns
- **Business logic**: Validate refund eligibility based on timing and workshop status
- **Database transactions**: Use `executeWithRLS()` wrapper for all mutations

## Frontend

### Coordinator Features
- Attendee management interface for coordinators
- Refund processing forms
- Attendance tracking interface

### Member Features
- Refund policy display for members
- Registration status with refund eligibility
- Attendance confirmation view

### Frontend Guidelines
- Use Svelte 5 syntax exclusively
- ALWAYS use svelte-shadcn components first, resort to tailwind 4 custom styles if components do not suffice
- Implement proper error handling and loading states
- Use TanStack Query for data fetching and caching
- Component naming: kebab-case (e.g., `attendee-management.svelte`)

## Business Logic

### Refund Eligibility
- Refund eligibility based on cancellation timing (default: 3 days before workshop)
- Workshop status validation (can't refund for finished workshops)
- Payment status validation (can't refund unpaid registrations)

### Refund Processing
- Automated refund processing through Stripe
- Refund amount calculation (full or partial based on policy)
- Refund status tracking and notifications

### Attendance Management
- Attendance confirmation workflow
- Attendance tracking for analytics
- Integration with member profiles

## Tests
- Refund policy enforcement tests
- Attendance tracking tests
- Refund processing integration tests

### Testing Requirements
- **Test Driven Development**: All code MUST be covered by tests
- **E2E Testing**: Use unique test data with timestamps and random suffixes
- **Authentication**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (supabase:start, supabase:functions:serve, dev)
- **Response format**: API responses follow `{success: true, [resource]: data}` pattern
- **Refund testing**: Test Stripe refund integration with test payment methods

## Security Requirements
- All mutations through Kysely with RLS enforcement
- Role-based access control throughout
- Stripe webhook signature verification
- Input validation with Valibot schemas
- Secure handling of refund information

## Performance Considerations
- Database indexes on frequently queried fields
- TanStack Query for efficient data fetching and caching
- Optimistic updates for better UX
- Proper error handling for refund processing timeouts

## Success Criteria
- Coordinators can view and manage attendee lists
- Refund processing works correctly with Stripe integration
- Refund eligibility is properly validated based on workshop timing
- Attendance tracking functions correctly
- Refund policies are enforced automatically
- Member dashboard shows refund status and eligibility
- RLS policies prevent unauthorized access
- All mutations use Kysely with `executeWithRLS()`
- Frontend follows existing component patterns
- Comprehensive test coverage for all functionality