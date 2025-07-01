# Beginner's Workshop Feature (ALE-63) – Implementation Plan

> **Status:** Draft

---

## 1. Goal

Implement an end-to-end "Beginner's Workshop" workflow that allows administrators to schedule and manage workshops,
invite wait-listed members to pay and reserve their spots, run QR-code check-in on the day, and automatically handle
follow-up communications – all inside our existing SvelteKit + Supabase stack.

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
5. Two days before workshop send "pre-workshop onboarding email" with link to complete requirements.
6. Pre-workshop onboarding (2-3 days before)
    - Self-serve form with attendee-specific token
    - Insurance form confirmation (required)
    - Social media consent (optional)
    - Digital signature (optional, no legal requirement)
    - Mark attendee **pre-checked** once completed
7. Workshop day self-service check-in
    - Single workshop-wide QR code displayed at entrance
    - Attendees scan → self-check-in page
    - Identify attendee (email selection or token)
    - Quick "I'm here" confirmation
    - Backup forms for any missed pre-workshop items
    - Mark attendee **attended**
8. Post-workshop
    - Auto follow-up email to **attended** users.

---

## 3. Technical Stack Fit & Feasibility

| Requirement         | Feasible in current stack?                                                      | Notes                                                                                     |
|---------------------|---------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| Data storage        | ✅ Supabase Postgres                                                             | New tables + RLS                                                                          
| Batch emails        | ✅ Supabase Edge Functions + `process-emails` queue                              | Reuse existing pattern                                                                    
| Payment             | ✅ Stripe integration already in app                                             | Fixed price – store Stripe **lookup key** per workshop (configurable, default hard-coded) 
| Wait-list selection | ✅ Wait-list table exists                                                        | Simple SQL ordering                                                                       
| Scheduled jobs      | ✅ Supabase scheduled functions (cron)                                           | For cool-off & reminders                                                                  
| QR code generation  | ✅ Generate workshop-wide QR code linking to self-check-in page                 | One QR per workshop, not per attendee                                                     |
| Check-in page       | ✅ SvelteKit route with attendee identification + self-service                   | Attendees identify themselves via email/token                                             |
| Pre-workshop forms  | ✅ SvelteKit route + attendee-specific tokens                                    | Insurance/consent collected before workshop day                                           |
| Signature capture   | ⚠️ Digital signature optional; no legal requirement                              | Marked as *optional*                                                                      |

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
workshop_id         uuid FK → workshops(id)
user_profile_id     uuid FK → user_profiles(id) -- every invited person already has a profile (created by `create_profile_from_waitlist` proc)
status              text   -- invited | confirmed | pre_checked | attended | no_show | cancelled
priority            int    -- higher first; manual overrides < 0
invited_at          timestamptz
payment_url         text    -- unique link token
paid_at             timestamptz
onboarding_token    text    -- token for pre-workshop onboarding form
onboarding_completed_at timestamptz  -- when pre-workshop form was completed
checked_in_at       timestamptz
consent_media_at    timestamptz  -- null until attendee gives consent
insurance_ok_at     timestamptz  -- null until insurance form verified
signature_url       text   -- optional digital signature
refunded_at         timestamptz  -- if payment refunded/credited
credit_used_at      timestamptz  -- if credit applied to future workshop

-- email_log (generic table already exists – else create)
```

*RLS*: attendees can `select/update` only their own rows via `user_profile_id` and token; admins full access.

> **Note:** the existing stored procedure that converts a wait-list entry into an account automatically creates the
> corresponding `user_profiles` row, so we safely reference `user_profile_id` here. The original `waitlist_id` can always
> be reached through `user_profiles.waitlist_id` if needed for analytics.

---

## 5. Backend/API Tasks

1. **Kysely migrations** for new tables.
2. **Server actions**
    - POST `/api/workshops` → create draft workshop.
    - PATCH `/api/workshops/:id/publish` → mark published & enqueue first batch.
    - PATCH `/api/workshops/:id/finish` → mark finished.
3. **Edge Function `workshop_inviter`**
    - Input: `workshop_id`.
    - Logic: determine available slots, fetch wait-list (priority order), create `workshop_attendees` rows, send email
      using `process-emails`.
4. **Scheduled cron `workshop_topup` (daily)**
    - For each *published* workshop with date > today: if `slotsRemaining > 0` AND
      `lastBatchSent + cool_off_days <= today` → call `workshop_inviter`.
5. **Stripe payment session endpoint** (we are using stripe payment links with Stripe self-hosted UI)
    - Webhook on payment_success updates attendee `status=confirmed`.
6. **Edge Function `workshop_onboarding`** (cron, daily)
    - Two days pre-event, send onboarding email with pre-workshop form link to all `confirmed` attendees.
7. **Workshop-wide QR code generation**
    - Generate single QR code per workshop linking to `/workshop/checkin/[workshop_id]`
    - Display QR at workshop entrance for attendee self-check-in
8. **Edge Function `workshop_followup`** (cron, daily)
    - Day after event, email all `attended` attendees.

### 5.1 Payment, Refunds & Credits

• Each workshop row stores `stripe_price_key` referencing a Stripe Price (fixed fee).
• On successful payment attendee marked `paid_at`.
• Refund flow: admin panel button triggers Stripe refund **and** sets `refunded_at`, optionally writes credit record (
reuse existing credits table if any).

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
3. **Pre-Workshop Onboarding Page** (`/workshop/onboarding/[token]`)
    - Attendee-specific form for insurance confirmation, consent, optional signature
    - Updates attendee status to `pre_checked` when completed
4. **Workshop Check-In Page** (`/workshop/checkin/[workshop_id]`)
    - Self-service check-in via workshop-wide QR code
    - Attendee identification (email selection from confirmed list)
    - Quick "I'm here" confirmation + backup forms for missed onboarding
5. **Admin Real-Time Attendance Dashboard**
    - Live view of who has checked in during workshop
    - Status overview: invited → confirmed → pre_checked → attended
6. **Responsive QR Code Component** for onboarding emails & admin view.
7. **Member Dashboard** (optional): show upcoming workshop enrolments.

---

## 7. Email Campaigns (Loops.so)

We'll leverage [Loops.so](https://loops.so) instead of self-hosted HTML templates:

| Email                | Loops approach                                                                      | Trigger                                                                                    |
|----------------------|-------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| Invite               | **Broadcast** with variables (`workshop_date`, `location`, `payment_link`, `slots`) | Edge Function `workshop_inviter` calls Loops API `send/broadcast` for each recipient batch |
| Pre-workshop onboarding (T-2) | **Broadcast** with onboarding form link and workshop QR code                   | Cron `workshop_onboarding`                                                                 |
| Follow-up            | **Workflow step** after `attended` tag set                                          | Cron `workshop_followup`                                                                   |

Variables passed via the Loops API JSON payload; Loops handles HTML generation and deliverability. No local MJML
templates required.

---

## 8. Step-by-Step Implementation Timeline

1. **[DONE]** DB migrations & RLS (~1 d)
2. **[DONE]** Admin CRUD pages (draft state) (~1 d)
3. **[DONE]** Publish action + batch inviter function (~1 d)
4. **[DONE]** Payment flow & webhook integration (~1 d)
5. **[DONE]** Cool-off top-up scheduler (~0.5 d)
6. Pre-workshop onboarding email & forms (~0.5 d)
7. Workshop QR generation & check-in page (~0.5 d)
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
