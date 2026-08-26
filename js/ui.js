// ============================================================================
// DOMUS — Helpers de interfaz compartidos entre páginas
// ============================================================================

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

export function alternarCargando(botonId, cargando, textoNormal) {
  const boton = document.getElementById(botonId);
  if (!boton) return;
  boton.disabled = cargando;
  boton.innerHTML = cargando
    ? `<span class="spinner-border spinner-border-sm me-2"></span>Cargando...`
    : textoNormal;
}
