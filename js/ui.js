// ============================================================================
// DOMUS — Helpers de interfaz compartidos entre páginas
// ============================================================================

/**
 * Fecha de HOY en la zona horaria del dispositivo, como "YYYY-MM-DD".
 * OJO: nunca uses `new Date().toISOString().slice(0, 10)` para esto —
 * toISOString() convierte a UTC, así que en Colombia (UTC-5) muestra el día
 * siguiente durante las últimas horas de la noche (ej. 11pm del 22 ya
 * calcula 23 en UTC).
 */
export function fechaLocalHoy(referencia = new Date()) {
  const anio = referencia.getFullYear();
  const mes = String(referencia.getMonth() + 1).padStart(2, '0');
  const dia = String(referencia.getDate()).padStart(2, '0');
  return `${anio}-${mes}-${dia}`;
}

/** Muestra un mensaje de error/éxito dentro de un contenedor Bootstrap. */
export function mostrarMensaje(contenedorId, texto, tipo = 'danger') {
  const contenedor = document.getElementById(contenedorId);
  if (!contenedor) return;
  contenedor.innerHTML = `
    <div class="alert alert-${tipo} alert-dismissible fade show" role="alert">
      ${texto}
      <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Cerrar"></button>
    </div>`;
}

export function limpiarMensaje(contenedorId) {
  const contenedor = document.getElementById(contenedorId);
  if (contenedor) contenedor.innerHTML = '';
}

/** Traduce los errores más comunes de Supabase Auth a español. */
export function traducirErrorAuth(error) {
  const mensaje = error?.message ?? String(error);
  const mapa = {
    'Invalid login credentials': 'Correo o contraseña incorrectos.',
    'User already registered': 'Ya existe una cuenta con ese correo.',
    'Email not confirmed': 'Debes confirmar tu correo antes de iniciar sesión.',
    'Password should be at least 6 characters': 'La contraseña debe tener al menos 6 caracteres.',
  };
  return mapa[mensaje] ?? mensaje;
}

export function formatearMoneda(valor) {
  return new Intl.NumberFormat('es-CO', {
    style: 'currency',
    currency: 'COP',
    maximumFractionDigits: 0,
  }).format(valor ?? 0);
}

/**
 * Convierte un <input> de dinero en un campo con separador de miles mientras
 * se escribe (ej. "36000" -> "36.000"). El input debe ser type="text" en el
 * HTML (los inputs type="number" del navegador no aceptan puntos). Usa
 * obtenerValorNumerico() para leer el valor real (sin puntos) al enviar.
 */
export function activarFormatoMiles(input) {
  if (!input) return;
  input.addEventListener('input', () => {
    const crudo = input.value.replace(/\D/g, '');
    input.value = crudo ? Number(crudo).toLocaleString('es-CO') : '';
  });
}

/** Lee el valor numérico real de un input formateado con activarFormatoMiles(). */
export function obtenerValorNumerico(input) {
  return Number(String(input?.value ?? '').replace(/\D/g, '')) || 0;
}

export function alternarCargando(botonId, cargando, textoNormal) {
  const boton = document.getElementById(botonId);
  if (!boton) return;
  boton.disabled = cargando;
  boton.innerHTML = cargando
    ? `<span class="spinner-border spinner-border-sm me-2"></span>Cargando...`
    : textoNormal;
}
