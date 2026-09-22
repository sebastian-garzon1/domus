// ============================================================================
// DOMUS — Configuración de Supabase
// ----------------------------------------------------------------------------
// Reemplaza los dos valores de abajo con los de TU proyecto de Supabase:
// Dashboard → Project Settings → API → "Project URL" y "anon public" key.
//
// Estos valores NO son secretos: la anon key está diseñada para exponerse en
// el navegador (por eso este archivo se sube al repositorio sin problema). La
// seguridad real la dan las políticas RLS que ya quedaron definidas en
// sql/001_init.sql — sin ellas, cualquiera con esta key podría leer/escribir
// cualquier tabla; con ellas, cada usuario solo puede tocar sus propios hogares.
// ============================================================================

export const SUPABASE_URL = 'https://xnklugxabkemaurpoptc.supabase.co';
export const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhua2x1Z3hhYmtlbWF1cnBvcHRjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODU0MzY3NzcsImV4cCI6MjEwMTAxMjc3N30.thbots9nR-9R2cR62rmxDt86_msJXEu4MGJkDNDzHzg';
