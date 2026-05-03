// community-feed — Supabase Edge Function for AstroSharper.
//
// Returns the latest 50 community thumbnails (max 3 per machine_uuid)
// alongside short-lived signed URLs the client can render directly.
// Powers the "Show other peoples thumbs" window.
//
// Why max-6-per-machine: one prolific contributor with hundreds of
// uploads would otherwise dominate the feed and bury everyone else.
// PARTITION BY machine_uuid + ROW_NUMBER ≤ 6 caps each contributor
// at their six most recent stacks; the outer LIMIT 50 then takes
// the most recent across all of those. Bumped from 3 → 6 on
// 2026-05-03 — users wanted to see more of each contributor's work.
//
// Why server-side signed URLs (not client-side): the storage bucket
// is private (public=false). Generating signed URLs requires the
// service-role key, which lives only on the server. The client
// receives ready-to-fetch URLs (no auth needed) with a 1-hour TTL.
//
// Request: GET ?limit=50&app=astrosharper (both optional).
// Response 200: { entries: [ { id, machineUuid, target, frameCount,
//                              elapsedSec, createdAt, signedUrl } ] }
// Response 500: { error: string }
//
// CORS open — public-read by design.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const BUCKET = "community-thumbnails";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 200;
const PER_MACHINE_CAP = 6;
const SIGNED_URL_TTL_SECONDS = 3600;

interface FeedEntry {
  id: string;
  machineUuid: string;
  target: string | null;
  frameCount: number | null;
  elapsedSec: number | null;
  createdAt: string;
  signedUrl: string;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "GET" && req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Use GET or POST." }), {
      status: 405, headers: corsHeaders,
    });
  }

  // Parse query params (works for both GET and POST since clients
  // can encode in either; POST bodies are ignored here).
  const url = new URL(req.url);
  const rawLimit = parseInt(url.searchParams.get("limit") || `${DEFAULT_LIMIT}`, 10);
  const limit = Math.max(1, Math.min(MAX_LIMIT, isNaN(rawLimit) ? DEFAULT_LIMIT : rawLimit));
  const app = url.searchParams.get("app") || "astrosharper";

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  // Window-function query: latest 3 per machine_uuid, then latest
  // `limit` across all those rows. Filtered by app + non-flagged.
  // The PostgREST RPC bridge can't easily do window functions, so
  // we use the SQL editor via supabase.rpc isn't an option — fall
  // back to .from().select() with explicit ordering and a slightly
  // larger fetch + client-side per-machine cap. With a few thousand
  // total rows this is still sub-100ms.
  const FETCH_OVERSAMPLE = 250;          // pull more than needed, cap client-side
  const { data: rows, error: queryError } = await supabase
    .from("community_thumbnails")
    .select("id, machine_uuid, target, frame_count, elapsed_sec, storage_path, created_at")
    .eq("app", app)
    .eq("flagged", false)
    .order("created_at", { ascending: false })
    .limit(FETCH_OVERSAMPLE);

  if (queryError) {
    console.error("community_thumbnails select failed:", queryError);
    return new Response(
      JSON.stringify({ error: "Database error." }),
      { status: 500, headers: corsHeaders }
    );
  }
  if (!rows) {
    return new Response(JSON.stringify({ entries: [] }), { headers: corsHeaders });
  }

  // Per-machine cap: walk the rows in order, count how many we've
  // taken per machine_uuid, skip once we hit PER_MACHINE_CAP.
  const perMachineCount = new Map<string, number>();
  const capped: typeof rows = [];
  for (const row of rows) {
    const muid = row.machine_uuid as string;
    const n = perMachineCount.get(muid) ?? 0;
    if (n >= PER_MACHINE_CAP) continue;
    perMachineCount.set(muid, n + 1);
    capped.push(row);
    if (capped.length >= limit) break;
  }

  // Generate a signed URL per row. Sequential is fine — we have at
  // most `limit` (default 50) so this is one ~50ms storage RTT.
  // Promise.all to parallelise; failures fall through with a null
  // signedUrl which the client renders as a placeholder.
  const entries: FeedEntry[] = await Promise.all(
    capped.map(async (row): Promise<FeedEntry> => {
      const { data: signed, error: signError } = await supabase.storage
        .from(BUCKET)
        .createSignedUrl(row.storage_path as string, SIGNED_URL_TTL_SECONDS);
      const signedUrl = signError || !signed?.signedUrl ? "" : signed.signedUrl;
      return {
        id: row.id as string,
        machineUuid: row.machine_uuid as string,
        target: row.target as string | null,
        frameCount: row.frame_count as number | null,
        elapsedSec: row.elapsed_sec as number | null,
        createdAt: row.created_at as string,
        signedUrl,
      };
    })
  );

  return new Response(
    JSON.stringify({ entries }),
    { status: 200, headers: corsHeaders }
  );
});
