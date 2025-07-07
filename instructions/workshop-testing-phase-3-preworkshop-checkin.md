# Workshop Testing Phase 3: Pre-workshop & Check-in

> **Status:** Draft  
> **Updated:** 2025-07-04  
> **Scope:** Pre-workshop onboarding, QR code check-in, and attendance tracking testing

## Overview

Phase 3 focuses on testing the pre-workshop onboarding process and workshop day check-in functionality. This includes automated onboarding emails, pre-workshop forms, QR code generation, self-service check-in, and real-time attendance tracking.

## Test Scenarios

### 1. Pre-workshop Onboarding System

#### 1.1 Onboarding Email Triggers
**Cron Tests** (Edge Function: `workshop_onboarding`):
```typescript
// Test cases:
- Trigger onboarding emails 2 days before workshop
- Process multiple workshops on same day
- Skip workshops with no confirmed attendees
- Handle workshops with past dates
- Process attendees who haven't completed onboarding
- Skip attendees who already completed onboarding
- Handle email sending failures gracefully
- Verify onboarding token generation
```

**API Tests** (`/api/workshop/onboarding/trigger`):
```typescript
// Test cases:
- Manual trigger of onboarding emails
- Trigger for specific workshop
- Trigger with date override (testing)
- Handle workshop not found (404)
- Trigger without authentication (401)
- Trigger with insufficient permissions (403)
- Verify email queue creation
- Check onboarding token generation
```

#### 1.2 Onboarding Token Management
**Database Tests**:
```typescript
// Test cases:
- Generate unique onboarding tokens
- Token expiration validation
- Token security (cryptographically secure)
- Associate tokens with correct attendees
- Prevent token reuse
- Handle token collision (extremely rare)
- Clean up expired tokens
- Token audit trail
```

**API Tests** (`/api/workshop/onboarding/validate-token`):
```typescript
// Test cases:
- Validate active onboarding token
- Reject expired tokens
- Reject invalid/malformed tokens
- Reject already used tokens
- Handle non-existent tokens
- Rate limiting on token validation
- Token validation without auth
```

### 2. Pre-workshop Onboarding Form

#### 2.1 Onboarding Form Access
**UI Tests** (`/workshop/onboarding/[token]`):
```typescript
// Test cases:
- Load onboarding page with valid token
- Display workshop information correctly
- Show attendee name and details
- Handle invalid token gracefully
- Handle expired token with clear message
- Display form fields correctly
- Test responsive design
- Handle page refresh with token
```

**API Tests** (`/api/workshop/onboarding/[token] GET`):
```typescript
// Test cases:
- Fetch onboarding data with valid token
- Return workshop and attendee information
- Handle invalid token (404)
- Return appropriate error messages
- Validate token format
- Check token permissions
```

#### 2.2 Onboarding Form Submission
**API Tests** (`/api/workshop/onboarding POST`):
```typescript
// Test cases:
- Submit valid onboarding form
- Handle missing required fields (insurance)
- Process optional fields (media consent, signature)
- Update attendee status to 'pre_checked'
- Record submission timestamp
- Handle duplicate submissions gracefully
- Validate form data server-side
- Submit without valid token (403)
```

**UI Tests** (`/workshop/onboarding/[token]`):
```typescript
// Test cases:
- Fill out insurance confirmation (required)
- Toggle media consent checkbox
- Enter digital signature (optional)
- Submit form and verify success
- Test form validation client-side
- Handle form submission errors
- Display success confirmation
- Test form accessibility
- Handle network errors during submission
```

#### 2.3 Onboarding Data Validation
**Database Tests**:
```typescript
// Test cases:
- Insurance confirmation recorded correctly
- Media consent timestamp saved
- Digital signature stored properly
- Onboarding completion timestamp
- Status update to 'pre_checked'
- Data integrity constraints
- Audit trail for onboarding completion
```

### 3. QR Code Generation & Management

#### 3.1 Workshop QR Code Creation
**API Tests** (`/api/workshop/[id]/qr-code`):
```typescript
// Test cases:
- Generate QR code for workshop
- Create unique QR per workshop
- Include correct check-in URL
- Handle non-existent workshop (404)
- Generate QR with custom size/format
- Cache QR code generation
- QR code without authentication
- QR code with insufficient permissions
```

**Integration Tests**:
```typescript
// Test cases:
- QR code contains correct check-in URL
- QR code scannable by standard readers
- URL format matches expected pattern
- QR code resolution appropriate
- Error correction level adequate
- Batch QR generation for multiple workshops
```

#### 3.2 QR Code Display & Management
**UI Tests** (`/dashboard/beginners-workshop/[id]/qr-code`):
```typescript
// Test cases:
- Display QR code for workshop
- Show check-in URL below QR code
- Print-friendly QR code layout
- Download QR code as image
- QR code responsive sizing
- Test QR code regeneration
- Display QR code creation timestamp
- Handle QR generation errors
```

### 4. Workshop Check-in System

#### 4.1 Check-in Page Access
**UI Tests** (`/workshop/checkin/[workshopId]`):
```typescript
// Test cases:
- Load check-in page via QR code scan
- Display workshop information
- Show check-in form
- Handle invalid workshop ID (404)
- Display workshop date and location
- Show available attendees for check-in
- Test mobile responsiveness (primary use case)
- Handle workshop not yet started
- Handle finished workshop check-in
```

**API Tests** (`/api/workshop/[id]/checkin-data`):
```typescript
// Test cases:
- Fetch workshop check-in data
- Return confirmed and pre_checked attendees
- Filter out already checked-in attendees
- Handle workshop not found (404)
- Return workshop basic information
- Check data access permissions
- Validate workshop ID format
```

#### 4.2 Attendee Identification
**UI Tests** (`/workshop/checkin/[workshopId]`):
```typescript
// Test cases:
- Display attendee selection dropdown
- Show attendee names clearly
- Filter attendees by status
- Indicate pre-checked attendees (✓)
- Show warning for non-pre-checked (⚠️)
- Search/filter attendee list
- Handle empty attendee list
- Display attendee count information
```

**Database Tests**:
```typescript
// Test cases:
- Query confirmed attendees efficiently
- Filter by workshop ID correctly
- Exclude already attended attendees
- Include pre_checked status indication
- Order attendees alphabetically
- Join with user profiles correctly
- Apply RLS policies properly
```

#### 4.3 Check-in Processing
**API Tests** (`/api/workshop/checkin POST`):
```typescript
// Test cases:
- Check in confirmed attendee
- Check in pre_checked attendee
- Update status to 'attended'
- Record check-in timestamp
- Handle attendee not found (404)
- Prevent double check-in
- Handle invalid workshop ID
- Check-in without proper identification
- Validate attendee belongs to workshop
```

**UI Tests** (`/workshop/checkin/[workshopId]`):
```typescript
// Test cases:
- Select attendee from dropdown
- Submit check-in form
- Display check-in success message
- Clear form after successful check-in
- Handle check-in errors gracefully
- Show progress/loading during check-in
- Display real-time attendee updates
- Test rapid consecutive check-ins
```

### 5. Backup Onboarding at Check-in

#### 5.1 Missing Onboarding Detection
**API Tests** (`/api/workshop/checkin/validate-attendee`):
```typescript
// Test cases:
- Detect attendee without insurance confirmation
- Detect attendee without media consent decision
- Check onboarding completion status
- Return missing requirements list
- Handle fully pre-checked attendees
- Validate attendee eligibility for check-in
```

**UI Tests** (`/workshop/checkin/[workshopId]/backup-onboarding`):
```typescript
// Test cases:
- Display backup onboarding form
- Show missing requirements clearly
- Require insurance confirmation
- Allow media consent decision
- Complete backup onboarding
- Proceed to check-in after completion
- Handle form validation errors
- Skip backup for pre-checked attendees
```

#### 5.2 Emergency Onboarding Processing
**API Tests** (`/api/workshop/emergency-onboarding POST`):
```typescript
// Test cases:
- Process emergency onboarding
- Update attendee onboarding status
- Record emergency completion timestamp
- Proceed with check-in automatically
- Validate required fields
- Handle attendee not found
- Prevent misuse of emergency onboarding
```

### 6. Real-time Attendance Tracking

#### 6.1 Admin Attendance Dashboard
**UI Tests** (`/dashboard/beginners-workshop/[id]/attendance`):
```typescript
// Test cases:
- Display real-time attendance list
- Show attendee status indicators
- Update attendance without page refresh
- Display check-in timestamps
- Show onboarding completion status
- Filter attendees by status
- Search attendees by name
- Export attendance report
- Handle workshop day vs. non-workshop day
```

**API Tests** (`/api/workshop/[id]/attendance`):
```typescript
// Test cases:
- Fetch current attendance data
- Real-time updates via webhooks/SSE
- Filter attendance by status
- Include check-in timestamps
- Show onboarding completion details
- Handle large attendee lists
- Paginate attendance data
- Export attendance to CSV
```

#### 6.2 Live Updates System
**Integration Tests** (Supabase Realtime):
```typescript
// Test cases:
- Real-time updates on status changes
- Multiple admin users see updates
- Updates propagate within 2 seconds
- Handle connection drops gracefully
- Batch updates efficiently
- Filter updates by workshop
- Handle high-frequency updates
- Clean up subscriptions properly
```

### 7. Workshop Day Edge Cases

#### 7.1 Time-based Access Control
**API Tests**:
```typescript
// Test cases:
- Allow check-in on workshop day
- Restrict check-in before workshop day
- Allow check-in after workshop start
- Handle timezone differences
- Grace period for late check-ins
- Prevent check-in for cancelled workshops
- Handle workshop date changes
```

**UI Tests**:
```typescript
// Test cases:
- Display appropriate messages for timing
- Show countdown to workshop start
- Handle timezone display correctly
- Update UI based on current time
- Show workshop status clearly
- Handle date/time edge cases
```

#### 7.2 Capacity and Overbooking
**Integration Tests**:
```typescript
// Test cases:
- Check in attendees at full capacity
- Handle manual attendee additions
- Process check-ins beyond original capacity
- Track actual vs. planned attendance
- Handle no-shows accurately
- Update capacity tracking in real-time
```

### 8. Error Handling & Recovery

#### 8.1 Network and Service Issues
**UI Tests**:
```typescript
// Test cases:
- Handle network disconnection during check-in
- Retry failed check-in requests
- Cache check-in data locally
- Display appropriate error messages
- Allow manual retry of operations
- Graceful degradation of features
```

#### 8.2 Data Integrity Issues
**Database Tests**:
```typescript
// Test cases:
- Handle concurrent check-in attempts
- Prevent duplicate attendance records
- Maintain status consistency
- Handle transaction rollbacks
- Validate data integrity constraints
- Recover from partial failures
```

## Test Data Setup

### Workshop Scenarios
```typescript
const workshopScenarios = {
  workshop_day: {
    workshop_date: new Date(), // Today
    status: 'published',
    attendees: 15 // Mix of pre_checked and confirmed
  },
  future_workshop: {
    workshop_date: new Date(Date.now() + 7 * 86400000), // Next week
    status: 'published',
    attendees: 12
  },
  onboarding_ready: {
    workshop_date: new Date(Date.now() + 2 * 86400000), // 2 days away
    status: 'published',
    attendees: 10 // All confirmed, none pre_checked
  }
};
```

### Attendee States
```typescript
const attendeeStates = {
  confirmed_no_onboarding: {
    status: 'confirmed',
    onboarding_completed_at: null,
    insurance_ok_at: null,
    consent_media_at: null
  },
  pre_checked_complete: {
    status: 'pre_checked',
    onboarding_completed_at: new Date(),
    insurance_ok_at: new Date(),
    consent_media_at: new Date()
  },
  attended: {
    status: 'attended',
    checked_in_at: new Date(),
    onboarding_completed_at: new Date()
  }
};
```

## Test Execution Order

### Sequential Dependencies
1. **Workshop Setup** → Onboarding Email Trigger
2. **Confirmed Attendees** → Onboarding Form Access
3. **Onboarding Complete** → Check-in Process
4. **Check-in Success** → Attendance Tracking

### Parallel Execution
- Multiple attendee onboarding processes
- Concurrent check-in operations
- Real-time update testing
- QR code generation for multiple workshops

## Success Criteria

### Onboarding System
- Email triggers work 2 days before workshop
- Onboarding forms accessible and functional
- Data properly recorded and validated
- Status transitions work correctly

### Check-in System
- QR codes generate and scan correctly
- Check-in process is smooth and fast
- Real-time updates work reliably
- Backup onboarding functions properly

### Data Integrity
- Attendance records accurate
- Status transitions consistent
- Timestamps recorded correctly
- No duplicate check-ins possible

## Performance Benchmarks

### Onboarding Process
- Onboarding email trigger: < 60 seconds for batch
- Form page load: < 2 seconds
- Form submission: < 3 seconds
- Status update propagation: < 1 second

### Check-in Process
- QR code scan to page load: < 3 seconds
- Attendee selection and submission: < 2 seconds
- Real-time update propagation: < 2 seconds
- Backup onboarding completion: < 5 seconds

### Scalability Targets
- Support 50 simultaneous check-ins
- Handle 200+ attendee workshops
- Process 10+ workshops per day
- Maintain sub-second response times

This comprehensive test plan ensures reliable pre-workshop onboarding and efficient workshop day check-in processes while maintaining real-time tracking capabilities.