// ============================================================================
// DOMUS — Cliente único de Supabase, compartido por toda la app.
// ============================================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

if (SUPABASE_URL.includes('TU-PROYECTO') || SUPABASE_ANON_KEY.includes('TU-ANON-KEY')) {
  console.warn(
    '[Domus] Falta configurar js/config.js con la URL y anon key reales de tu proyecto de Supabase.'
  );
}

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
