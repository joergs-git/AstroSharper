// community-thumbnail — Supabase Edge Function for AstroSharper.
//
// Accepts a multipart-form upload with two parts:
//   * "metadata" — JSON CommunityShareMetadata (machineUUID, target,
//                  frameCount, timestamp, appVersion).
//   * "thumbnail" — binary JPEG bytes (≤ 800 px on the long edge,
//                  enforced client-side; we additionally cap byte
//                  size here at 256 KB).
//
// Stores the JPEG in the `community-thumbnails` storage bucket under
// `community/<machineUUID>/<unix-ms>.jpg`, then INSERTs a pointer
// row in public.community_thumbnails. The row is returned to the
// client so it can render the upload immediately if it wants.
//
// Privacy contract enforced server-side (mirrors the telemetry endpoint):
//   * `app` forced to 'astrosharper'.
//   * No filename of the source SER, no path, no telescope/camera
//     string makes it into either the metadata row or the storage
//     path. The path is `community/<random-uuid>/<ts>.jpg` only.
//   * Per-machine_uuid hour bucket caps uploads at 10/hour to stop
//     a runaway client.

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

const MAX_THUMBNAIL_BYTES = 256 * 1024;     // 256 KB cap (800 px JPEG fits comfortably)
const RATE_LIMIT_PER_HOUR = 10;
const rateLimitBuckets = new Map<string, { hour: number; count: number }>();

interface CommunityShareMetadata {
  machineUUID: string;
  target: string | null;
  frameCount: number;
  timestamp: string;
  appVersion: string;
  elapsedSec: number | null;   // added 2026-05-03 #2 — surfaces in feed
}

function badRequest(message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status: 400,
    headers: corsHeaders,
  });
}

function isValidMetadata(obj: unknown): obj is CommunityShareMetadata {
  if (typeof obj !== "object" || obj === null) return false;
  const o = obj as Record<string, unknown>;
  return (
    typeof o.machineUUID === "string" && o.machineUUID.length >= 8 &&
    (o.target === null || typeof o.target === "string") &&
    typeof o.frameCount === "number" && o.frameCount >= 0 &&
    typeof o.timestamp === "string" &&
    typeof o.appVersion === "string" &&
    // elapsedSec accepted as number, null, or absent (old clients
    // that haven't been updated yet; the column is nullable).
    (o.elapsedSec === null ||
     o.elapsedSec === undefined ||
     typeof o.elapsedSec === "number")
  );
}

function checkRateLimit(machineUUID: string): boolean {
  const hour = Math.floor(Date.now() / (60 * 60 * 1000));
  const bucket = rateLimitBuckets.get(machineUUID);
  if (!bucket || bucket.hour !== hour) {
    rateLimitBuckets.set(machineUUID, { hour, count: 1 });
    return true;
  }
  if (bucket.count >= RATE_LIMIT_PER_HOUR) return false;
  bucket.count += 1;
  return true;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return badRequest("Use POST.");
  }

  const contentType = req.headers.get("content-type") || "";
  if (!contentType.includes("multipart/form-data")) {
    return badRequest("Expected multipart/form-data with 'metadata' + 'thumbnail' parts.");
  }

  let formData: FormData;
  try {
    formData = await req.formData();
  } catch (_e) {
    return badRequest("Could not parse multipart body.");
  }

  // Metadata part — JSON string.
  const metadataRaw = formData.get("metadata");
  if (typeof metadataRaw !== "string") {
    return badRequest("Missing 'metadata' field (expected JSON string).");
  }
  let metadata: unknown;
  try {
    metadata = JSON.parse(metadataRaw);
  } catch (_e) {
    return badRequest("'metadata' is not valid JSON.");
  }
  if (!isValidMetadata(metadata)) {
    return badRequest("'metadata' shape mismatch — see CommunityShareMetadata contract.");
  }
  const meta = metadata as CommunityShareMetadata;

  // Thumbnail part — binary File.
  const thumbnail = formData.get("thumbnail");
  if (!(thumbnail instanceof File)) {
    return badRequest("Missing 'thumbnail' field (expected JPEG file).");
  }
  if (thumbnail.size > MAX_THUMBNAIL_BYTES) {
    return badRequest(`Thumbnail too large (${thumbnail.size} bytes, max ${MAX_THUMBNAIL_BYTES}).`);
  }
  const mime = thumbnail.type;
  if (mime && !mime.startsWith("image/jpeg")) {
    return badRequest(`Expected image/jpeg, got ${mime}.`);
  }

  if (!checkRateLimit(meta.machineUUID)) {
    return new Response(
      JSON.stringify({ error: "Rate limit exceeded (10/hour per machine)." }),
      { status: 429, headers: corsHeaders }
    );
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  // Storage path: community/<machineUUID>/<unix-ms>.jpg. Random UUID
  // in the path means there's no filename leakage AND simultaneous
  // uploads from the same machine don't collide.
  const ts = Date.now();
  const storagePath = `community/${meta.machineUUID}/${ts}.jpg`;

  const bytes = new Uint8Array(await thumbnail.arrayBuffer());
  const { error: uploadError } = await supabase.storage
    .from(BUCKET)
    .upload(storagePath, bytes, {
      contentType: "image/jpeg",
      upsert: false,
    });

  if (uploadError) {
    console.error("thumbnail storage upload failed:", uploadError);
    return new Response(
      JSON.stringify({ error: "Storage upload failed." }),
      { status: 500, headers: corsHeaders }
    );
  }

  // Pointer row.
  const { data: rowData, error: insertError } = await supabase
    .from("community_thumbnails")
    .insert({
      app: "astrosharper",
      machine_uuid: meta.machineUUID,
      target: meta.target,
      frame_count: meta.frameCount,
      storage_path: storagePath,
      app_version: meta.appVersion,
      elapsed_sec: meta.elapsedSec ?? null,
      // flagged + created_at default server-side.
    })
    .select()
    .maybeSingle();

  if (insertError) {
    console.error("community_thumbnails insert failed:", insertError);
    // Best-effort cleanup of the orphaned upload — don't fail the
    // response on this either.
    await supabase.storage.from(BUCKET).remove([storagePath]);
    return new Response(
      JSON.stringify({ error: "Database error." }),
      { status: 500, headers: corsHeaders }
    );
  }

  return new Response(
    JSON.stringify({ ok: true, row: rowData }),
    { status: 201, headers: corsHeaders }
  );
});
