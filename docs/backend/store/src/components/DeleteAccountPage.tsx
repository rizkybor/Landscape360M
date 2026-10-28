import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { UserX } from "lucide-react";
import type { User } from "@supabase/supabase-js";
import { LegalSection, SitePageLayout } from "./SitePageLayout";
import { supabase } from "../lib/supabaseClient";
import { authFetch } from "../lib/authFetch";

// Public page Google Play links to: how to delete a Landscape 360 account, and the
// deletion itself for a signed-in user (two steps, password asked again)

type Step = "intro" | "confirm" | "deleting" | "done";

export const DeleteAccountPage = () => {
  const [user, setUser] = useState<User | null>(null);
  const [step, setStep] = useState<Step>("intro");
  const [password, setPassword] = useState("");
  const [typed, setTyped] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => setUser(data.user ?? null));
    const { data } = supabase.auth.onAuthStateChange((_e, session) => setUser(session?.user ?? null));
    return () => data.subscription.unsubscribe();
  }, []);

  const deleteAccount = async () => {
    if (!user?.email) return;
    setError(null);
    setStep("deleting");
    try {
      // The password again, so an unlocked device alone cannot delete the account
      const { error: signInError } = await supabase.auth.signInWithPassword({ email: user.email, password });
      if (signInError) throw new Error("Your password is not correct");
      const res = await authFetch("/api/account", { method: "DELETE" });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(body.error || `Request failed (${res.status})`);
      await supabase.auth.signOut({ scope: "local" });
      setStep("done");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setStep("confirm");
    }
  };

  return (
    <SitePageLayout
      title="Delete your account"
      subtitle="Landscape 360 by Jendela Cakra Digital"
      icon={UserX}
      path="/delete-account"
      seoDescription="How to delete your Landscape 360 account and the data in it."
    >
      <div className="space-y-10">
        <LegalSection title="In the app">
          <p>
            Open <strong>User Account</strong> (the round button with your initial in the map panel), scroll down and
            tap <strong>Delete account</strong>. Confirm, then enter your password.
          </p>
        </LegalSection>

        <LegalSection title="What is deleted">
          <ul>
            <li>your account, profile, organization and phone number;</li>
            <li>your surveys, recorded tracks, marked locations and marked areas, and the links and shares made from them;</li>
            <li>your offline map list, uploaded custom basemaps, GPS tracking logs and S.O.S alerts;</li>
            <li>your sign-in history and reviews.</li>
          </ul>
          <p>
            Deletion is immediate and cannot be undone. Backups of the database are overwritten within
            30 days. Data on your phone (offline map tiles, recordings not uploaded, emergency contacts)
            is removed when you delete the account in the app, or when you uninstall the app.
          </p>
        </LegalSection>

        <LegalSection title="Delete it here">
          {step === "done" ? (
            <p className="font-bold text-ink">Your account has been deleted.</p>
          ) : !user ? (
            <p>
              <Link to="/" className="underline font-bold text-ink">Sign in on the map</Link>, then come back to this
              page. Can't sign in? Email <strong>contact@jcdigital.co.id</strong> from your account's email address
              and we will delete it within 7 days.
            </p>
          ) : step === "intro" ? (
            <div className="space-y-3">
              <p>Signed in as <strong>{user.email}</strong>.</p>
              <button
                onClick={() => setStep("confirm")}
                className="px-4 py-2 rounded-xl bg-brick-500 text-white text-sm font-bold cursor-pointer hover:bg-brick-600"
              >
                Delete my account
              </button>
            </div>
          ) : (
            <div className="space-y-3 max-w-sm">
              <p>This cannot be undone. Enter your password and type <strong>DELETE</strong> to confirm.</p>
              <input
                type="password"
                autoComplete="current-password"
                placeholder="Password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                className="w-full px-3 py-2 rounded-xl border border-sand-300 text-sm"
              />
              <input
                placeholder="Type DELETE"
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                className="w-full px-3 py-2 rounded-xl border border-sand-300 text-sm"
              />
              {error && <p className="text-brick-500 font-bold">{error}</p>}
              <div className="flex gap-2">
                <button
                  onClick={() => setStep("intro")}
                  className="px-4 py-2 rounded-xl border border-sand-300 text-sm font-bold cursor-pointer"
                >
                  Cancel
                </button>
                <button
                  disabled={step === "deleting" || !password || typed.trim() !== "DELETE"}
                  onClick={deleteAccount}
                  className="px-4 py-2 rounded-xl bg-brick-500 text-white text-sm font-bold cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  {step === "deleting" ? "Deleting…" : "Delete forever"}
                </button>
              </div>
            </div>
          )}
        </LegalSection>
      </div>
    </SitePageLayout>
  );
};
