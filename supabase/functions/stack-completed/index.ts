// stack-completed — Supabase Edge Function for AstroSharper telemetry.
//
// Accepts a single TelemetryEvent JSON payload, validates the shape,
// and INSERTs into public.stack_telemetry. Per-machine_uuid rate-limit
// of 60 inserts / hour to keep an accidental client loop from
// flooding the table.
//
// Privacy contract enforced server-side:
//   - The `app` field is forced to 'astrosharper' regardless of what
//     the client sends, so a misconfigured client can't pollute
//     AstroBlink's data.
//   - schema_version pinned to 1 here (also enforced client-side).
//     Future schema bumps land as a separate function path.
//
// Rate-limit: a small in-memory LRU keyed by machine_uuid + the
// current hour bucket. Resets when the function cold-starts (Supabase
// edge containers cycle every few minutes), which is acceptable for
// abuse mitigation — we don't need persistence-grade limits.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

// Per-machine_uuid hour bucket. Cleared on container recycle — that's
// fine for "stop a runaway client" semantics, not for billing-grade
// quota enforcement.
const RATE_LIMIT_PER_HOUR = 60;
const rateLimitBuckets = new Map<string, { hour: number; count: number }>();

interface TelemetryEvent {
  machineUUID: string;
  schemaVersion: number;
  event: string;
  target: string | null;
  frameCount: number;
  imageWidth: number;
  imageHeight: number;
  autoPSFSigma: number | null;
  autoAPGrid: number;
  autoAPPatch: number;
  shiftSigma: number | null;
  elapsedSec: number;
  autoNuke: boolean;
  appVersion: string;
  timestamp: string;
}

function badRequest(message: string): Response {
  return new Response(JSON.stringify({ error: message }), {
    status: 400,
    headers: corsHeaders,
  });
}

function isValidPayload(body: unknown): body is TelemetryEvent {
  if (typeof body !== "object" || body === null) return false;
  const b = body as Record<string, unknown>;
  return (
    typeof b.machineUUID === "string" && b.machineUUID.length >= 8 &&
    typeof b.schemaVersion === "number" && b.schemaVersion === 1 &&
    typeof b.event === "string" && b.event === "stack_completed" &&
    (b.target === null || typeof b.target === "string") &&
    typeof b.frameCount === "number" && b.frameCount >= 0 &&
    typeof b.imageWidth === "number" && b.imageWidth >= 0 &&
    typeof b.imageHeight === "number" && b.imageHeight >= 0 &&
    (b.autoPSFSigma === null || typeof b.autoPSFSigma === "number") &&
    typeof b.autoAPGrid === "number" &&
    typeof b.autoAPPatch === "number" &&
    (b.shiftSigma === null || typeof b.shiftSigma === "number") &&
    typeof b.elapsedSec === "number" && b.elapsedSec >= 0 &&
    typeof b.autoNuke === "boolean" &&
    typeof b.appVersion === "string" &&
    typeof b.timestamp === "string"
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
  // CORS preflight — Supabase functions are public-facing.
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return badRequest("Use POST.");
  }

  let payload: unknown;
  try {
    payload = await req.json();
  } catch (_e) {
    return badRequest("Invalid JSON body.");
  }

  if (!isValidPayload(payload)) {
    return badRequest("Payload shape mismatch — see TelemetryEvent contract.");
  }
  const event = payload as TelemetryEvent;

  if (!checkRateLimit(event.machineUUID)) {
    return new Response(
      JSON.stringify({ error: "Rate limit exceeded (60/hour per machine)." }),
      { status: 429, headers: corsHeaders }
    );
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  // Force app='astrosharper' regardless of client value — cross-app
  // pollution mitigation.
  const row = {
    app: "astrosharper",
    machine_uuid: event.machineUUID,
    schema_version: event.schemaVersion,
    event: event.event,
    target: event.target,
    frame_count: event.frameCount,
    image_width: event.imageWidth,
    image_height: event.imageHeight,
    auto_psf_sigma: event.autoPSFSigma,
    auto_ap_grid: event.autoAPGrid,
    auto_ap_patch: event.autoAPPatch,
    shift_sigma: event.shiftSigma,
    elapsed_sec: event.elapsedSec,
    auto_nuke: event.autoNuke,
    app_version: event.appVersion,
    // created_at intentionally NOT supplied — let the DB DEFAULT
    // now() so the timestamp is server-side authoritative (clients
    // with broken clocks can't backdate rows).
  };

  const { error } = await supabase
    .from("stack_telemetry")
    .insert(row);

  if (error) {
    console.error("stack_telemetry insert failed:", error);
    return new Response(
      JSON.stringify({ error: "Database error." }),
      { status: 500, headers: corsHeaders }
    );
  }

  return new Response(JSON.stringify({ ok: true }), {
    status: 201,
    headers: corsHeaders,
  });
});
