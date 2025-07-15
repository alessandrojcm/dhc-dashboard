# Workshop Feature Implementation Plan

## Overview
Create a comprehensive workshop planning feature for extra club activities (training sessions, social events, etc.). The system will be called "workshops" in the frontend but use `club_activities` as the database schema to avoid confusion with the existing beginners workshop system.

## Database Schema: `club_activities` (Frontend: "workshops")

### Key Design Decisions
- **Database naming**: `club_activities` schema to distinguish from existing beginners workshop
- **Frontend terminology**: "workshops" for user-facing elements
- **API pattern**: Mutation-only endpoints (use Supabase client for queries)
- **Calendar integration**: vkurko/calendar library for calendar display
- **Data access**: Kysely for all mutations, Supabase client for queries

## Implementation Stages

### **Stage 1: Core Database Schema & Basic CRUD**
**Goal:** Foundation for workshop management by coordinators
**MVP:** Workshop coordinator can create, read, update, delete workshops

#### Database Changes
- `club_activities` table with core fields:
  - Basic info: title, description, location
  - Scheduling: start_date, end_date
  - Capacity: max_capacity (hard limit, no waitlists)
  - Pricing: price_member, price_non_member
  - Visibility: is_public
  - Policies: refund_policy enum (default: 3 days before workshop)
  - Status: club_activity_status enum (planned, published, finished, cancelled)
- Status transition validation functions
- RLS policies for workshop_coordinator role
- Hard capacity enforcement (no waitlist system)

#### API Endpoints (Mutation-only)
- `POST /api/workshops/` - Create workshop
- `PUT /api/workshops/[id]/` - Update workshop
- `DELETE /api/workshops/[id]/` - Delete workshop
- `POST /api/workshops/[id]/publish` - Publish workshop
- `POST /api/workshops/[id]/cancel` - Cancel workshop

#### Frontend
- Basic coordinator dashboard at `/dashboard/workshops/`
- Create/edit workshop forms with validation
- Workshop list view with status indicators
- State transition buttons (publish, cancel)

#### Tests
- Database schema and constraint tests
- API endpoint tests
- Basic UI interaction tests

---

### **Stage 2: Expression of Interest System**
**Goal:** Allow members to express interest in planned workshops
**MVP:** Members can view planned workshops and express interest for feasibility assessment

#### Database Changes
- `club_activity_interest` table
- Interest aggregation functions
- Interest tracking per user/workshop

#### API Endpoints
- `POST /api/workshops/[id]/interest` - Express/withdraw interest
- Interest count queries via Supabase client

#### Frontend
- Member calendar view at `/dashboard/my-workshops/`
- vkurko/calendar integration showing planned workshops
- Interest buttons on planned workshops
- Interest count display for coordinators

#### Tests
- Interest tracking functionality
- Calendar display tests
- Interest aggregation accuracy

---

### **Stage 3: Registration & Payment System**
**Goal:** Enable registration and payment for published workshops
**MVP:** Members can register and pay with differential pricing (member vs non-member)

#### Database Changes
- `club_activity_registrations` table
- Payment tracking fields
- Hard capacity validation functions (no waitlists)
- Registration status enum

#### API Endpoints
- `POST /api/workshops/[id]/register` - Registration with payment
- `DELETE /api/workshops/[id]/register` - Cancel registration
- `POST /api/workshops/[id]/payments/create-intent` - Stripe payment intent

#### Frontend
- Registration flow with Stripe Elements (multiple payment methods)
- If public, frontend url to be `(public)/workshops/[id]`
- If private, frontend url to be `dashboard/workshops/[id]` (requires authentication)
- Pricing logic: Private workshops = member pricing (requires sign-in), Public workshops = non-member pricing unless authenticated
- Registration confirmation pages
- Registration status in member dashboard

#### Stripe Integration
- Payment intents for workshops (multiple payment methods supported)
- Webhook handling for payment confirmations
- Metadata tracking for registrations

#### Tests
- Payment flow end-to-end tests
- Registration capacity validation
- Member vs non-member pricing tests

---

### **Stage 4: Attendee Management & Refund System**
**Goal:** Complete attendee lifecycle management
**MVP:** Coordinators can manage attendees, handle refunds, mark attendance

#### Database Changes
- Refund tracking table
- Attendance tracking fields
- Refund policy enforcement logic

#### API Endpoints
- `POST /api/workshops/[id]/refunds` - Process refunds
- `PUT /api/workshops/[id]/attendance` - Mark attendance
- Attendee list via Supabase client

#### Frontend
- Attendee management interface for coordinators
- Refund processing forms
- Attendance tracking interface
- Refund policy display for members

#### Business Logic
- Refund eligibility based on cancellation timing (default: 3 days before workshop)
- Automated refund processing through Stripe
- Attendance confirmation workflow

#### Tests
- Refund policy enforcement tests
- Attendance tracking tests
- Refund processing integration tests

---

### **Stage 5: Advanced Member Dashboard & Analytics**
**Goal:** Comprehensive member experience and coordinator insights
**MVP:** Members have full workshop management interface with analytics

#### Frontend Enhancements
- Full vkurko/calendar implementation
- Advanced filtering and search
- Registration history view
- Upcoming workshops dashboard (in the vkurko/calendar)
- Mobile-responsive design

#### Analytics Features
- Workshop attendance analytics

#### Tests
- Complete dashboard functionality tests
- Analytics accuracy verification
- Mobile responsiveness tests

---

### **Stage 6: Communication System**
**Goal:** Automated notifications and announcements
**MVP:** Email notifications for workshop updates and registrations

#### API Endpoints
- `POST /api/workshops/[id]/announce` - Send announcements
- Webhook handlers for automated email triggers, integreate with Loops and the email processing queue

#### Email Integration
- Workshop update notifications (via Loops and email processing queue)
- Reminder emails before workshops (via Loops and email processing queue)

#### Frontend
- Announcement composition interface
- Email template management

#### Tests
- Email delivery tests
- Notification trigger tests
- Template rendering tests

---

## Cross-Cutting Concerns

### Security
- All mutations through Kysely with RLS enforcement
- Role-based access control throughout
- Stripe webhook signature verification
- Input validation with Valibot schemas
- Secure handling of payment information

### Performance
- Database indexes on frequently queried fields
- TanStack Query for efficient data fetching and caching
- Pagination for large workshop lists
- Optimistic updates for better UX
- Lazy loading for calendar views

### Testing Strategy
- Unit tests for business logic and validation
- Integration tests for API endpoints
- End-to-end tests for critical user flows
- Database constraint and RLS policy tests
- Payment flow integration tests
- Performance tests for calendar rendering

### Code Quality
- Follow existing codebase patterns
- Use established component library (shadcn-svelte)
- Consistent error handling and logging
- TypeScript type safety throughout
- Proper separation of concerns

## Questions for Clarification - ANSWERED

1. **Refund Policy Granularity**: Should refund policies be configurable per workshop or system-wide defaults?
   - **Answer**: Per workshop, default to 3 days before the workshop

2. **Capacity Management**: Should there be waitlists for full workshops or just hard capacity limits?
   - **Answer**: Hard capacity limits only (no waitlists)

3. **Recurring Workshops**: Do you need support for recurring/series workshops?
   - **Answer**: No

4. **Member Verification**: How should the system verify member status for pricing (automatic via roles or manual verification)?
   - **Answer**: Private workshops require members to be signed in, so authentication determines member status

5. **Workshop Categories**: Should workshops have categories/tags for better organization and filtering?
   - **Answer**: No

6. **Notification Preferences**: What level of notification control should members have?
   - **Answer**: No preferences needed - members will get emails and/or discord notifications

7. **Payment Methods**: Should we support multiple payment methods or just SEPA debit like the existing system?
   - **Answer**: Multiple payment methods

8. **Cancellation Policies**: Should there be different cancellation policies for different workshop types?
   - **Answer**: No, same policy for all workshop types

## Key Implementation Details (Based on Clarifications)

### Workshop Access & Pricing
- **Public workshops**: Accessible at `(public)/workshops/[id]`, non-member pricing unless authenticated
- **Private workshops**: Accessible at `dashboard/workshops/[id]`, requires authentication (member pricing)
- **Member verification**: Authentication status determines pricing eligibility

### Capacity & Registration
- **Hard capacity limits**: No waitlist system - when full, registration closes
- **Refund policy**: Configurable per workshop, defaults to 3 days before event
- **Payment methods**: Multiple payment methods supported (not just SEPA debit)

### Communication
- **Email notifications**: Integrated with Loops and existing email processing queue
- **Discord notifications**: Planned for future integration
- **No user preferences**: All members receive notifications

### Simplified Features
- **No workshop categories**: Simple list/calendar view without filtering by category
- **No recurring workshops**: Each workshop is a standalone event
- **Unified cancellation policy**: Same refund rules for all workshop types

## Success Criteria

Each stage should be:
- **Functional**: Core features work as expected
- **Testable**: Comprehensive test coverage
- **Secure**: Proper authentication and authorization
- **Performant**: Acceptable response times under load
- **Maintainable**: Clean, documented code following project patterns

The implementation should integrate seamlessly with existing systems while providing a foundation for future enhancements.
