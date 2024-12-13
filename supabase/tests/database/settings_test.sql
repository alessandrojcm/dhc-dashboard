BEGIN;
SELECT plan(11);

-- Test 1: Check if settings table exists
SELECT has_table('public', 'settings', 'Should have settings table');

-- Test 2: Check if setting_type enum exists
SELECT has_type('public', 'setting_type', 'Should have setting_type enum');

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
SELECT has_column('public', 'settings', 'id', 'Should have id column');
SELECT has_column('public', 'settings', 'key', 'Should have key column');
SELECT has_column('public', 'settings', 'value', 'Should have value column');
SELECT has_column('public', 'settings', 'type', 'Should have type column');
SELECT has_column('public', 'settings', 'description', 'Should have description column');
SELECT has_column('public', 'settings', 'updated_by', 'Should have updated_by column');

-- Test 11: Check RLS policies exist
SELECT policies_are('public', 'settings', ARRAY[
    'Authenticated users can read settings',
    'Admin roles can manage settings'
], 'settings should have exactly these policies');

SELECT * FROM finish();
ROLLBACK;
