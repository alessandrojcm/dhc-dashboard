# Stage 2: Expression of Interest System

## Overview
Allow members to express interest in planned workshops. Members can view planned workshops and express interest for feasibility assessment.

## Context & Clarifications

### Key Design Decisions
- **Database naming**: `club_activities` schema to distinguish from existing beginners workshop
- **Frontend terminology**: "workshops" for user-facing elements
- **API pattern**: Mutation-only endpoints (use Supabase client for queries)
- **Calendar integration**: Schedule-X library for calendar display
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

## Database Changes

### `club_activity_interest` table
- Track interest per user/workshop combination
- Link to existing `club_activities` table
- User identification via authentication
- Timestamp tracking for interest expression

### Additional Database Requirements:
- Interest aggregation functions
- Interest tracking per user/workshop
- Prevent duplicate interest entries per user/workshop

## API Endpoints
- `POST /api/workshops/[id]/interest` - Express/withdraw interest
- Interest count queries via Supabase client

### API Implementation Guidelines
- **Pattern consistency**: Follow existing endpoint patterns exactly
- **Security pattern**: Use roles: `['admin', 'president', 'beginners_coordinator']` for admin endpoints, authenticated users for interest
- **Response format**: Always return `{success: true, [resource]: updatedRecord}`
- **Error handling**: Use Sentry integration and error mapping patterns
- **Business logic**: Validate user can express interest (not already registered, workshop in correct state)
- **Database transactions**: Use `executeWithRLS()` wrapper for all mutations

## Frontend
- Member calendar view at `/dashboard/my-workshops/`
- Schedule-X calendar integration showing planned workshops
- Interest buttons on planned workshops
- Interest count display for coordinators

### Frontend Guidelines
- Use Svelte 5 syntax exclusively
- ALWAYS use svelte-shadcn components first, resort to tailwind 4 custom styles if components do not suffice
- Implement proper error handling and loading states
- Use TanStack Query for data fetching and caching
- Component naming: kebab-case (e.g., `workshop-calendar.svelte`)

### Schedule-X Calendar Integration
- Display planned workshops in calendar view
- Show interest status for each workshop
- Allow interest expression directly from calendar
- Mobile-responsive calendar interface

## Tests
- Interest tracking functionality
- Calendar display tests
- Interest aggregation accuracy

### Testing Requirements
- **Test Driven Development**: All code MUST be covered by tests
- **E2E Testing**: Use unique test data with timestamps and random suffixes
- **Authentication**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (supabase:start, supabase:functions:serve, dev)
- **Response format**: API responses follow `{success: true, [resource]: data}` pattern
- **Calendar functionality**: Test Schedule-X integration and workshop display

## Security Requirements
- All mutations through Kysely with RLS enforcement
- Role-based access control throughout
- Input validation with Valibot schemas
- Authenticated users can only express interest for themselves

## Performance Considerations
- Database indexes on frequently queried fields
- TanStack Query for efficient data fetching and caching
- Lazy loading for calendar views
- Optimistic updates for interest expressions

## Success Criteria
- Members can view planned workshops in calendar format
- Interest expression works correctly with proper validation
- Interest counts are accurately tracked and displayed
- Calendar integration functions properly on mobile and desktop
- RLS policies prevent unauthorized access
- All mutations use Kysely with `executeWithRLS()`
- Frontend follows existing component patterns
- Comprehensive test coverage for all functionality