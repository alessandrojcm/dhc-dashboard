# Stage 6: Communication System

## Overview

Automated notifications and announcements. Email notifications for workshop updates and registrations.

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

### Communication

- **Email notifications**: Integrated with Loops and existing email processing queue
- **Discord notifications**: Planned for future integration
- **No user preferences**: All members receive notifications

## API Endpoints

- `POST /api/workshops/[id]/announce` - Send announcements
- Webhook handlers for automated email triggers, integrate with Loops and the email processing queue

### API Implementation Guidelines

- **Pattern consistency**: Follow existing endpoint patterns exactly
- **Security pattern**: Use roles: `['admin', 'president', 'beginners_coordinator']` for announcement endpoints
- **Response format**: Always return `{success: true, [resource]: updatedRecord}`
- **Error handling**: Use Sentry integration and error mapping patterns
- **Business logic**: Validate announcement eligibility and recipient lists
- **Database transactions**: Use `executeWithRLS()` wrapper for all mutations

## Email Integration

### Workshop Update Notifications

- Registration confirmation emails
- Workshop update notifications (time, location, etc.)
- Workshop cancellation notifications
- Refund confirmation emails

### Reminder Emails

- Reminder emails before workshops
- Registration deadline reminders
- Payment reminder emails

### Integration Requirements

- **Loops Integration**: Use existing Loops integration for email sending
- **Email Processing Queue**: Integrate with existing email processing queue
- **Template Management**: Use existing email template system
- **Webhook Integration**: Handle email delivery status webhooks

## Frontend

### Announcement Composition Interface

- Rich text editor for announcements
- Recipient selection (all registered, specific groups)
- Preview functionality before sending
- Scheduling for future delivery

### Email Template Management

- Template editing interface for coordinators
- Preview templates with sample data
- Template versioning and approval workflow
- Template assignment to workshop types

### Frontend Guidelines

- Use Svelte 5 syntax exclusively
- ALWAYS use svelte-shadcn components first, resort to tailwind 4 custom styles if components do not suffice
- Implement proper error handling and loading states
- Use TanStack Query for data fetching and caching
- Component naming: kebab-case (e.g., `announcement-composer.svelte`)

## Tests

- Email delivery tests
- Notification trigger tests
- Template rendering tests

### Testing Requirements

- **Test Driven Development**: All code MUST be covered by tests
- **E2E Testing**: Use unique test data with timestamps and random suffixes
- **Authentication**: Always use `makeAuthenticatedRequest()` instead of direct authorization headers
- **Service dependencies**: E2E tests require all services running (supabase:start, supabase:functions:serve, dev)
- **Response format**: API responses follow `{success: true, [resource]: data}` pattern
- **Email testing**: Test email integration with proper mocking
- **Template testing**: Test email template rendering and delivery

## Security Requirements

- All mutations through Kysely with RLS enforcement
- Role-based access control throughout
- Input validation with Valibot schemas
- Secure handling of recipient information
- Email template security (prevent XSS in templates)

## Performance Considerations

- Database indexes on frequently queried fields
- TanStack Query for efficient data fetching and caching
- Bulk email processing for large recipient lists
- Queue management for email delivery
- Proper error handling for email delivery failures

## Success Criteria

- Automated email notifications work for all workshop events
- Manual announcements can be sent to selected recipients
- Email templates are properly managed and versioned
- Integration with Loops and email processing queue functions correctly
- Email delivery status is properly tracked
- Rich text editor works properly for announcements
- Template preview functionality works correctly
- Bulk email processing handles large recipient lists
- RLS policies prevent unauthorized access
- All mutations use Kysely with `executeWithRLS()`
- Frontend follows existing component patterns
- Comprehensive test coverage for all functionality
