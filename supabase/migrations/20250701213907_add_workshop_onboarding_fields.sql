-- Add onboarding fields to workshop_attendees table
ALTER TABLE workshop_attendees 
ADD COLUMN IF NOT EXISTS onboarding_token text,
ADD COLUMN IF NOT EXISTS onboarding_completed_at timestamptz;

-- Add pre_checked status to the enum
ALTER TYPE workshop_attendee_status ADD VALUE IF NOT EXISTS 'pre_checked';

-- Add index on onboarding_token for fast lookups
CREATE INDEX IF NOT EXISTS idx_workshop_attendees_onboarding_token 
ON workshop_attendees(onboarding_token) 
WHERE onboarding_token IS NOT NULL;

-- Add RLS policy for onboarding token access
CREATE POLICY "Attendees can access via onboarding token" 
ON workshop_attendees FOR UPDATE
USING (onboarding_token IS NOT NULL AND onboarding_token = current_setting('request.headers.x-onboarding-token', true))
WITH CHECK (onboarding_token IS NOT NULL AND onboarding_token = current_setting('request.headers.x-onboarding-token', true));