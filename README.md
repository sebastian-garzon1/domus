# Domus — Administración inteligente del hogar

Base sólida inicial: estructura del proyecto, autenticación, modelo de datos
de **hogares** y **Row Level Security**, más el primer módulo funcional:
**mercado y lista de compras**. Los módulos de gastos, servicios, calendario,
etc. se agregan de forma incremental sobre esta base.

## Qué incluye esta versión

- PWA instalable (HTML5 + Bootstrap 5 + JS moderno, sin frameworks ni build step).
- Registro, inicio de sesión, cerrar sesión y recuperación de contraseña (Supabase Auth).
- Crear hogares, pertenecer a varios a la vez, cambiar de hogar activo.
- Invitar miembros por correo (con roles: administrador / miembro / invitado).
- **Mercado y lista de compras compartida**: agregar ítems (nombre, categoría,
  cantidad, unidad, prioridad, precio estimado, observaciones), marcarlos como
  comprados (con precio final y quién los compró), reabrirlos, historial de
  comprados y totales automáticos (por comprar / gastado en el mes).
- Base de datos Postgres con **Row Level Security**: cada usuario solo puede
  ver o modificar datos de los hogares a los que pertenece, verificado en la
  base de datos (no solo en el navegador).
- Todo el esquema SQL (`sql/001_init.sql`, `sql/002_mercado.sql`) fue probado
  de punta a punta en un motor Postgres real antes de entregarse: creación de
  hogares, aislamiento entre hogares, invitaciones a usuarios existentes y no
  registrados, permisos de admin vs. miembro, CRUD y aislamiento del mercado,
  imposibilidad de falsificar autoría, restricciones de datos, etc.

## 1. Crear el proyecto en Supabase

1. Entra a [supabase.com](https://supabase.com) → **New project**.
2. Elige nombre, contraseña de base de datos (guárdala) y región (la más cercana a Colombia: `sa-east-1` o `us-east-1`).
3. Espera a que aprovisione el proyecto (1-2 minutos).

## 2. Ejecutar el esquema SQL

1. En el dashboard de Supabase: **SQL Editor → New query**.
2. Pega **todo** el contenido de [`sql/001_init.sql`](sql/001_init.sql) y dale **Run**.
3. Repite con [`sql/002_mercado.sql`](sql/002_mercado.sql) (en una consulta nueva, después del anterior).
4. Deberías ver `Success. No rows returned` en cada uno. Si algo falla, el error indica la línea exacta — puedes volver a correr cualquiera de los dos scripts completos las veces que necesites, están escritos para ser seguros de re-ejecutar.

`001_init.sql` crea las tablas `profiles`, `hogares`, `hogar_miembros`,
`invitaciones`, las funciones de apoyo y sus políticas de RLS. `002_mercado.sql`
agrega la tabla `mercado_items` (lista de compras) con su propia RLS.

## 3. Configurar Authentication

En **Authentication → URL Configuration**:

- **Site URL**: la URL donde vas a publicar el sitio (ej. `https://tu-usuario.github.io/domus/`).
- **Redirect URLs**: agrega también `https://tu-usuario.github.io/domus/nueva-password.html`.

En **Authentication → Providers → Email**, mientras desarrollas puedes
desactivar "Confirm email" para poder probar registro/login sin revisar
correos. Actívalo de nuevo antes de compartir el link con tu familia.

## 4. Conectar el frontend a tu proyecto

Abre [`js/config.js`](js/config.js) y reemplaza los dos valores:

```js
export const SUPABASE_URL = 'https://TU-PROYECTO.supabase.co';
export const SUPABASE_ANON_KEY = 'TU-ANON-KEY-AQUI';
```

Los encuentras en **Project Settings → API**. La `anon public key` **no es
secreta** — está diseñada para ir en el navegador; la protección real la dan
las políticas RLS del paso 2. Nunca copies aquí la `service_role key`.

## 5. Probar en tu computador

Como el sitio usa ES modules (`import`/`export`), no puedes simplemente abrir
`index.html` con doble clic — necesitas un servidor local. La forma más
simple, desde la carpeta del proyecto:

```bash
python3 -m http.server 8080
# o, si tienes Node: npx serve .
```

Y abres `http://localhost:8080` en el navegador.

## 6. Publicar gratis en GitHub Pages

```bash
git init
git add .
git commit -m "Domus: base inicial (auth + hogares + RLS)"
git branch -M main
git remote add origin https://github.com/TU-USUARIO/domus.git
git push -u origin main
```

Luego en GitHub: **Settings → Pages → Source: Deploy from a branch → Branch:
`main` / `root`**. En un par de minutos tu app queda publicada en
`https://tu-usuario.github.io/domus/`.

Recuerda volver al paso 3 y confirmar que esa URL exacta esté en el **Site
URL** y **Redirect URLs** de Supabase, o el login y la recuperación de
contraseña no van a redirigir bien.

## Estructura del proyecto

```
domus/
├── index.html            Login
├── registro.html         Crear cuenta
├── recuperar.html        Solicitar recuperación de contraseña
├── nueva-password.html   Definir nueva contraseña (llega desde el correo)
├── hogares.html           Crear / listar / seleccionar hogar
├── dashboard.html         Panel principal del hogar activo (con placeholders de módulos)
├── miembros.html          Ver e invitar miembros del hogar activo
├── perfil.html             Editar nombre del perfil
├── mercado.html            Mercado y lista de compras del hogar activo
├── manifest.json           Configuración PWA
├── sw.js                   Service worker (cachea el app shell)
├── css/styles.css
├── js/
│   ├── config.js            ← credenciales de Supabase (editar aquí)
│   ├── supabaseClient.js
│   ├── auth.js
│   ├── hogares.js
│   ├── mercado.js
│   ├── ui.js
│   └── register-sw.js
├── icons/                   Íconos PWA (192, 512, maskable)
└── sql/
    ├── 001_init.sql         Perfiles, hogares, membresías, invitaciones + RLS
    └── 002_mercado.sql      Mercado y lista de compras + RLS
```

## Próximos módulos

Siguiendo el mismo patrón (`sql/003_*.sql`, `004_*.sql`, ...), cada uno con
su tabla, índices y política RLS basada en `is_hogar_member(hogar_id)`:

1. ~~Mercado y lista de compras~~ ✅
2. Gastos + presupuesto mensual
3. Servicios y pagos recurrentes (+ comprobantes en Supabase Storage)
4. Calendario compartido
5. Inventario del hogar
6. Estadísticas y gráficas (Chart.js)

## Notas de seguridad

- Todas las tablas tienen RLS habilitado desde el primer script; ninguna
  tabla nueva debería crearse sin su política correspondiente.
- Las funciones sensibles (como `invitar_miembro`) están marcadas
  `SECURITY DEFINER` con permisos explícitos, y revocan el acceso público
  por defecto.
- El plan gratuito de Supabase pausa proyectos inactivos tras 7 días sin
  uso — se reactivan en segundos desde el dashboard.
