BEGIN;

-- Load the pgTAP extension
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";

SELECT plan(18);

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
    ARRAY['uuid', 'text', 'text', 'text', 'timestamptz', 'text', 'public.gender', 'text', 'text', 'text', 'public.preferred_weapon[]', 'jsonb'],
    'Function create_pending_member should exist with correct parameters'
);

-- Setup test data
SELECT tests.create_supabase_user('active_user', 'active@test.com');
SELECT tests.create_supabase_user('banned_user', 'banned@test.com');
SELECT tests.create_supabase_user('new_user', 'new@test.com');
SELECT tests.create_supabase_user('new_user2', 'new2@test.com');
SELECT tests.create_supabase_user('existing_member', 'member@test.com');
SELECT tests.create_supabase_user('no_waitlist_user', 'no_waitlist@test.com');
SELECT tests.create_supabase_user('incomplete_user', 'incomplete@test.com');

-- Create test data
INSERT INTO public.waitlist (id, email, status)
VALUES 
    (gen_random_uuid(), 'new@test.com', 'completed'),
    (gen_random_uuid(), 'new2@test.com', 'completed'),
    (gen_random_uuid(), 'member@test.com', 'completed'),
    (gen_random_uuid(), 'active@test.com', 'completed'),
    (gen_random_uuid(), 'incomplete@test.com', 'waiting');

-- Create incomplete user profile
INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    waitlist_id,
    first_name,
    last_name,
    phone_number,
    date_of_birth,
    pronouns,
    gender,
    is_active
)
SELECT 
    gen_random_uuid(),
    tests.get_supabase_uid('incomplete_user'),
    w.id,
    'Incomplete',
    'User',
    '+1234567890',
    '1990-01-01'::timestamptz,
    'they/them',
    'non-binary',
    false
FROM public.waitlist w
WHERE w.email = 'incomplete@test.com';

-- Create a user profile without waitlist entry
INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    waitlist_id,
    first_name,
    last_name,
    phone_number,
    date_of_birth,
    pronouns,
    gender,
    is_active
)
VALUES (
    gen_random_uuid(),
    tests.get_supabase_uid('no_waitlist_user'),
    null,
    'No',
    'Waitlist',
    '+1234567890',
    '1990-01-01'::timestamptz,
    'they/them',
    'non-binary',
    false
);

-- Create user profiles
INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    waitlist_id,
    first_name,
    last_name,
    phone_number,
    date_of_birth,
    pronouns,
    gender,
    is_active
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
    'non-binary',
    false
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
    gender,
    is_active
)
SELECT 
    gen_random_uuid(),
    tests.get_supabase_uid('new_user2'),
    w.id,
    'New2',
    'User2',
    '+1234567890',
    '1990-01-01'::timestamptz,
    'they/them',
    'non-binary',
    false
FROM public.waitlist w
WHERE w.email = 'new2@test.com';

INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    waitlist_id,
    first_name,
    last_name,
    phone_number,
    date_of_birth,
    pronouns,
    gender,
    is_active
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
    'non-binary',
    false
FROM public.waitlist w
WHERE w.email = 'member@test.com';

INSERT INTO public.user_profiles (
    id,
    supabase_user_id,
    waitlist_id,
    first_name,
    last_name,
    phone_number,
    date_of_birth,
    pronouns,
    gender,
    is_active
)
SELECT 
    gen_random_uuid(),
    tests.get_supabase_uid('active_user'),
    w.id,
    'Active',
    'User',
    '+1234567890',
    '1990-01-01'::timestamptz,
    'they/them',
    'non-binary',
    true
FROM public.waitlist w
WHERE w.email = 'active@test.com';

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
    ARRAY['longsword']::public.preferred_weapon[]
FROM public.user_profiles up
WHERE up.supabase_user_id = tests.get_supabase_uid('existing_member');

-- Ban a user
UPDATE auth.users 
SET banned_until = now() + interval '1 day'
WHERE email = 'banned@test.com';

-- Test get_membership_info function

-- Test 1: Null input
SELECT throws_ok(
    'SELECT get_membership_info(NULL)',
    'U0002',
    'User not found.',
    'Should throw U0002 for null user ID'
);

-- Test 2: Non-existent user
SELECT throws_ok(
    'SELECT get_membership_info(''00000000-0000-0000-0000-000000000000''::uuid)',
    'U0002',
    'User not found.',
    'Should throw U0002 for non-existent user'
);

-- Test 3: Banned user
SELECT throws_ok(
    format('SELECT get_membership_info(%L::uuid)', tests.get_supabase_uid('banned_user')),
    'U0003',
    'User is banned.',
    'Should throw U0003 for banned user'
);

-- Test 4: User with member profile
SELECT throws_ok(
    format('SELECT get_membership_info(%L::uuid)', tests.get_supabase_uid('existing_member')),
    'U0004',
    'User already has a member profile.',
    'Should throw U0004 for user with member profile'
);

-- Test 5: Active user
SELECT throws_ok(
    format('SELECT get_membership_info(%L::uuid)', tests.get_supabase_uid('active_user')),
    'U0005',
    'User is already active.',
    'Should throw U0005 for active user'
);

-- Test 6: No waitlist entry
SELECT throws_ok(
    format('SELECT get_membership_info(%L::uuid)', tests.get_supabase_uid('no_waitlist_user')),
    'U0006',
    format('Waitlist entry not found for email: %s', 'no_waitlist@test.com'),
    'Should throw U0006 for user without waitlist entry'
);

-- Test 7: Incomplete workshop
SELECT throws_ok(
    format('SELECT get_membership_info(%L::uuid)', tests.get_supabase_uid('incomplete_user')),
    'U0007',
    'This user has not completed the workshop.',
    'Should throw U0007 for user with incomplete workshop'
);

-- Test 8: Valid new user
SELECT lives_ok(
    format('SELECT get_membership_info(%L::uuid)', tests.get_supabase_uid('new_user')),
    'Should not throw for valid new user'
);

-- Test 9: Check all required fields for valid user
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

-- Test create_pending_member function

-- Test 10: Create pending member success
SELECT lives_ok(
    format(
        'SELECT create_pending_member(%L::uuid, ''Updated'', ''Name'', ''+1234567890'', ''1990-01-01''::timestamptz, ''they/them'', ''non-binary'', ''none'', ''Next of Kin'', ''+9876543210'', ARRAY[''longsword'']::public.preferred_weapon[], ''{}''::jsonb)',
        tests.get_supabase_uid('new_user')
    ),
    'Should successfully create pending member'
);

-- Test 11: Check member_id in response
SELECT ok(
    (SELECT id IS NOT NULL FROM public.member_profiles WHERE id = tests.get_supabase_uid('new_user')),
    'Should have created member profile with correct ID'
);

-- Test 12: Check insurance_form_submitted is false
SELECT is(
    (SELECT insurance_form_submitted FROM public.member_profiles WHERE id = tests.get_supabase_uid('new_user')),
    false,
    'Insurance form submitted should be false for new member'
);

-- Test 13: Verify user profile is active
SELECT is(
    (SELECT is_active FROM public.user_profiles WHERE supabase_user_id = tests.get_supabase_uid('new_user')),
    true,
    'User profile should be active after creating member profile'
);

-- Test 14: Verify profile fields in response
SELECT ok(
    (
        SELECT bool_and(key IS NOT NULL) AND count(*) = 11
        FROM jsonb_object_keys(
            (create_pending_member(
                tests.get_supabase_uid('new_user2'),
                'New2',
                'User2',
                '+1234567890',
                '1990-01-01'::timestamptz,
                'they/them',
                'non-binary',
                'none',
                'Next of Kin',
                '+9876543210',
                ARRAY['longsword']::public.preferred_weapon[],
                '{}'::jsonb
            )->'profile')::jsonb
        ) AS key
        WHERE key IN (
            'first_name', 'last_name', 'phone_number', 'date_of_birth', 'pronouns', 'gender',
            'medical_conditions', 'next_of_kin_name', 'next_of_kin_phone', 'preferred_weapon',
            'insurance_form_submitted'
        )
    ),
    'Should return all required fields in profile'
);

-- Test 15: Verify error propagation
SELECT throws_ok(
    format(
        'SELECT create_pending_member(%L::uuid, ''Test'', ''User'', ''+1234567890'', ''1990-01-01''::timestamptz, ''they/them'', ''non-binary'', ''none'', ''Next of Kin'', ''+9876543210'', ARRAY[''longsword'']::public.preferred_weapon[], ''{}''::jsonb)',
        tests.get_supabase_uid('banned_user')
    ),
    'U0003',
    'User is banned.',
    'Should propagate error from get_membership_info'
);

-- Test 16: Verify error propagation for incomplete workshop
SELECT throws_ok(
    format(
        'SELECT create_pending_member(%L::uuid, ''Test'', ''User'', ''+1234567890'', ''1990-01-01''::timestamptz, ''they/them'', ''non-binary'', ''none'', ''Next of Kin'', ''+9876543210'', ARRAY[''longsword'']::public.preferred_weapon[], ''{}''::jsonb)',
        tests.get_supabase_uid('incomplete_user')
    ),
    'U0007',
    'This user has not completed the workshop.',
    'Should propagate error from get_membership_info for incomplete workshop'
);

-- Cleanup test data
SELECT tests.clear_authentication();

-- Finish the test
SELECT * FROM finish();
ROLLBACK;
