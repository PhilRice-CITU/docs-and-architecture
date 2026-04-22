-- ============================================================
-- Migration 001: Kiosk grading flow
-- Run this in Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- Add status, batch_name, and callback_url to results
ALTER TABLE results
    ADD COLUMN IF NOT EXISTS batch_name   TEXT,
    ADD COLUMN IF NOT EXISTS status       TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'graded', 'failed')),
    ADD COLUMN IF NOT EXISTS callback_url TEXT;

-- Add batch_number to result_images so each image is linked to its capture pair
ALTER TABLE result_images
    ADD COLUMN IF NOT EXISTS batch_number INTEGER NOT NULL DEFAULT 1;
