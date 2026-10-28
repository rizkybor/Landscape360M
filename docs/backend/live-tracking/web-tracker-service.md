# Live tracking on private channels: changes for the web repo

The app sends live positions to the private channel `tracking-room` and listens on
`tracking-heartbeat`. The web's Team Monitor needs to join the same private channels. Do
the three steps together; until they are done, the app reports "Live tracking is not set
up on the server yet" and monitors see nobody.

## 1. Migration

Copy `20261029000020_private_live_tracking.sql` (next to this file) to
`supabase/migrations/` and apply it (`supabase db push`).

## 2. `src/services/TrackerService.ts`

Only monitor accounts join `tracking-room` now. Members share their position from the app,
so the web no longer joins as a broadcaster.

Change the condition `if (!channelRef.current) {` (around line 610) to
`if (!channelRef.current && userRole === 'monitor360' && subscriptionStatus === 'Enterprise') {`.
Do not return early, because Record Activity further down still needs the GPS. Then replace
the channel creation inside it (around line 615):

```ts
      // Private channel: the server checks is_monitor() before anyone can listen
      void supabase.realtime.setAuth();
      const channel = supabase.channel('tracking-room', {
        config: {
          private: true,
          broadcast: { self: false },
          presence: { key: user?.id || 'anon' }
        }
      });
```

The `heartbeat-request` listener on `tracking-room` (around line 646) can be removed:
members no longer hear this channel.

Replace the heartbeat request after joining (around line 672):

```ts
          // If I am a Monitor, ask everyone sharing to report now
          if (userRole === 'monitor360' && subscriptionStatus === 'Enterprise') {
              supabase
                .channel('tracking-heartbeat', { config: { private: true } })
                .httpSend('heartbeat-request', {})
                .catch(() => {});
          }
```

Admins pass `is_monitor()` too. If an admin should watch on the web, use the same check
that `is_monitor()` uses (admin or Enterprise monitor360) in place of `isMonitor` above.

## 3. Supabase dashboard

Do this last, after the migration and the web change are live: the current web monitor
still uses the public channel until then.

Realtime (left menu) > Settings, or
`https://supabase.com/dashboard/project/<project-ref>/realtime/settings`: under Channel
Restrictions, switch off **Allow public access** and save. A public channel with the
same name is a separate channel, but this stops anyone from opening a new public one with
the anon key. Check first that nothing else uses a public channel; in the web repo only
`TrackerService.ts` opens a Realtime channel.

## Checking it

1. Sign in on the web as an Enterprise monitor360 and open Team Monitor.
2. In the app, sign in as a pengguna360 on Pro or Enterprise, open Tools > GPS and start
   sharing. The member appears on the web within a few seconds.
3. Sign in to the app as a Free account: there is no Start button. A Pro or Enterprise
   member's REST broadcast with another account's token is refused (403).
