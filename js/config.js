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

export const SUPABASE_URL = 'https://TU-PROYECTO.supabase.co';
export const SUPABASE_ANON_KEY = 'TU-ANON-KEY-AQUI';
