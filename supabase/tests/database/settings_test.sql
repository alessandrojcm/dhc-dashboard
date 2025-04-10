BEGIN;
SELECT plan(11);
-- Test 1: Check if settings table exists
SELECT has_table(
        'public',
        'settings',
        'Should have settings table'
    );
-- Test 2: Check if setting_type enum exists
SELECT has_type(
        'public',
        'setting_type',
        'Should have setting_type enum'
    );
-- Test 3-4: Check enum values
SELECT ok(
        'text'::setting_type IS NOT NULL,
        'setting_type should accept text value'
    );
SELECT ok(
        'boolean'::setting_type IS NOT NULL,
        'setting_type should accept boolean value'
    );
-- Test 5-10: Check columns
SELECT has_column(
        'public',
        'settings',
        'id',
        'Should have id column'
    );
SELECT has_column(
        'public',
        'settings',
        'key',
        'Should have key column'
    );
SELECT has_column(
        'public',
        'settings',
        'value',
        'Should have value column'
    );
SELECT has_column(
        'public',
        'settings',
        'type',
        'Should have type column'
    );
SELECT has_column(
        'public',
        'settings',
        'description',
        'Should have description column'
    );
SELECT has_column(
        'public',
        'settings',
        'updated_by',
        'Should have updated_by column'
    );
-- Test 11: Check RLS policies exist
SET LOCAL ROLE authenticated;
SET LOCAL "request.jwt.claims" TO '{"role": "authenticated", "sub": "11111111-1111-1111-1111-111111111111"}';
-- Test that non-admin users cannot insert settings
SELECT throws_ok(
        $$
        INSERT INTO public.settings (key, value)
        VALUES ('test_key', 'test_value') $$,
            '42501',
            'new row violates row-level security policy for table "settings"',
            'Non-admin users should not be able to insert settings'
    );
SELECT *
FROM finish();
ROLLBACK;