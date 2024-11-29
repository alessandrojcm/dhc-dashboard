BEGIN;

-- Load the pgTAP extension
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";

SELECT plan(11);

-- Test function existence
SELECT has_function(
    'public',
    'get_membership_info',
    ARRAY['uuid'],
    'Function get_membership_info(uuid) should exist'
);

SELECT has_function(
    'public',
    'create_pending_member',
    ARRAY['uuid', 'text', 'text', 'text', 'timestamptz', 'text', 'public.gender', 'text', 'text', 'text', 'public.preferred_weapon', 'jsonb'],
    'Function create_pending_member should exist with correct parameters'
);

-- Setup test data
SELECT tests.create_supabase_user('active_user', 'active@test.com');
SELECT tests.create_supabase_user('banned_user', 'banned@test.com');
SELECT tests.create_supabase_user('new_user', 'new@test.com');
SELECT tests.create_supabase_user('existing_member', 'member@test.com');

-- Create test data
INSERT INTO public.waitlist (id, email)
VALUES 
    (gen_random_uuid(), 'new@test.com'),
    (gen_random_uuid(), 'member@test.com');

INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    waitlist_id,
    first_name,
    last_name,
    phone_number,
    date_of_birth,
    pronouns,
    gender
)
SELECT 
    gen_random_uuid(),
    tests.get_supabase_uid('new_user'),
    w.id,
    'New',
    'User',
    '+1234567890',
    '1990-01-01'::timestamptz,
    'they/them',
    'non-binary'
FROM public.waitlist w
WHERE w.email = 'new@test.com';

INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    waitlist_id,
    first_name,
    last_name,
    phone_number,
    date_of_birth,
    pronouns,
    gender
)
SELECT 
    gen_random_uuid(),
    tests.get_supabase_uid('existing_member'),
    w.id,
    'Existing',
    'Member',
    '+0987654321',
    '1990-01-01'::timestamptz,
    'they/them',
    'non-binary'
FROM public.waitlist w
WHERE w.email = 'member@test.com';

-- Create an existing member
INSERT INTO public.member_profiles (
    id,
    user_profile_id,
    next_of_kin_name,
    next_of_kin_phone,
    preferred_weapon
)
SELECT 
    tests.get_supabase_uid('existing_member'),
    up.id,
    'Next Kin',
    '+1111111111',
    'longsword'
FROM public.user_profiles up
WHERE up.supabase_user_id = tests.get_supabase_uid('existing_member');

-- Ban a user
UPDATE auth.users 
SET banned_until = now() + interval '1 day'
WHERE email = 'banned@test.com';

-- Test 1: Null input
SELECT is(
    get_membership_info(NULL)::jsonb,
    jsonb_build_object(
        'error', jsonb_build_object(
            'http_code', 400,
            'message', 'User ID cannot be null.'
        )
    ),
    'Should return error for null user ID'
);

-- Test 2: Banned user
SELECT is(
    (get_membership_info(tests.get_supabase_uid('banned_user'))::jsonb->'error'->>'http_code'),
    '403',
    'Should return 403 for banned user'
);

-- Test 3: Non-existent user
SELECT is(
    (get_membership_info('00000000-0000-0000-0000-000000000000'::uuid)::jsonb->'error'->>'http_code'),
    '403',
    'Should return 403 for non-existent user'
);

-- Test 4: User without waitlist entry
SELECT is(
    (get_membership_info(tests.get_supabase_uid('active_user'))::jsonb->'error'->>'http_code'),
    '404',
    'Should return 404 for user without waitlist entry'
);

-- Test 5: Valid new user
SELECT ok(
    (get_membership_info(tests.get_supabase_uid('new_user'))::jsonb->>'first_name') IS NOT NULL,
    'Should return user profile info for valid new user'
);

-- Test 6: Check all required fields are present for valid user
SELECT ok(
    (
        SELECT bool_and(key IS NOT NULL)
        FROM jsonb_object_keys(
            get_membership_info(tests.get_supabase_uid('new_user'))::jsonb
        ) AS key
        WHERE key IN ('first_name', 'last_name', 'phone_number', 'date_of_birth', 'pronouns', 'gender')
    ),
    'Should return all required fields for valid user'
);

-- Test 7: Create pending member success
SELECT ok(
    (create_pending_member(
        tests.get_supabase_uid('new_user'),
        'Updated',
        'Name',
        '+1234567890',
        '1990-01-01'::timestamptz,
        'they/them',
        'non-binary',
        'none',
        'Next of Kin',
        '+9876543210',
        'longsword',
        '{}'::jsonb
    )::jsonb->>'member_id') IS NOT NULL,
    'Should successfully create pending member'
);

-- Test 8: Verify user profile is inactive after pending member creation
SELECT is(
    (SELECT is_active FROM public.user_profiles WHERE supabase_user_id = tests.get_supabase_uid('new_user')),
    false,
    'User profile should be inactive after creating pending member'
);

-- Test 9: Attempt to create duplicate member
SELECT is(
    (create_pending_member(
        tests.get_supabase_uid('existing_member'),
        'Duplicate',
        'Member',
        '+1234567890',
        '1990-01-01'::timestamptz,
        'they/them',
        'non-binary',
        'none',
        'Next of Kin',
        '+9876543210',
        'longsword',
        '{}'::jsonb
    )::jsonb->'error'->>'http_code'),
    '400',
    'Should return error when attempting to create duplicate member'
);

-- Cleanup test data
SELECT tests.clear_authentication();

-- Finish the test
SELECT * FROM finish();
ROLLBACK;
