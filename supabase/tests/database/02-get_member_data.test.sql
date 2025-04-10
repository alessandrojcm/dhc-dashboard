BEGIN;

-- Load the pgTAP and test helpers extensions
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";

SELECT plan(20);

-- Test function existence
SELECT has_function(
    'public',
    'get_member_data',
    ARRAY['uuid'],
    'Function get_member_data(uuid) should exist'
);

SELECT has_function(
    'public',
    'update_member_data',
    ARRAY['uuid', 'text', 'text', 'boolean', 'text', 'text', 'public.gender', 'text', 'date', 'text', 'text', 'public.preferred_weapon[]', 'timestamp with time zone', 'timestamp with time zone', 'timestamp with time zone', 'boolean', 'jsonb', 'public.social_media_consent'],
    'Function update_member_data should exist with all optional parameters'
);

-- Setup test data
SELECT tests.create_supabase_user('test_member', 'test_member@test.com');
SELECT tests.create_supabase_user('nonexistent_user', 'nonexistent@test.com');

-- Set security definer for test context
SET LOCAL role postgres;

-- Create test user profile
INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    first_name,
    last_name,
    medical_conditions,
    phone_number,
    gender,
    pronouns,
    date_of_birth,
    is_active
)
VALUES (
    gen_random_uuid(),
    tests.get_supabase_uid('test_member'),
    'Test',
    'User',
    'None',
    '+1234567890',
    'non-binary'::public.gender,
    'they/them',
    '1990-01-01'::date,
    true
);

-- Reset role after inserts
RESET role;

-- Create test member profile
INSERT INTO public.member_profiles (
    id,
    user_profile_id,
    next_of_kin_name,
    next_of_kin_phone,
    preferred_weapon,
    membership_start_date,
    membership_end_date,
    last_payment_date,
    insurance_form_submitted,
    additional_data
)
SELECT 
    tests.get_supabase_uid('test_member'),
    up.id,
    'Next Kin',
    '+1234567890',
    ARRAY['longsword']::public.preferred_weapon[],
    NOW(),
    NOW() + interval '1 year',
    NOW(),
    true,
    '{}'::jsonb
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

-- Test 3-12: Successful retrieval
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

SELECT is(
    (SELECT next_of_kin_phone FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    '+1234567890',
    'Next of kin phone should match'
);

SELECT is(
    (SELECT phone_number FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    '+1234567890',
    'Phone number should match'
);

SELECT is(
    (SELECT gender::text FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    'non-binary',
    'Gender should match'
);

SELECT is(
    (SELECT pronouns FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    'they/them',
    'Pronouns should match'
);

SELECT is(
    (SELECT date_of_birth FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    '1990-01-01'::date,
    'Date of birth should match'
);

SELECT is(
    (SELECT is_active FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    true,
    'Is active should match'
);

SELECT is(
    (SELECT insurance_form_submitted FROM public.get_member_data(tests.get_supabase_uid('test_member'))),
    true,
    'Insurance form submitted should match'
);

SELECT tests.authenticate_as('test_member');

-- Test RLS policies
SET LOCAL role authenticated;
SET LOCAL "request.jwt.claims" to '{"role": "authenticated", "sub": "11111111-1111-1111-1111-111111111111"}';

-- Test that non-committee users cannot update member data
UPDATE public.member_profiles
SET next_of_kin_name = 'Updated'
WHERE user_profile_id = '11111111-1111-1111-1111-111111111111';

-- Switch to service role to verify
SET LOCAL ROLE service_role;
SELECT results_eq(
    'select count(*) from public.member_profiles where user_profile_id = ''11111111-1111-1111-1111-111111111111'' and next_of_kin_name = ''Updated''',
    array[0::bigint],
    'Non-committee users should not be able to update member data'
);

-- Switch back to authenticated for insert
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" to '{"role": "authenticated", "sub": "11111111-1111-1111-1111-111111111111"}';

-- Test that non-committee users cannot insert member data
SELECT throws_ok(
    $$
    INSERT INTO public.member_profiles (user_profile_id, next_of_kin_name, next_of_kin_phone)
    VALUES ('11111111-1111-1111-1111-111111111111', 'Test', '1234567890')
    $$,
    '42501',
    'new row violates row-level security policy for table "member_profiles"',
    'Non-committee users should not be able to insert member data'
);

-- Reset role
SET LOCAL ROLE authenticated;

-- Test direct update should fail due to RLS
SELECT results_eq(
    'SELECT COUNT(*) FROM public.user_profiles WHERE supabase_user_id = tests.get_supabase_uid(''test_member'') AND first_name = ''Updated Name''',
    ARRAY[0::bigint],
    'Update operation should fail due to RLS restrictions'
);

-- Test direct insert should fail due to RLS
SELECT results_eq(
    'SELECT COUNT(*) FROM public.user_profiles WHERE supabase_user_id = tests.get_supabase_uid(''test_member'') AND first_name = ''Inserted Name''',
    ARRAY[0::bigint],
    'Insert operation should fail due to RLS restrictions'
);


-- Test error handling for non-existent user
SELECT throws_ok(
    $$SELECT * FROM public.update_member_data(
        user_uuid := NULL::uuid,
        p_first_name := NULL,
        p_last_name := NULL,
        p_is_active := NULL,
        p_medical_conditions := NULL,
        p_phone_number := NULL,
        p_gender := NULL,
        p_pronouns := NULL,
        p_date_of_birth := NULL,
        p_next_of_kin_name := NULL,
        p_next_of_kin_phone := NULL,
        p_preferred_weapon := NULL,
        p_membership_start_date := NULL,
        p_membership_end_date := NULL,
        p_last_payment_date := NULL,
        p_insurance_form_submitted := NULL,
        p_additional_data := NULL
    )$$,
    'User with UUID <NULL> not found',
    'Should throw error for null user ID in update'
);

SELECT throws_ok(
    format(
        $$SELECT * FROM public.update_member_data(
            user_uuid := %L::uuid,
            p_first_name := NULL,
            p_last_name := NULL,
            p_is_active := NULL,
            p_medical_conditions := NULL,
            p_phone_number := NULL,
            p_gender := NULL,
            p_pronouns := NULL,
            p_date_of_birth := NULL,
            p_next_of_kin_name := NULL,
            p_next_of_kin_phone := NULL,
            p_preferred_weapon := NULL,
            p_membership_start_date := NULL,
            p_membership_end_date := NULL,
            p_last_payment_date := NULL,
            p_insurance_form_submitted := NULL,
            p_additional_data := NULL
        )$$,
        tests.get_supabase_uid('nonexistent_user')
    ),
    format(
        'User with UUID %s not found',
        tests.get_supabase_uid('nonexistent_user')
    ),
    'Should throw error for non-existent user in update'
);

SELECT * FROM finish();
ROLLBACK;
