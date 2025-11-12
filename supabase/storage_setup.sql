-- Storage setup for inventory management equipment photos
-- This should be run manually in the Supabase dashboard or via SQL editor

-- Create storage bucket for equipment photos
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'equipment-photos',
    'equipment-photos',
    true,
    5242880, -- 5MB limit
    ARRAY['image/jpeg', 'image/png', 'image/webp']
) ON CONFLICT (id) DO NOTHING;

-- Storage policies for equipment photos bucket

-- Allow quartermaster to upload photos
CREATE POLICY "Quartermaster can upload equipment photos" ON storage.objects
    FOR INSERT WITH CHECK (
        bucket_id = 'equipment-photos' AND
        has_any_role(auth.uid(), ARRAY['quartermaster', 'admin', 'president']::role_type[])
    );

-- Allow quartermaster to update photos
CREATE POLICY "Quartermaster can update equipment photos" ON storage.objects
    FOR UPDATE USING (
        bucket_id = 'equipment-photos' AND
        has_any_role(auth.uid(), ARRAY['quartermaster', 'admin', 'president']::role_type[])
    );

-- Allow quartermaster to delete photos
CREATE POLICY "Quartermaster can delete equipment photos" ON storage.objects
    FOR DELETE USING (
        bucket_id = 'equipment-photos' AND
        has_any_role(auth.uid(), ARRAY['quartermaster', 'admin', 'president']::role_type[])
    );

-- Allow all authenticated users to view photos (public bucket)
CREATE POLICY "All users can view equipment photos" ON storage.objects
    FOR SELECT USING (
        bucket_id = 'equipment-photos' AND
        auth.role() = 'authenticated'
    );