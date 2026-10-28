-- Live tracking on private Realtime channels (security findings S1 and S2 in
-- docs/flutter-spec.md of the mobile app).
--
-- Before: the public channel 'tracking-room' let anyone holding the anon key hear every
-- member's live position and send fake ones; the plan check was only in the browser.
--
-- After:
--   tracking-room       positions. Only monitors (Enterprise monitor360 or admin) can join
--                       and hear them; only members who may share (pengguna360 on Pro or
--                       Enterprise) can send them, through the REST broadcast endpoint
--                       without joining, so they never hear each other.
--   tracking-heartbeat  "send your position now". Monitors ask, sharing members listen.
--
-- Copy this file to supabase/migrations/ in the web repo and apply it (supabase db push),
-- together with the TrackerService.ts change in web-tracker-service.md. The app and the
-- web monitor must both use private channels from then on.

CREATE OR REPLACE FUNCTION public.can_broadcast_location()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid()
      AND NOT COALESCE(is_admin, false)
      AND status_user = 'pengguna360'
      AND status_subscribe IN ('Pro', 'Enterprise')
  );
$$;

REVOKE ALL ON FUNCTION public.can_broadcast_location() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_broadcast_location() TO authenticated;

-- Positions: monitors hear them (and show up in presence) ...
DROP POLICY IF EXISTS "tracking-room: monitors receive" ON realtime.messages;
CREATE POLICY "tracking-room: monitors receive"
  ON realtime.messages FOR SELECT TO authenticated
  USING (
    realtime.topic() = 'tracking-room'
    AND extension IN ('broadcast', 'presence')
    AND public.is_monitor()
  );

DROP POLICY IF EXISTS "tracking-room: monitors presence" ON realtime.messages;
CREATE POLICY "tracking-room: monitors presence"
  ON realtime.messages FOR INSERT TO authenticated
  WITH CHECK (
    realtime.topic() = 'tracking-room'
    AND extension = 'presence'
    AND public.is_monitor()
  );

-- ... and members on Pro or Enterprise send them
DROP POLICY IF EXISTS "tracking-room: members send positions" ON realtime.messages;
CREATE POLICY "tracking-room: members send positions"
  ON realtime.messages FOR INSERT TO authenticated
  WITH CHECK (
    realtime.topic() = 'tracking-room'
    AND extension = 'broadcast'
    AND public.can_broadcast_location()
  );

-- "Send your position now": monitors ask, sharing members listen
DROP POLICY IF EXISTS "tracking-heartbeat: members listen" ON realtime.messages;
CREATE POLICY "tracking-heartbeat: members listen"
  ON realtime.messages FOR SELECT TO authenticated
  USING (
    realtime.topic() = 'tracking-heartbeat'
    AND extension = 'broadcast'
    AND (public.can_broadcast_location() OR public.is_monitor())
  );

DROP POLICY IF EXISTS "tracking-heartbeat: monitors ask" ON realtime.messages;
CREATE POLICY "tracking-heartbeat: monitors ask"
  ON realtime.messages FOR INSERT TO authenticated
  WITH CHECK (
    realtime.topic() = 'tracking-heartbeat'
    AND extension = 'broadcast'
    AND public.is_monitor()
  );
