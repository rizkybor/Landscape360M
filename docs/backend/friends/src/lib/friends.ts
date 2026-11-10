import { supabase } from './supabaseClient';
import type { Attachment } from './community';
import { SITE } from './community';

// Friends & Chat (docs/FRIENDS_PRD.md in the app repo; 20261111000032_friends_chat.sql): friends
// added by email or by a personal link / QR (/?friend=<token>), requests, and one-to-one chat that
// is not real time. A message is text, my location (one fix), or a copy of a map item (Pro and up).

const MISSING = /PGRST202|PGRST205|42P01|could not find the (function|table)|relation .* does not exist/i;
const fail = (error: { message: string; code?: string }) =>
  new Error(
    MISSING.test(`${error.code ?? ''} ${error.message}`) ? 'Friends is not set up yet (run the 20261111000032 migration)' : error.message,
  );

type Row = Record<string, unknown>;
const time = (v: unknown) => Date.parse(String(v ?? ''));

export const CHAT_BODY_MAX = 2000;
export const CHAT_REFRESH_MS = 15_000;
export const FRIENDS_REFRESH_MS = 30_000;
export const CHAT_DELETE_WINDOW_MS = 60 * 60 * 1000;

export type ChatKind = 'text' | 'location' | 'attachment';

export interface Friend {
  userId: string;
  name: string;
  organization: string | null;
  since: number;
  lastAt: number | null;
  lastKind: ChatKind | null;
  lastBody: string | null;
  lastFromMe: boolean;
  lastDeleted: boolean;
  unread: number;
}

export interface FriendRequest {
  id: string;
  direction: 'in' | 'out';
  userId: string;
  name: string;
  organization: string | null;
  createdAt: number;
}

export interface ChatLocation {
  lat: number;
  lng: number;
  accuracy?: number;
  elevation?: number;
}

export interface ChatMessage {
  id: string;
  fromMe: boolean;
  kind: ChatKind;
  body: string | null;
  data: Record<string, unknown> | null;
  createdAt: number;
  readAt: number | null;
  deleted: boolean;
  updatedAt: number;
}

/** The last message in one line, as in a chat list ("You: Location") */
export const friendPreview = (f: Friend): string | null => {
  if (!f.lastKind) return null;
  const what = f.lastDeleted
    ? 'Message deleted'
    : f.lastKind === 'text'
      ? (f.lastBody ?? '').replace(/\n/g, ' ')
      : f.lastKind === 'location'
        ? 'Location'
        : 'Map data';
  return f.lastFromMe ? `You: ${what}` : what;
};

export const friendLinkUrl = (token: string, base = SITE) => `${base}/?friend=${token}`;

/** The friend token in "?friend=", or null */
export const parseFriendParam = (search: string): string | null => {
  const t = new URLSearchParams(search).get('friend');
  return t && /^[0-9a-f]{32}$/.test(t) ? t : null;
};

/** Newest first; a newer copy of the same message (read, deleted) replaces it */
export const mergeMessages = (current: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] => {
  const byId = new Map(current.map((m) => [m.id, m]));
  for (const m of incoming) byId.set(m.id, m);
  return [...byId.values()].sort((a, b) => b.createdAt - a.createdAt);
};

const toFriend = (r: Row): Friend => ({
  userId: r.user_id as string,
  name: (r.name as string) ?? '',
  organization: ((r.organization as string | null) ?? '').trim() || null,
  since: time(r.since),
  lastAt: r.last_at ? time(r.last_at) : null,
  lastKind: (r.last_kind as ChatKind | null) ?? null,
  lastBody: (r.last_body as string | null) ?? null,
  lastFromMe: r.last_from_me === true,
  lastDeleted: r.last_deleted === true,
  unread: Number(r.unread ?? 0),
});

const toMessage = (r: Row): ChatMessage => ({
  id: r.id as string,
  fromMe: r.from_me === true,
  kind: r.kind as ChatKind,
  body: (r.body as string | null) ?? null,
  data: (r.data as Record<string, unknown> | null) ?? null,
  createdAt: time(r.created_at),
  readAt: r.read_at ? time(r.read_at) : null,
  deleted: r.deleted === true,
  updatedAt: time(r.updated_at),
});

export const fetchFriends = async (): Promise<Friend[]> => {
  const { data, error } = await supabase.rpc('my_friends');
  if (error) throw fail(error);
  return ((data ?? []) as Row[]).map(toFriend);
};

export const fetchFriendRequests = async (): Promise<FriendRequest[]> => {
  const { data, error } = await supabase.rpc('my_friend_requests');
  if (error) throw fail(error);
  return ((data ?? []) as Row[]).map((r) => ({
    id: r.id as string,
    direction: r.direction === 'in' ? 'in' : 'out',
    userId: r.user_id as string,
    name: (r.name as string) ?? '',
    organization: ((r.organization as string | null) ?? '').trim() || null,
    createdAt: time(r.created_at),
  }));
};

/** Unread messages and open requests to me (the badge) */
export const fetchChatUnread = async (): Promise<{ messages: number; requests: number }> => {
  const { data, error } = await supabase.rpc('my_chat_unread');
  if (error) throw fail(error);
  const r = ((data ?? []) as Row[])[0] ?? {};
  return { messages: Number(r.messages ?? 0), requests: Number(r.requests ?? 0) };
};

/** The same answer whether or not an account uses the email */
export const requestFriendByEmail = async (email: string) => {
  const { error } = await supabase.rpc('send_friend_request', { p_email: email.trim() });
  if (error) throw fail(error);
};

/** 'sent', or 'friends' when that made (or had made) you friends */
export const requestFriendByLink = async (token: string): Promise<'sent' | 'friends'> => {
  const { data, error } = await supabase.rpc('request_friend_by_link', { p_token: token });
  if (error) throw fail(error);
  return data === 'friends' ? 'friends' : 'sent';
};

export const fetchFriendLinkInfo = async (token: string): Promise<{ name: string; organization: string | null; isMe: boolean } | null> => {
  const { data, error } = await supabase.rpc('friend_link_info', { p_token: token });
  if (error) throw fail(error);
  const r = ((data ?? []) as Row[])[0];
  return r ? { name: (r.name as string) ?? '', organization: (r.organization as string | null) ?? null, isMe: r.is_me === true } : null;
};

export const answerFriendRequest = async (id: string, accept: boolean) => {
  const { error } = await supabase.rpc('answer_friend_request', { p_id: id, p_accept: accept });
  if (error) throw fail(error);
};

export const removeFriend = async (userId: string) => {
  const { error } = await supabase.rpc('remove_friend', { p_user_id: userId });
  if (error) throw fail(error);
};

export const fetchMyFriendLink = async (): Promise<string> => {
  const { data, error } = await supabase.rpc('my_friend_link');
  if (error) throw fail(error);
  return data as string;
};

export const renewMyFriendLink = async (): Promise<string> => {
  const { data, error } = await supabase.rpc('renew_friend_link');
  if (error) throw fail(error);
  return data as string;
};

/** A page before `before` (newest first), or with `since` only what changed after it */
export const fetchChatMessages = async (friendId: string, opts: { before?: number; since?: number } = {}): Promise<ChatMessage[]> => {
  const { data, error } = await supabase.rpc('chat_messages', {
    p_with: friendId,
    p_before: opts.before ? new Date(opts.before).toISOString() : null,
    p_since: opts.since ? new Date(opts.since).toISOString() : null,
  });
  if (error) throw fail(error);
  return ((data ?? []) as Row[]).map(toMessage);
};

export const sendChatMessage = async (
  friendId: string,
  m: { kind: 'text'; body: string } | { kind: 'location'; data: ChatLocation } | { kind: 'attachment'; data: Attachment },
) => {
  const { error } = await supabase.rpc('send_chat_message', {
    p_to: friendId,
    p_kind: m.kind,
    p_body: m.kind === 'text' ? m.body.trim() : null,
    p_data: m.kind === 'text' ? null : m.data,
    p_client_id: crypto.randomUUID(),
  });
  if (error) throw fail(error);
};

export const markChatRead = async (friendId: string) => {
  const { error } = await supabase.rpc('mark_chat_read', { p_with: friendId });
  if (error) throw fail(error);
};

export const deleteChatMessage = async (id: string) => {
  const { error } = await supabase.rpc('delete_chat_message', { p_id: id });
  if (error) throw fail(error);
};
