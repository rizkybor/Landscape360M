import { useEffect, useState } from "react";
import { ChevronRight, Users } from "lucide-react";
import { fetchMyClubs, photoUrl, ROLE_LABEL, type Club } from "../lib/community";
import { useCommunityStore } from "../store/useCommunityStore";

// User Account: the Community clubs of the signed-in account, with the club's logo (or its first
// letter) and the account's role. Clicking one opens it in the Community panel. Nothing shows
// when the account is in no club. Same as the app's User Account.

export const AccountClubs = ({ userId, onOpen }: { userId: string; onOpen?: () => void }) => {
  const [clubs, setClubs] = useState<Club[]>([]);

  useEffect(() => {
    let cancelled = false;
    fetchMyClubs().then(
      (c) => !cancelled && setClubs(c),
      () => undefined, // offline or no Community yet: no section
    );
    return () => {
      cancelled = true;
    };
  }, [userId]);

  if (clubs.length === 0) return null;

  const open = (id: string) => {
    const store = useCommunityStore.getState();
    store.openClub(id);
    store.setPanelOpen(true);
    onOpen?.();
  };

  return (
    <div className="mt-3 text-left" aria-label="Clubs">
      <div className="text-[10px] font-bold uppercase tracking-wider text-sand-500 mb-1.5">
        {clubs.length === 1 ? "Club" : "Clubs"}
      </div>
      <ul className="rounded-xl border border-sand-200 bg-white divide-y divide-sand-100 overflow-hidden">
        {clubs.map((c) => (
          <li key={c.id}>
            <button
              onClick={() => open(c.id)}
              className="cursor-pointer w-full flex items-center gap-2.5 px-3 py-2 text-left hover:bg-sand-50"
            >
              {c.photoPath ? (
                <img src={photoUrl(c.photoPath)} alt="" className="w-8 h-8 rounded-lg object-cover shrink-0 bg-sand-100" />
              ) : (
                <span className="w-8 h-8 rounded-lg shrink-0 flex items-center justify-center bg-forest-50 border border-forest-200 text-xs font-bold text-forest-800">
                  {c.name.trim().charAt(0).toUpperCase() || <Users size={13} />}
                </span>
              )}
              <span className="flex-1 min-w-0">
                <span className="block text-xs font-bold text-ink truncate">{c.name}</span>
                <span className="block text-[10px] text-sand-500">
                  {ROLE_LABEL[c.role]} · {c.memberCount} member{c.memberCount === 1 ? "" : "s"}
                </span>
              </span>
              <ChevronRight size={14} className="text-sand-400 shrink-0" />
            </button>
          </li>
        ))}
      </ul>
    </div>
  );
};
