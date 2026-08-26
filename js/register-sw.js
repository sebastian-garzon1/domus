// ============================================================================
// DOMUS — Registro del Service Worker (se incluye en todas las páginas)
// ============================================================================
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch((error) => {
      console.warn('[Domus] No se pudo registrar el service worker:', error);
    });
  });
}
