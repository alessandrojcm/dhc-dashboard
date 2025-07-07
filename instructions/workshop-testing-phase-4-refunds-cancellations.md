# Workshop Testing Phase 4: Refunds & Cancellations

> **Status:** Draft  
> **Updated:** 2025-07-04  
> **Scope:** Attendee cancellation workflows, refund processing, and waitlist priority management testing

## Overview

Phase 4 focuses on testing the workshop cancellation and refund system, including admin-initiated cancellations, Stripe refund processing, waitlist priority management, and credit handling. This phase covers the complex business logic around cancellations and their effects on future workshop prioritization.

## Test Scenarios

### 1. Attendee Cancellation Workflows

#### 1.1 Basic Cancellation Process
**API Tests** (`/api/workshops/[id]/attendees/[attendeeId]/cancel`):
```typescript
// Test cases:
- Cancel paid attendee with refund request
- Cancel paid attendee without refund request  
- Cancel unpaid attendee (invited status)
- Cancel pre_checked attendee
- Cancel attended attendee (should fail)
- Cancel non-existent attendee (404)
- Cancel without authentication (401)
- Cancel with insufficient permissions (403)
- Cancel attendee from finished workshop
- Cancel with invalid cancellation reason
```

**UI Tests** (`/dashboard/beginners-workshop/[id]/attendees`):
```typescript
// Test cases:
- Display cancel button for eligible attendees
- Hide cancel button for ineligible attendees
- Open cancellation modal with options
- Show attendee payment status in modal
- Display refund/waitlist options appropriately
- Submit cancellation with selected options
- Display cancellation success message
- Handle cancellation errors gracefully
- Test cancellation confirmation flow
- Verify attendee status updates in UI
```

#### 1.2 Cancellation Decision Tree
**Integration Tests**:
```typescript
// Test cases:
- Paid attendee → Refund + Waitlist → Process refund & set priority
- Paid attendee → Refund + Remove → Process refund & delete records
- Paid attendee → Keep Credit + Waitlist → Set priority & credit note
- Unpaid attendee → Move to Waitlist → Set priority
- Unpaid attendee → Remove from System → Delete records
- Test all decision tree branches
- Verify correct data updates for each path
- Check audit trail for all decisions
```

### 2. Stripe Refund Integration

#### 2.1 Refund Processing
**API Tests** (`/api/workshops/[id]/attendees/[attendeeId]/refund`):
```typescript
// Test cases:
- Process full refund via Stripe API
- Handle Stripe refund failures
- Process refund for invalid payment ID
- Refund already refunded payment (should fail)
- Handle partial refund scenarios
- Process refund with Stripe API errors
- Refund without authentication
- Refund with insufficient permissions
- Handle Stripe service unavailability
```

**Stripe Integration Tests**:
```typescript
// Test cases:
- Create refund via Stripe API
- Verify refund amount accuracy
- Handle declined refund requests
- Process refund with metadata
- Track refund ID from Stripe
- Handle refund webhook events
- Test refund timing and processing
- Verify refund appears in Stripe dashboard
```

#### 2.2 Refund Status Tracking
**Database Tests**:
```typescript
// Test cases:
- Update refund_requested flag
- Store Stripe refund ID
- Record refund_processed_at timestamp
- Update attendee cancellation status
- Track refund amount and currency
- Maintain refund audit trail
- Handle concurrent refund processing
- Validate refund data integrity
```

**Webhook Tests** (`/api/stripe/webhook`):
```typescript
// Test cases:
- Process refund.created webhook
- Handle refund.updated webhook
- Process refund.failed webhook
- Verify webhook signature validation
- Update database on refund confirmation
- Handle duplicate webhook events
- Process out-of-order webhook events
- Handle malformed webhook payloads
```

### 3. Waitlist Priority Management

#### 3.1 Priority Assignment Logic
**API Tests** (`/api/waitlist/[id]/set-priority`):
```typescript
// Test cases:
- Set priority level for cancelled attendee
- Update previous_workshop_id reference
- Set has_paid_credit flag correctly
- Handle priority conflicts
- Bulk priority updates
- Remove priority assignment
- Priority assignment without authentication
- Priority with insufficient permissions
```

**Database Tests**:
```typescript
// Test cases:
- Priority level enum validation (0, 1, 2)
- Workshop exclusion logic implementation
- Credit flag persistence
- Priority ordering in queries
- Cascade updates on workshop deletion
- Index performance on priority queries
- Concurrent priority updates
- Priority expiration handling
```

#### 3.2 Workshop Exclusion Rules
**Integration Tests**:
```typescript
// Test cases:
- Exclude attendee from same workshop they cancelled
- Allow attendee in different workshops
- Handle workshop ID changes/updates
- Process attendee with multiple cancellations
- Verify exclusion persists across invitations
- Test exclusion with manual attendee addition
- Handle workshop deletion edge cases
```

### 4. Credit System Management

#### 4.1 Payment Credit Tracking
**Database Tests**:
```typescript
// Test cases:
- Set has_paid_credit flag on cancellation
- Track credit amount and workshop source
- Maintain credit audit trail
- Handle multiple credits per user
- Credit expiration rules
- Credit usage tracking
- Credit transfer between profiles
```

**API Tests** (`/api/waitlist/[id]/credit-management`):
```typescript
// Test cases:
- Apply credit to future workshop payment
- Transfer credit between users
- Expire unused credits
- Query credit balance for user
- Credit usage without authentication
- Credit operations with insufficient permissions
- Handle invalid credit amounts
```

#### 4.2 Credit Application Workflow
**Integration Tests**:
```typescript
// Test cases:
- Apply credit during next workshop payment
- Reduce payment amount by credit value
- Handle credit greater than workshop cost
- Process partial credit usage
- Update credit status after usage
- Track credit application timestamps
- Handle credit application failures
```

### 5. Waitlist Re-entry Management

#### 5.1 Waitlist Addition Process
**API Tests** (`/api/waitlist/re-entry`):
```typescript
// Test cases:
- Add cancelled attendee back to waitlist
- Set appropriate priority level
- Update admin notes with cancellation reason
- Handle user already on waitlist
- Add user with existing profile
- Re-entry without authentication
- Re-entry with insufficient permissions
- Validate re-entry eligibility
```

**Database Tests**:
```typescript
// Test cases:
- Create new waitlist entry
- Link to existing user profile
- Set priority_level correctly
- Update admin_notes field
- Handle unique constraints
- Maintain referential integrity
- Track re-entry timestamps
```

#### 5.2 Priority Expiration System
**Cron Tests** (Priority Reset Logic):
```typescript
// Test cases:
- Reset priority after next workshop completion
- Update admin notes on priority expiration
- Handle multiple workshops completing simultaneously
- Skip users who attended next workshop
- Process bulk priority resets efficiently
- Handle workshop completion edge cases
- Verify priority reset notifications
```

### 6. Admin Cancellation Interface

#### 6.1 Cancellation Modal/Form
**UI Tests** (`/dashboard/beginners-workshop/[id]/attendees/cancel-modal`):
```typescript
// Test cases:
- Display attendee information clearly
- Show payment status prominently
- Present appropriate cancellation options
- Validate option selections
- Display cost implications clearly
- Show refund processing timeline
- Handle form submission states
- Display confirmation messages
- Test responsive design
- Handle modal close/cancel actions
```

#### 6.2 Bulk Cancellation Operations
**UI Tests** (`/dashboard/beginners-workshop/[id]/attendees/bulk-operations`):
```typescript
// Test cases:
- Select multiple attendees for cancellation
- Apply same cancellation options to batch
- Preview bulk cancellation effects
- Execute bulk cancellations
- Display bulk operation progress
- Handle partial failures in batch
- Show individual operation results
- Test bulk operation permissions
```

**API Tests** (`/api/workshops/[id]/attendees/bulk-cancel`):
```typescript
// Test cases:
- Process multiple cancellations in batch
- Handle mixed paid/unpaid attendees
- Apply consistent cancellation logic
- Track bulk operation progress
- Handle partial batch failures
- Validate bulk operation permissions
- Process refunds for multiple attendees
- Update multiple waitlist entries
```

### 7. Workshop Impact Management

#### 7.1 Capacity Updates
**Integration Tests**:
```typescript
// Test cases:
- Update available capacity on cancellation
- Enable new invitations if capacity available
- Handle cancellation near workshop date
- Process waitlist top-up after cancellations
- Update capacity tracking in real-time
- Handle rapid consecutive cancellations
- Verify capacity calculations accuracy
```

#### 7.2 Financial Impact Tracking
**API Tests** (`/api/workshops/[id]/financial-impact`):
```typescript
// Test cases:
- Calculate total refunds processed
- Track revenue impact of cancellations
- Generate cancellation reports
- Show refund vs. credit statistics
- Export financial impact data
- Handle currency and tax implications
- Track refund processing costs
```

### 8. Notification & Communication

#### 8.1 Cancellation Notifications
**Integration Tests** (Email System):
```typescript
// Test cases:
- Send cancellation confirmation email
- Include refund processing timeline
- Notify about waitlist re-entry (if applicable)
- Send refund confirmation when processed
- Handle email sending failures
- Track email delivery status
- Customize email content by cancellation type
```

#### 8.2 Admin Notifications
**API Tests** (`/api/notifications/cancellations`):
```typescript
// Test cases:
- Notify admins of workshop cancellations
- Alert on high cancellation rates
- Notify of refund processing failures
- Send daily cancellation summaries
- Alert on unusual cancellation patterns
- Track notification delivery
```

### 9. Error Handling & Edge Cases

#### 9.1 Stripe Integration Failures
**Integration Tests**:
```typescript
// Test cases:
- Handle Stripe API unavailability
- Process refund failures gracefully
- Retry failed refund requests
- Handle network timeouts
- Process webhook delivery failures
- Handle invalid payment references
- Manage refund processing delays
```

#### 9.2 Data Consistency Issues
**Database Tests**:
```typescript
// Test cases:
- Handle concurrent cancellation requests
- Prevent double refund processing
- Maintain attendee status consistency
- Handle partial transaction failures
- Recover from system failures
- Validate data integrity after operations
- Handle foreign key constraint issues
```

#### 9.3 Business Logic Edge Cases
**Integration Tests**:
```typescript
// Test cases:
- Cancel attendee who already checked in
- Process refund for workshop happening today
- Handle cancellation of finished workshop
- Cancel attendee with existing credit
- Process cancellation during payment
- Handle workshop cancellation vs. attendee cancellation
```

## Test Data Setup

### Attendee Scenarios
```typescript
const attendeeScenarios = {
  paid_confirmed: {
    status: 'confirmed',
    paid_at: new Date(Date.now() - 86400000), // Paid yesterday
    stripe_payment_id: 'pi_test_payment_123',
    payment_amount: 2500 // €25.00 in cents
  },
  unpaid_invited: {
    status: 'invited',
    invited_at: new Date(Date.now() - 3600000), // Invited 1 hour ago
    payment_url: 'workshop_pay_token_abc123'
  },
  attended: {
    status: 'attended',
    checked_in_at: new Date(Date.now() - 7200000), // Checked in 2 hours ago
    paid_at: new Date(Date.now() - 86400000)
  },
  pre_checked: {
    status: 'pre_checked',
    onboarding_completed_at: new Date(Date.now() - 86400000),
    paid_at: new Date(Date.now() - 172800000) // Paid 2 days ago
  }
};
```

### Cancellation Options
```typescript
const cancellationOptions = {
  refund_and_waitlist: {
    reason: 'Schedule conflict',
    moveToWaitlist: true,
    requestRefund: true
  },
  refund_and_remove: {
    reason: 'No longer interested',
    moveToWaitlist: false,
    requestRefund: true
  },
  credit_and_waitlist: {
    reason: 'Temporary conflict',
    moveToWaitlist: true,
    requestRefund: false
  },
  remove_only: {
    reason: 'Moving away',
    moveToWaitlist: false,
    requestRefund: false
  }
};
```

### Stripe Test Scenarios
```typescript
const stripeRefundScenarios = {
  successful_refund: {
    payment_intent: 'pi_test_successful',
    refund_amount: 2500,
    expected_status: 'succeeded'
  },
  failed_refund: {
    payment_intent: 'pi_test_failed',
    refund_amount: 2500,
    expected_error: 'charge_already_refunded'
  },
  partial_refund: {
    payment_intent: 'pi_test_partial',
    refund_amount: 1250, // Half refund
    expected_status: 'succeeded'
  }
};
```

## Test Execution Order

### Sequential Dependencies
1. **Workshop with Paid Attendees** → Cancellation Testing
2. **Cancellation Request** → Refund Processing
3. **Refund Processing** → Stripe Integration Testing
4. **Cancellation Complete** → Waitlist Priority Testing
5. **Priority Assignment** → Future Workshop Invitation Testing

### Parallel Execution
- Multiple attendee cancellation scenarios
- Concurrent refund processing tests
- Different cancellation option testing
- Stripe webhook event processing

## Success Criteria

### Cancellation System
- All cancellation workflows function correctly
- Proper decision tree implementation
- Accurate status updates and tracking
- Admin interface working smoothly

### Refund Processing
- Stripe integration working reliably
- Refund status tracking accurate
- Webhook processing functioning
- Error handling working properly

### Priority Management
- Waitlist priority system working
- Workshop exclusion rules enforced
- Credit system functioning correctly
- Priority expiration working

## Performance Benchmarks

### Cancellation Processing
- Individual cancellation: < 5 seconds
- Bulk cancellations (10 attendees): < 30 seconds
- Refund processing: < 15 seconds
- Status update propagation: < 2 seconds

### Stripe Operations
- Refund API call: < 10 seconds
- Webhook processing: < 3 seconds
- Refund status verification: < 5 seconds
- Error recovery time: < 1 minute

### Database Operations
- Priority query execution: < 1 second
- Waitlist updates: < 2 seconds
- Credit calculations: < 1 second
- Bulk data updates: < 10 seconds

This comprehensive test plan ensures reliable cancellation and refund processing while maintaining proper business logic and data integrity throughout the system.