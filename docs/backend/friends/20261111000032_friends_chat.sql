-- Friends & Chat (docs/FRIENDS_PRD.md): friends added by email or by a personal link / QR
-- (/?friend=<token>), friend requests, and one-to-one chat between friends that is not real time
-- (the apps ask for changes every 15–30 s while it is open). A message is text, my location, or a
-- copy of a map item (track, area, place, Field Work; Pro and up). All reads and writes go through
-- the functions below, which check friendship, plan and daily limits; the tables have RLS on and
-- no policies, so nothing is read directly. Everything goes when an account is deleted.
-- Requires 20261102000024 (community_clean) and 20261024000007 (review_author_name). Safe to re-run.

-- 1. Tables ------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.friend_links (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE CHECK (token ~ '^[0-9a-f]{32}$'),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.friend_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  to_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at TIMESTAMPTZ,
  UNIQUE (from_id, to_id),
  CHECK (from_id <> to_id)
);
CREATE INDEX IF NOT EXISTS friend_requests_to_idx ON public.friend_requests (to_id, status);

CREATE TABLE IF NOT EXISTS public.friendships (
  user_a UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  user_b UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_a, user_b),
  CHECK (user_a < user_b)
);
CREATE INDEX IF NOT EXISTS friendships_b_idx ON public.friendships (user_b);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  recipient_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('text', 'location', 'attachment')),
  body TEXT CHECK (body IS NULL OR char_length(body) <= 2000),
  data JSONB CHECK (data IS NULL OR (jsonb_typeof(data) = 'object' AND pg_column_size(data) <= 262144)),
  client_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  read_at TIMESTAMPTZ,
  deleted_at TIMESTAMPTZ,
  -- Any change (sent, read, deleted): what the apps ask for while a chat is open
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (sender_id, client_id)
);
CREATE INDEX IF NOT EXISTS chat_messages_pair_idx
  ON public.chat_messages (LEAST(sender_id, recipient_id), GREATEST(sender_id, recipient_id), created_at DESC);
CREATE INDEX IF NOT EXISTS chat_messages_unread_idx ON public.chat_messages (recipient_id) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS chat_messages_updated_idx
  ON public.chat_messages (LEAST(sender_id, recipient_id), GREATEST(sender_id, recipient_id), updated_at);

ALTER TABLE public.friend_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friend_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.friend_links, public.friend_requests, public.friendships, public.chat_messages FROM anon, authenticated;

-- 2. Helpers ----------------------------------------------------------------------------------

-- Per plan (FRIENDS_PRD.md §7): friends, messages a day, requests a day, map attachments.
-- NULL: no limit (the admin)
CREATE OR REPLACE FUNCTION public.friends_limits(p_user_id UUID)
RETURNS TABLE (friends INTEGER, messages INTEGER, requests INTEGER, attach BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 1000 WHEN p.status_subscribe = 'Pro' THEN 300 ELSE 100 END,
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 3000 WHEN p.status_subscribe = 'Pro' THEN 1000 ELSE 200 END,
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 100 WHEN p.status_subscribe = 'Pro' THEN 50 ELSE 20 END,
    COALESCE(p.is_admin, false) OR p.status_subscribe IN ('Pro', 'Enterprise')
  FROM (SELECT 1) one
  LEFT JOIN public.profiles p ON p.id = p_user_id;
$$;

CREATE OR REPLACE FUNCTION public.are_friends(p_a UUID, p_b UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.friendships WHERE user_a = LEAST(p_a, p_b) AND user_b = GREATEST(p_a, p_b));
$$;

CREATE OR REPLACE FUNCTION public.friend_count(p_user_id UUID)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT count(*)::INTEGER FROM public.friendships WHERE user_a = p_user_id OR user_b = p_user_id;
$$;

-- Makes two accounts friends (both under their friend limit)
CREATE OR REPLACE FUNCTION public.friends_connect(p_a UUID, p_b UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_max INTEGER;
BEGIN
  IF public.are_friends(p_a, p_b) THEN RETURN; END IF;
  SELECT l.friends INTO v_max FROM public.friends_limits(p_a) l;
  IF v_max IS NOT NULL AND public.friend_count(p_a) >= v_max THEN
    RAISE EXCEPTION 'You have reached your limit of % friends', v_max;
  END IF;
  SELECT l.friends INTO v_max FROM public.friends_limits(p_b) l;
  IF v_max IS NOT NULL AND public.friend_count(p_b) >= v_max THEN
    RAISE EXCEPTION 'That account has reached its limit of friends';
  END IF;
  INSERT INTO public.friendships (user_a, user_b) VALUES (LEAST(p_a, p_b), GREATEST(p_a, p_b)) ON CONFLICT DO NOTHING;
  UPDATE public.friend_requests SET status = 'accepted', decided_at = now()
  WHERE status = 'pending' AND ((from_id = p_a AND to_id = p_b) OR (from_id = p_b AND to_id = p_a));
END;
$$;

-- A request from the caller to p_to: 'friends' (already, or they had asked the caller) or 'sent'
CREATE OR REPLACE FUNCTION public.friends_request(p_to UUID)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_max INTEGER;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF p_to = v_me THEN RAISE EXCEPTION 'That is your own account'; END IF;
  IF public.are_friends(v_me, p_to) THEN RETURN 'friends'; END IF;
  -- They asked first: asking back makes you friends
  IF EXISTS (SELECT 1 FROM public.friend_requests WHERE from_id = p_to AND to_id = v_me AND status = 'pending') THEN
    PERFORM public.friends_connect(v_me, p_to);
    RETURN 'friends';
  END IF;
  SELECT l.requests INTO v_max FROM public.friends_limits(v_me) l;
  IF v_max IS NOT NULL AND (SELECT count(*) FROM public.friend_requests
      WHERE from_id = v_me AND created_at > now() - interval '1 day') >= v_max THEN
    RAISE EXCEPTION 'You can send up to % friend requests a day', v_max;
  END IF;
  INSERT INTO public.friend_requests (from_id, to_id) VALUES (v_me, p_to)
  ON CONFLICT (from_id, to_id) DO UPDATE SET status = 'pending', created_at = now(), decided_at = NULL
    WHERE public.friend_requests.status <> 'pending';
  RETURN 'sent';
END;
$$;

-- 3. Friends -----------------------------------------------------------------------------------

-- My link token (made on first use)
CREATE OR REPLACE FUNCTION public.my_friend_link()
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_token TEXT;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT token INTO v_token FROM public.friend_links WHERE user_id = auth.uid();
  IF v_token IS NULL THEN
    v_token := replace(gen_random_uuid()::text, '-', '');
    INSERT INTO public.friend_links (user_id, token) VALUES (auth.uid(), v_token)
    ON CONFLICT (user_id) DO NOTHING;
    SELECT token INTO v_token FROM public.friend_links WHERE user_id = auth.uid();
  END IF;
  RETURN v_token;
END;
$$;

-- A new token: the old link and QR stop working
CREATE OR REPLACE FUNCTION public.renew_friend_link()
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_token TEXT := replace(gen_random_uuid()::text, '-', '');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  INSERT INTO public.friend_links (user_id, token) VALUES (auth.uid(), v_token)
  ON CONFLICT (user_id) DO UPDATE SET token = EXCLUDED.token, created_at = now();
  RETURN v_token;
END;
$$;

-- Who a link belongs to: the name and organization for its card (also before signing in)
CREATE OR REPLACE FUNCTION public.friend_link_info(p_token TEXT)
RETURNS TABLE (name TEXT, organization TEXT, is_me BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.review_author_name(l.user_id), p.organization, l.user_id = auth.uid()
  FROM public.friend_links l LEFT JOIN public.profiles p ON p.id = l.user_id
  WHERE l.token = p_token;
$$;

-- By email. The answer is the same whether or not an account uses it, so the email of others
-- cannot be checked this way
CREATE OR REPLACE FUNCTION public.send_friend_request(p_email TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT id INTO v_user FROM public.profiles WHERE lower(email) = lower(trim(p_email)) LIMIT 1;
  IF v_user IS NULL THEN RETURN; END IF;
  PERFORM public.friends_request(v_user);
END;
$$;

-- From a friend link: 'sent', or 'friends' when that makes (or already made) you friends
CREATE OR REPLACE FUNCTION public.request_friend_by_link(p_token TEXT)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT user_id INTO v_user FROM public.friend_links WHERE token = p_token;
  IF v_user IS NULL THEN RAISE EXCEPTION 'This friend link is no longer valid'; END IF;
  RETURN public.friends_request(v_user);
END;
$$;

CREATE OR REPLACE FUNCTION public.answer_friend_request(p_id UUID, p_accept BOOLEAN)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_from UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT from_id INTO v_from FROM public.friend_requests WHERE id = p_id AND to_id = auth.uid() AND status = 'pending';
  IF v_from IS NULL THEN RAISE EXCEPTION 'This request is no longer open'; END IF;
  IF p_accept THEN
    PERFORM public.friends_connect(auth.uid(), v_from);
  ELSE
    UPDATE public.friend_requests SET status = 'declined', decided_at = now() WHERE id = p_id;
  END IF;
END;
$$;

-- Unfriends; the chat stays readable for both, but no new messages
CREATE OR REPLACE FUNCTION public.remove_friend(p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  DELETE FROM public.friendships WHERE user_a = LEAST(auth.uid(), p_user_id) AND user_b = GREATEST(auth.uid(), p_user_id);
  DELETE FROM public.friend_requests
  WHERE (from_id = auth.uid() AND to_id = p_user_id) OR (from_id = p_user_id AND to_id = auth.uid());
END;
$$;

-- My friends with their last message and my unread count, the most recent chat first
CREATE OR REPLACE FUNCTION public.my_friends()
RETURNS TABLE (
  user_id UUID, name TEXT, organization TEXT, since TIMESTAMPTZ,
  last_at TIMESTAMPTZ, last_kind TEXT, last_body TEXT, last_from_me BOOLEAN, last_deleted BOOLEAN, unread INTEGER
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH f AS (
    SELECT CASE WHEN user_a = auth.uid() THEN user_b ELSE user_a END AS other, created_at
    FROM public.friendships WHERE user_a = auth.uid() OR user_b = auth.uid()
  )
  SELECT f.other, public.review_author_name(f.other), p.organization, f.created_at,
         m.created_at, m.kind, left(m.body, 120), m.sender_id = auth.uid(), m.deleted_at IS NOT NULL,
         (SELECT count(*)::INTEGER FROM public.chat_messages u
          WHERE u.sender_id = f.other AND u.recipient_id = auth.uid() AND u.read_at IS NULL AND u.deleted_at IS NULL)
  FROM f
  LEFT JOIN public.profiles p ON p.id = f.other
  LEFT JOIN LATERAL (
    SELECT * FROM public.chat_messages c
    WHERE LEAST(c.sender_id, c.recipient_id) = LEAST(auth.uid(), f.other)
      AND GREATEST(c.sender_id, c.recipient_id) = GREATEST(auth.uid(), f.other)
    ORDER BY c.created_at DESC LIMIT 1
  ) m ON true
  WHERE auth.uid() IS NOT NULL
  ORDER BY COALESCE(m.created_at, f.created_at) DESC;
$$;

-- Open requests: to me ('in') and from me ('out'), newest first; older than 30 days are left out
CREATE OR REPLACE FUNCTION public.my_friend_requests()
RETURNS TABLE (id UUID, direction TEXT, user_id UUID, name TEXT, organization TEXT, created_at TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT r.id,
         CASE WHEN r.to_id = auth.uid() THEN 'in' ELSE 'out' END,
         CASE WHEN r.to_id = auth.uid() THEN r.from_id ELSE r.to_id END,
         public.review_author_name(CASE WHEN r.to_id = auth.uid() THEN r.from_id ELSE r.to_id END),
         p.organization, r.created_at
  FROM public.friend_requests r
  LEFT JOIN public.profiles p ON p.id = CASE WHEN r.to_id = auth.uid() THEN r.from_id ELSE r.to_id END
  WHERE r.status = 'pending' AND r.created_at > now() - interval '30 days'
    AND (r.to_id = auth.uid() OR r.from_id = auth.uid())
  ORDER BY r.created_at DESC;
$$;

-- 4. Chat --------------------------------------------------------------------------------------

-- Sends to a friend. client_id makes it safe to send again (the app's queue without signal):
-- the same id returns the message already there
CREATE OR REPLACE FUNCTION public.send_chat_message(p_to UUID, p_kind TEXT, p_body TEXT, p_data JSONB, p_client_id UUID)
RETURNS TABLE (id UUID, created_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_body TEXT := left(public.community_clean(p_body), 2000);
  v_lim RECORD;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  RETURN QUERY SELECT c.id, c.created_at FROM public.chat_messages c WHERE c.sender_id = v_me AND c.client_id = p_client_id;
  IF FOUND THEN RETURN; END IF;
  IF NOT public.are_friends(v_me, p_to) THEN RAISE EXCEPTION 'You can only message your friends'; END IF;
  SELECT * INTO v_lim FROM public.friends_limits(v_me);
  IF p_kind = 'text' THEN
    IF v_body IS NULL THEN RAISE EXCEPTION 'Write a message'; END IF;
  ELSIF p_kind = 'location' THEN
    IF p_data IS NULL OR jsonb_typeof(p_data->'lat') <> 'number' OR jsonb_typeof(p_data->'lng') <> 'number'
       OR abs((p_data->>'lat')::float8) > 90 OR abs((p_data->>'lng')::float8) > 180 THEN
      RAISE EXCEPTION 'The location is not valid';
    END IF;
  ELSIF p_kind = 'attachment' THEN
    IF NOT v_lim.attach THEN RAISE EXCEPTION 'Sending map data is for Pro and Enterprise accounts'; END IF;
    IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' OR NOT (p_data ? 'kind') THEN
      RAISE EXCEPTION 'The map data is not valid';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unknown kind of message';
  END IF;
  IF v_lim.messages IS NOT NULL AND (SELECT count(*) FROM public.chat_messages c
      WHERE c.sender_id = v_me AND c.created_at > now() - interval '1 day') >= v_lim.messages THEN
    RAISE EXCEPTION 'You can send up to % messages a day', v_lim.messages;
  END IF;
  RETURN QUERY
  INSERT INTO public.chat_messages AS c (sender_id, recipient_id, kind, body, data, client_id)
  VALUES (v_me, p_to, p_kind, v_body, CASE WHEN p_kind = 'text' THEN NULL ELSE p_data END, p_client_id)
  RETURNING c.id, c.created_at;
END;
$$;

-- The chat with a friend (or a former friend), newest first. p_since: only what changed after it
-- (new, read or deleted; for an open chat), else a page before p_before (30 at a time)
CREATE OR REPLACE FUNCTION public.chat_messages(p_with UUID, p_before TIMESTAMPTZ DEFAULT NULL, p_since TIMESTAMPTZ DEFAULT NULL)
RETURNS TABLE (
  id UUID, from_me BOOLEAN, kind TEXT, body TEXT, data JSONB, client_id UUID,
  created_at TIMESTAMPTZ, read_at TIMESTAMPTZ, deleted BOOLEAN, updated_at TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT c.id, c.sender_id = auth.uid(), c.kind,
         CASE WHEN c.deleted_at IS NULL THEN c.body END,
         CASE WHEN c.deleted_at IS NULL THEN c.data END,
         CASE WHEN c.sender_id = auth.uid() THEN c.client_id END,
         c.created_at, c.read_at, c.deleted_at IS NOT NULL, c.updated_at
  FROM public.chat_messages c
  WHERE auth.uid() IS NOT NULL
    AND LEAST(c.sender_id, c.recipient_id) = LEAST(auth.uid(), p_with)
    AND GREATEST(c.sender_id, c.recipient_id) = GREATEST(auth.uid(), p_with)
    AND (p_since IS NULL OR c.updated_at > p_since)
    AND (p_before IS NULL OR c.created_at < p_before)
  ORDER BY c.created_at DESC
  LIMIT CASE WHEN p_since IS NULL THEN 30 ELSE 500 END;
$$;

-- Opened the chat: the friend's messages are read
CREATE OR REPLACE FUNCTION public.mark_chat_read(p_with UUID)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  UPDATE public.chat_messages SET read_at = now(), updated_at = now()
  WHERE sender_id = p_with AND recipient_id = auth.uid() AND read_at IS NULL;
$$;

-- The sender takes a message back within an hour ("Message deleted")
CREATE OR REPLACE FUNCTION public.delete_chat_message(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.chat_messages WHERE id = p_id AND sender_id = auth.uid()) THEN
    RAISE EXCEPTION 'You can only delete your own messages';
  END IF;
  UPDATE public.chat_messages SET deleted_at = now(), updated_at = now(), body = NULL, data = NULL
  WHERE id = p_id AND sender_id = auth.uid() AND deleted_at IS NULL AND created_at > now() - interval '1 hour';
  IF NOT FOUND THEN RAISE EXCEPTION 'Messages can be deleted within an hour of sending'; END IF;
END;
$$;

-- The badge: messages to me not read yet, and open requests to me
CREATE OR REPLACE FUNCTION public.my_chat_unread()
RETURNS TABLE (messages INTEGER, requests INTEGER)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    (SELECT count(*)::INTEGER FROM public.chat_messages c
     WHERE c.recipient_id = auth.uid() AND c.read_at IS NULL AND c.deleted_at IS NULL
       AND public.are_friends(c.sender_id, auth.uid())),
    (SELECT count(*)::INTEGER FROM public.friend_requests r
     WHERE r.to_id = auth.uid() AND r.status = 'pending' AND r.created_at > now() - interval '30 days');
$$;

-- 5. Access -----------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.friends_limits(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.are_friends(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.friend_count(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.friends_connect(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.friends_request(UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.my_friend_link() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.renew_friend_link() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.friend_link_info(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.send_friend_request(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_friend_by_link(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.answer_friend_request(UUID, BOOLEAN) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_friend(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_friends() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_friend_requests() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, JSONB, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.chat_messages(UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_chat_read(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_chat_message(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_chat_unread() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.my_friend_link() TO authenticated;
GRANT EXECUTE ON FUNCTION public.renew_friend_link() TO authenticated;
-- The card of a friend link shows before signing in
GRANT EXECUTE ON FUNCTION public.friend_link_info(TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.send_friend_request(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_friend_by_link(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.answer_friend_request(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_friend(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_friends() TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_friend_requests() TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, JSONB, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chat_messages(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_chat_read(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_chat_message(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_chat_unread() TO authenticated;
