-- 1.1 Add new columns (safe, additive)
ALTER TABLE public.payment_sessions
  ADD COLUMN IF NOT EXISTS preview_monthly_amount INTEGER,
  ADD COLUMN IF NOT EXISTS preview_annual_amount INTEGER,
  ADD COLUMN IF NOT EXISTS discounted_monthly_amount INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discounted_annual_amount INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS discount_percentage INTEGER;

-- 1.2 Relax NOT-NULL on subscription / payment-intent columns
ALTER TABLE public.payment_sessions
  ALTER COLUMN monthly_subscription_id DROP NOT NULL,
  ALTER COLUMN annual_subscription_id DROP NOT NULL,
  ALTER COLUMN monthly_payment_intent_id DROP NOT NULL,
  ALTER COLUMN annual_payment_intent_id DROP NOT NULL,
  ALTER COLUMN monthly_amount DROP NOT NULL,
  ALTER COLUMN annual_amount DROP NOT NULL
  ALTER COLUMN total_amount DROP NOT NULL;