-- ============================================================================
-- DOMUS — Migración 006: comprobante adjunto en gastos
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/003_gastos.sql y sql/004_servicios.sql
-- (reutiliza el bucket privado "comprobantes" que crea 004_servicios.sql).
-- Es seguro volver a ejecutar (usa ADD COLUMN IF NOT EXISTS).
-- ============================================================================

alter table public.gastos
  add column if not exists comprobante_path text;

-- El bucket "comprobantes" y sus políticas de Storage ya cubren cualquier
-- archivo cuya ruta empiece por "{hogar_id}/...", sin importar si es un
-- comprobante de servicios_pagos o de gastos — no hace falta política nueva.

-- ============================================================================
-- Fin de la migración 006.
-- ============================================================================
