BEGIN;
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";
-- Load pgTAP
SELECT plan(56);
-- Adjust number based on total test count

-- Test schema existence
SELECT has_schema('public', 'Schema "public" should exist');

-- Test extensions
SELECT has_extension('uuid-ossp', 'Extension uuid-ossp should be installed');

-- Test enum
SELECT has_type('public', 'role_type', 'Type role_type should exist');
SELECT enum_has_labels('role_type', ARRAY [
    'admin',
    'president',
    'treasurer',
    'committee_coordinator',
    'sparring_coordinator',
    'workshop_coordinator',
    'beginners_coordinator',
    'quartermaster',
    'pr_manager',
    'volunteer_coordinator',
    'research_coordinator',
    'coach',
    'member'
    ], 'role_type should have all expected values');

-- Test tables existence
SELECT has_table('public', 'user_profiles', 'Table user_profiles should exist');
SELECT has_table('public', 'user_roles', 'Table user_roles should exist');
SELECT has_table('public', 'user_audit_log', 'Table user_audit_log should exist');

-- Test user_profiles columns
SELECT columns_are('public', 'user_profiles', ARRAY [
    'id',
    'first_name',
    'last_name',
    'is_active',
    'created_at',
    'updated_at',
    'date_of_birth',
    'gender',
    'phone_number',
    'pronouns',
    'search_text',
    'supabase_user_id',
    'waitlist_id',
    'medical_conditions'
    ], 'user_profiles should have the correct columns');

SELECT col_is_pk('public', 'user_profiles', 'id', 'user_profiles.id should be primary key');
SELECT col_not_null('public', 'user_profiles', 'first_name', 'first_name should not be null');
SELECT col_not_null('public', 'user_profiles', 'last_name', 'last_name should not be null');
SELECT col_has_default('public', 'user_profiles', 'is_active', 'is_active should have default value');
SELECT col_default_is('public', 'user_profiles', 'is_active', 'true', 'is_active should default to true');

-- Test user_roles columns
SELECT columns_are('public', 'user_roles', ARRAY [
    'id',
    'user_id',
    'role'
    ], 'user_roles should have the correct columns');

SELECT col_is_pk('public', 'user_roles', 'id', 'user_roles.id should be primary key');
SELECT col_not_null('public', 'user_roles', 'user_id', 'user_id should not be null');
SELECT col_not_null('public', 'user_roles', 'role', 'role should not be null');

-- Test user_audit_log columns
SELECT columns_are('public', 'user_audit_log', ARRAY [
    'id',
    'user_id',
    'action',
    'details',
    'ip_address',
    'created_at'
    ], 'user_audit_log should have the correct columns');

-- Test functions existence
SELECT has_function('public', 'has_role', ARRAY ['uuid', 'role_type'],
                    'Function has_role(uuid, role_type) should exist');
SELECT has_function('public', 'has_any_role', ARRAY ['uuid', 'role_type[]'],
                    'Function has_any_role(uuid, role_type[]) should exist');
SELECT has_function('public', 'update_updated_at_column', ARRAY []::text[],
                    'Function update_updated_at_column() should exist');
SELECT has_function('public', 'log_role_change', ARRAY []::text[], 'Function log_role_change() should exist');
SELECT has_function('public', 'custom_access_token_hook', ARRAY ['jsonb'],
                    'Function custom_access_token_hook(jsonb) should exist');

-- Test triggers
SELECT trigger_is('public', 'user_profiles', 'update_user_profiles_updated_at', 'public', 'update_updated_at_column',
                  'update_user_profiles_updated_at trigger should exist on user_profiles');

-- Test RLS is enabled

-- Test policies for user_profiles
SELECT policies_are('public', 'user_profiles', ARRAY [
    'Committee members can see al profiles',
    'Only admins and committee members can add profiles',
    'Only admins, committee members and the user can delete profiles',
    'Users can update their own basic info',
    'Users can view their own profile',
    'Service role can manage user profiles',
    'Committee members can update user profiles'
    ], 'user_profiles should have all expected policies');

-- Test policies for user_roles
SELECT policies_are('public', 'user_roles', ARRAY [
    'Committee coordinators can add roles',
    'Committee coordinators can update roles',
    'Users, admin and president can see their own roles',
    'Allow auth admin to read user roles',
    'Service role can insert user_roles entries'
    ], 'user_roles should have all expected policies');

-- Test policies for user_audit_log
SELECT policies_are('public', 'user_audit_log', ARRAY [
    'Audit logs viewable by admins'
    ], 'user_audit_log should have all expected policies');
-- Test indexes
SELECT has_index('public', 'user_audit_log', 'idx_user_audit_created_at', ARRAY ['created_at'],
                 'Should have index on user_audit_log(created_at)');
SELECT has_index('public', 'user_profiles', 'idx_waitlist_user_profile', ARRAY ['waitlist_id']);
SELECT has_index('public', 'user_profiles', 'idx_user_profiles_names', ARRAY ['first_name', 'last_name']);
SELECT has_index('public', 'user_profiles', 'idx_waitlist_concat_info',
                 ARRAY ['first_name', 'last_name', 'waitlist_id']);

-- Test function behavior
-- Create test users and roles
\set QUIET false


select tests.create_supabase_user('admin', 'admin@test.com');
select tests.create_supabase_user('president', 'president@test.com');
select tests.create_supabase_user('coach', 'coach@test.com');
select tests.create_supabase_user('member', 'member@test.com');

-- To avoid clashes, is going to be rolled back anyway
DELETE
from user_roles;

insert into user_roles (user_id, role)
values (tests.get_supabase_uid('admin'), 'admin');
insert into user_roles (user_id, role)
values (tests.get_supabase_uid('president'), 'president');
insert into user_roles (user_id, role)
values (tests.get_supabase_uid('coach'), 'coach');
insert into user_roles (user_id, role)
values (tests.get_supabase_uid('member'), 'member');
insert into user_profiles (supabase_user_id, first_name, last_name, is_active, date_of_birth)
values (tests.get_supabase_uid('member'), 'member', 'member', true, '11-05-1996');

-- Test has_role function
SELECT ok(
               has_role(tests.get_supabase_uid('admin'), 'admin'::role_type),
               'has_role should return true for admin user with admin role'
       );

SELECT ok(
               NOT has_role(tests.get_supabase_uid('member'), 'admin'::role_type),
               'has_role should return false for member user with admin role'
       );

-- Test has_any_role function
SELECT ok(
               has_any_role(
                       tests.get_supabase_uid('admin'),
                       ARRAY ['admin', 'president']::role_type[]
               ),
               'has_any_role should return true for admin user with admin or president roles'
       );

SELECT ok(
               NOT has_any_role(
                       tests.get_supabase_uid('member'),
                       ARRAY ['admin', 'president']::role_type[]
                   ),
               'has_any_role should return false for member user with admin or president roles'
       );

select tests.clear_authentication();

select throws_ok(
               'select * from user_roles where user_id = ''' || tests.get_supabase_uid('member') || '''',
               '42501',
               'permission denied for table user_roles'
       );

select tests.authenticate_as('admin');
select tests.create_supabase_user('test');
insert into user_profiles (supabase_user_id, first_name, last_name, is_active, date_of_birth)
values (tests.get_supabase_uid('test'), 'test', '1', true, '11-05-1996');
select tests.clear_authentication();

SELECT is(
               (SELECT id FROM user_profiles WHERE id = tests.get_supabase_uid('member')::uuid),
               NULL,
               'Check if unauthorized access to user_profiles returns NULL due to RLS'
       );
-- Member permissions check
SELECT tests.authenticate_as('member');

-- Positive tests: What a member *should* be able to do

SELECT is(
               (SELECT supabase_user_id
                FROM user_profiles
                WHERE supabase_user_id = tests.get_supabase_uid('member')::uuid),
               tests.get_supabase_uid('member')::uuid,
               'Member can view their own profile'
       );


SELECT lives_ok(
               $$
        UPDATE user_profiles
        SET first_name = 'UpdatedName'
        WHERE id = tests.get_supabase_uid('member')::uuid;
    $$,
               'Member can update their own profile'
       );


-- Negative tests: What a member *should not* be able to do

SELECT is(
               EXISTS((SELECT 1
                       FROM user_profiles
                       WHERE id = tests.get_supabase_uid('test')::uuid)),
               false,
               'Member cannot view other active profiles'
       );

SELECT throws_ok(
               'INSERT INTO user_profiles (supabase_user_id, first_name, last_name, date_of_birth) VALUES (gen_random_uuid(), ''Test'', ''User'', ''11-05-1996'')',
               '42501' -- Permission denied
       );

UPDATE user_profiles
SET first_name = 'UpdatedName'
WHERE id = tests.get_supabase_uid('test')::uuid;
SELECT is(
               (SELECT first_name FROM user_profiles WHERE id = tests.get_supabase_uid('test')::uuid),
               (SELECT first_name FROM user_profiles WHERE id = tests.get_supabase_uid('test')::uuid),
               'Member cannot update other users profiles'
       );

DELETE
FROM user_profiles
WHERE supabase_user_id = tests.get_supabase_uid('test')::uuid;
-- Need to authenticate as admin to assert
select tests.clear_authentication();
select tests.authenticate_as_service_role();
SELECT is(
               (SELECT supabase_user_id
                      FROM user_profiles
                      WHERE supabase_user_id = tests.get_supabase_uid('test')::uuid),
               (select tests.get_supabase_uid('test')),
               'Member cannot delete other users'' profiles'
       );
select tests.authenticate_as('member');

SELECT is(
               (SELECT id FROM user_audit_log LIMIT 1),
               NULL,
               'Member cannot view audit logs'
       );

SELECT throws_ok(
               'INSERT INTO user_roles (user_id, role) VALUES (tests.get_supabase_uid(''member'')::uuid, ''member'')',
               '42501'
       );



UPDATE user_roles
SET role = 'admin'
WHERE user_id = tests.get_supabase_uid('member')::uuid;

SELECT is(
               (SELECT role
                FROM user_roles
                WHERE user_id = tests.get_supabase_uid('member')::uuid
                LIMIT 1),
               (SELECT role
                FROM user_roles
                WHERE user_id = tests.get_supabase_uid('member')::uuid
                LIMIT 1),
               'Member cannot update user_roles'
       );


SELECT tests.clear_authentication();

-- Before running these tests, ensure to load required dependencies and setup

-- Example extension of RLS policies test section

-- Test RLS for non-member roles

-- Authenticate as admin user and validate RLS for admin
SELECT tests.authenticate_as('admin');
SELECT tests.create_supabase_user('test2');
-- Positive Test: Admin should be able to insert a new user profile
SELECT lives_ok(
               $$
    INSERT INTO user_profiles (supabase_user_id, first_name, last_name, is_active, date_of_birth)
    VALUES (tests.get_supabase_uid('test2'), 'Test', 'User', true, '11-05-1996');
    $$,
               'Admin should be able to insert a new user profile'
       );

-- Positive Test: Admin should be able to delete the user profile
SELECT lives_ok(
               $$
    DELETE FROM user_profiles
    WHERE id = tests.get_supabase_uid('test')::uuid;
    $$,
               'Admin should be able to delete the user profile'
       );

-- Positive Test: Admin should be able to update roles
SELECT lives_ok(
               $$
    UPDATE user_roles
    SET role = 'president'
    WHERE user_id = tests.get_supabase_uid('member')::uuid;
    $$,
               'Admin should be able to update roles'
       );

-- Negative Test: Admin should not be able to view user_profiles of inactive users
UPDATE user_profiles
SET is_active = false
WHERE id = tests.get_supabase_uid('test')::uuid;
SELECT is(
               (SELECT first_name FROM user_profiles WHERE id = tests.get_supabase_uid('test')::uuid),
               NULL,
               'Admin should not be able to view profiles of inactive users'
       );

-- Reset authentication
SELECT tests.clear_authentication();


-- Authenticate as president user and validate RLS for president
SELECT tests.authenticate_as('president');

-- Positive Test: President should be able to update their own profile
SELECT lives_ok(
               $$
    UPDATE user_profiles
    SET first_name = 'UpdatedPresident'
    WHERE id = tests.get_supabase_uid('president')::uuid;
    $$,
               'President should be able to update their own profile'
       );

-- Positive Test: President should be able to insert roles
SELECT lives_ok(
               $$
    INSERT INTO user_roles (user_id, role)
    VALUES (tests.get_supabase_uid('test'), 'coach');
    $$,
               'President should be able to insert roles'
       );

-- Positive Test: President should be able to view audit logs
SELECT lives_ok(
               $$
    SELECT *
    FROM user_audit_log
    $$,
               'President should be able to view audit logs'
       );

-- Negative Test: President should not be able to assign `admin` role
SELECT throws_ok(
               $$
    INSERT INTO user_roles (user_id, role)
    VALUES (tests.get_supabase_uid('test'), 'admin');
    $$,
               '42501'
       );

-- Reset authentication
SELECT tests.clear_authentication();


-- Authenticate as committee_coordinator user and validate RLS for committee_coordinator
SELECT tests.create_supabase_user('committee_coordinator');
SELECT tests.authenticate_as('committee_coordinator');

-- Positive Test: Committee coordinator should be able to update roles
SELECT lives_ok(
               $$
    UPDATE user_roles
    SET role = 'treasurer'
    WHERE user_id = tests.get_supabase_uid('member')::uuid;
    $$,
               'Committee coordinator should be able to update roles'
       );

-- Negative Test: Committee coordinator should not be able to view audit logs
SELECT is(
               (SELECT id FROM user_audit_log LIMIT 1),
               NULL,
               'Committee coordinator should not be able to view audit logs'
       );

-- Reset authentication
SELECT tests.clear_authentication();
-- Finish the test
SELECT *
FROM finish();
ROLLBACK;
