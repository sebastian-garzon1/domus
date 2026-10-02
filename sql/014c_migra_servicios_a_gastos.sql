-- ============================================================================
-- DOMUS — Migración 014c: migra los datos de Servicios a Gastos
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- (en una pestaña NUEVA)
-- Requiere haber corrido antes sql/014a y sql/014b.
-- NO es seguro volver a ejecutar: duplicaría filas si se corre dos veces.
-- Si se corta a la mitad, avisa antes de reintentar.
-- Parte 3 de 3 — última parte de la fusión de Servicios en Gastos.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. MIGRA servicios_recurrentes -> gastos_recurrentes (mismo id)
-- ----------------------------------------------------------------------------

insert into public.gastos_recurrentes (
  id, hogar_id, descripcion, categoria, monto, metodo_pago_id, dia_mes, es_personal,
  numero_referencia, enlace_pago, activo, creado_por, created_at, updated_at
)
select
  id, hogar_id, nombre, categoria, monto, metodo_pago_id, dia_mes, false,
  numero_referencia, enlace_pago, activo, creado_por, created_at, updated_at
from public.servicios_recurrentes
on conflict (id) do nothing;

-- ----------------------------------------------------------------------------
-- 2. MIGRA servicios_pagos -> gastos (mismo id) sin re-aplicar el descuento
--    de saldo (ya se aplicó una vez cuando el pago se creó/marcó pagado
--    dentro de servicios_pagos — re-insertarlo con el trigger activo lo
--    descontaría dos veces).
-- ----------------------------------------------------------------------------

alter table public.gastos disable trigger trg_gastos_sync_metodo_pago;

insert into public.gastos (
  id, hogar_id, descripcion, categoria, monto, metodo_pago_id, fecha, estado, fecha_pago,
  pagado_por, comprobante_path, registrado_por, observaciones, numero_referencia, enlace_pago,
  es_personal, recurrente_id, created_at, updated_at
)
select
  id, hogar_id, nombre, categoria, monto, metodo_pago_id, fecha_vencimiento, estado, fecha_pago,
  pagado_por, comprobante_path, registrado_por, observaciones, numero_referencia, enlace_pago,
  false, recurrente_id, created_at, updated_at
from public.servicios_pagos
on conflict (id) do nothing;

alter table public.gastos enable trigger trg_gastos_sync_metodo_pago;

-- ----------------------------------------------------------------------------
-- 3. Re-enlaza el historial de movimientos: lo que apuntaba a un servicio
--    ahora apunta al gasto migrado con el mismo id.
-- ----------------------------------------------------------------------------

update public.metodo_pago_movimientos
set gasto_id = servicio_id, servicio_id = null
where servicio_id is not null;

-- ----------------------------------------------------------------------------
-- 4. Respaldo: renombra las tablas viejas (no se borran, por si acaso).
-- ----------------------------------------------------------------------------

alter table if exists public.servicios_pagos rename to _legacy_servicios_pagos;
alter table if exists public.servicios_recurrentes rename to _legacy_servicios_recurrentes;

-- ============================================================================
-- Fin de la migración 014c. Servicios ya quedó fusionado dentro de Gastos.
-- ============================================================================
