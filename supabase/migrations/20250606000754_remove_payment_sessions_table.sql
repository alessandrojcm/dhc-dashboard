-- Migration to remove payment_sessions table
-- This migration removes the payment_sessions table and related infrastructure
-- since pricing is now calculated fresh from Stripe each time

-- Step 1: Remove the cron job first
SELECT cron.unschedule('cleanup-payment-sessions');

-- Step 2: Drop the cleanup function
DROP FUNCTION IF EXISTS public.cleanup_payment_sessions();

-- Step 3: Check if there are any important records we need to preserve
-- For production safety, let's log any active sessions before deletion
DO $$
DECLARE
    active_sessions_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO active_sessions_count 
    FROM public.payment_sessions 
    WHERE is_used = false AND expires_at > NOW();
    
    IF active_sessions_count > 0 THEN
        RAISE NOTICE 'Found % active payment sessions that will be deleted', active_sessions_count;
        
        -- Log the active sessions for reference
        INSERT INTO public.user_audit_log (user_id, action, details, created_at)
        SELECT 
            user_id,
            'payment_sessions_cleanup',
            jsonb_build_object(
                'coupon_id', coupon_id,
                'expires_at', expires_at,
                'original_created_at', created_at
            ),
            NOW()
        FROM public.payment_sessions 
        WHERE is_used = false AND expires_at > NOW();
    END IF;
END $$;

-- Step 4: Drop foreign key constraint first
ALTER TABLE public.payment_sessions DROP CONSTRAINT IF EXISTS payment_sessions_user_id_fkey;

-- Step 5: Drop indexes
DROP INDEX IF EXISTS idx_payment_sessions_user_id;

-- Step 6: Drop the table
DROP TABLE IF EXISTS public.payment_sessions CASCADE;

-- Step 7: Drop the sequence
DROP SEQUENCE IF EXISTS payment_sessions_id_seq CASCADE;

-- Migration complete - payment_sessions table and related infrastructure removed
-- Any active sessions have been logged to user_audit_log for reference 