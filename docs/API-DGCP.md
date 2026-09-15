# API de datos abiertos de la DGCP

Verificada endpoint por endpoint el 14–15 de septiembre de 2026.

```
https://datosabiertos.dgcp.gob.do/api-dgcp/v1
```

**Es pública y NO requiere autenticación.** Ni llave, ni convenio, ni solicitud
formal. El propio portal de la DGCP la consume con un cliente sin cabecera de
autorización.

## Dónde salió

No está documentada públicamente. La encontré dentro del portal
`https://datosabiertos.dgcp.gob.do` ("Sistema de Información de Contrataciones
Públicas"), que es una SPA. **El Swagger 2.0 completo está embebido** en:

```
https://datosabiertos.dgcp.gob.do/assets/api-dgcp-schema-*.js
```

El hash del nombre cambia en cada despliegue; se saca del `index-*.js` que
referencia el `index.html`. **No hay `/docs`, `/openapi.json` ni `/redoc`
servidos** — devuelven `Cannot GET /v1/docs` (es un Express detrás de un proxy
que quita el prefijo `/api-dgcp`).

## Envoltorio de respuesta

```json
{
  "code": 200,
  "hasError": false,
  "payload": { "content": [ ... ] },
  "page": 1,
  "limit": 100,
  "totalResults": 628687,
  "pages": 6287
}
```

Siempre comprobar `hasError`: un error llega con HTTP 200 y `hasError: true`,
con el motivo en `payload.message`.

## Endpoints (25)

| Endpoint | Qué entrega |
|---|---|
| `/procesos` | Licitaciones publicadas — **el corazón** |
| `/procesos/agrupados` | Procesos agrupados |
| `/procesos/articulos` | Artículos de cada proceso |
| `/procesos/documentos` | **Pliegos y anexos** (requiere `proceso`) |
| `/procesos/mipymes/articulos` | Artículos reservados a MIPYMES |
| `/procesos/mipymes/cuota_global` | Cuota global MIPYME |
| `/procesos/mipymes/cuota_institucion` | Cuota MIPYME por institución |
| `/contratos` | **Adjudicaciones: quién ganó y por cuánto** |
| `/contratos/articulos` | Artículos de cada contrato |
| `/ofertas` | Ofertas presentadas |
| `/proveedores` | Registro de Proveedores del Estado (RPE) |
| `/proveedores/rubro` | Proveedores por rubro |
| `/proveedores/estadisticas-mujeres` | Estadísticas de empresas de mujeres |
| `/unidades_compra` | Instituciones compradoras, con correos |
| `/pacc` | **Plan Anual de Compras** — anticipa lo que no ha salido |
| `/pacc/adquisiciones` | Adquisiciones del PACC |
| `/pacc/articulos` | Artículos del PACC |
| `/catalogo` | Catálogo de bienes y servicios (UNSPSC) |
| `/ocds/releases` | Estándar OCDS (requiere `ocid`) |
| `/ocds/releases/all` | OCDS completo |
| `/tablas/procesos`, `/tablas/contratos`, `/tablas/proveedores`, … | Vistas tabulares |

## Parámetros

**`/procesos`** — `page`, `limit` (por defecto 100, **máximo 1000**), `proceso`,
`unidad_compra` (int), `modalidad`, `estado`, `mipyme`, `mipyme_mujer`,
`startdate`, `enddate` (formato `YYYY-MM-DD`).

**`/contratos`** — `page`, `limit`, `rpe`, `proceso`, `unidad_compra`, `contrato`.

**`/procesos/documentos`** — `proceso` (obligatorio).

**`/pacc`** — `page`, `limit`, `unidad_compra`, `id`.

**`/proveedores`** — `page`, `limit`, `rpe`, `numero_documento`.
⚠️ **Los filtros `rpe` y `numero_documento` devuelven HTTP 500.** Es un fallo
de ellos, no nuestro. Para buscar un proveedor hay que paginar.

## Campos que importan

### `/procesos`
`objeto_proceso` — **`Obras` | `Bienes` | `Servicios`**. JMC solo compite en
Obras: de 1.000 procesos publicados en dos semanas, solo 17 lo eran. Por eso
el filtro vale tanto.

`estado_proceso` — el ciclo de vida:
`Proceso publicado` (**abierto, se puede ofertar**) → `Sobres estan abriendose`
→ `Sobres abiertos o aperturados` → `Proceso con etapa cerrada` →
`Proceso adjudicado y celebrado`. Terminales: `Cancelado`, `Proceso desierto`.

`modalidad` — por relevancia para obra: `Licitación Pública Nacional`,
`Licitación Pública Abreviada` y `Comparación de Precios` son las que importan.
`Compras por Debajo del Umbral`, `Contratación Menor`, `Subasta Inversa` y
`Procesos de Excepción` son casi siempre bienes y servicios.

Otros: `codigo_proceso` (clave), `unidad_compra`, `monto_estimado`,
`fecha_fin_recepcion_ofertas` (**la fecha que manda**), `fecha_apertura_ofertas`,
`dirigido_mipymes`, `area_requiriente`, `url` (ficha en el portal público).

### `/contratos`
Trae **`rpe` y `razon_social` del ganador** más `valor_contratado` — es la base
del análisis de competencia. También `plazo_pago_factura` y `metodo_pago`.

### `/procesos/documentos`
`nombre_documento`, `tipo_documento`, `url_documento` (descarga directa).
Promedio: ~17 documentos por obra.

## Volumen (al 15-sep-2026)

- **628.822** procesos históricos
- **719.071** contratos
- **3.141** PACC
- 2026 completo: 53.141 procesos, de los cuales **824 son obras**

## Cómo lo usamos

La ingesta corre **dentro de Postgres**, no en un servidor aparte: la extensión
`http` llama a la API y `pg_cron` la programa. Así no hay llaves que
administrar ni piezas externas que se caigan. Ver
`supabase/migrations/0002_dgcp_ingesta.sql`.

```sql
-- incremental (lo que hace el cron cada 3 h)
select public.dgcp_sincronizar();

-- carga histórica, por tandas; el mensaje de dgcp_sync dice cómo reanudar
select public.dgcp_sincronizar(desde => '2025-01-01', pagina_inicial => 1, max_paginas => 25);

-- pliegos, contratos y PACC
select public.dgcp_sincronizar_complementos(120, 120, true);
```

## Callejones sin salida ya descartados

No perder tiempo aquí otra vez:

- `api.dgcp.gob.do` y `comprasdominicana.gob.do` — no resuelven por DNS.
- `datos.gob.do` (portal CKAN) — la búsqueda de paquetes devuelve 0 resultados.
- data.world — cerró su comunidad de datos abiertos en julio de 2026.

## Pendiente de investigar

**InfoPago** (`https://infopago.dgcp.gob.do/`) — muestra si el Estado
efectivamente pagó, lo cual importa mucho para el flujo de caja de un
contratista. LicitaRD lo usa como fuente. El portal existe (Next.js, HTTP 200)
pero **no le encontré API pública**: las rutas `/api/*` dan 404. Habría que
mirar sus chunks de JavaScript con calma, como se hizo con datosabiertos.
