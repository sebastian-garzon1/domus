// ============================================================================
// DOMUS — Registro del Service Worker (se incluye en todas las páginas)
// ============================================================================
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    // js/register-sw.js siempre vive en <raíz-del-sitio>/js/, sin importar
    // desde qué página (raíz o subcarpeta como mercado/) se cargue este script.
    const raizSitio = new URL('../', import.meta.url);
    navigator.serviceWorker
      .register(new URL('sw.js', raizSitio), { scope: raizSitio.pathname })
      .catch((error) => {
        console.warn('[Domus] No se pudo registrar el service worker:', error);
      });
  });
}
