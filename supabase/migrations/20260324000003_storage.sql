-- Storage bucket for prize images (public read)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'prize-images',
  'prize-images',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- Allow anon upload only when a valid admin token is passed via a workaround:
-- Clients upload via Edge Function. For SQL-only setup, allow authenticated
-- inserts is not enough. We use a permissive insert policy gated by checking
-- that the object name starts with a valid pattern; actual auth is Edge Function.
-- For simplicity in free-tier SQL setup: allow public INSERT to this bucket
-- (event-night scoped). Tighten later with Edge Function if needed.

DROP POLICY IF EXISTS prize_images_public_read ON storage.objects;
CREATE POLICY prize_images_public_read ON storage.objects
  FOR SELECT TO anon, authenticated
  USING (bucket_id = 'prize-images');

DROP POLICY IF EXISTS prize_images_public_insert ON storage.objects;
CREATE POLICY prize_images_public_insert ON storage.objects
  FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'prize-images');

DROP POLICY IF EXISTS prize_images_public_update ON storage.objects;
CREATE POLICY prize_images_public_update ON storage.objects
  FOR UPDATE TO anon, authenticated
  USING (bucket_id = 'prize-images');

DROP POLICY IF EXISTS prize_images_public_delete ON storage.objects;
CREATE POLICY prize_images_public_delete ON storage.objects
  FOR DELETE TO anon, authenticated
  USING (bucket_id = 'prize-images');
