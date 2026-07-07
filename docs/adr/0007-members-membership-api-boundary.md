# Members and Membership share storage but expose separate API boundaries

Status: accepted

The Members/Membership Phoenix migration keeps the existing `user_profiles` and `member_profiles` storage shape, but exposes separate domain boundaries in the API and context modules: `Dhc.Members` owns profile facts and member reads, while `Dhc.Membership` owns subscription/access state and Stripe-facing pause/resume commands. This avoids a disruptive schema split while still giving follow-up implementation issues stable endpoint shapes: flat Member DTOs for reads/mutations, `PATCH /members/{memberId}` for profile facts, and `POST /members/{memberId}/membership/pause|resume` for membership commands.

Member write authorization is self-or-broad-committee: a user may update/read/pause/resume their own member record, while the broad `:members_admin_api` committee role set may act on any member. Cross-cutting enum options move behind public `GET /options`, sourced from Postgres enum labels at runtime, so SvelteKit no longer depends on Supabase `database.types.ts` for form options.
