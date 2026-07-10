# Stripe owns Membership state; DHC owns Member profile facts

Status: accepted

For Membership subscription state, Stripe is the source of truth. Pause/resume commands call Stripe first and only write `subscription_paused_until` after Stripe confirms; the Stripe webhook remains an idempotent re-sync path and the sole writer of the `user_profiles.is_active` projection. This preserves existing behavior without adding an admin-controlled active flag.

For Member profile facts, DHC is the source of truth. `PATCH /members/{memberId}` saves profile changes even if the best-effort Stripe customer echo (`customers.update` for name/phone) fails; failures are logged and reconciled later by the periodic Stripe sync path.
