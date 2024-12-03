BEGIN;

-- Load the pgTAP and test helpers extensions
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";

SELECT plan(6);

-- Test function existence
SELECT has_function(
    'public',
    'get_member_data',
    ARRAY['uuid'],
    'Function get_member_data(uuid) should exist'
);

-- Setup test data
SELECT tests.create_supabase_user('test_member', 'test_member@test.com');
SELECT tests.create_supabase_user('nonexistent_user', 'nonexistent@test.com');

-- Create test user profile
INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    first_name,
    last_name,
    medical_conditions,
    date_of_birth
)
VALUES (
    gen_random_uuid(),
    tests.get_supabase_uid('test_member'),
    'Test',
    'User',
    'None',
    '1990-01-01'::date
);

-- Create test member profile
INSERT INTO public.member_profiles (
    id,
    user_profile_id,
    next_of_kin_name,
    next_of_kin_phone,
    preferred_weapon
)
SELECT 
    tests.get_supabase_uid('test_member'),
    up.id,
    'Next Kin',
    '+1234567890',
    ARRAY['longsword']::public.preferred_weapon[]
FROM public.user_profiles up
WHERE up.supabase_user_id = tests.get_supabase_uid('test_member');

-- Test 1: Null input
SELECT throws_ok(
    'SELECT public.get_member_data(NULL)',
    'User with UUID <NULL> not found',
    'Should throw error for null user ID'
);

-- Test 2: Non-existent user
SELECT throws_ok(
    format(
        'SELECT public.get_member_data(%L::uuid)',
        tests.get_supabase_uid('nonexistent_user')
    ),
    format(
        'User with UUID %s not found',
        tests.get_supabase_uid('nonexistent_user')
    ),
    'Should throw error for non-existent user'
);

-- Test 3-6: Successful retrieval
SELECT is(
    (SELECT first_name FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    'Test',
    'First name should match'
);

SELECT is(
    (SELECT last_name FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    'User',
    'Last name should match'
);

SELECT is(
    (SELECT next_of_kin_name FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    'Next Kin',
    'Next of kin name should match'
);

-- Cleanup is handled by transaction ROLLBACK

SELECT * FROM finish();
ROLLBACK;
