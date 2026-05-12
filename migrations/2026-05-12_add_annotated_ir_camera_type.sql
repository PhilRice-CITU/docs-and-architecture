-- Migration: add annotated_ir camera type for IR-annotated images
-- Run this in Supabase SQL Editor before deploying the annotated IR feature.

ALTER TABLE result_images DROP CONSTRAINT IF EXISTS result_images_camera_type_check;
ALTER TABLE result_images ADD CONSTRAINT result_images_camera_type_check
    CHECK (camera_type IN ('noir', 'led', 'annotated', 'annotated_ir'));
