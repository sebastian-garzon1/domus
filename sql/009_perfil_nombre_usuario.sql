-- ============================================================================
-- DOMUS — Migración 009: nombre de usuario único en el perfil
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql.
-- Es seguro volver a ejecutar (usa ADD COLUMN IF NOT EXISTS).
--
-- Solo letras minúsculas, números y guion bajo (3-20 caracteres). La
-- unicidad se valida sin importar mayúsculas/minúsculas (índice único sobre
-- lower(nombre_usuario)), para que "Sebas" y "sebas" no puedan coexistir.
-- Es opcional (columna nullable) para no romper los perfiles que ya existen.
-- ============================================================================

alter table public.profiles
  add column if not exists nombre_usuario text;

alter table public.profiles drop constraint if exists profiles_nombre_usuario_formato;
alter table public.profiles add constraint profiles_nombre_usuario_formato check (
  nombre_usuario is null or nombre_usuario ~ '^[a-z0-9_]{3,20}$'
);

drop index if exists idx_profiles_nombre_usuario_unico;
create unique index idx_profiles_nombre_usuario_unico
  on public.profiles (lower(nombre_usuario))
  where nombre_usuario is not null;

-- ============================================================================
-- Fin de la migración 009.
-- ============================================================================
