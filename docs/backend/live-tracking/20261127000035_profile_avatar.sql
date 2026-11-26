-- Profile photo: each account can set, change or remove its own photo. The file is in the
-- public "avatars" bucket, in the account's own folder (<user id>/avatar-<time>.jpg): a small
-- square JPEG the apps make at most 256 px, and the bucket takes at most 100 KB per file.
-- profiles.avatar_path points at it. The browser cannot
-- update profiles rows (20261023000000_restrict_profile_self_update.sql), so it goes through
-- set_my_avatar(), which returns the previous file for the app to delete. Monitors see the
-- photo in Team Monitor (monitor_tracker_profiles in 20261127000034 returns avatar_path).
-- Safe to re-run.

-- 1. Column ------------------------------------------------------------------------------------

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_path TEXT CHECK (char_length(avatar_path) <= 200);

-- 2. Bucket: anyone can view; each account writes and deletes only in its own folder ----------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('avatars', 'avatars', true, 102400, ARRAY['image/jpeg', 'image/webp'])
ON CONFLICT (id) DO UPDATE
SET public = true, file_size_limit = 102400, allowed_mime_types = ARRAY['image/jpeg', 'image/webp'];

DROP POLICY IF EXISTS "Avatars: upload to own folder" ON storage.objects;
CREATE POLICY "Avatars: upload to own folder" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "Avatars: delete own or (admin) any" ON storage.objects;
CREATE POLICY "Avatars: delete own or (admin) any" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'avatars' AND ((storage.foldername(name))[1] = auth.uid()::text OR public.is_admin()));

-- 3. Set or remove my photo (NULL removes it); returns the previous path, if any ---------------

CREATE OR REPLACE FUNCTION public.set_my_avatar(p_path TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_path TEXT := NULLIF(trim(COALESCE(p_path, '')), '');
  v_old TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not signed in' USING ERRCODE = '42501';
  END IF;
  IF v_path IS NOT NULL THEN
    -- Only a photo of my own, already uploaded
    IF v_path !~ ('^' || v_uid::text || '/avatar-[0-9]+\.(jpg|webp)$') THEN
      RAISE EXCEPTION 'Not a photo of this account' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM storage.objects o WHERE o.bucket_id = 'avatars' AND o.name = v_path) THEN
      RAISE EXCEPTION 'Upload the photo first' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT p.avatar_path INTO v_old FROM public.profiles p WHERE p.id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No profile for this account' USING ERRCODE = 'P0002';
  END IF;
  UPDATE public.profiles SET avatar_path = v_path, updated_at = now() WHERE id = v_uid;
  RETURN CASE WHEN v_old IS DISTINCT FROM v_path THEN v_old END;
END;
$$;

REVOKE ALL ON FUNCTION public.set_my_avatar(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_my_avatar(TEXT) TO authenticated;
