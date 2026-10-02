-- ============================================================================
-- DOMUS — Migración 014: fusiona Servicios dentro de Gastos (hogar)
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001 a sql/013.
-- NO es seguro volver a ejecutar completa: la sección 3 (migración de datos)
-- duplicaría filas si se corre dos veces. Si por error se corta a la mitad,
-- avisa antes de reintentar.
--
-- Qué hace:
-- Servicios (servicios_pagos/servicios_recurrentes) tenía casi exactamente
-- la misma funcionalidad que Gastos (referencia, enlace de pago, comprobante,
-- recurrentes, método de pago) duplicada en dos tablas. Esta migración:
--   1. Amplía gastos/gastos_recurrentes para aceptar las categorías propias
--      de servicios (energía, agua, gas, etc.) y permitir monto vacío (los
--      recurrentes de pago variable, como un servicio público, no tienen un
--      monto fijo hasta que llega la factura).
--   2. Copia todos los servicios y sus recurrentes a gastos/gastos_recurrentes
--      (conservando el mismo id, para no romper ninguna referencia).
--   3. Re-enlaza el historial de movimientos de métodos de pago para que
--      apunte a los gastos migrados en vez de a los servicios originales.
--   4. Renombra (no borra) servicios_pagos/servicios_recurrentes como
--      respaldo — la app deja de usarlas por completo desde este punto.
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

-- El trigger de saldo debe ignorar montos nulos (no puede restar null); en la
-- práctica nunca debería dispararse con estado='pagado' y monto null gracias
-- al constraint de arriba, esto es solo una segunda capa de seguridad.
create or replace function public.sync_metodo_pago_gastos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if old.estado = 'pagado' and old.metodo_pago_id is not null and old.monto is not null then
      update public.metodos_pago set saldo = saldo + old.monto where id = old.metodo_pago_id;
      delete from public.metodo_pago_movimientos where gasto_id = old.id;
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    if new.estado = 'pagado' and new.metodo_pago_id is not null and new.monto is not null then
      update public.metodos_pago set saldo = saldo - new.monto where id = new.metodo_pago_id;
      insert into public.metodo_pago_movimientos (metodo_pago_id, usuario_id, tipo, monto, descripcion, gasto_id)
      values (new.metodo_pago_id, new.registrado_por, 'gasto', new.monto, new.descripcion, new.id);
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

-- ----------------------------------------------------------------------------
-- 1b. Asegura que servicios_pagos/servicios_recurrentes tengan todas las
--     columnas que esta migración necesita leer, sin importar si en este
--     proyecto se alcanzaron a correr sql/005 y sql/012 completas sobre
--     ellas (ADD COLUMN IF NOT EXISTS no rompe nada si ya existían).
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

-- ----------------------------------------------------------------------------
-- 2. MIGRA servicios_recurrentes -> gastos_recurrentes (mismo id)
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
-- 3. MIGRA servicios_pagos -> gastos (mismo id) sin re-aplicar el descuento
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
-- 4. Re-enlaza el historial de movimientos: lo que apuntaba a un servicio
--    ahora apunta al gasto migrado con el mismo id.
-- ----------------------------------------------------------------------------

update public.metodo_pago_movimientos
set gasto_id = servicio_id, servicio_id = null
where servicio_id is not null;

-- ----------------------------------------------------------------------------
-- 5. Respaldo: renombra las tablas viejas (no se borran, por si acaso).
-- ----------------------------------------------------------------------------

alter table if exists public.servicios_pagos rename to _legacy_servicios_pagos;
alter table if exists public.servicios_recurrentes rename to _legacy_servicios_recurrentes;

-- ============================================================================
-- Fin de la migración 014.
-- ============================================================================
