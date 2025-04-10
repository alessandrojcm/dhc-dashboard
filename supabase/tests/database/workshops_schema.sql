-- Create the extension for supabase test helpers
CREATE EXTENSION IF NOT EXISTS "basejump-supabase_test_helpers";

-- Load pgTAP
CREATE EXTENSION IF NOT EXISTS pgtap;

-- Test the RLS policy and the update function for the waitlist

BEGIN;

-- Plan the number of tests
SELECT plan(10);

-- Setup: Insert test users
SELECT tests.create_supabase_user('admin', 'admin@example.com');
SELECT tests.create_supabase_user('president', 'president@example.com');
SELECT tests.create_supabase_user('committee_coordinator', 'committee_coordinator@example.com');
SELECT tests.create_supabase_user('coach', 'coach@example.com');
SELECT tests.create_supabase_user('member', 'member@example.com');

SELECT tests.authenticate_as_service_role();
INSERT INTO user_roles (user_id, role)
VALUES ((SELECT tests.get_supabase_uid('admin')), 'admin'),
       ((SELECT tests.get_supabase_uid('president')), 'president'),
       ((SELECT tests.get_supabase_uid('committee_coordinator')), 'committee_coordinator'),
       ((SELECT tests.get_supabase_uid('coach')), 'coach'),
       ((SELECT tests.get_supabase_uid('member')), 'member');

-- Setup: Insert test records into the waitlist
INSERT INTO waitlist (id, email, status)
VALUES ('10000000-0000-0000-0000-000000000001', 'john@doe.com', 'waiting'),
       ('10000000-0000-0000-0000-000000000002', 'john2@doe.com', 'waiting');
SELECT tests.clear_authentication();

-- Test cases for RLS policies and function

-- Test case 1: Admin can update waitlist
SELECT tests.authenticate_as('admin');
SELECT lives_ok(
               $$ UPDATE waitlist SET status = 'invited' WHERE id = '10000000-0000-0000-0000-000000000001'; $$,
               'Admin should be able to update the waitlist'
       );

-- Test case 2: President can update waitlist
SELECT tests.authenticate_as('president');
SELECT lives_ok(
               $$ UPDATE waitlist SET status = 'invited' WHERE id = '10000000-0000-0000-0000-000000000002'; $$,
               'President should be able to update the waitlist'
       );

-- Test case 3: Committee Coordinator can update waitlist
SELECT tests.authenticate_as('committee_coordinator');
SELECT lives_ok(
               $$ UPDATE waitlist SET status = 'paid' WHERE id = '10000000-0000-0000-0000-000000000001'; $$,
               'Committee Coordinator should be able to update the waitlist'
       );

-- Test case 4: Coach cannot update waitlist and check if the status has not changed
SELECT tests.authenticate_as('coach');
UPDATE waitlist
SET status = 'paid'
WHERE id = '10000000-0000-0000-0000-000000000002';
SELECT is(
               (SELECT status FROM waitlist WHERE id = '10000000-0000-0000-0000-000000000002'),
               'waiting',
               'Coach should not be able to update the waitlist'
       );

-- Test case 5: Normal member cannot check the waitlist
SELECT tests.authenticate_as('member');
SELECT is(
               (SELECT status FROM waitlist WHERE id = '10000000-0000-0000-0000-000000000002'),
               NULL,
               'Normal member should not be able to update the waitlist'
       );

-- Test case 6: Admin can view waitlist
SELECT tests.authenticate_as('admin');
SELECT lives_ok(
               $$ SELECT * FROM waitlist; $$,
               'Admin should be able to view the waitlist'
       );

-- Test case 7: President can view waitlist
SELECT tests.authenticate_as('president');
SELECT lives_ok(
               $$ SELECT * FROM waitlist; $$,
               'President should be able to view the waitlist'
       );

-- Test case 8: Committee Coordinator can view waitlist
SELECT tests.authenticate_as('committee_coordinator');
SELECT lives_ok(
               $$ SELECT * FROM waitlist; $$,
               'Committee Coordinator should be able to view the waitlist'
       );

-- Test case 9: Coach can view waitlist
SELECT tests.authenticate_as('coach');
SELECT lives_ok(
               $$ SELECT * FROM waitlist; $$,
               'Coach should be able to view the waitlist'
       );

-- Test case 10: Normal member cannot view waitlist
SELECT tests.authenticate_as('member');
SELECT results_eq(
               'SELECT id FROM waitlist',
--     Matching an empty set
               'SELECT id FROM waitlist WHERE false'
       );

SELECT *
FROM finish();
-- Clean up
ROLLBACK;
