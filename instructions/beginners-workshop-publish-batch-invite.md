# Beginner's Workshop – Step 3: Publish Action & Batch Inviter Function

## Overview
This document outlines the technical approach for implementing Step 3 of the Beginner's Workshop feature: the publish action and batch inviter function. This step enables admins to publish a workshop, automatically invite wait-listed members in batches, and generate secure payment links using Stripe.

---

## Requirements
- Admin can publish a draft workshop.
- On publish:
  - Workshop status changes to `published`.
  - First batch (default 16) of wait-listed users are invited.
  - Each invitee receives an email with workshop details and a unique payment link.
  - Payment links are generated using Stripe's SDK and stored in the database.
  - Payment links are valid until the day before the workshop or until the workshop is full.
  - After a "cool-off" period (default 5 days), the next batch is invited if seats remain.
  - Admin can manually add priority attendees before or after publishing.
  - If the workshop becomes full, all unused/invited links are invalidated in the app.
- Proceed with partial success if some invites fail; log errors and continue.
- For now, emails are printed to the console instead of being sent.

---

## Technical Implementation

### 1. PATCH `/api/workshops/:id/publish` Endpoint
- **Purpose:** Admin triggers this endpoint to publish a draft workshop and start the invite process.
- **Flow:**
  1. Authenticate and check admin permissions.
  2. Update the workshop's `status` to `published`.
  3. Allow for pre-populated `workshop_attendees` (e.g., priority/cancelled users) before batch invite.
  4. Trigger the `workshop_inviter` function with the workshop ID.
  5. Return updated workshop data.

### 2. Edge Function: `workshop_inviter`
- **Purpose:** Handles batch selection, attendee row creation, Stripe payment link generation, and email queueing.
- **Flow:**
  1. **Input:** `workshop_id`
  2. **Fetch Workshop:** Get `capacity`, `batch_size`, etc.
  3. **Count Current Attendees:** Count all with status in (`invited`, `confirmed`, `attended`).
  4. **Calculate Slots:** `slots = capacity - current_attendees`
  5. **Fetch Waitlist:** In priority order, excluding those already in `workshop_attendees`.
  6. **Select Batch:** Up to `batch_size` or available slots, whichever is less.
  7. **For Each Attendee:**
      - Use Stripe's SDK to generate a unique payment link (Checkout Session or Payment Link) for the workshop, using the workshop's `stripe_price_key` and attendee info in metadata.
      - Insert into `workshop_attendees` with status `invited`, store the Stripe payment link, set `priority`, and `invited_at`.
  8. **Email/Queue:** For each, print the intended email (with payment link) to the console.
  9. **Invalidate Links:** If capacity is reached, mark all other pending/invited links as expired in the database (app-level enforcement).
  10. **Partial Success:** If any step fails for a user, log error and continue with others.

### 3. Payment Link Security & Expiry
- Use Stripe's SDK to generate secure, unguessable payment links.
- Links are valid until the day before the workshop or until the workshop is full (enforced by the app).
- When full, all unused/invited links are invalidated in the app, the link themselves need to be invalidated too.

### 4. Manual Attendee Handling
- **Pre-publish:** Admin UI allows adding specific users to `workshop_attendees` before publishing (e.g., for priority/cancelled users). Emails for these pre-populated attendees should not be sent until the workshop is published.
- **Post-publish:** Admin can still add attendees manually, even if full (overriding capacity).

### 5. Error Handling & Logging
- Continue processing even if some attendee rows or emails fail; log errors.
- For now, emails are printed to the console, but code is structured for easy integration with a real email queue/sender.

### 6. RLS & Security
- Only the invited user (by `user_profile_id` and token) or admins can access the payment page.
- Only admins can publish and trigger batch invites.

---

## Summary of Implementation Tasks
- [x] Implement PATCH `/api/workshops/:id/publish` endpoint.
- [x] Implement `workshop_inviter` edge function:
  - ✅ Batch selection, attendee row creation, Stripe payment link generation.
  - ✅ Print intended emails to console.
  - ✅ Invalidate links when full (with proper exclusion of current batch).
  - ✅ Log errors, continue on partial failure.
  - ✅ Uses Stripe Payment Links API for hosted payments.
  - ✅ Comprehensive Sentry error tracking.
  - 🔄 **Email integration TBD** - currently prints to console.
- [ ] Update admin UI to allow manual attendee addition before publishing.
- [ ] Ensure RLS and security for all new endpoints and data.

---

## Notes
- Always use the workshop's `batch_size` and `cool_off_days` fields.
- Payment links are generated via Stripe's SDK for each attendee.
- Proceed with partial success; errors are logged and do not halt the batch.
- Email delivery is stubbed to console output for now. 