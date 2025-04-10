-- Create payment_sessions table
CREATE TABLE IF NOT EXISTS public.payment_sessions (
  id SERIAL PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES public.user_profiles(supabase_user_id),
  monthly_subscription_id TEXT NOT NULL,
  annual_subscription_id TEXT NOT NULL,
  monthly_payment_intent_id TEXT NOT NULL,
  annual_payment_intent_id TEXT NOT NULL,
  monthly_amount INTEGER NOT NULL,
  annual_amount INTEGER NOT NULL,
  total_amount FLOAT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  is_used BOOLEAN NOT NULL DEFAULT FALSE
);

-- Add index for faster lookups
CREATE INDEX idx_payment_sessions_user_id ON public.payment_sessions(user_id);

-- Enable RLS but don't create policies as we're only using service roles
ALTER TABLE public.payment_sessions ENABLE ROW LEVEL SECURITY;
