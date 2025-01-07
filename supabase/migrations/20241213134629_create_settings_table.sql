-- Enable hstore extension
-- CREATE EXTENSION IF NOT EXISTS hstore;
-- Create setting type enum
CREATE TYPE setting_type AS ENUM ('text', 'boolean');
-- Create settings table
CREATE TABLE settings (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    key text NOT NULL UNIQUE,
    value text NOT NULL,
    type setting_type NOT NULL,
    description text,
    created_at timestamptz DEFAULT now(),
    updated_at timestamptz DEFAULT now(),
    updated_by uuid REFERENCES auth.users(id),
    CONSTRAINT valid_boolean_values CHECK (
        type != 'boolean'
        OR value IN ('true', 'false')
    )
);
-- Create index for faster lookups
CREATE INDEX settings_key_idx ON settings(key);
-- Enable Row Level Security
ALTER TABLE settings ENABLE ROW LEVEL SECURITY;
-- Create policies
-- Allow authenticated users to read settings
CREATE POLICY "Authenticated users can read settings" ON settings FOR
SELECT TO authenticated USING (true);
-- Allow admin, president, and committee coordinator to manage settings
CREATE POLICY "Admin roles can manage settings" ON settings FOR ALL TO authenticated USING (
    has_any_role(
        (
            SELECT auth.uid()
        ),
        ARRAY ['admin', 'president', 'committee_coordinator']::role_type []
    )
) WITH CHECK (
    has_any_role(
        (
            SELECT auth.uid()
        ),
        ARRAY ['admin', 'president', 'committee_coordinator']::role_type []
    )
);
-- Function to automatically update updated_at timestamp
CREATE OR REPLACE FUNCTION update_settings_updated_at() RETURNS TRIGGER AS $$ BEGIN NEW.updated_at = now();
NEW.updated_by = auth.uid();
RETURN NEW;
END;
$$ LANGUAGE plpgsql;
-- Trigger to call the function before update
CREATE TRIGGER settings_updated_at BEFORE
UPDATE ON settings FOR EACH ROW EXECUTE FUNCTION update_settings_updated_at();
INSERT INTO settings (key, value, type, description, updated_by)
VALUES (
        'waitlist_open',
        'false',
        'boolean',
        'Controls whether the waitlist is currently accepting new members',
        auth.uid()
    ),
    (
        'hema_insurance_form_link',
        '',
        'text',
        'Link to the HEMA insurance form for members',
        auth.uid()
    );