-- Create invitation_processing_logs table to track background processing of invitations
CREATE TABLE IF NOT EXISTS public.invitation_processing_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  total_count INTEGER NOT NULL,
  success_count INTEGER NOT NULL,
  failure_count INTEGER NOT NULL,
  results JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  
  CONSTRAINT invitation_processing_logs_total_count_check CHECK (total_count = success_count + failure_count)
);

-- Add comment to the table
COMMENT ON TABLE public.invitation_processing_logs IS 'Logs for tracking background processing of bulk invitations';

-- Add RLS policies to control access to the logs
ALTER TABLE public.invitation_processing_logs ENABLE ROW LEVEL SECURITY;

-- Only allow users to see their own logs
CREATE POLICY "Users can view their own invitation processing logs"
  ON public.invitation_processing_logs
  FOR SELECT
  USING ((select auth.uid()) = user_id);

-- Only allow service role to insert logs
CREATE POLICY "Service role can insert invitation processing logs"
  ON public.invitation_processing_logs
  FOR INSERT
  WITH CHECK (
    auth.jwt() ->> 'role' IN ('service_role', 'postgres')
  );

-- Create index for faster queries
CREATE INDEX invitation_processing_logs_user_id_idx ON public.invitation_processing_logs(user_id);
CREATE INDEX invitation_processing_logs_created_at_idx ON public.invitation_processing_logs(created_at);

-- Grant permissions to authenticated users
GRANT SELECT ON public.invitation_processing_logs TO authenticated;
