BEGIN;
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";
CREATE EXTENSION IF NOT EXISTS "pgtap";
SELECT plan(20);

-- Schema Tests
SELECT has_type('public', 'invitation_status', 'Type invitation_status should exist');
SELECT enum_has_labels(
    'public', 'invitation_status',
    ARRAY['pending', 'accepted', 'expired', 'revoked'],
    'invitation_status should have correct labels'
);

SELECT has_table('public', 'invitations', 'Table invitations should exist');
SELECT has_column('public', 'invitations', 'id', 'Should have id column');
SELECT has_column('public', 'invitations', 'email', 'Should have email column');
SELECT has_column('public', 'invitations', 'user_id', 'Should have user_id column');
SELECT has_column('public', 'invitations', 'status', 'Should have status column');
SELECT has_column('public', 'invitations', 'expires_at', 'Should have expires_at column');

-- RLS Tests
SELECT ok(
    (SELECT pg_catalog.pg_class.relrowsecurity 
     FROM pg_catalog.pg_class 
     JOIN pg_catalog.pg_namespace ON pg_catalog.pg_namespace.oid = pg_catalog.pg_class.relnamespace
     WHERE pg_catalog.pg_namespace.nspname = 'public' 
     AND pg_catalog.pg_class.relname = 'invitations'),
    'RLS should be enabled on invitations table'
);

SELECT policies_are('public', 'invitations', ARRAY[
    'Admins can see all invitations',
    'Admins can create and update invitations',
    'Users can see their own invitations'
], 'invitations table should have correct policies');

-- Setup test users
SELECT tests.create_supabase_user('admin', 'admin@test.com');
SELECT tests.create_supabase_user('normal', 'normal@test.com');
SELECT tests.create_supabase_user('banned', 'banned@test.com');
SELECT tests.create_supabase_user('invite_test1', 'invite_test1@test.com');
SELECT tests.create_supabase_user('invite_test2', 'invite_test2@test.com');
SELECT tests.create_supabase_user('invite_test3', 'invite_test3@test.com');

-- Insert test roles
INSERT INTO public.user_roles (user_id, role)
VALUES (tests.get_supabase_uid('admin'), 'admin');

-- Ban a user
SET ROLE postgres;
UPDATE auth.users 
SET banned_until = now() + interval '1 day'
WHERE email = 'banned@test.com';
RESET ROLE;

-- Test create_invitation function
SELECT tests.authenticate_as('admin');

SELECT lives_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('invite_test1'),
        'test@example.com',
        'Test',
        'User',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop',
        NULL,
        now() + interval '7 days',
        '{"test": true}'::jsonb
    )
    $$,
    'Admin should be able to create invitation'
);

SELECT tests.authenticate_as('normal');

SELECT throws_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('normal'),
        'test@example.com',
        'Test',
        'User',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop'
    )
    $$,
    'PERM1',
    'Permission denied: Admin role required to create invitations',
    'Normal user should not be able to create invitation'
);

-- Test duplicate invitation handling
SELECT tests.authenticate_as('admin');

SELECT lives_ok(
    $$
    SELECT public.create_invitation(
        tests.get_supabase_uid('invite_test2'),
        'duplicate@test.com',
        'Test',
        'User',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop'
    )
    $$,
    'First invitation should be created'
);

SELECT results_eq(
    $$
    SELECT status FROM public.invitations 
    WHERE email = 'duplicate@test.com' 
    ORDER BY created_at DESC LIMIT 1
    $$,
    ARRAY['pending'::invitation_status],
    'New invitation should be pending'
);

-- Test get_invitation_info function
SELECT tests.authenticate_as('banned');

-- Set role to postgres to bypass RLS for the test
SET ROLE postgres;
SELECT throws_ok(
    format(
        'SELECT public.get_invitation_info(%L::uuid)',
        tests.get_supabase_uid('banned')
    ),
    'U0003',
    'User is banned.',
    'Banned user should not be able to get invitation info'
);
RESET ROLE;

-- Test update_invitation_status function
SELECT tests.authenticate_as('admin');

WITH new_invitation AS (
    SELECT public.create_invitation(
        tests.get_supabase_uid('invite_test3'),
        'status@test.com',
        'Test',
        'User',
        '1990-01-01'::timestamptz,
        '1234567890',
        'workshop'
    ) as invitation_id
)
SELECT lives_ok(
    format(
        'SELECT public.update_invitation_status(%L::uuid, %L::invitation_status)',
        (SELECT invitation_id FROM new_invitation),
        'accepted'
    ),
    'Admin should be able to update invitation status'
);

-- Test mark_expired_invitations function
SELECT has_function(
    'public',
    'mark_expired_invitations',
    ARRAY[]::text[],
    'mark_expired_invitations function should exist'
);

-- Create expired invitation
INSERT INTO public.invitations (
    email,
    status,
    expires_at,
    created_by,
    invitation_type
) VALUES (
    'expired@test.com',
    'pending',
    now() - interval '1 day',
    tests.get_supabase_uid('admin'),
    'workshop'
);

SELECT is(
    (SELECT public.mark_expired_invitations()),
    1,
    'mark_expired_invitations should update one invitation'
);

SELECT results_eq(
    $$
    SELECT status FROM public.invitations 
    WHERE email = 'expired@test.com'
    $$,
    ARRAY['expired'::invitation_status],
    'Expired invitation should be marked as expired'
);

-- Test cron job scheduling
SELECT has_function(
    'cron',
    'schedule',
    ARRAY['text', 'text', 'text'],
    'cron.schedule function should exist'
);

-- Cleanup
SELECT tests.clear_authentication();

SELECT * FROM finish();
ROLLBACK;