-- Group chat and replies (docs/FRIENDS_PRD.md §15), on top of 20261111000032_friends_chat.sql:
--   * a club chat, opened by the club leader; its members are the club's members (they come and
--     go with the club), so there is nothing to manage;
--   * a new group, made by a Pro account (or up) who adds friends of theirs, up to the limits
--     below; only its maker adds, removes, renames and deletes, members may leave;
--   * a reply to an earlier message (chat or group): the message carries the id of the one it
--     answers, and reads come with a short quote of it;
--   * deleting: the sender within an hour (as before), and the group's maker or club leader any
--     time in that group.
-- Group messages live in chat_messages too (group_id instead of recipient_id); "read" in a group
-- is per member (the last time they opened it), not per message. Safe to re-run.

-- 1. Tables ------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.chat_groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind TEXT NOT NULL CHECK (kind IN ('club', 'group')),
  -- A club chat: one per club, its members are the club's
  club_id UUID UNIQUE REFERENCES public.community_clubs(id) ON DELETE CASCADE,
  name TEXT NOT NULL CHECK (char_length(name) BETWEEN 2 AND 60),
  created_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((kind = 'club') = (club_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS chat_groups_creator_idx ON public.chat_groups (created_by);

-- Members of a new group (a club chat follows community_club_members instead)
CREATE TABLE IF NOT EXISTS public.chat_group_members (
  group_id UUID NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  added_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, user_id)
);
CREATE INDEX IF NOT EXISTS chat_group_members_user_idx ON public.chat_group_members (user_id);

-- When each member last opened a group (both kinds): what counts as unread
CREATE TABLE IF NOT EXISTS public.chat_group_reads (
  group_id UUID NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  last_read_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, user_id)
);

ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS group_id UUID REFERENCES public.chat_groups(id) ON DELETE CASCADE;
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS reply_to UUID REFERENCES public.chat_messages(id) ON DELETE SET NULL;
ALTER TABLE public.chat_messages ALTER COLUMN recipient_id DROP NOT NULL;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chat_messages_one_target') THEN
    ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_one_target CHECK ((recipient_id IS NULL) <> (group_id IS NULL));
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS chat_messages_group_idx ON public.chat_messages (group_id, created_at DESC) WHERE group_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS chat_messages_group_updated_idx ON public.chat_messages (group_id, updated_at) WHERE group_id IS NOT NULL;

ALTER TABLE public.chat_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_group_reads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.chat_groups, public.chat_group_members, public.chat_group_reads FROM anon, authenticated;

-- 2. Helpers ----------------------------------------------------------------------------------

-- Per plan: friends, messages a day, requests a day, map attachments, groups one may make, and
-- members per group. NULL: no limit (the admin); 0 groups: cannot make one (Free)
DROP FUNCTION IF EXISTS public.friends_limits(UUID);
CREATE FUNCTION public.friends_limits(p_user_id UUID)
RETURNS TABLE (friends INTEGER, messages INTEGER, requests INTEGER, attach BOOLEAN, groups INTEGER, group_members INTEGER)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 1000 WHEN p.status_subscribe = 'Pro' THEN 300 ELSE 100 END,
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 3000 WHEN p.status_subscribe = 'Pro' THEN 1000 ELSE 200 END,
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 100 WHEN p.status_subscribe = 'Pro' THEN 50 ELSE 20 END,
    COALESCE(p.is_admin, false) OR p.status_subscribe IN ('Pro', 'Enterprise'),
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 30 WHEN p.status_subscribe = 'Pro' THEN 10 ELSE 0 END,
    CASE WHEN p.is_admin THEN NULL WHEN p.status_subscribe = 'Enterprise' THEN 200 WHEN p.status_subscribe = 'Pro' THEN 50 ELSE 0 END
  FROM (SELECT 1) one
  LEFT JOIN public.profiles p ON p.id = p_user_id;
$$;

-- In the group: a club's members for a club chat, else the member rows
CREATE OR REPLACE FUNCTION public.chat_group_has(p_group UUID, p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.chat_groups g
    WHERE g.id = p_group AND (
      (g.kind = 'club' AND EXISTS (SELECT 1 FROM public.community_club_members m WHERE m.club_id = g.club_id AND m.user_id = p_user))
      OR (g.kind = 'group' AND EXISTS (SELECT 1 FROM public.chat_group_members m WHERE m.group_id = g.id AND m.user_id = p_user))
    )
  );
$$;

-- The group's maker, or the club leader for a club chat
CREATE OR REPLACE FUNCTION public.chat_group_managed_by(p_group UUID, p_user UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.chat_groups g
    LEFT JOIN public.community_clubs c ON c.id = g.club_id
    WHERE g.id = p_group AND (g.created_by = p_user OR c.owner_id = p_user)
  );
$$;

CREATE OR REPLACE FUNCTION public.chat_group_member_count(p_group UUID)
RETURNS INTEGER
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT CASE g.kind
    WHEN 'club' THEN (SELECT count(*)::INTEGER FROM public.community_club_members m WHERE m.club_id = g.club_id)
    ELSE (SELECT count(*)::INTEGER FROM public.chat_group_members m WHERE m.group_id = g.id)
  END
  FROM public.chat_groups g WHERE g.id = p_group;
$$;

-- 3. Groups -----------------------------------------------------------------------------------

-- A new group (Pro and up, within the plan's number of groups); its maker is its first member
CREATE OR REPLACE FUNCTION public.create_chat_group(p_name TEXT)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_name TEXT := left(public.community_clean(p_name), 60);
  v_max INTEGER;
  v_id UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF v_name IS NULL OR char_length(v_name) < 2 THEN RAISE EXCEPTION 'Give the group a name'; END IF;
  SELECT l.groups INTO v_max FROM public.friends_limits(v_me) l;
  IF v_max = 0 THEN RAISE EXCEPTION 'Making a group is for Pro and Enterprise accounts'; END IF;
  IF v_max IS NOT NULL AND (SELECT count(*) FROM public.chat_groups WHERE created_by = v_me AND kind = 'group') >= v_max THEN
    RAISE EXCEPTION 'You can have up to % groups', v_max;
  END IF;
  INSERT INTO public.chat_groups (kind, name, created_by) VALUES ('group', v_name, v_me) RETURNING id INTO v_id;
  INSERT INTO public.chat_group_members (group_id, user_id, added_by) VALUES (v_id, v_me, v_me);
  INSERT INTO public.chat_group_reads (group_id, user_id) VALUES (v_id, v_me);
  RETURN v_id;
END;
$$;

-- The club's chat, opened by its leader (once; opening again returns the same one)
CREATE OR REPLACE FUNCTION public.create_club_chat(p_club_id UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_id UUID;
BEGIN
  PERFORM public.community_assert_club_owner(p_club_id);
  SELECT id INTO v_id FROM public.chat_groups WHERE club_id = p_club_id;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO public.chat_groups (kind, club_id, name, created_by)
  SELECT 'club', c.id, c.name, auth.uid() FROM public.community_clubs c WHERE c.id = p_club_id
  RETURNING id INTO v_id;
  INSERT INTO public.chat_group_reads (group_id, user_id) VALUES (v_id, auth.uid()) ON CONFLICT DO NOTHING;
  RETURN v_id;
END;
$$;

-- The club chat's id for a member, or NULL when the leader has not opened one
CREATE OR REPLACE FUNCTION public.club_chat_group(p_club_id UUID)
RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT g.id FROM public.chat_groups g WHERE g.club_id = p_club_id AND public.community_is_member(p_club_id);
$$;

-- The maker adds friends of theirs (within the plan's members per group); returns how many joined
CREATE OR REPLACE FUNCTION public.add_chat_group_members(p_group UUID, p_user_ids UUID[])
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_max INTEGER;
  v_user UUID;
  v_added INTEGER := 0;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.chat_groups WHERE id = p_group AND kind = 'group' AND created_by = v_me) THEN
    RAISE EXCEPTION 'Only the maker of the group can add members';
  END IF;
  SELECT l.group_members INTO v_max FROM public.friends_limits(v_me) l;
  FOREACH v_user IN ARRAY COALESCE(p_user_ids, '{}') LOOP
    IF v_user = v_me OR EXISTS (SELECT 1 FROM public.chat_group_members WHERE group_id = p_group AND user_id = v_user) THEN
      CONTINUE;
    END IF;
    IF NOT public.are_friends(v_me, v_user) THEN RAISE EXCEPTION 'You can only add your friends to a group'; END IF;
    IF v_max IS NOT NULL AND public.chat_group_member_count(p_group) >= v_max THEN
      RAISE EXCEPTION 'A group can have up to % members', v_max;
    END IF;
    INSERT INTO public.chat_group_members (group_id, user_id, added_by) VALUES (p_group, v_user, v_me);
    INSERT INTO public.chat_group_reads (group_id, user_id) VALUES (p_group, v_user) ON CONFLICT DO NOTHING;
    v_added := v_added + 1;
  END LOOP;
  RETURN v_added;
END;
$$;

-- The maker removes a member, or a member leaves (the maker deletes the group instead)
CREATE OR REPLACE FUNCTION public.remove_chat_group_member(p_group UUID, p_user_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_maker UUID;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT created_by INTO v_maker FROM public.chat_groups WHERE id = p_group AND kind = 'group';
  IF v_maker IS NULL THEN RAISE EXCEPTION 'A club chat follows the club''s members'; END IF;
  IF p_user_id = v_maker THEN RAISE EXCEPTION 'The maker of the group can delete it, not leave it'; END IF;
  IF v_me <> v_maker AND v_me <> p_user_id THEN RAISE EXCEPTION 'Only the maker of the group can remove members'; END IF;
  DELETE FROM public.chat_group_members WHERE group_id = p_group AND user_id = p_user_id;
  DELETE FROM public.chat_group_reads WHERE group_id = p_group AND user_id = p_user_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.rename_chat_group(p_group UUID, p_name TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_name TEXT := left(public.community_clean(p_name), 60);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF v_name IS NULL OR char_length(v_name) < 2 THEN RAISE EXCEPTION 'Give the group a name'; END IF;
  UPDATE public.chat_groups SET name = v_name WHERE id = p_group AND kind = 'group' AND created_by = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Only the maker of the group can rename it'; END IF;
END;
$$;

-- The maker (or the club leader) deletes the group and every message in it
CREATE OR REPLACE FUNCTION public.delete_chat_group(p_group UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  IF NOT public.chat_group_managed_by(p_group, auth.uid()) THEN
    RAISE EXCEPTION 'Only the maker of the group or the club leader can delete it';
  END IF;
  DELETE FROM public.chat_groups WHERE id = p_group;
END;
$$;

-- My groups (club chats and new groups) with their last message and my unread count
CREATE OR REPLACE FUNCTION public.my_chat_groups()
RETURNS TABLE (
  id UUID, kind TEXT, club_id UUID, name TEXT, is_manager BOOLEAN, member_count INTEGER, created_at TIMESTAMPTZ,
  last_at TIMESTAMPTZ, last_kind TEXT, last_body TEXT, last_from_me BOOLEAN, last_sender TEXT, last_deleted BOOLEAN,
  unread INTEGER
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT g.id, g.kind, g.club_id, g.name, public.chat_group_managed_by(g.id, auth.uid()), public.chat_group_member_count(g.id),
         g.created_at,
         m.created_at, m.kind, left(m.body, 120), m.sender_id = auth.uid(), public.review_author_name(m.sender_id),
         m.deleted_at IS NOT NULL,
         (SELECT count(*)::INTEGER FROM public.chat_messages u
          WHERE u.group_id = g.id AND u.sender_id <> auth.uid() AND u.deleted_at IS NULL
            AND u.created_at > COALESCE(r.last_read_at, '-infinity'))
  FROM public.chat_groups g
  LEFT JOIN public.chat_group_reads r ON r.group_id = g.id AND r.user_id = auth.uid()
  LEFT JOIN LATERAL (
    SELECT * FROM public.chat_messages c WHERE c.group_id = g.id ORDER BY c.created_at DESC LIMIT 1
  ) m ON true
  WHERE auth.uid() IS NOT NULL AND public.chat_group_has(g.id, auth.uid())
  ORDER BY COALESCE(m.created_at, g.created_at) DESC;
$$;

-- Who is in a group (members only); is_friend lets the maker see whom they can still add elsewhere
CREATE OR REPLACE FUNCTION public.chat_group_members(p_group UUID)
RETURNS TABLE (user_id UUID, name TEXT, organization TEXT, is_manager BOOLEAN, is_me BOOLEAN, is_friend BOOLEAN, since TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  WITH who AS (
    SELECT m.user_id, m.created_at FROM public.chat_groups g
    JOIN public.community_club_members m ON g.kind = 'club' AND m.club_id = g.club_id
    WHERE g.id = p_group
    UNION ALL
    SELECT m.user_id, m.created_at FROM public.chat_groups g
    JOIN public.chat_group_members m ON g.kind = 'group' AND m.group_id = g.id
    WHERE g.id = p_group
  )
  SELECT w.user_id, public.review_author_name(w.user_id), p.organization,
         public.chat_group_managed_by(p_group, w.user_id), w.user_id = auth.uid(),
         public.are_friends(auth.uid(), w.user_id), w.created_at
  FROM who w LEFT JOIN public.profiles p ON p.id = w.user_id
  WHERE public.chat_group_has(p_group, auth.uid())
  ORDER BY public.chat_group_managed_by(p_group, w.user_id) DESC, w.created_at;
$$;

-- 4. Messages ---------------------------------------------------------------------------------

-- Writes a message to a friend (p_to) or a group (p_group): the checks of send_chat_message,
-- plus the reply must be a message of the same chat
CREATE OR REPLACE FUNCTION public.chat_send(p_to UUID, p_group UUID, p_kind TEXT, p_body TEXT, p_data JSONB, p_client_id UUID, p_reply_to UUID)
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
  IF p_group IS NOT NULL THEN
    IF NOT public.chat_group_has(p_group, v_me) THEN RAISE EXCEPTION 'You are not in this group'; END IF;
  ELSIF NOT public.are_friends(v_me, p_to) THEN
    RAISE EXCEPTION 'You can only message your friends';
  END IF;
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
  IF p_reply_to IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.chat_messages r WHERE r.id = p_reply_to AND (
      (p_group IS NOT NULL AND r.group_id = p_group)
      OR (p_group IS NULL AND r.group_id IS NULL
          AND LEAST(r.sender_id, r.recipient_id) = LEAST(v_me, p_to) AND GREATEST(r.sender_id, r.recipient_id) = GREATEST(v_me, p_to))
    )
  ) THEN
    RAISE EXCEPTION 'You can only reply to a message of this chat';
  END IF;
  IF v_lim.messages IS NOT NULL AND (SELECT count(*) FROM public.chat_messages c
      WHERE c.sender_id = v_me AND c.created_at > now() - interval '1 day') >= v_lim.messages THEN
    RAISE EXCEPTION 'You can send up to % messages a day', v_lim.messages;
  END IF;
  RETURN QUERY
  INSERT INTO public.chat_messages AS c (sender_id, recipient_id, group_id, kind, body, data, client_id, reply_to)
  VALUES (v_me, CASE WHEN p_group IS NULL THEN p_to END, p_group, p_kind, v_body,
          CASE WHEN p_kind = 'text' THEN NULL ELSE p_data END, p_client_id, p_reply_to)
  RETURNING c.id, c.created_at;
END;
$$;

DROP FUNCTION IF EXISTS public.send_chat_message(UUID, TEXT, TEXT, JSONB, UUID);
CREATE OR REPLACE FUNCTION public.send_chat_message(p_to UUID, p_kind TEXT, p_body TEXT, p_data JSONB, p_client_id UUID, p_reply_to UUID DEFAULT NULL)
RETURNS TABLE (id UUID, created_at TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT * FROM public.chat_send(p_to, NULL, p_kind, p_body, p_data, p_client_id, p_reply_to);
$$;

CREATE OR REPLACE FUNCTION public.send_group_message(p_group UUID, p_kind TEXT, p_body TEXT, p_data JSONB, p_client_id UUID, p_reply_to UUID DEFAULT NULL)
RETURNS TABLE (id UUID, created_at TIMESTAMPTZ)
LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  SELECT * FROM public.chat_send(NULL, p_group, p_kind, p_body, p_data, p_client_id, p_reply_to);
$$;

-- The chat with a friend, as before, now with a quote of the message each one replies to
DROP FUNCTION IF EXISTS public.chat_messages(UUID, TIMESTAMPTZ, TIMESTAMPTZ);
CREATE FUNCTION public.chat_messages(p_with UUID, p_before TIMESTAMPTZ DEFAULT NULL, p_since TIMESTAMPTZ DEFAULT NULL)
RETURNS TABLE (
  id UUID, from_me BOOLEAN, kind TEXT, body TEXT, data JSONB, client_id UUID,
  created_at TIMESTAMPTZ, read_at TIMESTAMPTZ, deleted BOOLEAN, updated_at TIMESTAMPTZ,
  reply_to UUID, reply_from_me BOOLEAN, reply_name TEXT, reply_kind TEXT, reply_body TEXT, reply_deleted BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT c.id, c.sender_id = auth.uid(), c.kind,
         CASE WHEN c.deleted_at IS NULL THEN c.body END,
         CASE WHEN c.deleted_at IS NULL THEN c.data END,
         CASE WHEN c.sender_id = auth.uid() THEN c.client_id END,
         c.created_at, c.read_at, c.deleted_at IS NOT NULL, c.updated_at,
         r.id, r.sender_id = auth.uid(), public.review_author_name(r.sender_id), r.kind,
         CASE WHEN r.deleted_at IS NULL THEN left(r.body, 120) END, r.deleted_at IS NOT NULL
  FROM public.chat_messages c
  LEFT JOIN public.chat_messages r ON r.id = c.reply_to
  WHERE auth.uid() IS NOT NULL AND c.group_id IS NULL
    AND LEAST(c.sender_id, c.recipient_id) = LEAST(auth.uid(), p_with)
    AND GREATEST(c.sender_id, c.recipient_id) = GREATEST(auth.uid(), p_with)
    AND (p_since IS NULL OR c.updated_at > p_since)
    AND (p_before IS NULL OR c.created_at < p_before)
  ORDER BY c.created_at DESC
  LIMIT CASE WHEN p_since IS NULL THEN 30 ELSE 500 END;
$$;

-- A group's messages (members only), newest first, with who sent each; same paging as chat_messages
CREATE OR REPLACE FUNCTION public.group_messages(p_group UUID, p_before TIMESTAMPTZ DEFAULT NULL, p_since TIMESTAMPTZ DEFAULT NULL)
RETURNS TABLE (
  id UUID, from_me BOOLEAN, sender_id UUID, sender_name TEXT, kind TEXT, body TEXT, data JSONB, client_id UUID,
  created_at TIMESTAMPTZ, deleted BOOLEAN, updated_at TIMESTAMPTZ,
  reply_to UUID, reply_from_me BOOLEAN, reply_name TEXT, reply_kind TEXT, reply_body TEXT, reply_deleted BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT c.id, c.sender_id = auth.uid(), c.sender_id, public.review_author_name(c.sender_id), c.kind,
         CASE WHEN c.deleted_at IS NULL THEN c.body END,
         CASE WHEN c.deleted_at IS NULL THEN c.data END,
         CASE WHEN c.sender_id = auth.uid() THEN c.client_id END,
         c.created_at, c.deleted_at IS NOT NULL, c.updated_at,
         r.id, r.sender_id = auth.uid(), public.review_author_name(r.sender_id), r.kind,
         CASE WHEN r.deleted_at IS NULL THEN left(r.body, 120) END, r.deleted_at IS NOT NULL
  FROM public.chat_messages c
  LEFT JOIN public.chat_messages r ON r.id = c.reply_to
  WHERE c.group_id = p_group AND public.chat_group_has(p_group, auth.uid())
    AND (p_since IS NULL OR c.updated_at > p_since)
    AND (p_before IS NULL OR c.created_at < p_before)
  ORDER BY c.created_at DESC
  LIMIT CASE WHEN p_since IS NULL THEN 30 ELSE 500 END;
$$;

-- Opened the group: everything so far is read
CREATE OR REPLACE FUNCTION public.mark_group_read(p_group UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.chat_group_has(p_group, auth.uid()) THEN RETURN; END IF;
  INSERT INTO public.chat_group_reads (group_id, user_id, last_read_at) VALUES (p_group, auth.uid(), now())
  ON CONFLICT (group_id, user_id) DO UPDATE SET last_read_at = now();
END;
$$;

-- The sender takes a message back within an hour; in a group its maker (or the club leader) any time
CREATE OR REPLACE FUNCTION public.delete_chat_message(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_me UUID := auth.uid();
  v_msg RECORD;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  SELECT sender_id, group_id, created_at, deleted_at INTO v_msg FROM public.chat_messages WHERE id = p_id;
  IF v_msg IS NULL THEN RAISE EXCEPTION 'This message is gone'; END IF;
  IF v_msg.deleted_at IS NOT NULL THEN RETURN; END IF;
  IF v_msg.group_id IS NOT NULL AND public.chat_group_managed_by(v_msg.group_id, v_me) THEN
    NULL; -- the maker tidies the group
  ELSIF v_msg.sender_id <> v_me THEN
    RAISE EXCEPTION 'You can only delete your own messages';
  ELSIF v_msg.created_at <= now() - interval '1 hour' THEN
    RAISE EXCEPTION 'Messages can be deleted within an hour of sending';
  END IF;
  UPDATE public.chat_messages SET deleted_at = now(), updated_at = now(), body = NULL, data = NULL WHERE id = p_id;
END;
$$;

-- The badge: unread in chats and groups, and open requests to me
CREATE OR REPLACE FUNCTION public.my_chat_unread()
RETURNS TABLE (messages INTEGER, requests INTEGER)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    (SELECT count(*)::INTEGER FROM public.chat_messages c
     WHERE c.recipient_id = auth.uid() AND c.read_at IS NULL AND c.deleted_at IS NULL
       AND public.are_friends(c.sender_id, auth.uid()))
    + COALESCE((SELECT sum(g.unread)::INTEGER FROM public.my_chat_groups() g), 0),
    (SELECT count(*)::INTEGER FROM public.friend_requests r
     WHERE r.to_id = auth.uid() AND r.status = 'pending' AND r.created_at > now() - interval '30 days');
$$;

-- my_friends: group messages are not part of a friend's chat
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
    WHERE c.group_id IS NULL
      AND LEAST(c.sender_id, c.recipient_id) = LEAST(auth.uid(), f.other)
      AND GREATEST(c.sender_id, c.recipient_id) = GREATEST(auth.uid(), f.other)
    ORDER BY c.created_at DESC LIMIT 1
  ) m ON true
  WHERE auth.uid() IS NOT NULL
  ORDER BY COALESCE(m.created_at, f.created_at) DESC;
$$;

-- 5. Access -----------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.friends_limits(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chat_group_has(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chat_group_managed_by(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chat_group_member_count(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chat_send(UUID, UUID, TEXT, TEXT, JSONB, UUID, UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.create_chat_group(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_club_chat(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.club_chat_group(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.add_chat_group_members(UUID, UUID[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_chat_group_member(UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rename_chat_group(UUID, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_chat_group(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_chat_groups() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.chat_group_members(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, JSONB, UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, JSONB, UUID, UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.chat_messages(UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.group_messages(UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_group_read(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_chat_message(UUID) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_chat_unread() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.my_friends() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_chat_group(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_club_chat(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.club_chat_group(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_chat_group_members(UUID, UUID[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.remove_chat_group_member(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rename_chat_group(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_chat_group(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_chat_groups() TO authenticated;
GRANT EXECUTE ON FUNCTION public.chat_group_members(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_chat_message(UUID, TEXT, TEXT, JSONB, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.send_group_message(UUID, TEXT, TEXT, JSONB, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chat_messages(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.group_messages(UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_group_read(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_chat_message(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_chat_unread() TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_friends() TO authenticated;
