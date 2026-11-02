# Clubs in User Account: change for the web repo

The app's User Account now lists the account's Community clubs: the club's logo (or its first
letter), its name, and the account's role and the member count ("Leader · 24 members").
Tapping one opens the club. This brings the same to the web. No database change: it uses
`my_community_clubs`, which the Community panel already calls.

| File here | Copy to | What it is |
|---|---|---|
| `src/components/AccountClubs.tsx` | `src/components/` | The list; nothing shows when the account is in no club |

## Wire it in `src/components/AuthControl.tsx`

1. Import it with the other components:

   ```tsx
   import { AccountClubs } from "./AccountClubs";
   ```

2. In the User Account profile block, after the plan / status badges
   (the `<div className="flex flex-wrap md:justify-center items-center gap-1.5 mt-3">` that
   shows "`{subscriptionStatus} Plan`") and before the Edit / Sign out buttons, add:

   ```tsx
   <AccountClubs userId={currentUser.id} onOpen={() => setShowMenu(false)} />
   ```

   `onOpen` closes the account menu, so the Community panel with the club is in view.

Run `npm run lint` and `npm test` afterwards. Nothing else changes.
