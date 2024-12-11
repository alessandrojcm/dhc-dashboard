BEGIN;

CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";
CREATE EXTENSION IF NOT EXISTS pgtap;

SELECT plan(6);

-- Test 1: Check if social_media_consent type exists
SELECT has_type(
    'public', 'social_media_consent',
    'social_media_consent type should exist'
);

-- Test 2: Check enum values
SELECT results_eq(
    $$
    SELECT unnest(enum_range(NULL::social_media_consent))::text
    $$,
    ARRAY['no', 'yes_recognizable', 'yes_unrecognizable']::text[],
    'social_media_consent should have correct enum values'
);

-- Test 3: Check if social_media_consent column exists
SELECT has_column(
    'public', 'user_profiles', 'social_media_consent',
    'social_media_consent column should exist'
);

-- Test 4: Check column type
SELECT col_type_is(
    'public', 'user_profiles', 'social_media_consent', 'social_media_consent',
    'social_media_consent should be of type social_media_consent'
);

-- Test 5: Check not null constraint
SELECT col_not_null(
    'public', 'user_profiles', 'social_media_consent',
    'social_media_consent should be NOT NULL'
);

-- Create test user and profile
SELECT tests.create_supabase_user('user1@test.com');

INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    first_name,
    last_name,
    date_of_birth
) VALUES (
    gen_random_uuid(),
    tests.get_supabase_uid('user1@test.com'),
    'User',
    'Name',
    '1990-01-01'::timestamptz
);

-- Test 6: Test default value for new users
SELECT is(
    (SELECT social_media_consent::text FROM public.user_profiles 
    WHERE supabase_user_id = tests.get_supabase_uid('user1@test.com')),
    'no',
    'New user should have social_media_consent set to no by default'
);

-- Clean up
DELETE FROM auth.users WHERE email = 'user1@test.com';
DELETE FROM public.user_profiles WHERE supabase_user_id = tests.get_supabase_uid('user1@test.com');

SELECT * FROM finish();
ROLLBACK;
