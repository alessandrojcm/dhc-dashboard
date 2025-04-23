-- Create notifications table for realtime functionality
CREATE TABLE IF NOT EXISTS public.notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL,
  body TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  read_at TIMESTAMPTZ
);

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS notifications_user_id_idx ON public.notifications(user_id);
CREATE INDEX IF NOT EXISTS notifications_created_at_idx ON public.notifications(created_at);

-- Add RLS policies for notifications
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

-- Policy to allow users to view only their notifications
CREATE POLICY "Users can view their own notifications" 
  ON public.notifications
  FOR SELECT 
  USING ((SELECT auth.uid()) = user_id);

-- Policy to allow system to insert notifications for any user
CREATE POLICY "System can insert notifications" 
  ON public.notifications
  FOR INSERT 
  WITH CHECK (true);

-- Policy to allow users to mark their notifications as read
CREATE POLICY "Users can update their own notifications" 
  ON public.notifications
  FOR UPDATE 
  USING ((SELECT auth.uid()) = user_id)
  WITH CHECK ((SELECT auth.uid()) = user_id);

-- Create function to mark notification as read
CREATE OR REPLACE FUNCTION public.mark_notification_as_read(notification_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE public.notifications
  SET read_at = now()
  WHERE id = notification_id AND user_id = (SELECT auth.uid());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Enable realtime for notifications table
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
