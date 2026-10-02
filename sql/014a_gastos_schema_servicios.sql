-- ============================================================================
-- DOMUS — Migración 014a: esquema para fusionar Servicios dentro de Gastos
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001 a sql/013.
-- Es seguro volver a ejecutar (usa IF EXISTS / IF NOT EXISTS en todo).
-- Parte 1 de 3 — después sigue sql/014b y luego sql/014c, cada una en su
-- propia pestaña de query nueva.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. CATEGORÍAS y MONTO opcional en gastos / gastos_recurrentes
-- ----------------------------------------------------------------------------

alter table public.gastos drop constraint if exists gastos_categoria_check;
alter table public.gastos add constraint gastos_categoria_check check (categoria in (
  'mercado', 'servicios', 'energia', 'agua', 'gas', 'internet', 'telefono',
  'arriendo', 'streaming', 'seguro', 'transporte', 'salud', 'educacion',
  'entretenimiento', 'hogar', 'mascotas', 'otros'
));

alter table public.gastos_recurrentes drop constraint if exists gastos_recurrentes_categoria_check;
alter table public.gastos_recurrentes add constraint gastos_recurrentes_categoria_check check (categoria in (
  'mercado', 'servicios', 'energia', 'agua', 'gas', 'internet', 'telefono',
  'arriendo', 'streaming', 'seguro', 'transporte', 'salud', 'educacion',
  'entretenimiento', 'hogar', 'mascotas', 'otros'
));

-- Un recurrente de monto variable (ej. un servicio público) se crea sin
-- monto; el monto real se captura al marcar el pendiente generado como
-- pagado. Un gasto "del momento" (ya pagado) siempre trae su monto, eso lo
-- sigue exigiendo el formulario, no la base de datos.
alter table public.gastos alter column monto drop not null;
alter table public.gastos drop constraint if exists gastos_monto_check;
alter table public.gastos add constraint gastos_monto_check check (monto is null or monto > 0);

-- No se puede marcar "pagado" sin saber cuánto se pagó.
alter table public.gastos drop constraint if exists gastos_pagado_monto_check;
alter table public.gastos add constraint gastos_pagado_monto_check check (estado <> 'pagado' or monto is not null);

alter table public.gastos_recurrentes alter column monto drop not null;
alter table public.gastos_recurrentes drop constraint if exists gastos_recurrentes_monto_check;
alter table public.gastos_recurrentes add constraint gastos_recurrentes_monto_check check (monto is null or monto > 0);

-- ----------------------------------------------------------------------------
-- 2. Asegura que servicios_pagos/servicios_recurrentes tengan todas las
--    columnas que la migración 014c necesita leer, sin importar si en este
--    proyecto se alcanzaron a correr sql/005 y sql/012 completas sobre
--    ellas (ADD COLUMN IF NOT EXISTS no rompe nada si ya existían).
-- ----------------------------------------------------------------------------

alter table if exists public.servicios_pagos
  add column if not exists numero_referencia text,
  add column if not exists enlace_pago text,
  add column if not exists metodo_pago_id uuid references public.metodos_pago(id) on delete set null,
  add column if not exists recurrente_id uuid;

alter table if exists public.servicios_recurrentes
  add column if not exists numero_referencia text,
  add column if not exists enlace_pago text,
  add column if not exists metodo_pago_id uuid references public.metodos_pago(id) on delete set null;

-- ============================================================================
-- Fin de la migración 014a. Sigue con sql/014b en una pestaña nueva.
-- ============================================================================
