-- ============================================================================
-- DOMUS — Migración 005: número de referencia y enlace de pago en servicios
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/004_servicios.sql.
-- Es seguro volver a ejecutar (usa ADD COLUMN IF NOT EXISTS).
-- ============================================================================

alter table public.servicios_pagos
  add column if not exists numero_referencia text,
  add column if not exists enlace_pago text;

-- Solo se acepta http(s):// — evita que alguien guarde un esquema raro
-- (p. ej. "javascript:...") que luego el frontend abriría como si fuera un
-- link normal al mostrar el botón "Pagar".
alter table public.servicios_pagos drop constraint if exists servicios_pagos_enlace_pago_valido;
alter table public.servicios_pagos add constraint servicios_pagos_enlace_pago_valido check (
  enlace_pago is null or enlace_pago ~ '^https?://'
);

-- ============================================================================
-- Fin de la migración 005.
-- ============================================================================
