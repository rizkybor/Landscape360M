-- Community Clubs: hand the club over to another leader.
--   * Only the leader (or the Landscape 360 admin) hands it over, to a member of the club.
--   * The new leader needs an Enterprise account (or is the admin) and may lead at most as many
--     clubs as Enterprise allows (5).
--   * The old leader stays in the club as an admin (pengurus).
--   * It works while the old leader is no longer Enterprise: that is how a club whose leader
--     downgraded gets a manager again.
-- The club photo stays where it is (in the old leader's folder) until the new leader changes it.
-- Requires 20261102000027 (roles). Safe to re-run.

CREATE OR REPLACE FUNCTION public.transfer_community_club(p_club_id UUID, p_user_id UUID)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_owner UUID;
  v_max INTEGER;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  -- One hand-over at a time
  SELECT owner_id INTO v_owner FROM public.community_clubs WHERE id = p_club_id FOR UPDATE;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'Club not found'; END IF;
  IF v_owner <> auth.uid() AND NOT COALESCE(public.is_admin(), false) THEN
    RAISE EXCEPTION 'Only the club leader can hand the club over';
  END IF;
  IF p_user_id = v_owner THEN RAISE EXCEPTION 'This account already leads the club'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.community_club_members WHERE club_id = p_club_id AND user_id = p_user_id) THEN
    RAISE EXCEPTION 'Choose a member of this club';
  END IF;
  SELECT l.clubs INTO v_max FROM public.community_club_limits(p_user_id) l;
  IF v_max = 0 THEN RAISE EXCEPTION 'The new leader needs an Enterprise account'; END IF;
  IF v_max IS NOT NULL AND (SELECT count(*) FROM public.community_clubs WHERE owner_id = p_user_id) >= v_max THEN
    RAISE EXCEPTION 'That account already leads % clubs, the most an Enterprise account can', v_max;
  END IF;

  UPDATE public.community_clubs SET owner_id = p_user_id, updated_at = now() WHERE id = p_club_id;
  UPDATE public.community_club_members SET role = 'admin' WHERE club_id = p_club_id AND user_id = v_owner;
  UPDATE public.community_club_members SET role = 'owner' WHERE club_id = p_club_id AND user_id = p_user_id;
  RETURN public.review_author_name(p_user_id);
END;
$$;

REVOKE ALL ON FUNCTION public.transfer_community_club(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_community_club(UUID, UUID) TO authenticated;
