-- Unit tests for inventory management system
-- Run with: supabase test db

BEGIN;

-- Load pgtap extension
SELECT plan(20);

-- Test 1: Check that all tables exist
SELECT has_table('public', 'containers', 'containers table should exist');
SELECT has_table('public', 'equipment_categories', 'equipment_categories table should exist');
SELECT has_table('public', 'inventory_items', 'inventory_items table should exist');
SELECT has_table('public', 'inventory_history', 'inventory_history table should exist');

-- Test 2: Check that enum type exists
SELECT has_type('public', 'inventory_action', 'inventory_action enum should exist');

-- Test 3: Check that default categories were seeded
SELECT ok(
    (SELECT COUNT(*) FROM equipment_categories) >= 7,
    'Should have at least 7 default equipment categories'
);

-- Test 4: Check specific categories exist
SELECT ok(
    EXISTS(SELECT 1 FROM equipment_categories WHERE name = 'Masks'),
    'Masks category should exist'
);

SELECT ok(
    EXISTS(SELECT 1 FROM equipment_categories WHERE name = 'Longswords'),
    'Longswords category should exist'
);

-- Test 5: Test JSON Schema validation
-- Create a test user first
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-000000000001', 'test@example.com');

-- Create a test container
INSERT INTO containers (id, name, created_by) 
VALUES ('00000000-0000-0000-0000-000000000002', 'Test Container', '00000000-0000-0000-0000-000000000001');

-- Test valid attributes for Masks category
SELECT lives_ok(
    $$INSERT INTO inventory_items (container_id, category_id, attributes, created_by) 
      VALUES (
        '00000000-0000-0000-0000-000000000002',
        (SELECT id FROM equipment_categories WHERE name = 'Masks'),
        '{"brand": "Test Brand", "size": "M", "colour": "Black"}',
        '00000000-0000-0000-0000-000000000001'
      )$$,
    'Should accept valid mask attributes'
);

-- Test invalid attributes (missing required brand)
SELECT throws_ok(
    $$INSERT INTO inventory_items (container_id, category_id, attributes, created_by) 
      VALUES (
        '00000000-0000-0000-0000-000000000002',
        (SELECT id FROM equipment_categories WHERE name = 'Masks'),
        '{"size": "M", "colour": "Black"}',
        '00000000-0000-0000-0000-000000000001'
      )$$,
    'Item attributes do not match category schema',
    'Should reject mask attributes without required brand'
);

-- Test invalid size enum
SELECT throws_ok(
    $$INSERT INTO inventory_items (container_id, category_id, attributes, created_by) 
      VALUES (
        '00000000-0000-0000-0000-000000000002',
        (SELECT id FROM equipment_categories WHERE name = 'Masks'),
        '{"brand": "Test Brand", "size": "INVALID", "colour": "Black"}',
        '00000000-0000-0000-0000-000000000001'
      )$$,
    'Item attributes do not match category schema',
    'Should reject invalid size enum values'
);

-- Test 6: Test container hierarchy validation
-- Test valid hierarchy
INSERT INTO containers (id, name, parent_container_id, created_by) 
VALUES ('00000000-0000-0000-0000-000000000003', 'Child Container', '00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001');

SELECT ok(
    EXISTS(SELECT 1 FROM containers WHERE id = '00000000-0000-0000-0000-000000000003'),
    'Should allow valid container hierarchy'
);

-- Test circular reference prevention
SELECT throws_ok(
    $$UPDATE containers 
      SET parent_container_id = '00000000-0000-0000-0000-000000000003' 
      WHERE id = '00000000-0000-0000-0000-000000000002'$$,
    'Circular reference detected in container hierarchy',
    'Should prevent circular references in container hierarchy'
);

-- Test 7: Test history tracking
-- Get the item we created earlier
SELECT ok(
    EXISTS(SELECT 1 FROM inventory_history WHERE action = 'created'),
    'Should create history record when item is created'
);

-- Test item movement creates history
INSERT INTO containers (id, name, created_by) 
VALUES ('00000000-0000-0000-0000-000000000004', 'Another Container', '00000000-0000-0000-0000-000000000001');

UPDATE inventory_items 
SET container_id = '00000000-0000-0000-0000-000000000004',
    updated_by = '00000000-0000-0000-0000-000000000001'
WHERE container_id = '00000000-0000-0000-0000-000000000002';

SELECT ok(
    EXISTS(SELECT 1 FROM inventory_history WHERE action = 'moved'),
    'Should create history record when item is moved'
);

-- Test 8: Test maintenance status tracking
UPDATE inventory_items 
SET out_for_maintenance = true,
    updated_by = '00000000-0000-0000-0000-000000000001'
WHERE container_id = '00000000-0000-0000-0000-000000000004';

SELECT ok(
    EXISTS(SELECT 1 FROM inventory_history WHERE action = 'maintenance_out'),
    'Should create history record when item goes out for maintenance'
);

-- Test 9: Test quantity constraint
SELECT throws_ok(
    $$INSERT INTO inventory_items (container_id, category_id, attributes, quantity, created_by) 
      VALUES (
        '00000000-0000-0000-0000-000000000002',
        (SELECT id FROM equipment_categories WHERE name = 'Masks'),
        '{"brand": "Test Brand"}',
        0,
        '00000000-0000-0000-0000-000000000001'
      )$$,
    'new row for relation "inventory_items" violates check constraint "inventory_items_quantity_check"',
    'Should reject zero or negative quantities'
);

-- Test 10: Test updated_at timestamp trigger
SELECT ok(
    (SELECT updated_at FROM containers WHERE id = '00000000-0000-0000-0000-000000000002') > 
    (SELECT created_at FROM containers WHERE id = '00000000-0000-0000-0000-000000000002'),
    'Should update updated_at timestamp when container is modified'
);

SELECT * FROM finish();

ROLLBACK;