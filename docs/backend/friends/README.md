# Friends & Chat: changes for Supabase and the web repo

Friends added by email or by a personal link / QR, friend requests, and one-to-one chat between
friends that is not real time. See `docs/FRIENDS_PRD.md` for the full design. The app has it
built; it works once the migration below is applied.

| File here | Copy to | What it is |
|---|---|---|
| `20261111000032_friends_chat.sql` | `supabase/migrations/` | Tables and functions (required for app and web) |
| `src/lib/friends.ts` | `src/lib/` | Calls to the functions |
| `src/components/FriendsPanel.tsx` | `src/components/` | Friends button, panel, chat, and the `/?friend=` card |

## 1. Database (required)

Run the migration in the Supabase SQL editor, or `supabase db push`. It adds four tables
(`friend_links`, `friend_requests`, `friendships`, `chat_messages`) and the functions. The tables
have RLS on with no policies, so they are read only through the functions; each function checks
friendship, plan and daily limits. Everything is deleted with the account (`ON DELETE CASCADE`).
Safe to re-run.

Limits per plan (FRIENDS_PRD.md §7), in `friends_limits`:

| | Free | Pro | Enterprise | Admin |
|---|---|---|---|---|
| Friends | 100 | 300 | 1,000 | — |
| Messages a day | 200 | 1,000 | 3,000 | — |
| Friend requests a day | 20 | 50 | 100 | — |
| Send map data | — | ✓ | ✓ | ✓ |

Checked on Postgres 14: requests by email (same answer whether the email exists or not) and by
link, accepting, asking back makes friends at once, renewing the link, own link refused, chat only
between friends, the same client id never stored twice, HTML stripped, map data refused for Free,
read receipts, delete only own message within an hour, the daily limit, `anon` cannot read the
table, and everything gone with the account.

## 2. Web

1. Install the QR library:

   ```sh
   npm install qrcode
   npm install -D @types/qrcode
   ```

2. Copy `src/lib/friends.ts` and `src/components/FriendsPanel.tsx`.

3. In `src/components/AuthControl.tsx`, in the User Account profile block next to
   `<AccountClubs … />`, add the Friends button (it shows the unread badge and opens the panel;
   `onOpen` closes the account menu):

   ```tsx
   import { FriendsButton } from "./FriendsPanel";
   ...
   <FriendsButton onOpen={() => setShowMenu(false)} />
   ```

4. In `src/components/MapBoxContainer.tsx`, next to `<SharedJoinLink />`, add the card that a
   friend link opens:

   ```tsx
   import { SharedFriendLink } from "./FriendsPanel";
   ...
   <SharedFriendLink />
   ```

5. `npm run lint`, `npm test`, `npm run build`. Both files were checked with the repo's
   `tsc -p tsconfig.app.json` and ESLint (with `qrcode`'s types in place).

The panel matches the app: a bottom bar with Chats, Friends (an orange dot when a request is
waiting), My QR and Add friend; the logo in the header is `/android-chrome-192x192.png` from
`public/`. A chat has a faint contour background, day labels, soft orange bubbles for your own
messages with ✓ / ✓✓ (read), and map cards with **Show on map**. Enter sends, Shift+Enter makes a
new line.

On the web a chat sends text and "my location"; map data sent from the app (track, area,
location, Field Work) shows with **Show on map**. Sending map data from the web can follow later
with the Community attachment picker.

## 3. Links

`/?friend=<token>` opens the app when installed (the same verified domain as the other share
links), else the website, which shows the card from step 4.

## Before a store release (not done yet)

Block and Report a user, admin review of reports, push notifications, and the Privacy Policy /
Terms update (FRIENDS_PRD.md §5).
