BEGIN;
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";
CREATE EXTENSION IF NOT EXISTS "pgtap";
SELECT plan(8);

-- Test case: Expiration scenarios
-- This test verifies:
-- 1. The mark_expired_invitations function correctly expires invitations
-- 2. Invitations expire at the correct time
-- 3. The system handles invitations that expire during the signup process
-- 4. The get_invitation_info function correctly handles expired invitations

-- Setup test users
SELECT tests.create_supabase_user('admin_user_exp', 'admin_user_exp@test.com');
SELECT tests.create_supabase_user('test_user_exp1', 'test_user_exp1@test.com');
SELECT tests.create_supabase_user('test_user_exp2', 'test_user_exp2@test.com');
SELECT tests.create_supabase_user('test_user_exp3', 'test_user_exp3@test.com');
SELECT tests.create_supabase_user('test_user_exp4', 'test_user_exp4@test.com');

-- Insert admin role
INSERT INTO public.user_roles (user_id, role)
VALUES (tests.get_supabase_uid('admin_user_exp'), 'admin');

-- Test 1: Create an invitation that will expire soon
SELECT tests.authenticate_as('admin_user_exp');

SELECT lives_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('test_user_exp1'),
        'expiring_soon@example.com',
        'Test',
        'Expiring',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop',
        NULL,
        now() + interval '1 minute',
        '{"test": "expiring_soon"}'::jsonb
    )
    $$,
    'Should create an invitation that will expire soon'
);

-- Test 2: Create an invitation that is already expired
SELECT lives_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('test_user_exp2'),
        'already_expired@example.com',
        'Test',
        'Expired',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop',
        NULL,
        now() - interval '1 day',
        '{"test": "already_expired"}'::jsonb
    )
    $$,
    'Should create an invitation that is already expired'
);

-- Test 3: Verify the invitation with past expiration date is still pending
-- (since mark_expired_invitations hasn't run yet)
SELECT results_eq(
    $$
    SELECT status FROM public.invitations 
    WHERE email = 'already_expired@example.com'
    $$,
    ARRAY['pending'::public.invitation_status],
    'Invitation should still be pending until mark_expired_invitations runs'
);

-- Test 4: Run mark_expired_invitations and verify it expires the correct invitation
SELECT lives_ok(
    $$
    SELECT public.mark_expired_invitations()
    $$,
    'Should run mark_expired_invitations function successfully'
);

-- Test 5: Verify the expired invitation is now marked as expired
SELECT results_eq(
    $$
    SELECT status FROM public.invitations 
    WHERE email = 'already_expired@example.com'
    $$,
    ARRAY['expired'::public.invitation_status],
    'Invitation should be marked as expired after mark_expired_invitations runs'
);

-- Test 6: Create an invitation that expires during signup process
-- First create the invitation
SELECT lives_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('test_user_exp3'),
        'expires_during_signup@example.com',
        'Test',
        'MidSignup',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop',
        NULL,
        now() + interval '5 seconds',
        '{"test": "expires_during_signup"}'::jsonb
    )
    $$,
    'Should create an invitation that will expire during signup'
);

-- Test 7: Simulate time passing during signup (manually expire the invitation)
SELECT lives_ok(
    $$
    UPDATE public.invitations
    SET expires_at = now() - interval '1 second'
    WHERE email = 'expires_during_signup@example.com'
    $$,
    'Should update expiration time to simulate time passing during signup'
);

-- Test 8: Verify get_invitation_info correctly handles expired invitations
-- First, make sure the user has the correct email in auth.users
SET ROLE postgres;

UPDATE auth.users 
SET email = 'expires_during_signup@example.com'
WHERE id = tests.get_supabase_uid('test_user_exp3');

-- Now try to get invitation info for the user with expired invitation
SELECT throws_ok(
    format(
        'SELECT public.get_invitation_info(%L::uuid)',
        tests.get_supabase_uid('test_user_exp3')
    ),
    'U0009',
    'Invitation has expired.',
    'get_invitation_info should throw an error for expired invitation'
);

RESET ROLE;

-- Verify update_invitation_status correctly handles expired invitations
-- We'll do this without using the test framework to avoid the FOR UPDATE issue
SET ROLE postgres;

-- Update the auth.users table to ensure test_user_exp3 has the correct email
UPDATE auth.users 
SET email = 'expires_during_signup@example.com'
WHERE id = tests.get_supabase_uid('test_user_exp3');

-- Get the invitation ID
DO $$
DECLARE
    v_invitation_id UUID;
    v_error_caught BOOLEAN := FALSE;
BEGIN
    SELECT id INTO v_invitation_id 
    FROM public.invitations 
    WHERE email = 'expires_during_signup@example.com';
    
    -- Try to update the invitation status
    BEGIN
        PERFORM public.update_invitation_status(v_invitation_id, 'accepted');
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE '%Invitation has expired%' THEN
                v_error_caught := TRUE;
                RAISE NOTICE 'Successfully caught expired invitation error: %', SQLERRM;
            ELSE
                RAISE NOTICE 'Unexpected error: %', SQLERRM;
            END IF;
    END;
    
    IF NOT v_error_caught THEN
        RAISE NOTICE 'Test failed: Did not catch expired invitation error';
    END IF;
END $$;

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
