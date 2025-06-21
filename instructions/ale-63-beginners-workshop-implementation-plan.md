# Beginner's Workshop Feature (ALE-63) – Implementation Plan

> **Status:** Draft

---

## 1. Goal
Implement an end-to-end "Beginner's Workshop" workflow that allows administrators to schedule and manage workshops, invite wait-listed members to pay and reserve their spots, run QR-code check-in on the day, and automatically handle follow-up communications – all inside our existing SvelteKit + Supabase stack.

---

## 2. Functional Requirements (from issue)
1. Workshop has:
   - Date & place
   - One *coach* (registered user with **coach** or **committee** role)
   - Optional assistants (any member)
   - Soft-capped capacity = 16 (configurable, admins may exceed manually)
   - Attendees sourced from wait-list in oldest-first order
   - Admin can override priority / add attendees manually
   - Markdown **notes** field (what was taught)
2. Draft → Published workflow
   - While *draft*, nothing is sent.
   - When *published*:
     - Email first *batchSize* (default 16) wait-listed users.
     - Email contains workshop details + in-app payment link (Stripe Elements).
     - Links valid until day-before workshop **or** until capacity reached.
     - After *cool-off* (default 5 days) email next batch to top-up remaining seats.
3. Payment flow
   - Stripe card + alt methods.
   - Payment link page protected (email + DOB check – reuse member signup guard).
   - On successful payment attendee marked **confirmed**.
4. Capacity logic
   - Stop issuing links when full.
   - Admin can manually re-enable individual links / add attendees even if full.
5. Two days before workshop send "reminder email" with extra info + attendee-specific QR code.
6. On-site check-in via QR
   - User scans QR → secure page asks:
     1. Social media consent (boolean)
     2. Insurance form completed? (boolean)
     3. (Stretch) signature capture
   - Mark attendee **attended**.
7. Post-workshop
   - Auto follow-up email to **attended** users.

---

## 3. Technical Stack Fit & Feasibility
| Requirement | Feasible in current stack? | Notes |
| --- | --- | --- |
| Data storage | ✅ Supabase Postgres | New tables + RLS
| Batch emails | ✅ Supabase Edge Functions + `process-emails` queue | Reuse existing pattern
| Payment | ✅ Stripe integration already in app | Fixed price – store Stripe **lookup key** per workshop (configurable, default hard-coded)
| Wait-list selection | ✅ Wait-list table exists | Simple SQL ordering
| Scheduled jobs | ✅ Supabase scheduled functions (cron) | For cool-off & reminders
| QR code generation | ✅ Generate server-side using `qrcode` NPM; store as SVG/PNG in Supabase Storage | Lightweight
| Check-in page | ✅ SvelteKit route + Supabase row update | Standard
| Signature capture | ⚠️ Requires canvas component & extra storage; optional | Marked as *stretch*
|

> No show-stoppers detected. All tasks are feasible with reasonable effort.

---

## 4. Data Model (proposed)
```sql
-- workshops
id                uuid PK
status            text      -- draft | published | finished | cancelled
workshop_date     timestamptz
location          text
coach_id          uuid FK → profiles(id)
capacity          int       default 16
cool_off_days     int       default 5
batch_size        int       default 16
stripe_price_key  text      -- Stripe price (lookup key) for fixed workshop fee
notes_md          text      -- markdown
created_at        timestamptz default now()
updated_at        timestamptz default now()

-- workshop_assistants
workshop_id uuid FK → workshops(id)
member_id   uuid FK → profiles(id)
role        text  -- assistant | coach (optional convenience)

-- workshop_attendees
workshop_id      uuid FK → workshops(id)
user_profile_id  uuid FK → user_profiles(id) -- every invited person already has a profile (created by `create_profile_from_waitlist` proc)
status           text   -- invited | confirmed | attended | no_show | cancelled
priority         int    -- higher first; manual overrides < 0
invited_at       timestamptz
payment_url      text    -- unique link token
paid_at          timestamptz
checkin_token    text    -- signed JWT/hash embedded in QR
checked_in_at    timestamptz
consent_media_at timestamptz  -- null until attendee gives consent at check-in
insurance_ok_at  timestamptz  -- null until insurance form verified
signature_url    text   -- optional
refunded_at      timestamptz  -- if payment refunded/credited
credit_used_at   timestamptz  -- if credit applied to future workshop

-- email_log (generic table already exists – else create)
```
*RLS*: attendees can `select/update` only their own rows via `user_profile_id` and token; admins full access.

> **Note:** the existing stored procedure that converts a wait-list entry into an account automatically creates the corresponding `user_profiles` row, so we safely reference `user_profile_id` here. The original `waitlist_id` can always be reached through `user_profiles.waitlist_id` if needed for analytics.

---

## 5. Backend/API Tasks
1. **Kysely migrations** for new tables.
2. **Server actions**
   - POST `/api/workshops` → create draft workshop.
   - PATCH `/api/workshops/:id/publish` → mark published & enqueue first batch.
   - PATCH `/api/workshops/:id/finish` → mark finished.
3. **Edge Function `workshop_inviter`**
   - Input: `workshop_id`.
   - Logic: determine available slots, fetch wait-list (priority order), create `workshop_attendees` rows, send email using `process-emails`.
4. **Scheduled cron `workshop_topup` (daily)**
   - For each *published* workshop with date > today: if `slotsRemaining > 0` AND `lastBatchSent + cool_off_days <= today` → call `workshop_inviter`.
5. **Stripe payment session endpoint** `/api/workshop-payment/:token` (server-only)
   - Validate token, create Stripe Checkout Session, return client secret.
   - Webhook on payment_success updates attendee `status=confirmed`.
6. **Edge Function `workshop_reminder`** (cron, daily)
   - Two days pre-event, send reminder + QR to all `confirmed` attendees.
7. **Edge Function `workshop_followup`** (cron, daily)
   - Day after event, email all `attended` attendees.


### 5.1 Payment, Refunds & Credits
• Each workshop row stores `stripe_price_key` referencing a Stripe Price (fixed fee).
• On successful payment attendee marked `paid_at`.
• Refund flow: admin panel button triggers Stripe refund **and** sets `refunded_at`, optionally writes credit record (reuse existing credits table if any).

### 5.2 Permissions
• **Coach** role → read-only access to all workshop & attendee details.
• **Admin / President** roles → full CRUD.
• **Assistants** → no dashboard access, but (stretch) system can email Google-Calendar event invite when assigned.

RLS policies will reference `user_roles.role` to enforce the above.


---

## 6. Front-End (SvelteKit) Work
1. **Admin UI** (`/dashboard/beginners-workshop`)
   - List workshops, status badges.
   - Create/Edit draft form (date, place, coach, capacity, notes MD editor).
   - Publish button (with confirmation).
   - Attendees tab: table with status filters, manual add, priority drag/inputs.
2. **Public Payment Page** (`/workshop/pay/[token]`)
   - Guarded by email + DOB (reuse `authSchema.ts`).
   - Workshop summary, amount, Stripe Elements card form.
3. **Check-In Page** (`/workshop/checkin/[token]`)
   - Pull attendee row via RPC; display questions + optional signature pad.
4. **Responsive QR Code Component** for reminder email & admin view.
5. **Member Dashboard** (optional): show upcoming workshop enrolments.

---

## 7. Email Campaigns (Loops.so)
We'll leverage [Loops.so](https://loops.so) instead of self-hosted HTML templates:

| Email | Loops approach | Trigger |
| --- | --- | --- |
| Invite | **Broadcast** with variables (`workshop_date`, `location`, `payment_link`, `slots`) | Edge Function `workshop_inviter` calls Loops API `send/broadcast` for each recipient batch |
| Reminder (T-2) | **Workflow** or second broadcast containing QR code URL | Cron `workshop_reminder` |
| Follow-up | **Workflow step** after `attended` tag set | Cron `workshop_followup` |

Variables passed via the Loops API JSON payload; Loops handles HTML generation and deliverability. No local MJML templates required.

---

## 8. Step-by-Step Implementation Timeline
1. **[DONE]** DB migrations & RLS (~1 d)
2. Admin CRUD pages (draft state) (~1 d)
3. Publish action + batch inviter function (~1 d)
4. Payment flow & webhook integration (~1 d)
5. Cool-off top-up scheduler (~0.5 d)
6. Reminder email & QR generation (~0.5 d)
7. Check-in page & attendance marking (~0.5 d)
8. Follow-up email automation (~0.5 d)
9. QA & Playwright tests (~1 d)
10. Docs & seed scripts (~0.5 d)

Total ≈ **7 dev-days** (excluding buffer).

---

## 9. Stretch / Nice-to-Have
- Signature capture on check-in (requires canvas & Storage upload).
- Real-time seat counter on payment page using Supabase Realtime.
- SMS reminders (Twilio).

---

## 10. Open Questions / Clarifications Needed
1. **Workshop price & Stripe product id?**  
   (Fixed price or per-workshop configurable?)
2. **Exact email copy & assets** for invite, reminder, follow-up.
3. **Signature capture** – is it mandatory for v1?
4. **Assistants vs coach** – any permission differences besides label?
5. **Cancellation policy** – refund rules if attendee pays but later cancels?
6. **Wait-list source** – single global wait-list or per-course?
---