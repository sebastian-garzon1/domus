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

// En móvil (sobre todo como PWA instalada) el sistema operativo congela el
// timer de auto-refresh de Supabase cuando la app pasa a segundo plano. Si
// se queda así más de lo que dura el token de acceso, al volver a abrirla
// parece que "cerró sesión" aunque el refresh token siga siendo válido.
// Retomar el auto-refresh apenas la app vuelve a primer plano evita eso
// (ver recomendación de Supabase para apps móviles/PWA).
if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      supabase.auth.startAutoRefresh();
    } else {
      supabase.auth.stopAutoRefresh();
    }
  });
}
