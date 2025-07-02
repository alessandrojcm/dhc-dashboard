# Refunds & Cancellations Implementation Plan

> **Status:** Planning Phase  
> **Updated:** 2025-07-02  
> **Scope:** Workshop attendee cancellation and refund management system

## Overview

Implement a comprehensive system for handling workshop cancellations and refunds with the following business logic:

### Business Rules

#### Cancellation Options
1. **IF user cancels (before or after paying):**
   - Offer option to move back to waitlist
   - **IF they say YES:** Move to waitlist with priority note (excluded from same workshop, priority for next workshop)
   - **IF they decline:** Delete them from the system

#### Payment Handling
2. **IF they have paid:**
   - Offer refund option
   - **IF they accept refund:** Process Stripe refund
   - **IF they decline refund:** Make note that user has already paid (for future workshops)
   - **IF they don't want to stay on waitlist:** Automatic refund and removal

#### Priority System
3. **Priority Management:**
   - Priority lasts until next workshop only
   - After next workshop, attendee becomes normal priority
   - Attendees can manually request deferral (which grants priority again)

## Technical Requirements

### Confirmed Specifications
- ✅ **Stripe API Integration** for automated refunds
- ✅ **Admin-only interface** (no self-service cancellations)
- ✅ **Priority expires after next workshop** 
- ✅ **Manual deferral system** for re-prioritization
- ✅ **Full refund policy** (no partial refunds)
- ✅ **Cancellation deadline** - up until day of workshop (inclusive)
- 📝 **Email notifications** - to be implemented later (separate task)

## Implementation Phases

### Phase 1: Database Schema Updates

#### New Fields for `workshop_attendees` table:
```sql
-- Cancellation tracking
cancelled_at TIMESTAMPTZ,
cancelled_by UUID REFERENCES user_profiles(id),

-- Refund management  
refund_requested BOOLEAN DEFAULT FALSE,
stripe_refund_id TEXT,
refund_processed_at TIMESTAMPTZ,

-- Waitlist management
waitlist_return_requested BOOLEAN DEFAULT FALSE,
```

#### New Fields for `waitlist` table:
```sql
-- Priority system
priority_level INTEGER DEFAULT 0,  -- 0=normal, 1=cancelled_priority, 2=manual_priority
previous_workshop_id UUID REFERENCES workshops(id),
has_paid_credit BOOLEAN DEFAULT FALSE,
-- Use existing admin_notes field for cancellation/priority notes
```

#### Check if `admin_notes` field exists in `waitlist` table:
```sql
-- If admin_notes doesn't exist, add it:
-- ALTER TABLE waitlist ADD COLUMN admin_notes TEXT;
```

#### Update `workshop_attendee_status` enum:
```sql
-- Add 'cancelled' status if not exists
ALTER TYPE workshop_attendee_status ADD VALUE IF NOT EXISTS 'cancelled';
```

### Phase 2: Core API Endpoints

#### Cancellation Management
- `POST /api/workshops/[id]/attendees/[attendeeId]/cancel`
  - Input: `{ reason, moveToWaitlist, requestRefund }`
  - Handles full cancellation workflow

#### Refund Processing  
- `POST /api/workshops/[id]/attendees/[attendeeId]/refund`
  - Integrates with Stripe refund API
  - Updates refund tracking fields

#### Waitlist Management
- `POST /api/waitlist/[id]/remove` - Complete removal from system
- `POST /api/waitlist/[id]/set-priority` - Manual priority management
- `POST /api/waitlist/[id]/defer` - Manual deferral requests

### Phase 3: Stripe Integration

#### Refund Processing
```typescript
// Stripe refund integration
async function processRefund(attendeeId: string, amount: number) {
  // 1. Create Stripe refund
  // 2. Update workshop_attendees with refund details
  // 3. Handle refund webhook confirmation
}
```

#### Webhook Updates
- Extend existing Stripe webhook to handle refund events
- Update attendee status on refund confirmation

### Phase 4: Business Logic Implementation

#### Cancellation Decision Tree
```
Admin Cancels Attendee
├── Has Paid?
│   ├── Yes → Show Refund Options
│   │   ├── Refund + Move to Priority Waitlist → Process Refund + Set Priority
│   │   ├── Refund + Remove from System → Process Refund + Delete
│   │   └── No Refund + Move to Priority Waitlist → Set Priority + Note Paid Credit
│   └── No → Show Waitlist Options
│       ├── Move to Priority Waitlist → Set Priority
│       └── Remove from System → Delete Records
```

#### Priority Management Logic
```typescript
// Priority calculation for workshop invitations
function getWaitlistWithPriority(workshopId: string) {
  return db
    .selectFrom('waitlist')
    // Exclude people who cancelled from this specific workshop
    .where('previous_workshop_id', '!=', workshopId)
    .orWhere('previous_workshop_id', 'is', null)
    .orderBy([
      'priority_level desc',  // 2=manual, 1=cancelled, 0=normal
      'created_at asc'        // FIFO within same priority
    ]);
}

// Reset priority after workshop completion
function resetPriorityAfterWorkshop(workshopId: string) {
  return db
    .updateTable('waitlist')
    .set({ 
      priority_level: 0,
      admin_notes: db.raw("CASE WHEN admin_notes IS NOT NULL THEN admin_notes || ' [Priority expired after workshop]' ELSE '[Priority expired after workshop]' END")
    })
    .where('priority_level', '=', 1)
    .where('previous_workshop_id', '=', workshopId);
}
```

### Phase 5: Admin Interface

#### Workshop Detail Page Enhancements
- Add "Cancel Attendee" button for each attendee
- Cancellation modal with refund/waitlist options
- Display cancellation history and refund status

#### Waitlist Management Interface  
- Priority level indicators
- Manual priority assignment
- Deferral request handling

#### Refund Tracking
- Refund status display
- Stripe refund ID tracking
- Payment credit notes

### Phase 6: Integration Updates

#### Workshop Invitation System
- Update invitation logic to respect priority levels
- Exclude attendees from same workshop they cancelled from
- Reset priority after workshop completion

#### Attendee Status Tracking
- Real-time updates for cancellation status
- Refund processing status
- Waitlist priority changes

## Data Flow Examples

### Example 1: Paid Attendee Cancels with Refund
1. Admin clicks "Cancel" on attendee
2. System shows: "Attendee has paid €25. Options: Refund + Waitlist, Refund + Remove, Keep Credit + Waitlist"
3. Admin selects "Refund + Waitlist"
4. System processes Stripe refund and moves attendee to priority waitlist
5. Attendee gets priority for next workshop (but not this one)

### Example 2: Unpaid Attendee Cancels
1. Admin clicks "Cancel" on attendee  
2. System shows: "Options: Move to Waitlist, Remove from System"
3. Admin selects "Move to Waitlist"
4. Attendee moved to priority waitlist for next workshop

### Example 3: Priority Expiration
1. Workshop completes
2. System automatically resets priority_level to 0 for attendees where previous_workshop_id = completed_workshop_id
3. Previously prioritized attendees become normal waitlist members
4. Admin notes updated to reflect priority expiration

## Security Considerations

- Admin-only access to cancellation functions
- Audit trail for all cancellation/refund actions
- Stripe webhook signature verification
- RLS policies for refund data access

## Testing Requirements

- Stripe refund API integration tests
- Priority system logic tests  
- Cancellation workflow end-to-end tests
- Webhook handling tests

## Future Enhancements (Not in Scope)

- Email notification system for cancellations/refunds
- Self-service cancellation portal
- Automated refund policies based on timing
- Credit system for future workshops
- Bulk cancellation tools

---

## Notes

- Email confirmations will be implemented in a separate phase
- Priority system is designed to be fair while encouraging commitment
- Stripe integration ensures reliable refund processing
- Admin interface prioritizes clarity and prevents errors