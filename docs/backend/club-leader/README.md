# Club leader hand-over: changes for the web repo

The app can now hand a club over to another leader (Members tab → a member's menu →
**Make club leader**). It needs one new database function. The web can offer the same
button; that part is optional.

| File here | Copy to | What it is |
|---|---|---|
| `20261102000031_community_club_transfer.sql` | `supabase/migrations/` | `transfer_community_club(p_club_id, p_user_id)` |

## Rules (enforced by the function)

- Only the current leader (or the Landscape 360 admin) hands the club over.
- The new leader must already be a member of the club.
- The new leader needs an **Enterprise** account (or is the admin), and may lead at most
  as many clubs as Enterprise allows (5).
- The old leader stays in the club as an **admin** (pengurus).
- It works while the old leader is no longer Enterprise: that is how a club whose leader
  downgraded gets a manager again.
- Returns the new leader's name.

## 1. Database

Run the migration in the Supabase SQL editor, or with the CLI:

```sh
supabase db push
```

It only adds a function (no table changes) and is safe to re-run. Until it is applied, the
app shows the server's "function not found" error when **Make club leader** is pressed.

## 2. Web (optional): the same button

In `src/lib/community.ts`, next to `setClubRole`:

```ts
/** The leader hands the club over to a member with an Enterprise account; returns their name */
export const transferClub = async (clubId: string, userId: string): Promise<string> => {
  const { data, error } = await supabase.rpc('transfer_community_club', { p_club_id: clubId, p_user_id: userId });
  if (error) throw fail(error);
  return data as string;
};
```

In `src/components/CommunityPanel.tsx`, in the members list, after the
"Make admin / Remove admin" button (shown when `leader && m.role !== "owner"`). Note that
this button should show even when the leader can no longer manage the club:

```tsx
<button
  onClick={() => {
    if (window.confirm(`Make ${m.name} the club leader? They need an Enterprise account. You stay as an admin.`))
      act(() => transferClub(club.id, m.userId));
  }}
  disabled={busy}
  className="cursor-pointer shrink-0 px-1.5 py-0.5 rounded border border-gold-300 text-[10px] font-bold text-gold-700 hover:bg-gold-50"
  title="Hand the club over (the new leader needs Enterprise)"
>
  Make leader
</button>
```

After it succeeds, reload the clubs and members (the same refresh `act` already does).

## Club photo

The club photo stays in the old leader's storage folder. It keeps showing. When the new
leader changes the photo, the old file is not removed: storage only lets each account
delete its own folder. This leaves one orphan file per hand-over. It is harmless and can
be cleaned up by hand.
