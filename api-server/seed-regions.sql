-- ============================================================
-- SEED: Philippine Regions (PSA-defined, 17 regions)
-- Run once in Supabase SQL Editor after schema is applied.
-- Safe to re-run — uses ON CONFLICT DO NOTHING.
-- ============================================================

INSERT INTO regions (name, code) VALUES
  ('National Capital Region',                          'NCR'),
  ('Cordillera Administrative Region',                 'CAR'),
  ('Ilocos Region',                                    'Region I'),
  ('Cagayan Valley',                                   'Region II'),
  ('Central Luzon',                                    'Region III'),
  ('CALABARZON',                                       'Region IV-A'),
  ('MIMAROPA',                                         'Region IV-B'),
  ('Bicol Region',                                     'Region V'),
  ('Western Visayas',                                  'Region VI'),
  ('Central Visayas',                                  'Region VII'),
  ('Eastern Visayas',                                  'Region VIII'),
  ('Zamboanga Peninsula',                              'Region IX'),
  ('Northern Mindanao',                                'Region X'),
  ('Davao Region',                                     'Region XI'),
  ('SOCCSKSARGEN',                                     'Region XII'),
  ('Caraga',                                           'Region XIII'),
  ('Bangsamoro Autonomous Region in Muslim Mindanao',  'BARMM')
ON CONFLICT (code) DO NOTHING;
