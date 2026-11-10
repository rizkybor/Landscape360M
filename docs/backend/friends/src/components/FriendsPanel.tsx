import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import {
  ArrowLeft,
  ArrowUp,
  Ban,
  Check,
  CheckCheck,
  Loader2,
  Lock,
  LocateFixed,
  Map as MapIcon,
  MessageCircle,
  MessagesSquare,
  PlusCircle,
  QrCode,
  RefreshCw,
  Route,
  Share2,
  Trash2,
  UserPlus,
  Users,
  X,
} from "lucide-react";
import QRCode from "qrcode";
import type { Attachment } from "../lib/community";
import {
  answerFriendRequest,
  CHAT_BODY_MAX,
  CHAT_DELETE_WINDOW_MS,
  CHAT_REFRESH_MS,
  deleteChatMessage,
  fetchChatMessages,
  fetchChatUnread,
  fetchFriendLinkInfo,
  fetchFriendRequests,
  fetchFriends,
  fetchMyFriendLink,
  FRIENDS_REFRESH_MS,
  friendLinkUrl,
  markChatRead,
  mergeMessages,
  parseFriendParam,
  removeFriend,
  renewMyFriendLink,
  requestFriendByEmail,
  requestFriendByLink,
  sendChatMessage,
  type ChatLocation,
  type ChatMessage,
  type Friend,
  type FriendRequest,
} from "../lib/friends";
import { useCommunityStore } from "../store/useCommunityStore";
import { useMapStore } from "../store/useMapStore";
import { useSurveyStore } from "../store/useSurveyStore";

// Friends & Chat on the web (the app has the same): the Friends button in User Account with the
// unread badge; the panel with a bottom bar (Chats, Friends with requests, My QR, Add friend); one
// chat (read again every 15 s while open; text and my location; map data from the app shows with
// "Show on map"); and the card a friend link (/?friend=<token>) opens.

const pill = "cursor-pointer px-3 py-1.5 rounded-lg text-xs font-bold";
const field = "w-full rounded-lg border border-sand-200 bg-white px-3 py-2 text-sm focus:outline-none focus:border-forest-500";

// My bubbles and the send button: the logo's orange, softened (as in the app)
const PEACH = "#fce4d2";
const PEACH_LINE = "#f5cdae";
const PEACH_SUB = "#9c6b4c";
const SEND_ORANGE = "#f08a4b";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const sameDay = (a: number, b: number) => new Date(a).toDateString() === new Date(b).toDateString();
const clock = (t: number) => new Date(t).toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" });

const chatTime = (t: number) => {
  const d = new Date(t);
  const now = new Date();
  if (sameDay(t, now.getTime())) return clock(t);
  return `${d.getDate()} ${MONTHS[d.getMonth()]}${d.getFullYear() === now.getFullYear() ? "" : ` ${d.getFullYear()}`}`;
};

const dayLabel = (t: number) => {
  const now = Date.now();
  if (sameDay(t, now)) return "Today";
  if (sameDay(t, now - 86_400_000)) return "Yesterday";
  return chatTime(t);
};

const thousands = (n: number) => n.toLocaleString("en-US");

// A friend's first letter on a soft colour picked from their name (the same colour as in the app)
const PALETTE: [string, string][] = [
  ["var(--color-forest-100)", "var(--color-forest-800)"],
  ["var(--color-gold-100)", "var(--color-gold-700)"],
  ["#fbe3d3", "var(--color-ember-600)"],
  ["#dde7f5", "#2a5c9a"],
  ["var(--color-sand-200)", "var(--color-sand-700)"],
];

const Avatar = ({ name, size = 36 }: { name: string; size?: number }) => {
  const n = name.trim();
  const [bg, fg] = PALETTE[[...n].reduce((a, c) => a + c.charCodeAt(0), 0) % PALETTE.length];
  return (
    <span
      className="shrink-0 rounded-full font-bold flex items-center justify-center"
      style={{ width: size, height: size, fontSize: size * 0.4, background: bg, color: fg }}
    >
      {n.charAt(0).toUpperCase() || "?"}
    </span>
  );
};

/** Faint topographic lines behind the messages: a few hills drawn as wobbly rings */
const Contours = () => {
  const paths = useMemo(() => {
    const hills: [number, number, number, number][] = [
      [0.12, 0.18, 7, 0],
      [0.92, 0.55, 8, 1.7],
      [0.3, 0.95, 6, 3.1],
    ];
    const W = 420, H = 640, unit = Math.max(W, H) / 18;
    const out: string[] = [];
    for (const [cx, cy, rings, phase] of hills) {
      for (let k = 1; k <= rings; k++) {
        const base = unit * k * 0.9;
        let d = "";
        for (let i = 0; i <= 96; i++) {
          const t = (i / 96) * 2 * Math.PI;
          const r = base * (1 + 0.12 * Math.sin(3 * t + phase + k * 0.35) + 0.06 * Math.sin(5 * t - phase));
          d += `${i ? "L" : "M"}${(W * cx + Math.cos(t) * r * 1.25).toFixed(1)} ${(H * cy + Math.sin(t) * r).toFixed(1)}`;
        }
        out.push(d + "Z");
      }
    }
    return out;
  }, []);
  return (
    <svg className="pointer-events-none absolute inset-0 w-full h-full" viewBox="0 0 420 640" preserveAspectRatio="xMidYMid slice" aria-hidden>
      {paths.map((d, i) => (
        <path key={i} d={d} fill="none" stroke="var(--color-sand-300)" strokeOpacity={0.35} strokeWidth={0.8} />
      ))}
    </svg>
  );
};

/** Shows a location or a map item from a chat on the map */
const showOnMap = (item: Attachment) => {
  useCommunityStore.getState().setShownItem(item);
  const g = "geometry" in item ? item.geometry : null;
  if (g?.type === "Point") useMapStore.getState().triggerFlyTo({ center: g.coordinates, zoom: 15 });
  else if (g?.type === "LineString" && g.coordinates.length) useMapStore.getState().triggerFlyTo({ center: g.coordinates[0], zoom: 13 });
  else if (g?.type === "Polygon" && g.coordinates[0]?.length) useMapStore.getState().triggerFlyTo({ center: g.coordinates[0][0], zoom: 13 });
};

// --- The button in User Account ------------------------------------------------------------------

export const FriendsButton = ({ onOpen }: { onOpen?: () => void }) => {
  const user = useSurveyStore((s) => s.user);
  const [open, setOpen] = useState(false);
  const [unread, setUnread] = useState(0);

  const refresh = useCallback(() => {
    fetchChatUnread().then(
      (u) => setUnread(u.messages + u.requests),
      () => undefined,
    );
  }, []);

  useEffect(() => {
    if (!user) return;
    refresh();
    // Back to the tab: new messages and requests
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [user, refresh]);

  if (!user) return null;
  return (
    <>
      <button
        onClick={() => {
          setOpen(true);
          onOpen?.();
        }}
        className="cursor-pointer w-full flex items-center gap-2 px-3 py-2 rounded-lg border border-sand-200 bg-white hover:bg-sand-50 text-sm font-bold text-ink"
      >
        <Users size={15} className="text-forest-700" />
        <span className="flex-1 text-left">Friends</span>
        {unread > 0 && <span className="min-w-5 px-1.5 rounded-full bg-ember-500 text-white text-[11px] text-center">{unread > 99 ? "99+" : unread}</span>}
      </button>
      {open && (
        <FriendsPanel
          onClose={() => {
            setOpen(false);
            refresh();
          }}
        />
      )}
    </>
  );
};

// --- The panel ----------------------------------------------------------------------------------

type View = "chats" | "friends" | "qr" | "add";

/** The bottom bar: four equal items, icon over label; the open one sits on a soft green pill */
const NavItem = ({ active, label, dot, onClick, children }: { active: boolean; label: string; dot?: boolean; onClick: () => void; children: ReactNode }) => (
  <button onClick={onClick} aria-pressed={active} className="cursor-pointer flex-1 flex flex-col items-center justify-center gap-[3px] group">
    <span
      className={`relative w-[52px] h-[30px] rounded-full flex items-center justify-center transition-colors duration-200 ${
        active ? "bg-forest-100 text-forest-800" : "text-sand-500 group-hover:bg-sand-50"
      }`}
    >
      {children}
      {dot && <span className={`absolute top-0.5 right-3 w-[9px] h-[9px] rounded-full bg-ember-500 border-[1.5px] ${active ? "border-forest-100" : "border-white"}`} />}
    </span>
    <span className={`text-[11px] ${active ? "font-bold text-forest-800" : "font-medium text-sand-500"}`}>{label}</span>
  </button>
);

export const FriendsPanel = ({ onClose }: { onClose: () => void }) => {
  const [view, setView] = useState<View>("chats");
  const [friends, setFriends] = useState<Friend[]>([]);
  const [requests, setRequests] = useState<FriendRequest[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [chat, setChat] = useState<Friend | null>(null);

  const load = useCallback(async () => {
    try {
      const [f, r] = await Promise.all([fetchFriends(), fetchFriendRequests()]);
      setFriends(f);
      setRequests(r);
      setLoaded(true);
      setError(null);
    } catch (e) {
      setError((e as Error).message);
    }
  }, []);

  useEffect(() => {
    load();
    const timer = setInterval(load, FRIENDS_REFRESH_MS);
    return () => clearInterval(timer);
  }, [load]);

  const act = async (fn: () => Promise<unknown>) => {
    setBusy(true);
    setError(null);
    try {
      await fn();
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const incoming = requests.filter((r) => r.direction === "in");
  const outgoing = requests.filter((r) => r.direction === "out");
  const chats = friends.filter((f) => f.lastAt);
  const unreadChats = chats.filter((f) => f.unread > 0).length;
  const title = { chats: "Chats", friends: "Friends", qr: "My QR code", add: "Add friend" }[view];
  const subtitle =
    view === "chats"
      ? unreadChats
        ? `${unreadChats} unread ${unreadChats === 1 ? "chat" : "chats"}`
        : "All caught up"
      : view === "friends"
        ? `${friends.length} ${friends.length === 1 ? "friend" : "friends"}${incoming.length ? ` · ${incoming.length} new ${incoming.length === 1 ? "request" : "requests"}` : ""}`
        : view === "qr"
          ? "Let a friend scan it to add you"
          : "Send a request by email";
  const section = "px-1 pt-3 pb-1.5 text-[11px] font-bold uppercase tracking-wider text-sand-600";

  return (
    <div className="fixed inset-0 z-[70] flex items-end sm:items-center justify-center bg-ink/40 p-0 sm:p-4" role="dialog" aria-modal aria-label="Friends">
      <div className="w-full sm:w-[420px] h-[85vh] sm:h-[640px] bg-white rounded-t-2xl sm:rounded-2xl shadow-2xl flex flex-col text-ink overflow-hidden">
        {chat ? (
          <ChatView
            friend={chat}
            stillFriend={friends.some((f) => f.userId === chat.userId)}
            onBack={() => {
              setChat(null);
              load();
            }}
          />
        ) : (
          <>
            <div className="flex items-center gap-3 px-4 py-3 border-b border-sand-200">
              <span className="p-1 rounded-xl bg-sand-50">
                <img src="/android-chrome-192x192.png" alt="" className="w-9 h-9 rounded-lg" />
              </span>
              <span className="flex-1 min-w-0">
                <h2 className="text-xl font-extrabold leading-tight">{title}</h2>
                <span className="block text-[11.5px] text-sand-600 truncate">{subtitle}</span>
              </span>
              <button onClick={onClose} className="cursor-pointer p-1.5 rounded-lg hover:bg-sand-100 text-sand-500" aria-label="Close">
                <X size={18} />
              </button>
            </div>
            {error && <p className="px-4 pt-2 text-xs text-brick-600">{error}</p>}
            <div className="flex-1 overflow-y-auto bg-sand-50">
              {view === "chats" && (
                <div className="px-4 pb-4">
                  {chats.length === 0 ? (
                    <div className="py-12 text-center space-y-2">
                      <MessagesSquare size={32} className="mx-auto text-sand-400" />
                      <p className="text-sm font-bold">{loaded ? "No chats yet" : "Loading…"}</p>
                      {loaded && (
                        <p className="text-xs text-sand-500">
                          {friends.length ? "Open a friend in Friends to send a message." : "Add a friend by email or with your QR code, then send them a message or your location."}
                        </p>
                      )}
                    </div>
                  ) : (
                    <>
                      <p className={section}>Recent</p>
                      {chats.map((f, i) => (
                        <button
                          key={f.userId}
                          onClick={() => setChat(f)}
                          className={`cursor-pointer w-full flex items-center gap-3 px-1 py-2.5 text-left hover:bg-sand-100/60 ${i ? "border-t border-sand-200" : ""}`}
                        >
                          <Avatar name={f.name} size={38} />
                          <span className="flex-1 min-w-0">
                            <span className="flex items-center gap-2">
                              <span className={`flex-1 truncate text-sm ${f.unread ? "font-extrabold" : "font-semibold"}`}>{f.name}</span>
                              <span className={`text-[11px] shrink-0 ${f.unread ? "font-bold text-ember-600" : "text-sand-500"}`}>{f.lastAt ? chatTime(f.lastAt) : ""}</span>
                            </span>
                            <span className="flex items-center gap-1 mt-0.5 text-[12.5px]">
                              {f.lastFromMe && !f.lastDeleted && <span className="text-sand-500">You:</span>}
                              {f.lastDeleted ? (
                                <Ban size={13} className="text-sand-500 shrink-0" />
                              ) : f.lastKind === "location" ? (
                                <LocateFixed size={13} className={`shrink-0 ${f.unread ? "text-forest-700" : "text-sand-500"}`} />
                              ) : f.lastKind === "attachment" ? (
                                <Route size={13} className={`shrink-0 ${f.unread ? "text-forest-700" : "text-sand-500"}`} />
                              ) : null}
                              <span className={`flex-1 truncate ${f.lastDeleted ? "italic" : ""} ${f.unread ? "font-semibold text-ink" : "text-sand-600"}`}>
                                {f.lastDeleted ? "Message deleted" : f.lastKind === "text" ? (f.lastBody ?? "").replace(/\n/g, " ") : f.lastKind === "location" ? "Location" : "Map data"}
                              </span>
                              {f.unread > 0 && (
                                <span className="min-w-[18px] h-[18px] px-1 rounded-full bg-ember-500 text-white text-[10.5px] font-extrabold flex items-center justify-center">
                                  {f.unread > 99 ? "99+" : f.unread}
                                </span>
                              )}
                            </span>
                          </span>
                        </button>
                      ))}
                    </>
                  )}
                </div>
              )}
              {view === "friends" && (
                <div className="px-4 pb-4">
                  {incoming.length > 0 && <p className={section}>Requests</p>}
                  {incoming.map((r) => (
                    <div key={r.id} className="flex items-center gap-3 px-1 py-2">
                      <Avatar name={r.name} />
                      <span className="flex-1 min-w-0">
                        <span className="block text-sm font-bold truncate">{r.name}</span>
                        {r.organization && <span className="block text-xs text-sand-500 truncate">{r.organization}</span>}
                      </span>
                      <button disabled={busy} onClick={() => act(() => answerFriendRequest(r.id, false))} className="cursor-pointer p-1.5 rounded-lg hover:bg-sand-100 text-sand-500" aria-label="Decline">
                        <X size={15} />
                      </button>
                      <button disabled={busy} onClick={() => act(() => answerFriendRequest(r.id, true))} className="cursor-pointer p-1.5 rounded-lg bg-forest-800 text-white" aria-label="Accept">
                        <Check size={15} />
                      </button>
                    </div>
                  ))}
                  <p className={section}>Friends · {friends.length}</p>
                  {friends.length === 0 && loaded && <p className="px-1 py-2 text-xs text-sand-500">No friends yet. Use Add friend to send a request by email, or share your QR code.</p>}
                  {friends.map((f, i) => (
                    <div key={f.userId} className={`flex items-center gap-3 px-1 py-2 ${i ? "border-t border-sand-200" : ""}`}>
                      <button onClick={() => setChat(f)} className="cursor-pointer flex-1 min-w-0 flex items-center gap-3 text-left">
                        <Avatar name={f.name} />
                        <span className="min-w-0">
                          <span className="block text-sm font-bold truncate">{f.name}</span>
                          {f.organization && <span className="block text-xs text-sand-500 truncate">{f.organization}</span>}
                        </span>
                      </button>
                      <button onClick={() => setChat(f)} className="cursor-pointer p-1.5 rounded-lg hover:bg-sand-100 text-forest-700" aria-label={`Message ${f.name}`}>
                        <MessageCircle size={15} />
                      </button>
                      <button
                        disabled={busy}
                        onClick={() => {
                          if (window.confirm(`Remove ${f.name}? You will no longer be able to message each other. Your chat stays readable.`)) act(() => removeFriend(f.userId));
                        }}
                        className="cursor-pointer p-1.5 rounded-lg hover:bg-brick-50 text-brick-600"
                        aria-label={`Remove ${f.name}`}
                      >
                        <Trash2 size={14} />
                      </button>
                    </div>
                  ))}
                  {outgoing.length > 0 && <p className={section}>Waiting for an answer</p>}
                  {outgoing.map((r) => (
                    <div key={r.id} className="flex items-center gap-3 px-1 py-2 opacity-70">
                      <Avatar name={r.name} />
                      <span className="text-sm">{r.name}</span>
                    </div>
                  ))}
                </div>
              )}
              {view === "qr" && <MyCode />}
              {view === "add" && <AddFriend onSent={load} />}
            </div>
            <div className="bg-sand-50 px-4 pt-1.5 pb-3">
              <nav className="h-[66px] px-1.5 flex rounded-[22px] bg-white border border-sand-200 shadow-[0_4px_16px_rgba(30,60,19,.08)]" aria-label="Friends">
                <NavItem active={view === "chats"} label="Chats" dot={unreadChats > 0} onClick={() => setView("chats")}>
                  <MessageCircle size={21} />
                </NavItem>
                <NavItem active={view === "friends"} label="Friends" dot={incoming.length > 0} onClick={() => setView("friends")}>
                  <Users size={21} />
                </NavItem>
                <NavItem active={view === "qr"} label="My QR" onClick={() => setView("qr")}>
                  <QrCode size={21} />
                </NavItem>
                <NavItem active={view === "add"} label="Add friend" onClick={() => setView("add")}>
                  <UserPlus size={21} />
                </NavItem>
              </nav>
            </div>
          </>
        )}
      </div>
    </div>
  );
};

// --- Add friend (by email) and my code (QR / link) ----------------------------------------------------

const AddFriend = ({ onSent }: { onSent: () => void }) => {
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const send = async () => {
    if (!email.includes("@")) return setError("Enter the email of their Landscape 360 account.");
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      await requestFriendByEmail(email);
      // The same answer whether or not the account exists (their email stays private)
      setNote(`Request sent if a Landscape 360 account uses ${email.trim()}.`);
      setEmail("");
      onSent();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        send();
      }}
      className="p-4 space-y-2"
    >
      <p className="text-xs text-sand-600">Send a friend request to the email of their Landscape 360 account. Or show them your QR code in My QR.</p>
      <input value={email} onChange={(e) => setEmail(e.target.value)} type="email" placeholder="Their email" aria-label="Their email" className={field} />
      <button type="submit" disabled={busy} className="cursor-pointer w-full flex items-center justify-center gap-1.5 py-2 rounded-lg bg-forest-800 text-white text-sm font-bold disabled:opacity-60">
        {busy && <Loader2 size={14} className="animate-spin" />} Send request
      </button>
      {note && <p className="text-xs text-forest-700">{note}</p>}
      {error && <p className="text-xs text-brick-600">{error}</p>}
    </form>
  );
};

const MyCode = () => {
  const [token, setToken] = useState<string | null>(null);
  const [qr, setQr] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchMyFriendLink().then(setToken, (e: Error) => setError(e.message));
  }, []);
  useEffect(() => {
    if (!token) return;
    QRCode.toDataURL(friendLinkUrl(token), { margin: 1, width: 220, color: { dark: "#1e3c13", light: "#ffffff" } }).then(setQr, () => setQr(null));
  }, [token]);

  const url = token ? friendLinkUrl(token) : null;
  return (
    <div className="p-4">
      <div className="rounded-xl border border-sand-200 bg-white p-4 text-center space-y-2">
        <p className="text-[11px] text-sand-500">Friends scan it with the Landscape 360 app or their camera, or open your link.</p>
        {qr ? <img src={qr} alt="My friend QR code" className="mx-auto w-[200px] h-[200px]" /> : <Loader2 size={20} className="mx-auto animate-spin text-sand-400" />}
        <div className="flex gap-1.5 justify-center">
          <button
            disabled={!url}
            onClick={() => url && (navigator.share ? navigator.share({ text: `Add me as a friend on Landscape 360: ${url}` }).catch(() => undefined) : navigator.clipboard.writeText(url))}
            className={`${pill} bg-forest-800 text-white flex items-center gap-1`}
          >
            <Share2 size={12} /> {"share" in navigator ? "Share link" : "Copy link"}
          </button>
          <button
            disabled={!url}
            onClick={() => {
              if (window.confirm("Make a new code? Your current QR code and link stop working.")) renewMyFriendLink().then(setToken, (e: Error) => setError(e.message));
            }}
            className={`${pill} bg-sand-100 text-sand-700 flex items-center gap-1`}
          >
            <RefreshCw size={12} /> New code
          </button>
        </div>
        {error && <p className="text-xs text-brick-600">{error}</p>}
      </div>
    </div>
  );
};

// --- One chat ----------------------------------------------------------------------------------

const MapCard = ({ mine, kind, title, detail, icon, onClick }: { mine: boolean; kind: string; title: string; detail: string; icon: ReactNode; onClick: () => void }) => (
  <button onClick={onClick} className="cursor-pointer block w-full min-w-[220px] text-left rounded-[13px] overflow-hidden" style={{ background: mine ? "rgba(255,255,255,.6)" : "var(--color-sand-50)" }}>
    <span className="flex items-center gap-3 px-2.5 py-2.5">
      <span className="w-10 h-10 shrink-0 rounded-[11px] flex items-center justify-center" style={{ background: mine ? PEACH : "var(--color-forest-100)", color: mine ? "var(--color-ember-600)" : "var(--color-forest-700)" }}>
        {icon}
      </span>
      <span className="min-w-0">
        <span className="block text-[9.5px] font-bold uppercase tracking-wider" style={{ color: mine ? PEACH_SUB : "var(--color-sand-600)" }}>
          {kind}
        </span>
        <span className="block text-[13.5px] font-bold truncate">{title}</span>
        <span className="block text-[11px] truncate" style={{ color: mine ? PEACH_SUB : "var(--color-sand-600)" }}>
          {detail}
        </span>
      </span>
    </span>
    <span
      className="flex items-center justify-center gap-1.5 py-2 text-xs font-bold border-t"
      style={{ borderColor: mine ? PEACH_LINE : "var(--color-sand-200)", color: mine ? "var(--color-ember-600)" : "var(--color-forest-700)" }}
    >
      <MapIcon size={14} /> Show on map
    </span>
  </button>
);

const ChatView = ({ friend, stillFriend, onBack }: { friend: Friend; stillFriend: boolean; onBack: () => void }) => {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const since = useRef<number | null>(null);
  const bottom = useRef<HTMLDivElement>(null);

  const newest = (ms: ChatMessage[]) => ms.reduce<number | null>((t, m) => (t === null || m.updatedAt > t ? m.updatedAt : t), null);

  const load = useCallback(async () => {
    try {
      const changed = await fetchChatMessages(friend.userId, since.current ? { since: since.current } : {});
      if (changed.length === 0) return;
      const n = newest(changed);
      if (n && (!since.current || n > since.current)) since.current = n;
      setMessages((cur) => mergeMessages(cur, changed));
      if (changed.some((m) => !m.fromMe && !m.readAt)) markChatRead(friend.userId).catch(() => undefined);
    } catch (e) {
      setError((e as Error).message);
    }
  }, [friend.userId]);

  useEffect(() => {
    load();
    const timer = setInterval(load, CHAT_REFRESH_MS);
    return () => clearInterval(timer);
  }, [load]);
  useEffect(() => bottom.current?.scrollIntoView({ block: "end" }), [messages.length]);

  const send = async (m: Parameters<typeof sendChatMessage>[1]) => {
    setBusy(true);
    setError(null);
    try {
      await sendChatMessage(friend.userId, m);
      await load();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const sendLocation = () =>
    navigator.geolocation.getCurrentPosition(
      (p) => {
        const data: ChatLocation = {
          lat: +p.coords.latitude.toFixed(6),
          lng: +p.coords.longitude.toFixed(6),
          accuracy: Math.round(p.coords.accuracy),
          ...(p.coords.altitude != null ? { elevation: Math.round(p.coords.altitude) } : {}),
        };
        send({ kind: "location", data });
      },
      () => setError("Allow location in the browser to send where you are."),
      { enableHighAccuracy: true, timeout: 15000 },
    );

  const ordered = [...messages].reverse();
  const myNewest = messages.find((m) => m.fromMe);
  const since0 = new Date(friend.since);

  return (
    <>
      <div className="flex items-center gap-2.5 px-3 py-2.5 border-b border-sand-200">
        <button onClick={onBack} className="cursor-pointer p-1.5 rounded-lg hover:bg-sand-100" aria-label="Back">
          <ArrowLeft size={18} />
        </button>
        <Avatar name={friend.name} size={36} />
        <span className="flex-1 min-w-0">
          <span className="block text-[15px] font-bold truncate">{friend.name}</span>
          <span className="block text-xs text-sand-600 truncate">{friend.organization ?? "Landscape 360 friend"}</span>
        </span>
      </div>
      <div className="relative flex-1 min-h-0 bg-sand-50">
        <Contours />
        <div className="relative h-full overflow-y-auto px-3 py-3">
          {ordered.length === 0 ? (
            <div className="py-10 text-center space-y-2">
              <span className="inline-block">
                <Avatar name={friend.name} size={64} />
              </span>
              <p className="text-base font-bold">{friend.name}</p>
              <p className="text-xs text-sand-600">Say hello, or send your location. Messages arrive within about 15 seconds.</p>
            </div>
          ) : (
            <p className="flex flex-col items-center gap-1 pt-2 pb-1 text-center text-xs text-sand-500">
              <Lock size={14} />
              Friends since {since0.getDate()} {MONTHS[since0.getMonth()]} {since0.getFullYear()}
              <br />
              Only the two of you can read this chat
            </p>
          )}
          {ordered.map((m, i) => {
            const older = ordered[i - 1];
            const newDay = !older || !sameDay(older.createdAt, m.createdAt);
            const groupStart = newDay || older.fromMe !== m.fromMe;
            const mine = m.fromMe;
            const loc = !m.deleted && m.kind === "location" && m.data ? (m.data as unknown as ChatLocation) : null;
            const att = !m.deleted && m.kind === "attachment" && m.data ? (m.data as unknown as Attachment) : null;
            const card = !!(loc || att);
            const canDelete = mine && !m.deleted && Date.now() - m.createdAt < CHAT_DELETE_WINDOW_MS;
            const sub = mine ? PEACH_SUB : "var(--color-sand-500)";
            const r = "18px", tail = "5px";
            // CSS order: top-left, top-right, bottom-right, bottom-left; the tail side is tighter
            const radius = mine ? `${r} ${groupStart ? r : tail} ${tail} ${r}` : `${groupStart ? r : tail} ${r} ${r} ${tail}`;
            const read = mine && m.readAt;
            return (
              <div key={m.id}>
                {newDay && (
                  <div className="flex justify-center py-3">
                    <span className="px-3 py-1 rounded-full bg-white border border-sand-200 text-xs font-semibold text-sand-600">{dayLabel(m.createdAt)}</span>
                  </div>
                )}
                <div className={`flex ${mine ? "justify-end" : "justify-start"} ${groupStart ? "mt-2" : "mt-0.5"}`}>
                  <div
                    className={`group max-w-[78%] border shadow-[0_1px_3px_rgba(0,0,0,.05)] ${card ? "p-1.5" : "px-3 pt-[7px] pb-[5px]"}`}
                    style={{ background: mine ? PEACH : "#fff", borderColor: mine ? PEACH_LINE : "var(--color-sand-200)", borderRadius: radius }}
                  >
                    {m.deleted ? (
                      <span className="flex items-center gap-1.5 text-sm italic" style={{ color: sub }}>
                        <Ban size={14} /> Message deleted
                      </span>
                    ) : loc ? (
                      <MapCard
                        mine={mine}
                        kind="Location"
                        title={loc.elevation != null ? `${thousands(Math.round(loc.elevation))} mdpl` : "My location"}
                        detail={[`${loc.lat.toFixed(5)}, ${loc.lng.toFixed(5)}`, loc.accuracy != null ? `±${Math.round(loc.accuracy)} m` : null].filter(Boolean).join(" · ")}
                        icon={<LocateFixed size={20} />}
                        onClick={() => showOnMap({ kind: "place", name: `${friend.name}'s location`, category: "location", geometry: { type: "Point", coordinates: [loc.lng, loc.lat] } })}
                      />
                    ) : att ? (
                      <MapCard mine={mine} kind="Map data" title={att.name} detail="Track, area, location or Field Work" icon={<Route size={20} />} onClick={() => showOnMap(att)} />
                    ) : (
                      <span className="block whitespace-pre-wrap break-words text-sm leading-[1.35]">{m.body}</span>
                    )}
                    <span className={`flex items-center justify-end gap-1 text-[10px] ${card ? "px-1.5 pt-1 pb-0.5" : "pt-0.5"}`} style={{ color: sub }}>
                      {canDelete && (
                        <button
                          onClick={() => {
                            if (window.confirm("Delete this message for both of you?")) deleteChatMessage(m.id).then(load, (e: Error) => setError(e.message));
                          }}
                          className="cursor-pointer hidden group-hover:inline mr-1"
                          aria-label="Delete message"
                        >
                          <Trash2 size={11} />
                        </button>
                      )}
                      {clock(m.createdAt)}
                      {mine &&
                        (read ? (
                          <CheckCheck size={14} aria-label="Read" style={{ color: m.id === myNewest?.id ? "var(--color-ember-500)" : sub }} />
                        ) : (
                          <Check size={14} />
                        ))}
                    </span>
                  </div>
                </div>
              </div>
            );
          })}
          <div ref={bottom} />
        </div>
      </div>
      {error && <p className="px-3 pt-2 text-xs text-brick-600">{error}</p>}
      {stillFriend ? (
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (text.trim()) send({ kind: "text", body: text }).then(() => setText(""));
          }}
          className="flex items-end gap-2 p-2 border-t border-sand-200 bg-white"
        >
          <button type="button" onClick={sendLocation} disabled={busy} className="cursor-pointer w-10 h-10 shrink-0 flex items-center justify-center rounded-full hover:bg-sand-100 text-forest-700" aria-label="Send my location">
            <PlusCircle size={22} />
          </button>
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                if (text.trim()) send({ kind: "text", body: text }).then(() => setText(""));
              }
            }}
            maxLength={CHAT_BODY_MAX}
            rows={1}
            placeholder="Message"
            aria-label="Message"
            className="flex-1 resize-none rounded-[22px] border border-sand-200 bg-sand-50 px-4 py-2.5 text-sm focus:outline-none focus:border-forest-500"
          />
          <button
            type="submit"
            disabled={busy || !text.trim()}
            className="cursor-pointer w-10 h-10 shrink-0 flex items-center justify-center rounded-full text-white disabled:cursor-default"
            style={{ background: busy || !text.trim() ? "var(--color-sand-200)" : SEND_ORANGE }}
            aria-label="Send"
          >
            {busy ? <Loader2 size={18} className="animate-spin" /> : <ArrowUp size={20} />}
          </button>
        </form>
      ) : (
        <p className="p-3 text-center text-xs text-sand-500 border-t border-sand-200 bg-white">You are no longer friends, so you cannot send messages.</p>
      )}
    </>
  );
};

// --- A friend link (/?friend=<token>) --------------------------------------------------------------

const clearFriendParam = () => {
  const url = new URL(window.location.href);
  url.searchParams.delete("friend");
  window.history.replaceState(null, "", url.pathname + url.search + url.hash);
};

export const SharedFriendLink = () => {
  const [token] = useState(() => parseFriendParam(window.location.search));
  const user = useSurveyStore((s) => s.user);
  const [info, setInfo] = useState<{ name: string; organization: string | null; isMe: boolean } | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "gone" | "closed">("loading");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!token) return;
    let cancelled = false;
    fetchFriendLinkInfo(token).then(
      (i) => {
        if (cancelled) return;
        setInfo(i);
        setStatus(i ? "ready" : "gone");
      },
      () => !cancelled && setStatus("gone"),
    );
    return () => {
      cancelled = true;
    };
    // Again after signing in: "your own code" depends on who you are
  }, [token, user]);

  if (!token || status === "loading" || status === "closed") return null;
  const close = () => {
    clearFriendParam();
    setStatus("closed");
  };
  const add = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await requestFriendByLink(token);
      setResult(r === "friends" ? "You are now friends. Open Friends in User Account to chat." : "Request sent. They will see it in Friends.");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="fixed z-[70] top-3 left-1/2 -translate-x-1/2 w-[min(340px,calc(100vw-1.5rem))]" role="dialog" aria-label="Friend">
      <div className="rounded-2xl border border-sand-200 bg-white shadow-2xl p-4 space-y-3 text-ink">
        <div className="flex items-center gap-3">
          <Avatar name={info?.name ?? "?"} size={44} />
          <div className="flex-1 min-w-0">
            <p className="text-[10px] font-bold uppercase tracking-wider text-gold-700">Friend request</p>
            <h2 className="text-base font-bold truncate">{info?.name ?? "Landscape 360"}</h2>
            {info?.organization && <p className="text-[11px] text-sand-600 truncate">{info.organization}</p>}
          </div>
          <button onClick={close} className="cursor-pointer p-1 rounded-lg hover:bg-sand-100 text-sand-500" aria-label="Close">
            <X size={16} />
          </button>
        </div>
        {status === "gone" ? (
          <p className="text-xs text-brick-600">This friend link is no longer valid.</p>
        ) : result ? (
          <p className="text-xs font-bold text-forest-700">{result}</p>
        ) : info?.isMe ? (
          <p className="text-xs text-sand-600">This is your own code.</p>
        ) : user ? (
          <button onClick={add} disabled={busy} className="cursor-pointer w-full flex items-center justify-center gap-1.5 py-2 rounded-lg bg-forest-800 text-white text-sm font-bold disabled:opacity-60">
            {busy && <Loader2 size={14} className="animate-spin" />} Add friend
          </button>
        ) : (
          <p className="text-xs text-sand-700 rounded-lg bg-sand-50 border border-sand-200 p-2.5">
            Sign in first: open <strong>Sign In / Register</strong> in the Tools panel. This card stays open.
          </p>
        )}
        {error && <p className="text-xs text-brick-600">{error}</p>}
      </div>
    </div>
  );
};
