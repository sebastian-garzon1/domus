-- ============================================================================
-- DOMUS — Migración 007: perfil extendido (teléfono, dirección, foto)
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql.
-- Es seguro volver a ejecutar (usa ADD COLUMN IF NOT EXISTS).
--
-- profiles.avatar_url ya existía desde 001_init.sql (se dejó lista para este
-- momento); aquí solo agregamos teléfono y dirección, y el bucket de fotos.
-- ============================================================================

alter table public.profiles
  add column if not exists telefono text,
  add column if not exists direccion text;

-- ----------------------------------------------------------------------------
-- Bucket "avatares": a diferencia de "comprobantes", este es PÚBLICO — una
-- foto de perfil no es información sensible, y así se puede mostrar en <img>
-- directo sin pedir URLs firmadas que expiran. Lo que sí protege RLS es que
-- cada quien solo puede subir/editar/borrar su PROPIA foto (ruta
-- "{user_id}/archivo"), nunca la de otro usuario.
-- ----------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('avatares', 'avatares', true)
on conflict (id) do nothing;

drop policy if exists "avatares_select" on storage.objects;
create policy "avatares_select" on storage.objects
  for select using (bucket_id = 'avatares');

drop policy if exists "avatares_insert" on storage.objects;
create policy "avatares_insert" on storage.objects
  for insert with check (
    bucket_id = 'avatares' and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatares_update" on storage.objects;
create policy "avatares_update" on storage.objects
  for update using (
    bucket_id = 'avatares' and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "avatares_delete" on storage.objects;
create policy "avatares_delete" on storage.objects
  for delete using (
    bucket_id = 'avatares' and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ============================================================================
-- Fin de la migración 007.
-- ============================================================================
