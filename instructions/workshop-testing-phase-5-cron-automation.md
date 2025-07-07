# Workshop Testing Phase 5: Cron Jobs & Automation

> **Status:** Draft  
> **Updated:** 2025-07-04  
> **Scope:** Scheduled tasks, automated processes, and time-based workshop operations testing

## Overview

Phase 5 focuses on testing all automated and scheduled processes in the workshop system. This includes cron jobs for invitations, onboarding, follow-ups, priority management, and other time-based operations. Special attention is given to time manipulation testing and system reliability.

## Test Scenarios

### 1. Workshop Invitation Automation

#### 1.1 Initial Invitation Trigger (Workshop Publish)
**Edge Function Tests** (`workshop_inviter`):
```typescript
// Test cases:
- Trigger invitations immediately on workshop publish
- Process first batch based on batch_size
- Select waitlist users in correct priority order
- Create attendee records with 'invited' status
- Generate unique payment tokens
- Queue invitation emails properly
- Handle empty waitlist gracefully
- Process multiple workshops published simultaneously
- Handle invitation failures and retries
- Verify invitation count tracking
```

**Time-based Integration Tests**:
```typescript
// Test cases:
- Publish workshop and verify immediate invitation
- Check invitation processing within 30 seconds
- Verify email queue entries created
- Confirm attendee records with correct timestamps
- Test invitation during high system load
- Handle workshop publish at edge times (midnight, etc.)
```

#### 1.2 Cool-off Period Top-up Invitations
**Cron Function Tests** (`workshop_topup` - Daily):
```typescript
// Test cases:
- Execute daily at scheduled time (e.g., 9 AM)
- Process workshops needing top-up invitations
- Respect cool_off_days configuration
- Calculate remaining capacity correctly
- Select next batch from waitlist
- Skip workshops at full capacity
- Handle workshops with no remaining waitlist
- Process multiple workshops in single run
- Track last_batch_sent timestamps
- Handle cron execution failures
```

**Time Manipulation Tests**:
```typescript
// Test cases:
- Mock time to test cool-off period logic
- Advance time by cool_off_days and verify trigger
- Test edge cases around daylight saving time
- Verify timezone handling accuracy
- Test cron execution across month boundaries
- Handle leap year edge cases
- Test rapid time advancement scenarios
```

### 2. Pre-workshop Onboarding Automation

#### 2.1 Onboarding Email Trigger (T-2 Days)
**Cron Function Tests** (`workshop_onboarding` - Daily):
```typescript
// Test cases:
- Execute daily and find workshops 2 days away
- Process confirmed attendees without onboarding
- Generate onboarding tokens for attendees
- Queue onboarding emails with correct content
- Skip attendees who already completed onboarding
- Handle multiple workshops on same date
- Process workshops across different timezones
- Handle attendee status changes during processing
- Track onboarding email send status
- Handle email service failures gracefully
```

**Date Calculation Tests**:
```typescript
// Test cases:
- Verify "2 days before" calculation accuracy
- Handle workshop date changes after email sent
- Test weekend vs. weekday workshop scheduling
- Handle timezone differences correctly
- Test date boundaries (month-end, year-end)
- Verify inclusive vs. exclusive date ranges
```

#### 2.2 Onboarding Reminder System
**Cron Function Tests** (`onboarding_reminder` - Daily):
```typescript
// Test cases:
- Send reminders to attendees 1 day before workshop
- Only remind attendees who haven't completed onboarding
- Track reminder send status
- Avoid duplicate reminders
- Handle workshop date changes
- Process urgent onboarding cases
- Skip attended or cancelled attendees
- Handle email rate limiting
```

### 3. Post-workshop Follow-up Automation

#### 3.1 Follow-up Email Trigger (T+1 Day)
**Cron Function Tests** (`workshop_followup` - Daily):
```typescript
// Test cases:
- Execute daily for workshops that finished yesterday
- Process only 'attended' attendees
- Skip no-show and cancelled attendees
- Queue follow-up emails with workshop feedback forms
- Handle workshops with no attendees
- Process multiple finished workshops
- Track follow-up email delivery
- Handle delayed workshop completion updates
- Avoid duplicate follow-up emails
```

**Workshop Completion Detection**:
```typescript
// Test cases:
- Detect workshops that finished yesterday
- Handle manually marked finished workshops
- Process workshops that auto-finished
- Handle timezone differences in completion detection
- Verify workshop status transitions
- Handle edge cases around workshop timing
```

### 4. Priority Management Automation

#### 4.1 Priority Expiration Processing
**Cron Function Tests** (`priority_expiration` - Daily):
```typescript
// Test cases:
- Reset priority levels after next workshop completion
- Update admin notes with expiration information
- Process multiple priority expirations in batch
- Handle attendees who attended next workshop
- Skip attendees who cancelled next workshop
- Process complex priority scenarios
- Maintain priority audit trail
- Handle workshop completion delays
```

**Priority Logic Tests**:
```typescript
// Test cases:
- Verify priority expires only after "next" workshop
- Handle attendees with multiple workshop priorities
- Process priority transfers correctly
- Maintain priority history for auditing
- Handle manual priority overrides
- Test priority inheritance rules
```

#### 4.2 Credit Expiration Management
**Cron Function Tests** (`credit_expiration` - Weekly):
```typescript
// Test cases:
- Expire unused credits after set period
- Notify users before credit expiration
- Handle partial credit usage
- Transfer expired credits to charity/club funds
- Update credit status in database
- Generate credit expiration reports
- Handle credit disputes and extensions
```

### 5. System Maintenance Automation

#### 5.1 Data Cleanup Processes
**Cron Function Tests** (`system_cleanup` - Weekly):
```typescript
// Test cases:
- Clean up expired payment tokens
- Remove old onboarding tokens
- Archive completed workshops
- Purge old email queue entries
- Clean up temporary files
- Update database statistics
- Optimize database performance
- Handle cleanup failures gracefully
```

**Database Maintenance Tests**:
```typescript
// Test cases:
- Vacuum and analyze database tables
- Update index statistics
- Clean up orphaned records
- Compress old log entries
- Archive historical data
- Monitor database growth
- Handle long-running cleanup operations
```

#### 5.2 Health Check and Monitoring
**Cron Function Tests** (`health_check` - Hourly):
```typescript
// Test cases:
- Monitor system health metrics
- Check database connectivity
- Verify Stripe API connectivity
- Test email service availability
- Monitor cron job execution status
- Alert on system anomalies
- Generate health reports
- Handle monitoring service failures
```

### 6. Time-based Business Logic

#### 6.1 Workshop Status Automation
**Cron Function Tests** (`workshop_status_update` - Hourly):
```typescript
// Test cases:
- Auto-finish workshops after end time
- Mark workshops as 'in_progress' at start time
- Handle workshop date/time changes
- Process timezone conversions
- Update workshop status across multiple timezones
- Handle daylight saving time transitions
- Process bulk status updates efficiently
```

#### 6.2 Payment Link Expiration
**Cron Function Tests** (`payment_expiration` - Hourly):
```typescript
// Test cases:
- Expire payment links day before workshop
- Handle payment in progress at expiration
- Update attendee status for expired payments
- Free up capacity from expired invitations
- Trigger waitlist top-up after expiration
- Handle manual payment link extensions
- Process batch payment expirations
```

### 7. Error Handling & Recovery

#### 7.1 Cron Job Failure Recovery
**Error Handling Tests**:
```typescript
// Test cases:
- Handle database connection failures
- Recover from email service outages
- Process failed cron job retries
- Handle partial batch processing failures
- Manage transaction rollbacks
- Alert administrators on critical failures
- Implement exponential backoff for retries
- Handle cron job timeouts
```

#### 7.2 Data Consistency After Failures
**Recovery Tests**:
```typescript
// Test cases:
- Verify data consistency after cron failures
- Handle duplicate cron job executions
- Recover from incomplete operations
- Validate data integrity after recovery
- Handle cascading failure scenarios
- Test disaster recovery procedures
- Verify backup and restore operations
```

### 8. Performance & Scalability Testing

#### 8.1 High Volume Processing
**Load Tests**:
```typescript
// Test cases:
- Process 100+ workshops in single cron run
- Handle 1000+ attendees across multiple workshops
- Test email queue with high volume
- Process large waitlist selections
- Handle concurrent cron job executions
- Test database performance under load
- Monitor memory usage during bulk operations
```

#### 8.2 Cron Job Scheduling Conflicts
**Concurrency Tests**:
```typescript
// Test cases:
- Handle overlapping cron job executions
- Prevent duplicate processing with locks
- Test cron job queue management
- Handle priority-based job scheduling
- Test resource contention scenarios
- Verify cron job isolation
- Handle system resource limitations
```

### 9. Monitoring & Alerting

#### 9.1 Cron Job Monitoring
**Monitoring Tests**:
```typescript
// Test cases:
- Track cron job execution times
- Monitor success/failure rates
- Alert on missed cron executions
- Track processing volumes
- Monitor system resource usage
- Generate cron job performance reports
- Set up automated alerting thresholds
```

#### 9.2 Business Metric Monitoring
**Analytics Tests**:
```typescript
// Test cases:
- Track workshop invitation rates
- Monitor payment conversion rates
- Analyze onboarding completion rates
- Track follow-up email engagement
- Monitor system availability metrics
- Generate automated business reports
- Alert on unusual patterns or anomalies
```

## Test Data Setup

### Time-based Test Scenarios
```typescript
const timeScenarios = {
  workshop_publish_immediate: {
    workshop_date: new Date(Date.now() + 14 * 86400000), // 2 weeks away
    status: 'draft',
    waitlist_count: 25
  },
  cool_off_ready: {
    workshop_date: new Date(Date.now() + 7 * 86400000), // 1 week away
    status: 'published',
    last_batch_sent: new Date(Date.now() - 6 * 86400000), // 6 days ago
    cool_off_days: 5,
    current_attendees: 8,
    capacity: 16
  },
  onboarding_trigger: {
    workshop_date: new Date(Date.now() + 2 * 86400000), // 2 days away
    confirmed_attendees: 12,
    onboarding_completed: 3
  },
  follow_up_ready: {
    workshop_date: new Date(Date.now() - 1 * 86400000), // Yesterday
    status: 'finished',
    attended_count: 14
  }
};
```

### Cron Schedule Configuration
```typescript
const cronSchedules = {
  workshop_topup: '0 9 * * *', // Daily at 9 AM
  workshop_onboarding: '0 8 * * *', // Daily at 8 AM
  workshop_followup: '0 10 * * *', // Daily at 10 AM
  priority_expiration: '0 2 * * *', // Daily at 2 AM
  credit_expiration: '0 3 * * 0', // Weekly on Sunday at 3 AM
  system_cleanup: '0 1 * * 0', // Weekly on Sunday at 1 AM
  health_check: '0 * * * *' // Hourly
};
```

### Mock Time Utilities
```typescript
const timeUtils = {
  mockCurrentTime: (date: Date) => {
    // Mock current time for testing
  },
  advanceTime: (days: number, hours: number = 0) => {
    // Advance mocked time
  },
  resetTime: () => {
    // Reset to actual current time
  },
  timezoneTesting: {
    utc: 'UTC',
    dublin: 'Europe/Dublin',
    newYork: 'America/New_York'
  }
};
```

## Test Execution Strategy

### Time Manipulation Approach
1. **Mock Time Framework**: Use controlled time advancement
2. **Isolated Testing**: Each test gets clean time state
3. **Timezone Testing**: Test across multiple timezones
4. **Edge Case Testing**: Test boundary conditions
5. **Performance Testing**: Measure execution times

### Cron Job Testing
1. **Direct Function Testing**: Test cron functions directly
2. **Schedule Testing**: Test actual cron scheduling
3. **Integration Testing**: Test with real time delays
4. **Recovery Testing**: Test failure and recovery scenarios

## Success Criteria

### Automation Reliability
- All cron jobs execute at scheduled times
- Error rates below 1% for all automated processes
- Recovery mechanisms function correctly
- No data corruption from automated processes

### Performance Standards
- Invitation processing: < 2 minutes for 100 attendees
- Onboarding triggers: < 1 minute for 50 workshops
- Follow-up processing: < 30 seconds for 200 attendees
- Priority updates: < 5 seconds for 500 users

### Monitoring & Alerting
- All cron jobs have monitoring coverage
- Alert thresholds set appropriately
- Business metrics tracked accurately
- System health monitored continuously

This comprehensive test plan ensures reliable automated processes while maintaining system performance and business logic integrity across all time-based operations.