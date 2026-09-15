# Constructora JMC Ingenieros y Asociados — contexto del proyecto

RNC 101704977 · RPE 25564 · SRL constituida en 1996 · Santo Domingo, RD
Clasificación MIPYME: **Micro Empresa**.

> Este archivo es la memoria del proyecto entre sesiones y entre terminales.
> Léelo antes de proponer cambios. **No guardar contraseñas ni llaves aquí**:
> el repositorio es público.

---

## El objetivo

Una **plataforma integral** que cubra el ciclo completo de una constructora
dominicana: desde enterarse de que existe una licitación hasta cobrar la última
factura de la obra. No un monitor de licitaciones ni un ERP de obra por
separado — las dos cosas conectadas, porque el valor está justo en la costura:
una licitación ganada se convierte en obra sin volver a teclear nada, y la
cubicación aprobada se factura sola.

**El ciclo completo, en orden:**

1. **Detectar** — obras publicadas por la DGCP, filtradas a lo que le conviene a
   JMC, con alerta el mismo día. Y el PACC para anticipar lo que aún no sale.
2. **Decidir** — puntuación de conveniencia, precios de referencia de obras
   parecidas, quién suele ganar en esa institución.
3. **Preparar** — pliego descargado, lista de requisitos y **prellenado** de la
   documentación desde el Expediente Maestro que ya existe.
4. **Ofertar** — presupuesto por partidas, márgenes, garantías y fianzas.
5. **Ejecutar** — obra con avance por cubicaciones, presupuestado vs ejecutado
   en vivo, subcontratos, personal y maquinaria.
6. **Abastecer** — inventario y almacén por obra: entradas, salidas, quién
   retiró qué. Compras y órdenes a proveedores.
7. **Cobrar** — facturación electrónica e-CF ante la DGII desde la cubicación
   aprobada, caja chica por obra, y seguimiento de si el Estado pagó.

**Licitaciones públicas y privadas van en módulos SEPARADOS** — el usuario lo
pidió explícitamente. Las privadas llegan por invitación directa, sin portal ni
pliego estándar.

Restricción de diseño: **la parte de campo tiene que funcionar sin señal.** En
la obra no siempre hay datos, y es la razón por la que estos sistemas fracasan.

---

## ⚠️ Lo más urgente

**Facturación electrónica e-CF: fecha límite 15 de noviembre de 2026.**
Ley 32-23. JMC es Micro Empresa, así que le aplica esa fecha. El 10 de
septiembre de 2026 el director de la DGII declaró públicamente que **no habrá
otra prórroga**. Certificar la plataforma propia como emisor no cabe en el
plazo; lo realista es conectarse a un emisor ya certificado.

Las tablas `facturas` / `factura_lineas` ya guardan el acuse de la DGII
(campos `ecf_*`), pero **no hay conexión con ningún emisor** todavía.

---

## Hay DOS aplicaciones distintas, no una

1. **Sitio público estático** — este repositorio (`index.html`, `nosotros.html`,
   `servicios.html`, `proyectos.html`, `equipo.html`, `contacto.html`,
   `acceso.html`). Se despliega en Vercel al hacer push a `main`.

2. **Plataforma Next.js** — sirve `jmcconstruye.com/login` y `/app`. La
   construyó un tercero. **Su código NO está en este repositorio ni en la
   cuenta de GitHub del usuario** (solo hay un repo público: este). Autentica
   del lado del servidor contra el mismo Supabase.
   - Su sección de **Licitaciones dice "Próximamente"** — está vacía.
   - No conoce ninguna de las tablas nuevas (`dgcp_*`, `proyectos`,
     `inventario`, etc.). Aunque entres, no verás nada de eso.
   - **Bloqueo abierto:** sin ese código no se le pueden añadir pantallas.
     Averiguar quién la construyó y si hay acceso al proyecto en Vercel.

---

## Base de datos

Supabase `tbwcuuiengwyukhnkwel` — https://tbwcuuiengwyukhnkwel.supabase.co
Plan Free (500 MB; va por ~70 MB). Esquema completo en `supabase/` — ver su
README para reconstruirlo.

**32 tablas, 5 vistas, todas con control de acceso por fila.**

| Módulo | Qué hay |
|---|---|
| Expediente Maestro | `companies`, `documents`, `rpe_records`… — del tercero |
| DGCP | `dgcp_procesos`, `dgcp_documentos`, `dgcp_contratos`, `dgcp_pacc`, `dgcp_unidades_compra` |
| Licitaciones | `oportunidades` (públicas), `licitaciones_privadas` (separadas) |
| Obra | `proyectos`, `partidas`, `cubicaciones`, `subcontratos` |
| Inventario | `articulos`, `almacenes`, `movimientos_inventario` |
| Dinero | `cajas_chicas`, `movimientos_caja`, `facturas` |

**Vistas que debe leer la aplicación** (no las tablas directamente):
`v_oportunidades` (filtrar `abierta = true`), `v_competencia`, `v_obra_avance`,
`v_stock`, `v_caja_saldo`.

### Datos cargados
Todo 2026: 53.141 procesos, 824 obras, 13.868 pliegos, 689 contratos,
3.141 PACC, 755 instituciones. Se actualiza solo: `pg_cron` cada 3 h
(`dgcp-sincronizar`) y cada 6 h (`dgcp-complementos`).

---

## API de la DGCP

`https://datosabiertos.dgcp.gob.do/api-dgcp/v1` — **pública, sin autenticación**.
El Swagger está embebido en `https://datosabiertos.dgcp.gob.do/assets/api-dgcp-schema-*.js`
(no hay `/docs` servido). 25 endpoints; usamos procesos, unidades_compra,
procesos/documentos, contratos y pacc.

- `objeto_proceso` = Obras | Bienes | Servicios → **JMC solo compite en Obras**
  (de 1.000 procesos recientes, solo 17 lo son: por eso el filtro vale tanto).
- `estado_proceso` = `Proceso publicado` significa abierto para ofertar.
- Los filtros de `/proveedores` (`rpe`, `numero_documento`) **devuelven 500** —
  es un fallo de ellos.

Sin explorar aún: `infopago.dgcp.gob.do` (si el Estado pagó — clave para flujo
de caja). Existe, pero no le encontré API pública.

---

## Cómo trabajar en este proyecto

- **Verificar antes de afirmar.** Nunca decir "ya funciona" sin una prueba real
  (llamar al endpoint y ver el 200, correr la consulta y ver el resultado).
  Ya se entregaron credenciales que no entraban y costó confianza.
- **Explorar antes de crear.** Se crearon 6 tablas redundantes en una base que
  ya tenía plataforma, y una función `mi_rol()` duplicando `current_user_role()`
  que ya existía. Revisar `pg_proc` y `list_tables` primero.
- **Preguntar cuando el alcance no esté claro**, antes de construir.
- El usuario no es desarrollador: espera ejecución de punta a punta y
  enlaces/credenciales listos para usar. Escribe en español.

### Trampas conocidas
- En Postgres toda función nace con `execute` para **PUBLIC**, y `anon` hereda.
  `revoke ... from anon` **no sirve**: hay que `revoke execute ... from public`.
  Sin eso, cualquiera sin sesión podía inyectar licitaciones falsas por
  `/rest/v1/rpc/`.
- Un `exception when others` que marque el registro como procesado **pierde
  datos en silencio** (pasó con los pliegos de 10 de 824 obras).
- Insertar usuarios a mano en `auth.users` exige las 8 columnas de token en
  `''`, no NULL, o GoTrue devuelve 500.
- Cambiar el tipo de retorno de una función exige `drop function` antes.
- No se puede renombrar una columna de vista con `create or replace view`.

---

## Qué falta

1. **Las pantallas** — nada de esto se ve; hoy solo se consulta la base.
   Depende del bloqueo de la plataforma Next.js.
2. **Emisión e-CF** — contratar emisor certificado (fecha límite arriba).
3. **Notificaciones** — obra nueva, cierre próximo, documento por vencer,
   material bajo mínimo. Canal por decidir (correo / WhatsApp).
4. **Prellenado de documentos** — conectar el Expediente Maestro con los pliegos
   ya descargados. Es la función estrella de la competencia y las dos mitades ya
   están en la base.
5. **Puntuación de compatibilidad** — ordenar las obras abiertas por cuánto
   convienen, no solo listarlas.
6. **RLS por rol en las 12 tablas del tercero** — hoy solo comprueban que el
   usuario esté autenticado: cualquiera que entre ve estados financieros y
   cuentas bancarias. Arreglarlo puede romper su aplicación.

## Competencia (analizada 2026-09-14/15)

Todos son dominicanos. **Ninguno cubre el ciclo completo**, y ese es el hueco.

| Sistema | Cubre | No cubre | Precio |
|---|---|---|---|
| **licitahoy.com** | Alertas DGCP, tablero, análisis competitivo, fianzas, app móvil. Su función fuerte: ***Prellenado***, completa ~80% de la documentación | Obra, inventario, facturación | US$45/mes |
| **licitard.com** | Cruza 4 fuentes (DGCP, InfoPago, RPE, UNSPSC), puntuación de compatibilidad 0-1, detección de anomalías, ***Watchdog*** de competidores | Obra, inventario, facturación | US$0 / 39.99 / 74.99 |
| **coraxis.tech** | **El más cercano a lo que queremos.** Licitaciones + ejecución: módulos *START*, *BID*, *SIGNAL* y *EXECUTION* (partidas, órdenes de compra, pagos, contenedores, flujo de caja). **OCR de pliegos y actas** con nivel de confianza. Asistente *Leo*. Arquitectura local-first. Alertas gratis por correo | Inventario/almacén, facturación e-CF, caja chica, nómina, maquinaria, subcontratistas | No publicado |
| **emporio.com.do** | Constructoras **y ferreterías** → sí tiene inventario. **Emisor certificado e-CF**, cubicaciones que se facturan directo, rentabilidad por obra, **funciona sin conexión** | Licitaciones | No publicado |
| **lp.malla.io/construccion** | ERP de obra: presupuestado vs ejecutado, alertas de desviación, materiales por obra, avance, documentos | Licitaciones, inventario formal | Tras diagnóstico |

**Lecturas para el diseño:**
- El *prellenado* de licitahoy necesita un repositorio de papeles al día — que
  es exactamente el Expediente Maestro que ya está en la base. Las dos mitades
  existen y están desconectadas. **Es la ventaja que JMC ya tiene pagada.**
- Coraxis demuestra que licitación + ejecución es un producto viable, y deja
  libre justo lo que JMC necesita: almacén, e-CF, caja chica y maquinaria.
- El OCR de pliegos (Coraxis) y la puntuación de compatibilidad (LicitaRD) son
  las dos piezas de inteligencia que más ahorran tiempo real.
