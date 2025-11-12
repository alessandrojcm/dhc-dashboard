# Simplified Communication System Implementation Plan

## Overview

Streamlined workshop announcement system with Discord and email notifications for workshop status changes.

## Requirements Summary

### 1. Frontend Changes (Workshop Creation Only)

- Add two toggle switches to workshop creation form:
  - "Announce in Discord"
  - "Announce via Email"
- Explanatory text: "All workshop status changes will be announced through selected channels"
- These switches only appear during creation, not editing

### 2. Database Schema Changes

- Add `announce_discord` and `announce_email` boolean fields to workshops table
- Create `workshop_announcement` queue using pgmq
- Create `discord_queue` using pgmq (similar to existing `email_queue`)

### 3. Announcement Triggers

**Workshop Creation**: Add to `workshop_announcement` queue when created

**Workshop Updates**: Only trigger announcements for:

- Time changes
- Location changes
- Status changes (draft → published, published → cancelled, etc.)

### 4. Message Templates

**Planned Status**:
"Hey all! We are planning a {workshop_name} workshop on {date} at {location}. Please head to 'My Workshops' to express your interest!"

**Published Status**:
"{workshop_name} is happening on {date} at {location}. Head to 'My Workshops' to register!"

**Cancelled Status**:
"{workshop_name} scheduled for {date} has been cancelled."

### 5. Queue Processing System

**Daily Cron Job** (runs at noon):

- Process all items in `workshop_announcement` queue
- Batch announcements by type (email/discord)
- Route to appropriate queues (`email_queue` or `discord_queue`)
- Recipients: All users from `user_profile` where `is_active = true`

### 6. Discord Integration

- Create Discord edge function using Discord SDK
- Similar structure to `process-emails` function
- Handle Discord webhook/bot message sending
- Retry failed messages (put back in queue for next day)

### 7. Technical Architecture

- Follow existing pgmq patterns from `process-emails`
- Use `executeWithRLS()` for all database mutations
- Implement proper error handling with Sentry
- Use existing role-based security patterns

## Implementation Tasks

### High Priority

1. Analyze existing workshop creation form and database schema
2. Add announcement switches to workshop creation form UI
3. Create database migration for announcement fields and queues
4. Update workshop creation API to handle announcement flags

### Medium Priority

5. Create workshop_announcement queue processing logic
6. Create discord_queue processing infrastructure
7. Implement daily cron job for batch announcement processing
8. Add announcement triggers to workshop update operations
9. Create Discord SDK integration for sending messages
10. Implement message templates for different workshop statuses

### Low Priority

11. Add retry mechanism for failed announcements
12. Write comprehensive tests for announcement system

## Technical Specifications

### Database Fields

- `workshops.announce_discord: boolean`
- `workshops.announce_email: boolean`

### Queue Structure

- `workshop_announcement` queue: Contains workshop IDs to be processed
- `discord_queue`: Contains Discord messages to be sent
- `email_queue`: Existing queue for email messages

### Recipients

- Target: All users from `user_profile` table where `is_active = true`

### Retry Logic

- Failed announcements go back to queue for retry next day
- Use existing pgmq retry patterns

### Security

- Follow existing role-based access patterns
- Use `executeWithRLS()` for all mutations
- Implement proper input validation with Valibot schemas

## Success Criteria

- Workshop creation form includes announcement toggles
- Announcements triggered only for time, location, and status changes
- Daily batch processing of announcements at noon
- Discord and email messages sent to all active members
- Failed messages retry next day
- System follows existing codebase patterns and security practices
