# Store compliance: changes for the web repo

Google Play and the App Store need four things from the website. The files here copy
into the web repo (`../Landscape360`) at the same paths.

| File here | Copy to | What it is |
|---|---|---|
| `api/account.ts` | `api/account.ts` | `DELETE /api/account`: deletes the caller's account |
| `src/components/DeleteAccountPage.tsx` | `src/components/` | Public page `/delete-account` (Google Play's "delete account" link) |
| `public/.well-known/apple-app-site-association` | `public/.well-known/` | iPhone opens shared links in the app |
| `public/.well-known/assetlinks.json` | `public/.well-known/` | Android opens shared links in the app |

## 1. Delete account

1. Copy `api/account.ts`. It uses the same `SUPABASE_SERVICE_ROLE_KEY` as
   `api/account-requests.ts`, so nothing new is needed in Vercel.
2. Copy `DeleteAccountPage.tsx`, then add the route in `src/App.tsx` next to `/privacy`:

   ```tsx
   import { DeleteAccountPage } from './components/DeleteAccountPage';
   ...
   <Route path="/delete-account" element={<DeleteAccountPage />} />
   ```

3. Add `/delete-account` to `public/sitemap.xml` and link it from the Privacy Policy
   (section 7, "have your data deleted").

The app's Delete account button calls the same endpoint. Until it is deployed, the app
shows "Request failed (404)".

## 2. Shared links open the app

1. Copy both files in `public/.well-known/`.
2. In `apple-app-site-association`, replace `APPLE_TEAM_ID` with the Team ID of the paid
   Apple Developer account (Membership page, 10 characters).
3. In `assetlinks.json`, replace `PLAY_APP_SIGNING_SHA256` with the SHA-256 of the app
   signing key (Play Console > the app > Test and release > App integrity > App signing).
   The second entry is the dev build signed with this Mac's debug key, for testing.
4. `vercel.json`: the rewrite sends every path to `index.html`, so `/.well-known/` must
   be left out, and the Apple file needs a JSON content type. Change the rewrite source to

   ```json
   "source": "/((?!api/|\\.well-known/|sitemap\\.xml|robots\\.txt|manifest\\.webmanifest|sw\\.js|workbox-.*\\.js|assets|favicon\\.ico).*)",
   ```

   and add to `headers`:

   ```json
   {
     "source": "/.well-known/apple-app-site-association",
     "headers": [{ "key": "Content-Type", "value": "application/json" }]
   }
   ```

5. Check after deploying:
   - `curl -I https://landscape360.jcdigital.co.id/.well-known/apple-app-site-association`
     answers 200 with `content-type: application/json`, without redirects
   - `curl https://landscape360.jcdigital.co.id/.well-known/assetlinks.json` shows the JSON
   - Google's checker: https://developers.google.com/digital-asset-links/tools/generator

The app side is ready. Android verifies the domain itself. On iOS the Associated Domains
entitlement is set for Release builds only, because the free personal team cannot sign
it; it works once the paid account signs the App Store build.

## 3. Privacy Policy (`src/components/PrivacyPage.tsx`)

The app does things the web does not, so the policy must say so (App Store 5.1.1, Play
Data safety). Change:

- Section 2, the sentence "We do not collect your location in the background" →
  "The mobile app uses your location in the background only while you record a track,
  share your position with GPS Tracking or send an S.O.S; a notification (Android) or the
  blue location indicator (iPhone) shows while it does."
- Section 2, add: "**S.O.S:** when you send an S.O.S, your position, battery level and
  messages go to the admin. Your emergency contacts stay on your phone."
- Section 3, "to show ads through our advertising partner" → add "(website only; the
  mobile app has no ads)".
- Section 5, first item → "…deleted when you delete your account (User Account > Delete
  account in the app, or https://landscape360.jcdigital.co.id/delete-account)".
- Section 7, "have your data deleted" → link to `/delete-account`.
- Update `LEGAL_LAST_UPDATED` in `src/config.ts`.
