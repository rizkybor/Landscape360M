/**
 * The signed-in user's own account (Vercel Function).
 *
 *   DELETE /api/account   -> deletes the caller's account and everything in it
 *
 * Needed by Google Play and the App Store (an account made in the app can be deleted in the
 * app). The caller sends their Supabase access token as `Authorization: Bearer <token>`.
 * The app and the /delete-account page ask for the password again before calling this.
 *
 * Every table that holds the user's data references auth.users with ON DELETE CASCADE
 * (20261024000010_cascade_user_delete.sql), so deleting the auth user removes surveys,
 * tracks, marked locations and areas, shares and links, offline map rows, S.O.S alerts,
 * tracker logs and the profile. Files in Storage do not cascade: the custom basemaps under
 * `<user id>/` are removed first. The admin account cannot be deleted this way.
 *
 * Requires SUPABASE_SERVICE_ROLE_KEY and SUPABASE_URL (or VITE_SUPABASE_URL)
 * in the Vercel project environment variables.
 */
import { createClient, type SupabaseClient, type User } from '@supabase/supabase-js';

const BASEMAP_BUCKET = 'custom-basemaps';
const PAGE = 1000;

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const json = (body: unknown, status = 200) => Response.json(body, { status });

function getAdminClient(): SupabaseClient {
  const url = process.env.SUPABASE_URL ?? process.env.VITE_SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    throw new HttpError(500, 'Server is missing Supabase credentials');
  }
  return createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

async function caller(request: Request, supabase: SupabaseClient): Promise<User> {
  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '');
  if (!token) throw new HttpError(401, 'Missing access token');

  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, 'Invalid or expired session');
  return data.user;
}

// Every file in the user's basemap folder, page by page
async function removeBasemapFiles(supabase: SupabaseClient, userId: string) {
  const bucket = supabase.storage.from(BASEMAP_BUCKET);
  for (;;) {
    const { data, error } = await bucket.list(userId, { limit: PAGE });
    if (error) throw new HttpError(500, `Could not list your files: ${error.message}`);
    const paths = (data ?? []).filter((f) => f.name).map((f) => `${userId}/${f.name}`);
    if (paths.length === 0) return;
    const { error: removeError } = await bucket.remove(paths);
    if (removeError) throw new HttpError(500, `Could not delete your files: ${removeError.message}`);
    if (paths.length < PAGE) return;
  }
}

async function handleDelete(request: Request) {
  const supabase = getAdminClient();
  const user = await caller(request, supabase);

  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('is_admin')
    .eq('id', user.id)
    .maybeSingle();
  if (profileError) throw new HttpError(500, profileError.message);
  // There is a single admin (profiles_single_admin); deleting it would leave no one to run the service
  if (profile?.is_admin) throw new HttpError(403, 'The admin account cannot be deleted. Contact support.');

  await removeBasemapFiles(supabase, user.id);

  const { error } = await supabase.auth.admin.deleteUser(user.id);
  if (error) throw new HttpError(500, `Could not delete the account: ${error.message}`);

  return json({ ok: true });
}

export const DELETE = async (request: Request) => {
  try {
    return await handleDelete(request);
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    console.error('account error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
};
