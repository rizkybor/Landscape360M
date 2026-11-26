-- Team Monitor: the profile behind a live tracker. A position packet only names the member by
-- the email before the @ in capitals (or the first 8 characters of the account id), as sent by
-- the Landscape 360 Mobile App, so monitors see e.g. "2431500673". This function turns those
-- names into the account's profile (name, email, organization, phone, plan, photo) for monitors and
-- admins only (is_monitor()), who may already read every profile.
-- When one name fits several accounts (same email name, other domains) the account that logged
-- a position most recently is returned, with `matches` telling how many fit.
-- Requires 20261024000009 (profiles.organization, phone) and 20261023000000 (is_monitor with
-- admins). Safe to re-run.

-- The profile photo (set by its owner through set_my_avatar, 20261127000035)
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_path TEXT CHECK (char_length(avatar_path) <= 200);

-- The returned columns grew (avatar_path), which CREATE OR REPLACE cannot do
DROP FUNCTION IF EXISTS public.monitor_tracker_profiles(TEXT[]);

CREATE FUNCTION public.monitor_tracker_profiles(p_trackers TEXT[])
RETURNS TABLE (
  tracker_id TEXT,
  user_id UUID,
  name TEXT,
  email TEXT,
  organization TEXT,
  phone TEXT,
  plan TEXT,
  role TEXT,
  matches INTEGER,
  avatar_path TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
BEGIN
  IF NOT public.is_monitor() THEN
    RAISE EXCEPTION 'Only monitors can see tracker profiles' USING ERRCODE = '42501';
  END IF;
  IF p_trackers IS NULL OR array_length(p_trackers, 1) IS NULL THEN
    RETURN;
  END IF;
  IF array_length(p_trackers, 1) > 200 THEN
    RAISE EXCEPTION 'Too many trackers at once (200 at most)' USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH wanted AS (
    SELECT DISTINCT upper(trim(t)) AS tid FROM unnest(p_trackers) t WHERE trim(t) <> ''
  ),
  candidates AS (
    SELECT w.tid,
           u.id,
           COALESCE(NULLIF(trim(pr.email), ''), u.email)::TEXT AS mail,
           pr.organization, pr.phone, pr.status_subscribe, pr.status_user, pr.avatar_path AS photo,
           u.raw_user_meta_data AS meta,
           (SELECT max(l.timestamp) FROM public.tracker_logs l WHERE l.user_id = u.id) AS last_log
    FROM wanted w
    JOIN auth.users u
      ON upper(split_part(COALESCE(u.email, ''), '@', 1)) = w.tid
      -- Accounts without an email are named by their id
      OR (COALESCE(u.email, '') = '' AND upper(left(u.id::text, 8)) = w.tid)
    LEFT JOIN public.profiles pr ON pr.id = u.id
  ),
  ranked AS (
    SELECT c.*,
           count(*) OVER (PARTITION BY c.tid) AS n,
           row_number() OVER (PARTITION BY c.tid ORDER BY c.last_log DESC NULLS LAST, c.id) AS rn
    FROM candidates c
  )
  SELECT r.tid,
         r.id,
         NULLIF(trim(COALESCE(
           NULLIF(r.meta->>'display_name', ''),
           NULLIF(r.meta->>'full_name', ''),
           r.meta->>'name'
         )), ''),
         r.mail,
         NULLIF(trim(r.organization), ''),
         NULLIF(trim(r.phone), ''),
         r.status_subscribe::TEXT,
         r.status_user::TEXT,
         r.n::INTEGER,
         r.photo
  FROM ranked r
  WHERE r.rn = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.monitor_tracker_profiles(TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monitor_tracker_profiles(TEXT[]) TO authenticated;
