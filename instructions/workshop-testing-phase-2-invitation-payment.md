# Workshop Testing Phase 2: Invitation & Payment System

> **Status:** Draft  
> **Updated:** 2025-07-04  
> **Scope:** Workshop invitation logic, payment processing, and attendee management testing

## Overview

Phase 2 focuses on testing the workshop invitation and payment system, including waitlist processing, batch invitations, Stripe integration, and attendee status management. This phase covers the critical flow from workshop publication to confirmed attendees.

## Test Scenarios

### 1. Workshop Publishing & Invitation Trigger

#### 1.1 Workshop Publication
**API Tests** (`/api/workshops/[id]/publish`):
```typescript
// Test cases:
- Publish workshop with waitlist users available
- Publish workshop with no waitlist users
- Publish workshop with insufficient waitlist users
- Publish already published workshop (should fail)
- Publish workshop with invalid batch_size
- Publish workshop without authentication
- Publish workshop with insufficient permissions
- Publish workshop with past date (should fail)
```

**UI Tests** (`/dashboard/beginners-workshop/[id]`):
```typescript
// Test cases:
- Display publish button for draft workshops
- Show publish confirmation modal
- Execute publish action and verify state change
- Display success message after publishing
- Show invitation progress/status
- Test publish with network error
- Test publish button disabled state
- Verify invitation count display
```

#### 1.2 Batch Invitation Processing
**Integration Tests** (Edge Function: `workshop_inviter`):
```typescript
// Test cases:
- Process first batch invitation (default 16)
- Process with custom batch_size
- Process with waitlist smaller than batch_size
- Process with exactly batch_size waitlist
- Handle empty waitlist gracefully
- Process invitation with database errors
- Verify email queue entries created
- Check attendee records created with correct status
```

### 2. Waitlist Selection Logic

#### 2.1 Waitlist Priority Processing
**API Tests** (`/api/workshops/[id]/waitlist-selection`):
```typescript
// Test cases:
- Select waitlist users in FIFO order
- Respect manual priority overrides
- Exclude users with recent cancellations
- Handle users with priority from previous workshops
- Process users with has_paid_credit flag
- Verify correct batch size selection
- Handle waitlist with mixed priority levels
- Test selection with waitlist filtering
```

**Database Tests**:
```typescript
// Test cases:
- Verify waitlist ordering logic
- Test priority level calculations
- Check exclusion rules for previous workshops
- Validate waitlist status filtering
- Test concurrent waitlist access
- Verify RLS policies for waitlist data
```

#### 2.2 Manual Attendee Addition
**API Tests** (`/api/workshops/[id]/attendees/manual`):
```typescript
// Test cases:
- Add attendee manually to workshop
- Add attendee beyond capacity (should work)
- Add already invited attendee (should fail)
- Add non-existent user (should fail)
- Set custom priority for manual attendee
- Add manual attendee without authentication
- Add manual attendee with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]/attendees`):
```typescript
// Test cases:
- Display manual add attendee button
- Open manual add modal/form
- Search for users to add manually
- Select user and set priority
- Submit manual addition and verify
- Test manual add with network error
- Display manual attendee indicators
- Test permission-based manual add
```

### 3. Payment Link Generation

#### 3.1 Payment URL Creation
**API Tests** (`/api/workshops/[id]/payment-links`):
```typescript
// Test cases:
- Generate payment link for invited attendee
- Generate unique tokens for each attendee
- Set correct expiration dates
- Include workshop pricing information
- Handle Stripe price lookup failures
- Generate links with custom pricing
- Verify link security and validation
- Test link generation without authentication
```

**Integration Tests**:
```typescript
// Test cases:
- Payment link contains correct workshop data
- Link expiration set correctly (day before workshop)
- Token uniqueness across all attendees
- Link deactivation when capacity reached
- Payment link security validation
- Stripe price integration working
```

#### 3.2 Payment Link Access Control
**API Tests** (`/api/workshop/pay/[token]`):
```typescript
// Test cases:
- Access payment page with valid token
- Access with expired token (should fail)
- Access with invalid token (should fail)
- Access with already used token
- Verify email + DOB guard working
- Test rate limiting on payment access
- Access payment page multiple times
```

**UI Tests** (`/workshop/pay/[token]`):
```typescript
// Test cases:
- Load payment page with valid token
- Display workshop information correctly
- Show pricing and payment form
- Test email + DOB verification form
- Display error for invalid/expired tokens
- Test responsive design on payment page
- Show payment loading states
- Display payment success/failure states
```

### 4. Stripe Payment Integration

#### 4.1 Payment Processing
**API Tests** (`/api/workshop/payment/process`):
```typescript
// Test cases:
- Process successful card payment
- Handle declined card payment
- Process payment with invalid card
- Handle Stripe webhook events
- Update attendee status on payment success
- Handle payment session timeout
- Process refund via Stripe API
- Handle webhook signature validation
```

**Stripe Integration Tests**:
```typescript
// Test cases:
- Create Stripe payment session
- Handle successful payment webhook
- Handle failed payment webhook
- Process refund through Stripe
- Verify payment metadata
- Test different payment methods
- Handle Stripe API errors
- Test webhook retry logic
```

#### 4.2 Payment Status Management
**Database Tests**:
```typescript
// Test cases:
- Update attendee status to 'confirmed' on payment
- Record payment timestamp
- Store Stripe payment ID
- Handle duplicate payment webhooks
- Update capacity tracking
- Verify payment audit trail
- Test concurrent payment processing
```

**UI Tests** (`/workshop/pay/[token]`):
```typescript
// Test cases:
- Display Stripe payment form
- Handle payment form submission
- Show payment processing states
- Display payment success confirmation
- Handle payment error messages
- Test payment form validation
- Show workshop booking confirmation
- Test payment retry functionality
```

### 5. Attendee Status Transitions

#### 5.1 Status Flow Management
**API Tests**:
```typescript
// Test cases:
- Transition from 'invited' to 'confirmed'
- Prevent invalid status transitions
- Handle status updates with attendee not found
- Verify status transition timestamps
- Test bulk status updates
- Handle concurrent status changes
- Validate status transition permissions
```

**Database Tests**:
```typescript
// Test cases:
- Status enum validation
- Timestamp updates on status change
- Cascade updates to related tables
- RLS policy enforcement on status
- Audit trail for status changes
- Constraint validation on transitions
```

#### 5.2 Capacity Management
**Integration Tests**:
```typescript
// Test cases:
- Stop sending invitations when capacity reached
- Handle over-capacity scenarios
- Update available spots in real-time
- Prevent payment when workshop full
- Handle manual capacity overrides
- Verify capacity counting logic
- Test concurrent capacity updates
```

### 6. Cool-off Period & Top-up Invitations

#### 6.1 Cool-off Logic
**Cron Tests** (Edge Function: `workshop_topup`):
```typescript
// Test cases:
- Trigger top-up after cool-off period
- Respect cool-off days configuration
- Skip workshops with full capacity
- Process multiple workshops in single run
- Handle workshops with no remaining waitlist
- Verify last_batch_sent tracking
- Test cron execution scheduling
```

**API Tests** (`/api/workshops/[id]/topup`):
```typescript
// Test cases:
- Manual trigger of top-up invitations
- Check cool-off period validation
- Verify remaining capacity calculation
- Process second batch invitations
- Handle no remaining waitlist users
- Test top-up without authentication
- Top-up with insufficient permissions
```

#### 6.2 Multi-batch Processing
**Integration Tests**:
```typescript
// Test cases:
- Process first batch on publish
- Wait for cool-off period
- Process second batch automatically
- Handle third batch if needed
- Track batch numbers and timestamps
- Verify email spacing between batches
- Test batch size adjustments
```

### 7. Manual Priority & Waitlist Management

#### 7.1 Priority Assignment
**API Tests** (`/api/workshops/[id]/attendees/priority`):
```typescript
// Test cases:
- Set manual priority for attendee
- Update existing priority values
- Bulk priority updates
- Priority validation (negative values)
- Remove priority assignment
- Priority changes without authentication
- Priority changes with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]/attendees`):
```typescript
// Test cases:
- Display priority indicators
- Drag and drop priority reordering
- Manual priority input fields
- Bulk priority management tools
- Priority validation in UI
- Real-time priority updates
- Permission-based priority editing
```

#### 7.2 Waitlist Manipulation
**API Tests** (`/api/waitlist/priority-management`):
```typescript
// Test cases:
- Add user to workshop waitlist priority
- Remove user from priority list
- Transfer priority between workshops
- Bulk waitlist operations
- Waitlist filtering and search
- Priority expiration handling
```

### 8. Email Integration & Notifications

#### 8.1 Invitation Emails
**Integration Tests** (Email Service):
```typescript
// Test cases:
- Send invitation email via Loops.so
- Include correct workshop details
- Include valid payment link
- Handle email sending failures
- Verify email template variables
- Test email rate limiting
- Batch email processing
- Email delivery confirmation
```

**API Tests** (`/api/workshop/emails/invitation`):
```typescript
// Test cases:
- Queue invitation emails for batch
- Verify email payload structure
- Handle email service errors
- Test email template rendering
- Track email sending status
- Retry failed email sends
```

#### 8.2 Email Status Tracking
**Database Tests**:
```typescript
// Test cases:
- Log email send attempts
- Track email delivery status
- Record email open/click events
- Handle bounce notifications
- Update attendee communication log
- Email audit trail maintenance
```

### 9. Error Handling & Edge Cases

#### 9.1 Payment Failures
**Integration Tests**:
```typescript
// Test cases:
- Handle declined payment cards
- Process expired payment sessions
- Manage insufficient funds errors
- Handle Stripe service outages
- Process payment timeout scenarios
- Retry failed payment webhooks
```

#### 9.2 Workshop Capacity Edge Cases
**Integration Tests**:
```typescript
// Test cases:
- Simultaneous payment completion at capacity
- Manual attendee addition beyond capacity
- Capacity changes during invitation process
- Race conditions in attendee addition
- Workshop cancellation during payment
- Payment completion for cancelled workshop
```

#### 9.3 Data Consistency
**Database Tests**:
```typescript
// Test cases:
- Concurrent invitation processing
- Attendee status consistency
- Payment record integrity
- Waitlist state management
- Workshop capacity accuracy
- Transaction rollback scenarios
```

## Test Data Setup

### Waitlist Templates
```typescript
const waitlistUsers = {
  standard: Array(25).fill(null).map((_, i) => ({
    email: `waitlist-${i}@test.com`,
    priority_level: 0,
    created_at: new Date(Date.now() - i * 86400000) // Stagger by days
  })),
  priority: Array(5).fill(null).map((_, i) => ({
    email: `priority-${i}@test.com`,
    priority_level: 1,
    previous_workshop_id: 'uuid-previous-workshop'
  })),
  credit: Array(3).fill(null).map((_, i) => ({
    email: `credit-${i}@test.com`,
    has_paid_credit: true,
    priority_level: 1
  }))
};
```

### Workshop Configuration
```typescript
const workshopConfigs = {
  standard: {
    capacity: 16,
    batch_size: 16,
    cool_off_days: 5,
    stripe_price_key: 'beginners_workshop_25eur'
  },
  small: {
    capacity: 8,
    batch_size: 8,
    cool_off_days: 3,
    stripe_price_key: 'small_workshop_20eur'
  },
  large: {
    capacity: 24,
    batch_size: 12,
    cool_off_days: 7,
    stripe_price_key: 'large_workshop_30eur'
  }
};
```

### Stripe Test Data
```typescript
const stripeTestCards = {
  success: '4242424242424242',
  declined: '4000000000000002',
  insufficient_funds: '4000000000009995',
  expired: '4000000000000069',
  processing_error: '4000000000000119'
};
```

## Test Execution Order

### Sequential Dependencies
1. **Workshop Creation** → Workshop Publishing
2. **Waitlist Setup** → Invitation Processing
3. **Invitation Sent** → Payment Processing
4. **Payment Success** → Status Updates
5. **First Batch Complete** → Cool-off Top-up

### Parallel Execution
- Multiple workshop invitation processes
- Concurrent payment processing tests
- Different Stripe test scenarios
- Email delivery verification

## Success Criteria

### Invitation System
- Correct waitlist selection and ordering
- Proper batch size handling
- Email delivery confirmation
- Payment link generation working

### Payment Processing
- Stripe integration functioning
- Payment status updates accurate
- Error handling working correctly
- Webhook processing reliable

### Data Integrity
- Attendee status consistency
- Capacity tracking accuracy
- Payment record completeness
- Audit trail maintenance

## Performance Benchmarks

### Invitation Processing
- Batch invitation processing: < 30 seconds
- Payment link generation: < 5 seconds per attendee
- Waitlist selection query: < 2 seconds
- Workshop publish action: < 10 seconds

### Payment Processing
- Payment page load: < 3 seconds
- Stripe payment processing: < 15 seconds
- Webhook processing: < 5 seconds
- Status update propagation: < 2 seconds

This comprehensive test plan ensures reliable invitation and payment processing while maintaining system performance and data integrity.