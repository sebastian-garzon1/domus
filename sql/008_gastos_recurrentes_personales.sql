-- ============================================================================
-- DOMUS — Migración 008: gastos personales/hogar + gastos recurrentes
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql y sql/003_gastos.sql.
-- Es seguro volver a ejecutar (usa IF NOT EXISTS / DROP ... IF EXISTS).
--
-- Qué agrega:
-- 1. Cada gasto puede ser "personal" (solo lo ve quien lo registró) o "del
--    hogar" (lo ven todos los miembros, como hasta ahora) — es_personal.
-- 2. Un gasto puede quedar "pendiente" (con fecha de vencimiento, número de
--    referencia y enlace de pago, igual que Servicios) en vez de darse por
--    hecho/pagado de inmediato, para cubrir cuotas y pagos programados.
-- 3. Tabla gastos_recurrentes: "plantillas" (ej. cuota mensual) desde las
--    que se generan gastos pendientes cada mes con el botón "Generar
--    pendientes del mes" (generación manual, no automática por cron).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TABLA gastos_recurrentes (plantillas)
-- ----------------------------------------------------------------------------

create table if not exists public.gastos_recurrentes (
  id                uuid primary key default gen_random_uuid(),
  hogar_id          uuid not null references public.hogares(id) on delete cascade,
  descripcion       text not null check (length(trim(descripcion)) > 0),
  categoria         text not null default 'otros' check (categoria in (
                      'mercado', 'servicios', 'transporte', 'salud', 'educacion',
                      'entretenimiento', 'hogar', 'mascotas', 'otros'
                    )),
  monto             numeric(12,2) not null check (monto > 0),
  metodo_pago       text not null default 'efectivo' check (metodo_pago in (
                      'efectivo', 'tarjeta_debito', 'tarjeta_credito', 'transferencia', 'otro'
                    )),
  -- Día del mes en que vence (topado a 28 para que exista en todos los meses,
  -- incluyendo febrero).
  dia_mes           int not null check (dia_mes between 1 and 28),
  es_personal       boolean not null default false,
  numero_referencia text,
  enlace_pago       text,
  activo            boolean not null default true,
  creado_por        uuid not null references public.profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint gastos_recurrentes_enlace_pago_valido check (
    enlace_pago is null or enlace_pago ~ '^https?://'
  )
);

create index if not exists idx_gastos_recurrentes_hogar on public.gastos_recurrentes (hogar_id);

drop trigger if exists trg_gastos_recurrentes_updated_at on public.gastos_recurrentes;
create trigger trg_gastos_recurrentes_updated_at
  before update on public.gastos_recurrentes
  for each row execute function public.set_updated_at();

alter table public.gastos_recurrentes enable row level security;

drop policy if exists "gastos_recurrentes_select" on public.gastos_recurrentes;
create policy "gastos_recurrentes_select" on public.gastos_recurrentes
  for select using (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and creado_por = auth.uid())
  );

drop policy if exists "gastos_recurrentes_insert" on public.gastos_recurrentes;
create policy "gastos_recurrentes_insert" on public.gastos_recurrentes
  for insert with check (
    public.is_hogar_member(hogar_id) and creado_por = auth.uid()
  );

drop policy if exists "gastos_recurrentes_update" on public.gastos_recurrentes;
create policy "gastos_recurrentes_update" on public.gastos_recurrentes
  for update using (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and creado_por = auth.uid())
  )
  with check (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and creado_por = auth.uid())
  );

drop policy if exists "gastos_recurrentes_delete" on public.gastos_recurrentes;
create policy "gastos_recurrentes_delete" on public.gastos_recurrentes
  for delete using (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and creado_por = auth.uid())
  );

-- ----------------------------------------------------------------------------
-- 2. NUEVAS COLUMNAS en gastos
-- ----------------------------------------------------------------------------

alter table public.gastos
  add column if not exists es_personal       boolean not null default false,
  add column if not exists estado            text not null default 'pagado' check (estado in ('pendiente', 'pagado')),
  add column if not exists fecha_pago        date,
  add column if not exists pagado_por        uuid references public.profiles(id),
  add column if not exists numero_referencia text,
  add column if not exists enlace_pago       text,
  add column if not exists recurrente_id     uuid references public.gastos_recurrentes(id) on delete set null;

-- Backfill: los gastos que ya existían antes de esta migración quedaron con
-- estado = 'pagado' (el default de la columna nueva) pero fecha_pago en
-- null, porque esa columna tampoco existía. Como siempre fueron gastos "del
-- momento" (ya hechos), su fecha_pago es la misma fecha del gasto. Sin este
-- backfill, el CHECK de coherencia de abajo rechaza la migración.
update public.gastos
set fecha_pago = fecha
where estado = 'pagado' and fecha_pago is null;

-- Un gasto "pagado" siempre tiene fecha_pago; uno "pendiente" nunca (mismo
-- patrón que servicios_pagos).
alter table public.gastos drop constraint if exists gastos_pago_coherente;
alter table public.gastos add constraint gastos_pago_coherente check (
  (estado = 'pagado' and fecha_pago is not null)
  or (estado = 'pendiente' and fecha_pago is null)
);

alter table public.gastos drop constraint if exists gastos_enlace_pago_valido;
alter table public.gastos add constraint gastos_enlace_pago_valido check (
  enlace_pago is null or enlace_pago ~ '^https?://'
);

create index if not exists idx_gastos_hogar_estado on public.gastos (hogar_id, estado);

-- ----------------------------------------------------------------------------
-- 3. TRIGGER: autocompleta fecha_pago / pagado_por al cambiar estado
-- ----------------------------------------------------------------------------
-- Un gasto "del momento" (ej. el sandwich) se inserta directo en estado
-- 'pagado': fecha_pago toma la fecha que ya trae el registro (fecha en que
-- ocurrió). Un gasto que pasa de 'pendiente' a 'pagado' (ej. una cuota ya
-- generada) toma la fecha de hoy como fecha_pago, dejando "fecha" intacta
-- como su fecha de vencimiento original.

create or replace function public.handle_gasto_estado()
returns trigger
language plpgsql
as $$
begin
  if new.estado = 'pagado' and (tg_op = 'INSERT' or old.estado is distinct from 'pagado') then
    if new.fecha_pago is null then
      if tg_op = 'INSERT' then
        new.fecha_pago := coalesce(new.fecha, current_date);
      else
        new.fecha_pago := current_date;
      end if;
    end if;
    if new.pagado_por is null then
      new.pagado_por := auth.uid();
    end if;
  elsif new.estado = 'pendiente' and (tg_op = 'INSERT' or old.estado is distinct from 'pendiente') then
    new.fecha_pago := null;
    new.pagado_por := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_gastos_estado on public.gastos;
create trigger trg_gastos_estado
  before insert or update on public.gastos
  for each row execute function public.handle_gasto_estado();

-- ----------------------------------------------------------------------------
-- 4. RLS actualizada en gastos: agrega la rama "personal"
-- ----------------------------------------------------------------------------
-- El INSERT no cambia (ya exigía is_hogar_member + registrado_por = auth.uid(),
-- válido tanto para gastos personales como del hogar).

drop policy if exists "gastos_select" on public.gastos;
create policy "gastos_select" on public.gastos
  for select using (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and registrado_por = auth.uid())
  );

drop policy if exists "gastos_update" on public.gastos;
create policy "gastos_update" on public.gastos
  for update using (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and registrado_por = auth.uid())
  )
  with check (
    ((es_personal = false and public.is_hogar_member(hogar_id))
     or (es_personal = true and registrado_por = auth.uid()))
    and (pagado_por is null or pagado_por = auth.uid())
  );

drop policy if exists "gastos_delete" on public.gastos;
create policy "gastos_delete" on public.gastos
  for delete using (
    (es_personal = false and public.is_hogar_member(hogar_id))
    or (es_personal = true and registrado_por = auth.uid())
  );

-- ----------------------------------------------------------------------------
-- 5. STORAGE: comprobantes de gastos personales
-- ----------------------------------------------------------------------------
-- Los comprobantes de gastos DEL HOGAR siguen guardándose en
-- "{hogar_id}/..." (política ya creada en 004_servicios.sql, basada solo en
-- pertenencia al hogar). Un comprobante de gasto PERSONAL no debe ser
-- visible para el resto del hogar, así que usa una ruta distinta
-- "personal/{usuario_id}/..." con políticas propias, restringidas al dueño.
--
-- Ojo: las políticas "comprobantes_*" de 004_servicios.sql hacen
-- (storage.foldername(name))[1]::uuid sin condición. Postgres combina todas
-- las políticas permisivas de un mismo comando con OR, así que al subir un
-- archivo bajo "personal/..." también se evalúa esa política vieja, y castear
-- el texto "personal" a uuid lanza un error en vez de simplemente dar falso.
-- Se redefinen aquí (mismo nombre, mismo criterio) protegiendo el cast con
-- public.es_uuid(), para que ambas convenciones de ruta convivan sin chocar.

create or replace function public.es_uuid(p_texto text)
returns boolean
language plpgsql
immutable
as $$
begin
  perform p_texto::uuid;
  return true;
exception when invalid_text_representation then
  return false;
end;
$$;

drop policy if exists "comprobantes_select" on storage.objects;
create policy "comprobantes_select" on storage.objects
  for select using (
    bucket_id = 'comprobantes'
    and public.es_uuid((storage.foldername(name))[1])
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "comprobantes_insert" on storage.objects;
create policy "comprobantes_insert" on storage.objects
  for insert with check (
    bucket_id = 'comprobantes'
    and public.es_uuid((storage.foldername(name))[1])
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "comprobantes_update" on storage.objects;
create policy "comprobantes_update" on storage.objects
  for update using (
    bucket_id = 'comprobantes'
    and public.es_uuid((storage.foldername(name))[1])
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "comprobantes_delete" on storage.objects;
create policy "comprobantes_delete" on storage.objects
  for delete using (
    bucket_id = 'comprobantes'
    and public.es_uuid((storage.foldername(name))[1])
    and public.is_hogar_member((storage.foldername(name))[1]::uuid)
  );

drop policy if exists "comprobantes_personal_select" on storage.objects;
create policy "comprobantes_personal_select" on storage.objects
  for select using (
    bucket_id = 'comprobantes'
    and (storage.foldername(name))[1] = 'personal'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists "comprobantes_personal_insert" on storage.objects;
create policy "comprobantes_personal_insert" on storage.objects
  for insert with check (
    bucket_id = 'comprobantes'
    and (storage.foldername(name))[1] = 'personal'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists "comprobantes_personal_update" on storage.objects;
create policy "comprobantes_personal_update" on storage.objects
  for update using (
    bucket_id = 'comprobantes'
    and (storage.foldername(name))[1] = 'personal'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

drop policy if exists "comprobantes_personal_delete" on storage.objects;
create policy "comprobantes_personal_delete" on storage.objects
  for delete using (
    bucket_id = 'comprobantes'
    and (storage.foldername(name))[1] = 'personal'
    and (storage.foldername(name))[2] = auth.uid()::text
  );

-- ============================================================================
-- Fin de la migración 008.
-- ============================================================================
