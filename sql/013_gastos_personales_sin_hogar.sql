-- ============================================================================
-- DOMUS — Migración 013: gastos personales sin necesidad de un hogar
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001, 003, 008 y 011.
-- Es seguro volver a ejecutar (usa DROP ... IF EXISTS antes de crear).
--
-- Qué corrige: un gasto personal es del usuario, no del hogar — pero hasta
-- ahora hogar_id era NOT NULL en gastos/gastos_recurrentes, así que en la
-- práctica no se podía registrar ni ver un gasto personal sin tener antes un
-- hogar activo seleccionado (la página redirigía a "Mis hogares"). Esta
-- migración quita esa dependencia: hogar_id ahora puede ser null, pero SOLO
-- para gastos personales (un gasto del hogar sigue exigiendo hogar_id).
-- ============================================================================

alter table public.gastos alter column hogar_id drop not null;
alter table public.gastos_recurrentes alter column hogar_id drop not null;

alter table public.gastos drop constraint if exists gastos_hogar_coherente;
alter table public.gastos add constraint gastos_hogar_coherente check (
  es_personal = true or hogar_id is not null
);

alter table public.gastos_recurrentes drop constraint if exists gastos_recurrentes_hogar_coherente;
alter table public.gastos_recurrentes add constraint gastos_recurrentes_hogar_coherente check (
  es_personal = true or hogar_id is not null
);

-- El insert de gastos exigía is_hogar_member(hogar_id) sin importar
-- es_personal — con hogar_id en null eso siempre da falso (null no es igual
-- a nada), así que bloqueaba cualquier gasto personal sin hogar activo.
drop policy if exists "gastos_insert" on public.gastos;
create policy "gastos_insert" on public.gastos
  for insert with check (
    ((es_personal = false and hogar_id is not null and public.is_hogar_member(hogar_id))
      or (es_personal = true and registrado_por = auth.uid()))
    and registrado_por = auth.uid()
  );

drop policy if exists "gastos_recurrentes_insert" on public.gastos_recurrentes;
create policy "gastos_recurrentes_insert" on public.gastos_recurrentes
  for insert with check (
    ((es_personal = false and hogar_id is not null and public.is_hogar_member(hogar_id))
      or (es_personal = true and creado_por = auth.uid()))
    and creado_por = auth.uid()
  );

-- ============================================================================
-- Fin de la migración 013.
-- ============================================================================
