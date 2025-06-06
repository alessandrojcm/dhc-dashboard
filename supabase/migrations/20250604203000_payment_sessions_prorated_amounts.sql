-- Add prorated amount columns to payment_sessions table
ALTER TABLE public.payment_sessions
  ADD COLUMN IF NOT EXISTS prorated_monthly_amount INTEGER,
  ADD COLUMN IF NOT EXISTS prorated_annual_amount INTEGER;
