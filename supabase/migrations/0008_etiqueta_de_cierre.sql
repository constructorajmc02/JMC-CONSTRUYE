-- ============================================================
-- `dias_para_cierre = 0` NO significa "hoy": significa "falta menos de un
-- día". Una pantalla que lo interprete como "hoy" miente.
--
-- Caso real reportado: HRJPP-DAF-CM-2026-0061 se mostraba como "Cierra hoy"
-- cuando en realidad cierra el 21/09 a las 3:00 pm — 22 horas después.
-- Peor aún al revés: una que cierre hoy a las 9:00 am sigue diciendo "hoy" a
-- las 2:00 pm, cuando ya no se puede ofertar.
--
-- Para que ninguna pantalla tenga que calcular esto (y equivocarse), la vista
-- entrega el texto ya armado en hora dominicana. Basta imprimirlo.
--
-- Requiere 0001–0007.
-- ============================================================

create or replace function public.etiqueta_cierre(p_cierre timestamptz)
returns text language sql stable
set search_path = public, pg_temp
as $$
  with d as (
    select
      p_cierre as ts,
      (p_cierre at time zone 'America/Santo_Domingo') as local,
      (now()    at time zone 'America/Santo_Domingo') as ahora_local,
      extract(epoch from (p_cierre - now())) / 3600.0 as horas
  ),
  f as (
    select d.*,
      (local::date - ahora_local::date) as dias_calendario,
      trim(to_char(local, 'FMHH12:MI'))
        || case when to_char(local,'AM') = 'AM' then ' am' else ' pm' end as hora
    from d
  )
  select case
    when ts is null           then 'Sin fecha'
    when horas <= 0           then 'Cerrada'
    when horas < 1            then 'Cierra en ' || round(horas * 60) || ' min · ' || hora
    when dias_calendario = 0  then 'Cierra hoy ' || hora
    when dias_calendario = 1  then 'Cierra mañana ' || hora
    when dias_calendario <= 6 then 'Cierra ' ||
      (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])
        [extract(dow from local)::int + 1] || ' ' || hora
    else 'Cierra ' || to_char(local, 'DD/MM/YYYY') || ' ' || hora
  end
  from f;
$$;

comment on function public.etiqueta_cierre is
  'Texto listo para mostrar, en hora dominicana. Distingue hoy de manana.';

revoke execute on function public.etiqueta_cierre(timestamptz) from public;
revoke execute on function public.etiqueta_cierre(timestamptz) from anon;
grant  execute on function public.etiqueta_cierre(timestamptz) to authenticated;

-- OJO: create or replace view NO conserva security_invoker — hay que repetirlo.
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
  o.potencial, o.potencial_marcada_en,
  (current_date - (p.fecha_publicacion at time zone 'America/Santo_Domingo')::date)::integer as dias_desde_publicacion,
  (p.fecha_fin_recepcion_ofertas at time zone 'America/Santo_Domingo') as cierre_rd,
  to_char(p.fecha_fin_recepcion_ofertas at time zone 'America/Santo_Domingo',
          'DD/MM/YYYY HH24:MI')                                        as cierre_texto,
  (p.fecha_apertura_ofertas at time zone 'America/Santo_Domingo')      as apertura_rd,
  round(extract(epoch from (p.fecha_fin_recepcion_ofertas - now())) / 3600.0, 1) as horas_para_cierre,
  case
    when p.fecha_fin_recepcion_ofertas is null then 'sin_fecha'
    when p.fecha_fin_recepcion_ofertas <= now() then 'cerrada'
    when p.fecha_fin_recepcion_ofertas <= now() + interval '6 hours'  then 'critica'
    when p.fecha_fin_recepcion_ofertas <= now() + interval '48 hours' then 'urgente'
    when p.fecha_fin_recepcion_ofertas <= now() + interval '7 days'   then 'proxima'
    else 'holgada'
  end as urgencia,
  -- ESTO es lo que debe pintar cualquier pantalla, tal cual.
  public.etiqueta_cierre(p.fecha_fin_recepcion_ofertas) as cierre_etiqueta,
  to_char(p.fecha_publicacion at time zone 'America/Santo_Domingo',
          'DD/MM/YYYY HH24:MI')                         as publicada_texto
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
  'Licitaciones de interes para JMC. Mostrar cierre_etiqueta tal cual: ya viene en hora dominicana y distingue hoy de manana.';
grant select on public.v_oportunidades to authenticated;
