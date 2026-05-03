-- AstroSharper community feed extension (2026-05-03 #2).
--
-- Adds the elapsed_sec column to community_thumbnails so the
-- "Community Stacks" feed window can display how long each stack
-- took on the contributor's machine. Useful both as a usability
-- signal ("I bet that 30s render is on an Intel Mac, my M2 finishes
-- in 5s") and as material for a future stack-time leaderboard view.
--
-- Idempotent — uses ADD COLUMN IF NOT EXISTS so a re-run is a
-- no-op. Old rows get NULL for elapsed_sec; the feed renders
-- "—" in the duration column for those.

BEGIN;

ALTER TABLE public.community_thumbnails
    ADD COLUMN IF NOT EXISTS elapsed_sec DOUBLE PRECISION;

COMMIT;

-- =========================================================
-- POST-MIGRATION CHECKLIST:
-- =========================================================
-- 1. Verify the column landed:
--      \d public.community_thumbnails
--    Should show elapsed_sec | double precision | nullable.
-- 2. Deploy the new edge function:
--      supabase functions deploy community-feed
-- 3. The existing community-thumbnail edge function also needs
--    re-deploy with the updated index.ts that accepts elapsed_sec
--    in the metadata payload:
--      supabase functions deploy community-thumbnail
-- 4. Smoke test from curl — see PROMPT_FOR_ASTROBLINK_REPO_FEED.md.
