-- Add discounted amount fields to payment_sessions table
ALTER TABLE public.payment_sessions
ADD COLUMN discounted_monthly_amount INTEGER,
ADD COLUMN discounted_annual_amount INTEGER,
ADD COLUMN discount_percentage INTEGER;
