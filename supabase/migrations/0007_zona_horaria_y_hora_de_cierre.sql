-- ============================================================
-- La API de la DGCP devuelve las fechas en hora dominicana (UTC-04:00) pero
-- las etiqueta con "Z", como si fueran UTC. Guardarlas tal cual las dejaba
-- CUATRO HORAS ADELANTADAS.
--
-- Verificado contra el portal oficial, proceso AMQ-DAF-CM-2026-0001:
--   portal: "Presentación de Oferta Económica … 21/09/2026 09:00:00 (UTC-04:00)"
--           "16 hours left"
--   base:    2026-09-21 09:00:00+00  → que es 05:00 en RD. Mal.
-- Las cuatro fechas del proceso (publicación, cierre, apertura y adjudicación)
-- traían el mismo desfase.
--
-- Prueba estadística que lo delató: tratadas como UTC, 3.626 licitaciones
-- cerraban entre las 4 y las 6 de la mañana. Interpretadas como hora local, el
-- rango es 8:00–18:00 — horario de oficina.
--
-- Consecuencia real: el tablero mostraba el cierre 4 horas antes y daba por
-- cerrada una licitación en la que todavía se podía ofertar.
--
-- Requiere 0001–0006.
-- ============================================================

-- Bitácora de correcciones de datos, para que un arreglo de una sola vez no se
-- aplique dos veces si se reproducen las migraciones sobre datos ya corregidos.
create table if not exists public.migraciones_datos (
  clave       text primary key,
  aplicada_en timestamptz not null default now(),
  detalle     text
);

alter table public.migraciones_datos enable row level security;
drop policy if exists migraciones_datos_lectura on public.migraciones_datos;
create policy migraciones_datos_lectura on public.migraciones_datos
  for select to authenticated using (public.rol_es('administrador','director'));

-- Interpreta el texto de la API como hora local dominicana.
-- RD no aplica horario de verano, pero se usa la zona por nombre igualmente.
create or replace function public.dgcp_ts_rd(t text)
returns timestamptz language sql immutable
set search_path = pg_catalog, pg_temp
as $$
  select case when t ~ '^\d{4}-\d{2}-\d{2}'
              then (regexp_replace(t, '(Z|[+-]\d{2}:?\d{2})$', ''))::timestamp
                   at time zone 'America/Santo_Domingo'
         end
$$;
comment on function public.dgcp_ts_rd is
  'Convierte una fecha de la API de la DGCP: ellos mandan hora dominicana etiquetada como Z.';

revoke execute on function public.dgcp_ts_rd(text) from public;
revoke execute on function public.dgcp_ts_rd(text) from anon, authenticated;

-- ------------------------------------------------------------
-- Corrección de los datos ya cargados (una sola vez)
-- ------------------------------------------------------------
do $$
declare n_proc bigint; n_con bigint; n_doc bigint; n_pacc bigint; n_art bigint; n_his bigint;
begin
  if exists (select 1 from public.migraciones_datos where clave = 'zona_horaria_dgcp_v1') then
    raise notice 'La correccion de zona horaria ya se aplico; no se repite.';
    return;
  end if;

  -- El reloj guardado (leído como UTC) es en realidad hora dominicana.
  update public.dgcp_procesos set
    fecha_publicacion           = (fecha_publicacion           at time zone 'UTC') at time zone 'America/Santo_Domingo',
    fecha_enmienda              = (fecha_enmienda              at time zone 'UTC') at time zone 'America/Santo_Domingo',
    fecha_fin_recepcion_ofertas = (fecha_fin_recepcion_ofertas at time zone 'UTC') at time zone 'America/Santo_Domingo',
    fecha_apertura_ofertas      = (fecha_apertura_ofertas      at time zone 'UTC') at time zone 'America/Santo_Domingo',
    fecha_estimada_adjudicacion = (fecha_estimada_adjudicacion at time zone 'UTC') at time zone 'America/Santo_Domingo';
  get diagnostics n_proc = row_count;

  update public.dgcp_contratos set
    fecha_adjudicacion      = (fecha_adjudicacion      at time zone 'UTC') at time zone 'America/Santo_Domingo',
    fecha_creacion_contrato = (fecha_creacion_contrato at time zone 'UTC') at time zone 'America/Santo_Domingo';
  get diagnostics n_con = row_count;

  update public.dgcp_documentos set
    fecha_carga_archivo = (fecha_carga_archivo at time zone 'UTC') at time zone 'America/Santo_Domingo';
  get diagnostics n_doc = row_count;

  update public.dgcp_pacc set
    fecha_publicacion = (fecha_publicacion at time zone 'UTC') at time zone 'America/Santo_Domingo';
  get diagnostics n_pacc = row_count;

  update public.dgcp_articulos set
    fecha_publicacion = (fecha_publicacion at time zone 'UTC') at time zone 'America/Santo_Domingo';
  get diagnostics n_art = row_count;

  update public.jmc_historial set
    fecha_adjudicacion = (fecha_adjudicacion at time zone 'UTC') at time zone 'America/Santo_Domingo';
  get diagnostics n_his = row_count;

  insert into public.migraciones_datos (clave, detalle) values (
    'zona_horaria_dgcp_v1',
    format('+4h sobre fechas de la DGCP. procesos=%s contratos=%s documentos=%s pacc=%s articulos=%s historial=%s',
           n_proc, n_con, n_doc, n_pacc, n_art, n_his)
  );
end $$;

-- ------------------------------------------------------------
-- Los cargadores pasan a usar dgcp_ts_rd: si no, el cron volvería a meter las
-- fechas adelantadas en cada corrida.
-- ------------------------------------------------------------
do $$
declare r record; def text;
begin
  for r in
    select p.oid, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('dgcp_cargar_procesos','dgcp_cargar_unidades',
                        'dgcp_traer_documentos','dgcp_traer_contratos',
                        'dgcp_traer_pacc','dgcp_traer_articulos','jmc_traer_historial')
  loop
    def := pg_get_functiondef(r.oid);
    if position('public.dgcp_ts(' in def) > 0 then
      execute replace(def, 'public.dgcp_ts(', 'public.dgcp_ts_rd(');
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------
-- La vista expone fecha y hora exactas, no solo "cierra hoy".
-- Una licitación que cierra hoy a las 09:00 ya no admite oferta a las 14:00.
--
-- OJO: create or replace view NO conserva security_invoker — hay que repetirlo.
-- ------------------------------------------------------------
create or replace view public.v_oportunidades
with (security_invoker = true) as
select
  o.id, o.estado as seguimiento, o.responsable, o.monto_ofertado,
  o.motivo_descarte, o.notas, o.motivo_ingreso,
  p.codigo_proceso, p.titulo, p.descripcion, p.modalidad, p.estado_proceso,
  p.objeto_proceso, p.monto_estimado, p.divisa, p.fecha_publicacion,
  p.fecha_fin_recepcion_ofertas, p.fecha_apertura_ofertas,
  p.duracion_contrato, p.area_requiriente, p.dirigido_mipymes, p.url,
  u.codigo_unidad_compra,
  coalesce(u.acronimo, u.unidad_compra) as institucion,
  u.unidad_compra as institucion_nombre,
  u.seguida as institucion_seguida,
  (p.estado_proceso = 'Proceso publicado' and p.fecha_fin_recepcion_ofertas > now()) as abierta,
  floor(extract(epoch from (p.fecha_fin_recepcion_ofertas - now())) / 86400)::integer as dias_para_cierre,
  (select count(*) from public.dgcp_documentos d where d.codigo_proceso = p.codigo_proceso) as documentos,
  rub.rubros,
  adj.razon_social as adjudicado_a,
  adj.valor_contratado as valor_adjudicado,
  o.potencial,
  o.potencial_marcada_en,
  (current_date - (p.fecha_publicacion at time zone 'America/Santo_Domingo')::date)::integer as dias_desde_publicacion,
  (p.fecha_fin_recepcion_ofertas at time zone 'America/Santo_Domingo') as cierre_rd,
  to_char(p.fecha_fin_recepcion_ofertas at time zone 'America/Santo_Domingo',
          'DD/MM/YYYY HH24:MI')                                        as cierre_texto,
  (p.fecha_apertura_ofertas at time zone 'America/Santo_Domingo')      as apertura_rd,
  round(extract(epoch from (p.fecha_fin_recepcion_ofertas - now())) / 3600.0, 1) as horas_para_cierre,
  -- Urgencia por el tiempo real que queda, no por el día del calendario.
  case
    when p.fecha_fin_recepcion_ofertas is null then 'sin_fecha'
    when p.fecha_fin_recepcion_ofertas <= now() then 'cerrada'
    when p.fecha_fin_recepcion_ofertas <= now() + interval '6 hours'  then 'critica'
    when p.fecha_fin_recepcion_ofertas <= now() + interval '48 hours' then 'urgente'
    when p.fecha_fin_recepcion_ofertas <= now() + interval '7 days'   then 'proxima'
    else 'holgada'
  end as urgencia
from public.oportunidades o
join public.dgcp_procesos p on p.codigo_proceso = o.codigo_proceso
left join public.dgcp_unidades_compra u on u.codigo_unidad_compra = p.codigo_unidad_compra
left join lateral (
  select array_agg(distinct r.descripcion order by r.descripcion) as rubros
  from public.dgcp_articulos a
  join public.jmc_rubros r on r.familia_unspsc = a.familia_unspsc and r.activo
  where a.codigo_proceso = p.codigo_proceso
) rub on true
left join lateral (
  select c.razon_social, c.valor_contratado
  from public.dgcp_contratos c
  where c.codigo_proceso = p.codigo_proceso
  order by c.valor_contratado desc nulls last
  limit 1
) adj on true;

comment on view public.v_oportunidades is
  'Licitaciones que le interesan a JMC. cierre_texto y horas_para_cierre van en hora dominicana; urgencia mide el tiempo real que queda.';
grant select on public.v_oportunidades to authenticated;
