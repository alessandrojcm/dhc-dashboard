# Workshop Testing Phase 1: Core Management

> **Status:** Draft  
> **Updated:** 2025-07-04  
> **Scope:** Workshop creation, editing, and basic administration testing

## Overview

Phase 1 focuses on testing the core workshop management functionality, including CRUD operations, state transitions, and administrative features. This phase covers both API endpoints and UI interactions for workshop management.

## Test Scenarios

### 1. Workshop CRUD Operations

#### 1.1 Workshop Creation
**API Tests** (`/api/workshops POST`):
```typescript
// Test cases:
- Create workshop with valid data
- Create workshop with missing required fields
- Create workshop with invalid coach_id
- Create workshop with future date
- Create workshop with past date (should fail)
- Create workshop with invalid capacity
- Create workshop with duplicate location/date
- Create workshop with long markdown notes
- Create workshop without authentication
- Create workshop with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop`):
```typescript
// Test cases:
- Navigate to workshop creation page
- Fill out workshop form with valid data
- Submit form and verify success message
- Verify workshop appears in workshop list
- Test form validation for required fields
- Test date picker functionality
- Test coach selection dropdown
- Test capacity input validation
- Test markdown editor for notes
- Test form cancellation
- Test form submission with network error
```

#### 1.2 Workshop Reading/Listing
**API Tests** (`/api/workshops GET`):
```typescript
// Test cases:
- Fetch all workshops as admin
- Fetch workshops as coach (should see own workshops)
- Fetch workshops as member (should see limited data)
- Fetch workshops with pagination
- Fetch workshops with filtering by status
- Fetch workshops with sorting
- Fetch single workshop by ID
- Fetch non-existent workshop (404)
- Fetch workshop without authentication
```

**UI Tests** (`/dashboard/beginners-workshop`):
```typescript
// Test cases:
- Load workshop dashboard
- Verify workshop list displays correctly
- Test workshop filtering by status
- Test workshop sorting by date
- Test workshop search functionality
- Test pagination controls
- Click workshop to view details
- Test workshop status badges
- Test responsive design
- Test empty state when no workshops
```

#### 1.3 Workshop Updates
**API Tests** (`/api/workshops/[id] PATCH`):
```typescript
// Test cases:
- Update workshop details as admin
- Update workshop as coach (limited fields)
- Update workshop capacity
- Update workshop location
- Update workshop notes
- Update workshop date (future only)
- Update non-existent workshop (404)
- Update workshop with invalid data
- Update workshop without authentication
- Update workshop with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]/edit`):
```typescript
// Test cases:
- Navigate to workshop edit page
- Load existing workshop data in form
- Update workshop details
- Save changes and verify update
- Test form validation on update
- Test permission-based field restrictions
- Test update with network error
- Test cancel edit functionality
- Test unsaved changes warning
```

#### 1.4 Workshop Deletion
**API Tests** (`/api/workshops/[id] DELETE`):
```typescript
// Test cases:
- Delete draft workshop as admin
- Delete workshop with attendees (should fail)
- Delete published workshop (should fail)
- Delete non-existent workshop (404)
- Delete workshop without authentication
- Delete workshop with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]`):
```typescript
// Test cases:
- Show delete button for eligible workshops
- Hide delete button for ineligible workshops
- Test delete confirmation modal
- Execute delete and verify removal
- Test delete cancellation
- Test delete with network error
```

### 2. Workshop State Management

#### 2.1 Status Transitions
**API Tests** (`/api/workshops/[id]/publish`, `/api/workshops/[id]/finish`, `/api/workshops/[id]/cancel`):
```typescript
// Test cases:
- Publish draft workshop
- Finish published workshop
- Cancel workshop (any state)
- Invalid state transitions
- Publish workshop without attendees
- Finish workshop with pending attendees
- State transition without authentication
- State transition with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]`):
```typescript
// Test cases:
- Display current workshop status
- Show appropriate action buttons for each state
- Test publish confirmation modal
- Test finish confirmation modal
- Test cancel confirmation modal
- Execute state changes and verify UI updates
- Test state change with network error
- Test permission-based button visibility
```

#### 2.2 Workshop Lifecycle
**Integration Tests**:
```typescript
// Test cases:
- Complete workshop lifecycle (draft → published → finished)
- Workshop with attendees lifecycle
- Workshop cancellation at different stages
- Workshop state persistence across sessions
- Workshop state validation rules
```

### 3. Coach and Assistant Management

#### 3.1 Coach Assignment
**API Tests** (`/api/workshops/[id]/coach`):
```typescript
// Test cases:
- Assign coach to workshop
- Reassign coach to workshop
- Assign non-existent coach (404)
- Assign user without coach role (403)
- Remove coach from workshop
- Assign coach without authentication
- Assign coach with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]/edit`):
```typescript
// Test cases:
- Load coach selection dropdown
- Select coach from dropdown
- Verify coach assignment
- Test coach search functionality
- Test coach removal
- Test coach assignment with network error
- Test permission-based coach management
```

#### 3.2 Assistant Management
**API Tests** (`/api/workshops/[id]/assistants`):
```typescript
// Test cases:
- Add assistant to workshop
- Remove assistant from workshop
- Add multiple assistants
- Add non-existent assistant (404)
- Add duplicate assistant (should handle gracefully)
- Assistant operations without authentication
- Assistant operations with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]/assistants`):
```typescript
// Test cases:
- View assistant list
- Add assistant via search/dropdown
- Remove assistant
- Test assistant search functionality
- Test assistant list pagination
- Test assistant management with network error
- Test permission-based assistant management
```

### 4. Capacity and Attendee Management

#### 4.1 Capacity Configuration
**API Tests** (`/api/workshops/[id]/capacity`):
```typescript
// Test cases:
- Set workshop capacity
- Update workshop capacity
- Set capacity below current attendee count (should fail)
- Set invalid capacity (negative, zero, too high)
- Capacity changes without authentication
- Capacity changes with insufficient permissions
```

**UI Tests** (`/dashboard/beginners-workshop/[id]/settings`):
```typescript
// Test cases:
- Display current capacity
- Update capacity via form
- Test capacity validation
- Test capacity update with existing attendees
- Test capacity update with network error
- Test permission-based capacity management
```

#### 4.2 Attendee Overview
**UI Tests** (`/dashboard/beginners-workshop/[id]/attendees`):
```typescript
// Test cases:
- Display attendee list
- Show attendee status badges
- Test attendee filtering by status
- Test attendee sorting
- Test attendee search
- Test attendee pagination
- Test real-time attendee updates
- Test attendee management permissions
```

### 5. Workshop Scheduling and Validation

#### 5.1 Date and Time Validation
**API Tests**:
```typescript
// Test cases:
- Create workshop with future date
- Create workshop with past date (should fail)
- Create workshop with same date/location (conflict check)
- Update workshop date to past (should fail)
- Update workshop date to future
- Date validation with different timezones
```

**UI Tests**:
```typescript
// Test cases:
- Test date picker functionality
- Test date validation in form
- Test time picker functionality
- Test timezone handling
- Test date conflict warnings
- Test date formatting
```

#### 5.2 Location Management
**API Tests**:
```typescript
// Test cases:
- Create workshop with valid location
- Create workshop with empty location (should fail)
- Create workshop with long location name
- Update workshop location
- Location validation rules
```

**UI Tests**:
```typescript
// Test cases:
- Test location input field
- Test location validation
- Test location autocomplete (if implemented)
- Test location update functionality
```

### 6. Permissions and Access Control

#### 6.1 Role-Based Access
**API Tests**:
```typescript
// Test cases:
- Admin access to all workshop operations
- Coach access to own workshops only
- Member access restrictions
- Anonymous user access (should fail)
- Role verification for each endpoint
```

**UI Tests**:
```typescript
// Test cases:
- Admin dashboard access
- Coach dashboard access (limited)
- Member dashboard access (read-only)
- Anonymous user redirects
- Permission-based button visibility
- Permission-based page access
```

#### 6.2 Data Access Control
**Integration Tests**:
```typescript
// Test cases:
- Workshop data visibility by role
- Attendee data access restrictions
- Coach can only see assigned workshops
- Member can only see workshops they're attending
- RLS policy enforcement
```

### 7. Error Handling and Edge Cases

#### 7.1 Network Error Handling
**UI Tests**:
```typescript
// Test cases:
- Workshop creation with network failure
- Workshop update with network failure
- Workshop deletion with network failure
- Status change with network failure
- Form submission retry mechanisms
- Error message display
```

#### 7.2 Data Validation
**API Tests**:
```typescript
// Test cases:
- Invalid UUID formats
- Invalid JSON payloads
- Missing required fields
- Field length validation
- Data type validation
- SQL injection attempts
```

#### 7.3 Concurrent Operations
**Integration Tests**:
```typescript
// Test cases:
- Multiple users editing same workshop
- Concurrent status changes
- Concurrent attendee additions
- Race condition handling
- Optimistic locking
```

## Test Data Setup

### Workshop Templates
```typescript
const workshopTemplates = {
  basic: {
    workshop_date: '2025-08-15T10:00:00Z',
    location: 'Main Training Hall',
    capacity: 16,
    notes_md: 'Basic longsword techniques for beginners'
  },
  advanced: {
    workshop_date: '2025-08-22T14:00:00Z',
    location: 'Secondary Training Room',
    capacity: 12,
    notes_md: '## Advanced Topics\n- Complex binds\n- Advanced footwork'
  },
  weekend: {
    workshop_date: '2025-08-16T09:00:00Z',
    location: 'Outdoor Training Area',
    capacity: 20,
    notes_md: 'Weekend intensive workshop'
  }
};
```

### User Roles
```typescript
const testUsers = {
  admin: { roles: ['admin'], permissions: 'full' },
  coach: { roles: ['coach'], permissions: 'limited' },
  member: { roles: ['member'], permissions: 'read-only' },
  anonymous: { roles: [], permissions: 'none' }
};
```

## Test Execution Order

### Sequential Dependencies
1. **Workshop Creation** → Workshop Update/Delete tests
2. **Coach Assignment** → Coach-related permissions tests
3. **Workshop Publishing** → Status transition tests
4. **Attendee Addition** → Capacity management tests

### Parallel Execution
- API and UI tests can run in parallel
- Different user role tests can run simultaneously
- Independent workshop scenarios can run concurrently

## Success Criteria

### API Tests
- All endpoints return correct status codes
- Response data matches expected schemas
- Error handling works as specified
- Authentication and authorization enforced

### UI Tests
- All pages load correctly
- Forms work with validation
- State changes reflect in UI
- Error messages display appropriately
- Responsive design works

### Integration Tests
- Complete workflows function end-to-end
- Data consistency maintained
- Performance meets benchmarks
- Security controls effective

## Maintenance Notes

### Test Data Cleanup
- Each test creates and cleans up its own data
- Workshop deletion cascades to related records
- User cleanup includes auth and profile deletion

### Test Environment
- Local Supabase instance required
- Admin service role key needed
- Test database reset between runs
- Stripe test mode configuration

This comprehensive test plan ensures thorough coverage of the core workshop management functionality while maintaining test reliability and performance.