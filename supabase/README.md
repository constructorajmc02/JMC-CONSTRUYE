# Base de datos JMC (Supabase)

Proyecto Supabase: `tbwcuuiengwyukhnkwel` — https://tbwcuuiengwyukhnkwel.supabase.co

Aquí vive el esquema completo de la plataforma. **Hasta ahora solo existía dentro
de Supabase**; estos archivos lo hacen reconstruible desde el repositorio.

## Cómo reconstruirlo

Los archivos de `migrations/` se aplican en orden alfabético:

```bash
supabase link --project-ref tbwcuuiengwyukhnkwel
supabase db push
```

O directamente con psql, en orden:

```bash
psql "$DATABASE_URL" -f supabase/migrations/0001_fundacion_expediente_maestro.sql
psql "$DATABASE_URL" -f supabase/migrations/0002_dgcp_ingesta.sql
psql "$DATABASE_URL" -f supabase/migrations/0003_gestion_obra.sql
```

## Cómo volver a exportar desde Supabase

Si se aplican migraciones nuevas desde el panel o por MCP, se vuelcan con:

```sql
select string_agg(
  '-- ' || version || '  ' || name || E'\n' || array_to_string(statements, E';\n\n') || ';',
  E'\n\n' order by version)
from supabase_migrations.schema_migrations;
```

## Qué contiene cada archivo

| Archivo | Qué trae |
|---|---|
| `0001_fundacion_expediente_maestro.sql` | Expediente Maestro: perfiles y roles, empresa, accionistas, cuentas, RPE, documentos con control de vencimiento, sincronización con Google Drive. Construido por un tercero. |
| `0002_dgcp_ingesta.sql` | Integración con la DGCP: procesos, instituciones, pliegos, contratos y PACC; los cargadores, la sincronización automática y el tablero de oportunidades. |
| `0003_gestion_obra.sql` | Licitaciones privadas, proyectos, partidas, cubicaciones, subcontratos, inventario, caja chica y facturación e-CF, con sus permisos y vistas. |

## Cosas que NO están en estos archivos

- **Los datos.** El esquema se reconstruye vacío; la carga se rehace con
  `select public.dgcp_sincronizar(desde => '2026-01-01', pagina_inicial => 1);`
  repitiendo con `pagina_inicial` hasta que devuelva `completo = true`.
- **Las tareas programadas** (`pg_cron`), porque dependen de la instancia:

  ```sql
  select cron.schedule('dgcp-sincronizar', '15 */3 * * *',
    $$select public.dgcp_sincronizar(max_paginas => 12, por_pagina => 500)$$);
  select cron.schedule('dgcp-complementos', '45 */6 * * *',
    $$select public.dgcp_sincronizar_complementos(120, 120, extract(hour from now())::int < 6)$$);
  ```

- **La función Edge `dgcp-sync`**, que es solo un disparador manual: llama por RPC
  a `dgcp_sincronizar`. El motor real es SQL y está en `0002`.

## Vistas que debe leer la aplicación

| Vista | Para qué |
|---|---|
| `v_oportunidades` | Obras de la DGCP con el seguimiento de JMC. Filtrar `abierta = true`. |
| `v_competencia` | Qué contratista gana qué, por cuánto y en qué instituciones. |
| `v_obra_avance` | Presupuestado vs ejecutado vs facturado, con margen estimado. |
| `v_stock` | Existencia por artículo y almacén, derivada de los movimientos. |
| `v_caja_saldo` | Saldo de cada caja chica. |

## Nota de seguridad

En Postgres toda función nace con `execute` para `PUBLIC`, y `anon` hereda de ahí.
Revocar de `anon` **no basta**: hay que `revoke execute ... from public`. Las
funciones internas (`dgcp_traer_*`, `dgcp_cargar_*`, `dgcp_sincronizar*`) están
cerradas así en `0002`; si se añade una función nueva, cerrarla igual.
