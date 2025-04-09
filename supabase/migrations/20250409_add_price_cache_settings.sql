-- Insert initial price cache entries if they don't exist
INSERT INTO settings (key, value, updated_at, type)
VALUES 
  ('stripe_monthly_price_id', '', NOW(), 'text'),
  ('stripe_annual_price_id', '', NOW(), 'text')
ON CONFLICT (key) DO NOTHING;
