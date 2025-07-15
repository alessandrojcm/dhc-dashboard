# Stage 5: Advanced Member Dashboard & Analytics

## Overview
Comprehensive member experience and coordinator insights. Members have full workshop management interface with analytics.

## Context & Clarifications

### Key Design Decisions
- **Database naming**: `club_activities` schema to distinguish from existing beginners workshop
- **Frontend terminology**: "workshops" for user-facing elements
- **API pattern**: Mutation-only endpoints (use Supabase client for queries)
- **Calendar integration**: vkurko/calendar library for calendar display
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

### Simplified Features
- **No workshop categories**: Simple list/calendar view without filtering by category
- **No recurring workshops**: Each workshop is a standalone event
- **Unified cancellation policy**: Same refund rules for all workshop types

## Frontend Enhancements

### Full vkurko/calendar Implementation
- Complete calendar integration with all workshop states
- Interactive calendar with workshop details
- Mobile-responsive calendar interface
- Calendar view switching (month, week, day)

### Advanced Filtering and Search
- Search workshops by title, description, location
- Filter by workshop status (planned, published, finished, cancelled)
- Filter by date range
- Filter by registration status (for members)

### Registration History View
- Complete registration history for members
- Payment status and refund information
- Attendance tracking display
- Registration timeline

### Upcoming Workshops Dashboard
- vkurko/calendar integration for upcoming workshops
- Quick registration actions from dashboard
- Workshop reminders and notifications
- Registration deadline alerts

### Mobile-Responsive Design
- Fully responsive calendar interface
- Touch-friendly workshop interactions
- Mobile-optimized registration flow
- Responsive dashboard layout

### Frontend Guidelines
- Use Svelte 5 syntax exclusively
- ALWAYS use svelte-shadcn components first, resort to tailwind 4 custom styles if components do not suffice
- Implement proper error handling and loading states
- Use TanStack Query for data fetching and caching
- Component naming: kebab-case (e.g., `workshop-calendar.svelte`)

## Analytics Features

### Workshop Attendance Analytics
- Attendance rates by workshop type
- Member participation tracking
- Workshop popularity metrics
- Capacity utilization statistics

### Coordinator Dashboard Analytics
- Registration trends over time
- Revenue tracking per workshop
- Refund rate analysis
- Member engagement metrics

### Member Analytics
- Personal workshop history
- Attendance tracking
- Participation statistics
- Spending analysis

## Tests
- Complete dashboard functionality tests
- Analytics accuracy verification
- Mobile responsiveness tests

### Testing Requirements
- **Test Driven Development**: All code MUST be covered by tests
- **E2E Testing**: Use unique test data with timestamps and random suffixes
- **Authentication**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (supabase:start, supabase:functions:serve, dev)
- **Response format**: API responses follow `{success: true, [resource]: data}` pattern
- **Mobile testing**: Test responsive design and touch interactions
- **Calendar testing**: Test vkurko/calendar integration and all calendar features

## Security Requirements
- All mutations through Kysely with RLS enforcement
- Role-based access control throughout
- Input validation with Valibot schemas
- Secure handling of analytics data

## Performance Considerations
- Database indexes on frequently queried fields
- TanStack Query for efficient data fetching and caching
- Pagination for large workshop lists
- Optimistic updates for better UX
- Lazy loading for calendar views
- Performance optimization for analytics queries

## Success Criteria
- Full vkurko/calendar integration works on all devices
- Advanced search and filtering functions correctly
- Registration history displays complete member information
- Mobile interface is fully functional and responsive
- Analytics provide accurate insights for coordinators
- Dashboard loads quickly with proper caching
- All calendar interactions work smoothly
- Search and filtering provide relevant results
- Member dashboard shows comprehensive workshop information
- RLS policies prevent unauthorized access
- Frontend follows existing component patterns
- Comprehensive test coverage for all functionality