-- ============================================================================
-- DOMUS — Migración 010: endurecimiento tras auditoría de seguridad
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Requiere haber corrido antes sql/001_init.sql y sql/007_perfil_extendido.sql.
-- Es seguro volver a ejecutar (usa DROP ... IF EXISTS antes de crear).
--
-- Qué corrige:
-- profiles.avatar_url no tenía ninguna validación de formato (a diferencia de
-- enlace_pago, que en gastos/servicios ya exige http(s)://). El campo ya
-- estaba protegido contra XSS por el escapeHtml() del frontend al día de
-- hoy, pero un CHECK en la base de datos es una segunda capa de defensa
-- independiente del frontend, consistente con el resto del sistema.
-- ============================================================================

alter table public.profiles drop constraint if exists profiles_avatar_url_valido;
alter table public.profiles add constraint profiles_avatar_url_valido check (
  avatar_url is null or avatar_url ~ '^https?://'
);

-- ============================================================================
-- Fin de la migración 010.
-- ============================================================================
