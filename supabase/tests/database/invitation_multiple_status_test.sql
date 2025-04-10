BEGIN;
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";
CREATE EXTENSION IF NOT EXISTS "pgtap";
SELECT plan(6);

-- Test case 1: Multiple status invitations test
-- This test verifies:
-- 1. Creating multiple invitations for the same email with different statuses
-- 2. Verifying the correct invitation is selected based on status priority
-- 3. Testing the unique constraint (email + status)
-- 4. Verifying that creating a new pending invitation expires any existing ones

-- Setup test users
SELECT tests.create_supabase_user('admin_user', 'admin_user@test.com');
SELECT tests.create_supabase_user('test_user1', 'test_user1@test.com');
SELECT tests.create_supabase_user('test_user2', 'test_user2@test.com');
SELECT tests.create_supabase_user('test_user3', 'test_user3@test.com');
SELECT tests.create_supabase_user('test_user4', 'test_user4@test.com');
SELECT tests.create_supabase_user('test_user5', 'test_user5@test.com');
SELECT tests.create_supabase_user('test_user6', 'test_user6@test.com');

-- Insert admin role
INSERT INTO public.user_roles (user_id, role)
VALUES (tests.get_supabase_uid('admin_user'), 'admin');

-- Test 1: Verify unique constraint (email + status)
SELECT tests.authenticate_as('admin_user');

-- Create first invitation with pending status
SELECT lives_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('test_user1'),
        'multi_status@example.com',
        'Test',
        'User',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop',
        NULL,
        now() + interval '7 days',
        '{"test": "pending"}'::jsonb
    )
    $$,
    'Should create first invitation with pending status'
);

-- Test 2: Verify that a new invitation with the same email expires the previous one
SELECT lives_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('test_user2'),
        'multi_status@example.com',
        'Test',
        'User2',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop',
        NULL,
        now() + interval '7 days',
        '{"test": "new_pending"}'::jsonb
    )
    $$,
    'Should create second invitation and expire the first one'
);

-- Test 3: Verify first invitation was expired
SELECT results_eq(
    $$
    SELECT status FROM public.invitations 
    WHERE email = 'multi_status@example.com' AND user_id = tests.get_supabase_uid('test_user1')
    $$,
    ARRAY['expired'::public.invitation_status],
    'First invitation should be marked as expired'
);

-- Test 4: Verify second invitation is pending
SELECT results_eq(
    $$
    SELECT status FROM public.invitations 
    WHERE email = 'multi_status@example.com' AND user_id = tests.get_supabase_uid('test_user2')
    $$,
    ARRAY['pending'::public.invitation_status],
    'Second invitation should be pending'
);

-- Test 5: Manually create invitations with different statuses for the same email
-- Set role to postgres to bypass RLS for direct inserts
SET ROLE postgres;

-- Create accepted invitation
INSERT INTO public.invitations (
    email,
    user_id,
    status,
    expires_at,
    created_by,
    invitation_type,
    metadata
) VALUES (
    'multi_status_test@example.com',
    tests.get_supabase_uid('test_user3'),
    'accepted',
    now() + interval '7 days',
    tests.get_supabase_uid('admin_user'),
    'workshop',
    '{"status": "accepted"}'::jsonb
);

-- Create expired invitation
INSERT INTO public.invitations (
    email,
    user_id,
    status,
    expires_at,
    created_by,
    invitation_type,
    metadata
) VALUES (
    'multi_status_test@example.com',
    tests.get_supabase_uid('test_user4'),
    'expired',
    now() - interval '1 day',
    tests.get_supabase_uid('admin_user'),
    'workshop',
    '{"status": "expired"}'::jsonb
);

-- Create revoked invitation
INSERT INTO public.invitations (
    email,
    user_id,
    status,
    expires_at,
    created_by,
    invitation_type,
    metadata
) VALUES (
    'multi_status_test@example.com',
    tests.get_supabase_uid('test_user5'),
    'revoked',
    now() + interval '7 days',
    tests.get_supabase_uid('admin_user'),
    'workshop',
    '{"status": "revoked"}'::jsonb
);

RESET ROLE;

-- Test 6: Verify we can have multiple invitations with the same email but different statuses
SELECT is(
    (SELECT COUNT(*) FROM public.invitations WHERE email = 'multi_status_test@example.com'),
    3::bigint,
    'Should have 3 invitations with the same email but different statuses'
);

-- Test 7: Verify the unique constraint works (can't have duplicate email + status)
SET ROLE postgres;

SELECT throws_ok(
    $$
    INSERT INTO public.invitations (
        email,
        user_id,
        status,
        expires_at,
        created_by,
        invitation_type
    ) VALUES (
        'multi_status_test@example.com',
        tests.get_supabase_uid('test_user6'),
        'accepted',
        now() + interval '7 days',
        tests.get_supabase_uid('admin_user'),
        'workshop'
    )
    $$,
    '23505', -- Unique violation error code
    'duplicate key value violates unique constraint "invitations_email_status_unique"',
    'Should not allow duplicate email + status combination'
);

RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
