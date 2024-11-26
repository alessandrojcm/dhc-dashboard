BEGIN;
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";
-- Load pgTAP
SELECT plan(29);

-- Test enum exists and has correct values
SELECT has_type('public'::name, 'preferred_weapon'::name, 'Type preferred_weapon should exist');
SELECT enum_has_labels('public'::name, 'preferred_weapon'::name, ARRAY ['longsword', 'sword_and_buckler', 'both'],
                       'preferred_weapon should have correct labels');

-- Test table existence and structure
SELECT has_table('public'::name, 'member_profiles'::name, 'Table member_profiles should exist');

-- Test columns
SELECT columns_are('public'::name, 'member_profiles'::name, ARRAY [
    'id',
    'user_profile_id',
    'next_of_kin_name',
    'next_of_kin_phone',
    'preferred_weapon',
    'membership_start_date',
    'membership_end_date',
    'last_payment_date',
    'additional_data',
    'created_at',
    'updated_at'
    ]);

-- Test column types
SELECT col_type_is('public', 'member_profiles', 'id', 'uuid', 'id should be uuid');
SELECT col_type_is('public', 'member_profiles', 'user_profile_id', 'uuid', 'user_profile_id should be uuid');
SELECT col_type_is('public', 'member_profiles', 'next_of_kin_name', 'text', 'next_of_kin_name should be text');
SELECT col_type_is('public', 'member_profiles', 'next_of_kin_phone', 'text', 'next_of_kin_phone should be text');
SELECT col_type_is('public', 'member_profiles', 'preferred_weapon', 'preferred_weapon',
                   'preferred_weapon should be preferred_weapon enum');
SELECT col_type_is('public', 'member_profiles', 'additional_data', 'jsonb', 'additional_data should be jsonb');

-- Test NOT NULL constraints
SELECT col_not_null('public', 'member_profiles', 'id', 'id should be NOT NULL');
SELECT col_not_null('public', 'member_profiles', 'user_profile_id', 'user_profile_id should be NOT NULL');
SELECT col_not_null('public', 'member_profiles', 'next_of_kin_name', 'next_of_kin_name should be NOT NULL');
SELECT col_not_null('public', 'member_profiles', 'next_of_kin_phone', 'next_of_kin_phone should be NOT NULL');
SELECT col_not_null('public', 'member_profiles', 'preferred_weapon', 'preferred_weapon should be NOT NULL');

-- Test default values
SELECT col_default_is('public', 'member_profiles', 'membership_start_date', 'now()',
                      'membership_start_date should default to now()');
SELECT col_default_is('public', 'member_profiles', 'additional_data', '{}', 'additional_data should default to empty jsonb');
SELECT col_default_is('public', 'member_profiles', 'created_at', 'now()', 'created_at should default to now()');
SELECT col_default_is('public', 'member_profiles', 'updated_at', 'now()', 'updated_at should default to now()');

-- Test indexes
SELECT has_index('public', 'member_profiles', 'idx_member_profiles_user_id', 'Should have index on user_profile_id');

-- Test foreign keys
SELECT has_fk('public', 'member_profiles', 'fk_user_profile');
SELECT fk_ok('public', 'member_profiles', 'user_profile_id', 'public', 'user_profiles', 'id',
             'FK user_profile_id references user_profiles(id)');

-- Test functions existence
SELECT has_function('public', 'complete_member_registration',
                    ARRAY ['uuid', 'text', 'text', 'public.preferred_weapon', 'jsonb'],
                    'Function complete_member_registration should exist');
SELECT has_function('public', 'update_member_payment', ARRAY ['uuid', 'timestamp with time zone'],
                    'Function update_member_payment should exist');
SELECT has_function('public', 'update_updated_at_column', ARRAY []::text[],
                    'Function update_updated_at_column should exist');

-- Test view existence and structure
SELECT has_view('public', 'member_management_view', 'View member_management_view should exist');

-- Test RLS policies exist
SELECT policies_are('public', 'member_profiles', ARRAY [
    'Members can view their own profile',
    'Committee members can view all profiles',
    'Committee members can modify profiles'
    ], 'member_profiles should have exactly these policies');

-- Test triggers
SELECT trigger_is('public', 'member_profiles', 'update_member_profiles_updated_at', 'public',
                  'update_updated_at_column', 'Should have update_updated_at trigger');

-- Test function behavior
-- Setup test data
\set QUIET false
select tests.create_supabase_user('test');
insert into public.user_profiles (id, supabase_user_id, date_of_birth, first_name, last_name) values (gen_random_uuid(), tests.get_supabase_uid('test'), '11-05-1996', 'User', 'Name');

-- Test complete_member_registration
SELECT isnt(
               (SELECT public.complete_member_registration(
                               p_user_profile_id := (select id from public.user_profiles where supabase_user_id = tests.get_supabase_uid('test')),
                               p_next_of_kin_name := 'Test Kin',
                               p_next_of_kin_phone := '1234567890',
                               p_preferred_weapon := 'longsword'::public.preferred_weapon,
                               p_additional_data := '{
                                 "test": true
                               }'::jsonb
                       )),
               null,
               'complete_member_registration should return UUID'
       );

-- Finish the test
SELECT *
FROM finish();
ROLLBACK;
