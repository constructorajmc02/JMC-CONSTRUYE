-- ============================================================
-- Trabajo del 16–17 de septiembre de 2026. Estaba solo dentro de Supabase.
-- Requiere 0001–0004.
--
--   1. RLS por rol en las tablas del Expediente Maestro (cerró el hueco por el
--      que cualquier usuario veía estados financieros y cuentas bancarias)
--   2. Escritura de licitaciones privadas
--   3. Los 40 rubros reales del RPE 25564 (antes solo 5)
--   4. Checklist de requisitos por licitación, contra su fecha de cierre
--   5. Presupuestos, APUs y banco de precios
--   6. Alta de usuarios desde Configuración
--   7. Marca de licitación potencial
-- ============================================================

-- ------------------------------------------------------------
-- 1. RLS por rol en el Expediente Maestro
--    Reemplaza las políticas "_all USING(true)" del esquema original.
--    'administrador' conserva acceso total en todas.
-- ------------------------------------------------------------

-- Cuentas bancarias: lo más sensible
drop policy if exists "bank_all" on bank_accounts;
create policy "bank_select" on bank_accounts for select to authenticated
  using (rol_es('administrador','director','finanzas','representante_legal'));
create policy "bank_insert" on bank_accounts for insert to authenticated
  with check (rol_es('administrador','finanzas'));
create policy "bank_update" on bank_accounts for update to authenticated
  using (rol_es('administrador','finanzas')) with check (rol_es('administrador','finanzas'));
create policy "bank_delete" on bank_accounts for delete to authenticated
  using (rol_es('administrador','finanzas'));

-- Accionistas: cédulas, PEP, % de participación
drop policy if exists "stakeholders_all" on company_stakeholders;
create policy "stakeholders_select" on company_stakeholders for select to authenticated
  using (rol_es('administrador','director','legal','representante_legal','finanzas','gerente_licitaciones'));
create policy "stakeholders_insert" on company_stakeholders for insert to authenticated
  with check (rol_es('administrador','legal'));
create policy "stakeholders_update" on company_stakeholders for update to authenticated
  using (rol_es('administrador','legal')) with check (rol_es('administrador','legal'));
create policy "stakeholders_delete" on company_stakeholders for delete to authenticated
  using (rol_es('administrador','legal'));

-- Empresa: datos maestros, se leen en toda la aplicación
drop policy if exists "companies_all" on companies;
create policy "companies_select" on companies for select to authenticated using (true);
create policy "companies_insert" on companies for insert to authenticated
  with check (rol_es('administrador','director','legal'));
create policy "companies_update" on companies for update to authenticated
  using (rol_es('administrador','director','legal')) with check (rol_es('administrador','director','legal'));
create policy "companies_delete" on companies for delete to authenticated
  using (rol_es('administrador'));

-- RPE: necesario para saber si se puede ofertar
drop policy if exists "rpe_all" on rpe_records;
create policy "rpe_select" on rpe_records for select to authenticated using (true);
create policy "rpe_insert" on rpe_records for insert to authenticated
  with check (rol_es('administrador','director','legal','representante_legal'));
create policy "rpe_update" on rpe_records for update to authenticated
  using (rol_es('administrador','director','legal','representante_legal'))
  with check (rol_es('administrador','director','legal','representante_legal'));
create policy "rpe_delete" on rpe_records for delete to authenticated
  using (rol_es('administrador'));

drop policy if exists "activities_all" on commercial_activities;
create policy "activities_select" on commercial_activities for select to authenticated using (true);
create policy "activities_insert" on commercial_activities for insert to authenticated
  with check (rol_es('administrador','director','gerente_licitaciones'));
create policy "activities_update" on commercial_activities for update to authenticated
  using (rol_es('administrador','director','gerente_licitaciones'))
  with check (rol_es('administrador','director','gerente_licitaciones'));
create policy "activities_delete" on commercial_activities for delete to authenticated
  using (rol_es('administrador'));

drop policy if exists "doccat_all" on document_categories;
create policy "doccat_select" on document_categories for select to authenticated using (true);
create policy "doccat_insert" on document_categories for insert to authenticated
  with check (rol_es('administrador'));
create policy "doccat_update" on document_categories for update to authenticated
  using (rol_es('administrador')) with check (rol_es('administrador'));
create policy "doccat_delete" on document_categories for delete to authenticated
  using (rol_es('administrador'));

drop policy if exists "thresholds_all" on alert_thresholds;
create policy "thresholds_select" on alert_thresholds for select to authenticated using (true);
create policy "thresholds_insert" on alert_thresholds for insert to authenticated
  with check (rol_es('administrador'));
create policy "thresholds_update" on alert_thresholds for update to authenticated
  using (rol_es('administrador')) with check (rol_es('administrador'));
create policy "thresholds_delete" on alert_thresholds for delete to authenticated
  using (rol_es('administrador'));

-- Documentos: usa el campo `confidentiality` que ya modelaba el esquema original
drop policy if exists "documents_all" on documents;
create policy "documents_select" on documents for select to authenticated
  using (
    confidentiality in ('publico','interno')
    or rol_es('administrador','director','legal','finanzas','representante_legal','gerente_licitaciones')
  );
create policy "documents_insert" on documents for insert to authenticated
  with check (not rol_es('lectura'));
create policy "documents_update" on documents for update to authenticated
  using (not rol_es('lectura')) with check (not rol_es('lectura'));
create policy "documents_delete" on documents for delete to authenticated
  using (rol_es('administrador','legal'));

-- Versiones: heredan la confidencialidad del documento padre
drop policy if exists "docversions_all" on document_versions;
create policy "docversions_select" on document_versions for select to authenticated
  using (
    exists (
      select 1 from documents d
      where d.id = document_versions.document_id
        and (
          d.confidentiality in ('publico','interno')
          or rol_es('administrador','director','legal','finanzas','representante_legal','gerente_licitaciones')
        )
    )
  );
create policy "docversions_insert" on document_versions for insert to authenticated
  with check (not rol_es('lectura'));
create policy "docversions_update" on document_versions for update to authenticated
  using (rol_es('administrador')) with check (rol_es('administrador'));
create policy "docversions_delete" on document_versions for delete to authenticated
  using (rol_es('administrador'));

-- ------------------------------------------------------------
-- 2. Licitaciones privadas: llegan por invitación, se capturan a mano
-- ------------------------------------------------------------
create policy "licitaciones_privadas_insert" on licitaciones_privadas for insert to authenticated
  with check (rol_es('administrador','director','gerente_licitaciones'));
create policy "licitaciones_privadas_update" on licitaciones_privadas for update to authenticated
  using (rol_es('administrador','director','gerente_licitaciones'))
  with check (rol_es('administrador','director','gerente_licitaciones'));
create policy "licitaciones_privadas_delete" on licitaciones_privadas for delete to authenticated
  using (rol_es('administrador'));

-- ------------------------------------------------------------
-- 3. Los 40 rubros de la constancia RPE 25564 (DGCP, 13/08/2026).
--    Antes solo había 5: se perdían licitaciones de los otros 35.
-- ------------------------------------------------------------
insert into jmc_rubros (familia_unspsc, descripcion, activo, origen, notas) values
  ('11110000','Tierra y piedra',true,'rpe',null),
  ('22100000','Maquinaria y equipo pesado de construcción',true,'rpe',null),
  ('23100000','Maquinaria para el procesamiento de materias primas',true,'rpe',null),
  ('23130000','Maquinaria y equipos lapidarios',true,'rpe',null),
  ('24100000','Maquinaria y equipo para manejo de materiales',true,'rpe',null),
  ('24130000','Refrigeración industrial',true,'rpe',null),
  ('26110000','Baterías y generadores y transmisión de energía cinética',true,'rpe',null),
  ('26120000','Alambres, cables y arneses',true,'rpe',null),
  ('27110000','Herramientas de mano',true,'rpe',null),
  ('30100000','Componentes estructurales y formas básicas',true,'rpe',null),
  ('30110000','Hormigón, cemento y yeso',true,'rpe',null),
  ('30130000','Productos de construcción estructurales',true,'rpe',null),
  ('30140000','Aislamiento',true,'rpe',null),
  ('30150000','Materiales para acabado de exteriores',true,'rpe',null),
  ('30160000','Materiales de acabado de interiores',true,'rpe',null),
  ('30170000','Puertas y ventanas y vidrio',true,'rpe',null),
  ('30180000','Instalaciones de plomería',true,'rpe',null),
  ('30190000','Equipo de apoyo para construcción y mantenimiento',true,'rpe',null),
  ('30200000','Estructuras prefabricadas',true,'rpe',null),
  ('30220000','Estructuras permanentes',true,'rpe',null),
  ('31150000','Cuerda, cadena, cable, alambre y correa',true,'rpe',null),
  ('31160000','Ferretería',true,'rpe',null),
  ('31170000','Rodamientos, cojinetes ruedas y engranajes',true,'rpe',null),
  ('31180000','Empaques, glándulas, fundas y cubiertas',true,'rpe',null),
  ('31200000','Adhesivos y selladores',true,'rpe',null),
  ('31210000','Pinturas y bases y acabados',true,'rpe',null),
  ('31250000','Sistemas de control neumático, hidráulico o eléctrico',true,'rpe',null),
  ('39100000','Lámparas y bombillas y componentes para lámparas',true,'rpe',null),
  ('39110000','Iluminación, artefactos y accesorios',true,'rpe',null),
  ('39120000','Equipos, suministros y componentes eléctricos',true,'rpe',null),
  ('40100000','Calefacción, ventilación y circulación del aire',true,'rpe',null),
  ('40140000','Distribución de fluidos y gas',true,'rpe',null),
  ('40150000','Bombas y compresores industriales',true,'rpe',null),
  ('40160000','Filtrado y purificación industrial',true,'rpe',null),
  ('72100000','Servicios de mantenimiento y reparaciones de construcciones e instalaciones',true,'rpe',null),
  ('72130000','Construcción general de edificios',true,'rpe','Rubro principal'),
  ('78130000','Almacenaje',true,'rpe',null),
  ('78140000','Servicios de transporte',true,'rpe',null),
  ('81100000','Servicios profesionales de ingeniería',true,'rpe',null),
  ('81110000','Servicios informáticos',true,'rpe',null)
on conflict (familia_unspsc) do update set
  descripcion = excluded.descripcion, activo = true, origen = 'rpe';

-- ------------------------------------------------------------
-- 4. Checklist de requisitos POR licitación.
--    La diferencia con el checklist genérico: compara la vigencia de cada
--    documento contra la fecha de cierre de ESA licitación, no contra hoy.
--    Un papel que vence antes del cierre no sirve, aunque hoy esté vigente.
--    SECURITY INVOKER (por defecto): respeta el RLS de `documents`.
-- ------------------------------------------------------------
do $$ begin
  create type estado_requisito_licitacion as enum
    ('listo', 'vence_antes_del_cierre', 'no_disponible', 'no_aplica');
exception when duplicate_object then null; end $$;

create or replace function public.checklist_por_licitacion(p_codigo_proceso text)
returns table (
  clave text, requisito text, obligatorio boolean, orden int, notas text,
  estado estado_requisito_licitacion, elementos int, evidencia jsonb
)
language plpgsql stable
as $function$
declare v_fecha_cierre timestamptz;
begin
  select fecha_fin_recepcion_ofertas into v_fecha_cierre
  from dgcp_procesos where codigo_proceso = p_codigo_proceso;

  -- Sin licitación o sin fecha publicada: compara contra hoy.
  v_fecha_cierre := coalesce(v_fecha_cierre, now());

  return query
  with docs_match as (
    select
      r.clave as r_clave, d.id, d.name, d.expiry_date, d.status, d.drive_url,
      (d.expiry_date is null or d.expiry_date >= v_fecha_cierre) as vigente_para_este_cierre
    from requisitos_oferta r
    join documents d
      on r.fuente = 'documents'
      and d.status not in ('no_aplica','no_disponible')
      and (d.name ilike '%' || split_part(r.requisito, ' ', 1) || '%'
           or d.doc_type ilike '%' || split_part(r.requisito, ' ', 1) || '%')
  )
  select
    r.clave, r.requisito, r.obligatorio, r.orden, r.notas,
    case r.fuente
      when 'companies' then
        case when exists (select 1 from companies where is_primary) then 'listo' else 'no_disponible' end
      when 'documents' then
        case
          when not exists (select 1 from docs_match m where m.r_clave = r.clave) then 'no_disponible'
          when exists (select 1 from docs_match m where m.r_clave = r.clave and m.vigente_para_este_cierre) then 'listo'
          else 'vence_antes_del_cierre'
        end
      when 'jmc_historial' then
        case when exists (select 1 from jmc_historial) then 'listo' else 'no_disponible' end
      when 'articulos' then
        case when exists (select 1 from articulos where tipo='equipo' and activo) then 'listo' else 'no_disponible' end
      when 'partidas' then
        case when exists (select 1 from partidas) then 'listo' else 'no_disponible' end
      else 'no_disponible'
    end::estado_requisito_licitacion as estado,
    coalesce((select count(*)::int from docs_match m where m.r_clave = r.clave), 0) as elementos,
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', m.name, 'vencimiento', m.expiry_date,
        'vigente_para_este_cierre', m.vigente_para_este_cierre, 'url', m.drive_url))
      from docs_match m where m.r_clave = r.clave
    ), '[]'::jsonb) as evidencia
  from requisitos_oferta r
  where r.lo_entrega = 'oferente'
  order by r.orden;
end;
$function$;

revoke all on function public.checklist_por_licitacion(text) from public;
grant execute on function public.checklist_por_licitacion(text) to authenticated;

-- ------------------------------------------------------------
-- 5. Presupuestos, APUs y banco de precios
-- ------------------------------------------------------------
do $$ begin
  create type tipo_insumo as enum ('material','mano_obra','equipo','subcontrato');
exception when duplicate_object then null; end $$;
do $$ begin
  create type tipo_presupuesto as enum ('oferta','proyecto');
exception when duplicate_object then null; end $$;
do $$ begin
  create type estado_presupuesto as enum ('borrador','revisado','enviado','ganador','descartado');
exception when duplicate_object then null; end $$;

create table if not exists insumos (
  id uuid primary key default gen_random_uuid(),
  codigo text,
  descripcion text not null,
  tipo tipo_insumo not null,
  unidad text not null,
  precio_referencia numeric,
  precio_actualizado_en date,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists idx_insumos_tipo on insumos(tipo);

-- El historial de precios NO se borra: permite ver la evolución y comparar
-- proveedores.
create table if not exists insumo_precios_historicos (
  id uuid primary key default gen_random_uuid(),
  insumo_id uuid not null references insumos(id) on delete cascade,
  proveedor text,
  precio numeric not null,
  cantidad numeric,
  proyecto_id uuid references proyectos(id),
  fuente text default 'manual',
  fecha date not null default current_date,
  registrado_por uuid references profiles(id),
  notas text,
  created_at timestamptz not null default now()
);
create index if not exists idx_precios_insumo on insumo_precios_historicos(insumo_id, fecha desc);

create or replace function actualizar_precio_referencia() returns trigger as $$
begin
  update insumos set precio_referencia = new.precio, precio_actualizado_en = new.fecha
  where id = new.insumo_id
    and (precio_actualizado_en is null or new.fecha >= precio_actualizado_en);
  return new;
end;
$$ language plpgsql set search_path = public;

drop trigger if exists trg_precio_historico_actualiza on insumo_precios_historicos;
create trigger trg_precio_historico_actualiza
  after insert on insumo_precios_historicos
  for each row execute function actualizar_precio_referencia();

-- Banco de APUs (Análisis de Precios Unitarios), reutilizable entre obras.
create table if not exists apus (
  id uuid primary key default gen_random_uuid(),
  codigo text,
  actividad text not null,
  unidad text not null,
  rendimiento numeric,
  notas text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists apu_insumos (
  id uuid primary key default gen_random_uuid(),
  apu_id uuid not null references apus(id) on delete cascade,
  insumo_id uuid references insumos(id),
  descripcion_libre text,
  cantidad numeric not null default 0,
  desperdicio_pct numeric not null default 0,
  precio_unitario numeric,
  orden int not null default 0
);
create index if not exists idx_apu_insumos_apu on apu_insumos(apu_id);

create or replace function costo_apu(p_apu_id uuid) returns numeric as $$
  select coalesce(sum(
    ai.cantidad * (1 + ai.desperdicio_pct/100.0) *
    coalesce(ai.precio_unitario, i.precio_referencia, 0)
  ), 0)
  from apu_insumos ai
  left join insumos i on i.id = ai.insumo_id
  where ai.apu_id = p_apu_id;
$$ language sql stable set search_path = public;

-- Presupuestos: de oferta (antes de ganar) o de proyecto (en ejecución).
create table if not exists presupuestos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  tipo tipo_presupuesto not null default 'oferta',
  oportunidad_id uuid references oportunidades(id),
  proyecto_id uuid references proyectos(id),
  moneda text not null default 'DOP',
  margen_pct numeric not null default 15,
  indirectos_pct numeric not null default 0,
  estado estado_presupuesto not null default 'borrador',
  responsable uuid references profiles(id),
  notas text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_presupuestos_oportunidad on presupuestos(oportunidad_id);
create index if not exists idx_presupuestos_proyecto on presupuestos(proyecto_id);

create table if not exists presupuesto_partidas (
  id uuid primary key default gen_random_uuid(),
  presupuesto_id uuid not null references presupuestos(id) on delete cascade,
  codigo text,
  descripcion text not null,
  unidad text not null,
  cantidad numeric not null default 0,
  apu_id uuid references apus(id),
  costo_unitario numeric,
  orden int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists idx_presupuesto_partidas_presupuesto on presupuesto_partidas(presupuesto_id);

drop trigger if exists trg_apus_updated on apus;
create trigger trg_apus_updated before update on apus for each row execute function set_updated_at();
drop trigger if exists trg_presupuestos_updated on presupuestos;
create trigger trg_presupuestos_updated before update on presupuestos for each row execute function set_updated_at();

create or replace view v_presupuesto_totales as
select
  p.id as presupuesto_id, p.nombre, p.tipo, p.moneda,
  p.margen_pct, p.indirectos_pct, p.estado, p.oportunidad_id, p.proyecto_id,
  coalesce(sum(pp.cantidad * coalesce(pp.costo_unitario, costo_apu(pp.apu_id), 0)), 0) as costo_directo,
  coalesce(sum(pp.cantidad * coalesce(pp.costo_unitario, costo_apu(pp.apu_id), 0)), 0)
    * (p.indirectos_pct / 100.0) as indirectos,
  coalesce(sum(pp.cantidad * coalesce(pp.costo_unitario, costo_apu(pp.apu_id), 0)), 0)
    * (1 + p.indirectos_pct / 100.0) as costo_total,
  coalesce(sum(pp.cantidad * coalesce(pp.costo_unitario, costo_apu(pp.apu_id), 0)), 0)
    * (1 + p.indirectos_pct / 100.0) * (p.margen_pct / 100.0) as utilidad,
  coalesce(sum(pp.cantidad * coalesce(pp.costo_unitario, costo_apu(pp.apu_id), 0)), 0)
    * (1 + p.indirectos_pct / 100.0) * (1 + p.margen_pct / 100.0) as precio_oferta,
  count(pp.id) as partidas
from presupuestos p
left join presupuesto_partidas pp on pp.presupuesto_id = p.id
group by p.id;

alter table insumos                   enable row level security;
alter table insumo_precios_historicos enable row level security;
alter table apus                      enable row level security;
alter table apu_insumos               enable row level security;
alter table presupuestos              enable row level security;
alter table presupuesto_partidas      enable row level security;

create policy "insumos_select" on insumos for select to authenticated using (true);
create policy "insumos_write" on insumos for insert to authenticated
  with check (rol_es('administrador','director','presupuesto','compras','ingenieria'));
create policy "insumos_update" on insumos for update to authenticated
  using (rol_es('administrador','director','presupuesto','compras','ingenieria'))
  with check (rol_es('administrador','director','presupuesto','compras','ingenieria'));
create policy "insumos_delete" on insumos for delete to authenticated using (rol_es('administrador'));

create policy "precios_select" on insumo_precios_historicos for select to authenticated using (true);
create policy "precios_insert" on insumo_precios_historicos for insert to authenticated
  with check (rol_es('administrador','director','presupuesto','compras','ingenieria'));
create policy "precios_delete" on insumo_precios_historicos for delete to authenticated using (rol_es('administrador'));

create policy "apus_select" on apus for select to authenticated using (true);
create policy "apus_write" on apus for insert to authenticated
  with check (rol_es('administrador','director','presupuesto','ingenieria'));
create policy "apus_update" on apus for update to authenticated
  using (rol_es('administrador','director','presupuesto','ingenieria'))
  with check (rol_es('administrador','director','presupuesto','ingenieria'));
create policy "apus_delete" on apus for delete to authenticated using (rol_es('administrador'));

create policy "apu_insumos_select" on apu_insumos for select to authenticated using (true);
create policy "apu_insumos_write" on apu_insumos for insert to authenticated
  with check (rol_es('administrador','director','presupuesto','ingenieria'));
create policy "apu_insumos_update" on apu_insumos for update to authenticated
  using (rol_es('administrador','director','presupuesto','ingenieria'))
  with check (rol_es('administrador','director','presupuesto','ingenieria'));
create policy "apu_insumos_delete" on apu_insumos for delete to authenticated
  using (rol_es('administrador','director','presupuesto','ingenieria'));

create policy "presupuestos_select" on presupuestos for select to authenticated using (true);
create policy "presupuestos_write" on presupuestos for insert to authenticated
  with check (rol_es('administrador','director','gerente_licitaciones','presupuesto'));
create policy "presupuestos_update" on presupuestos for update to authenticated
  using (rol_es('administrador','director','gerente_licitaciones','presupuesto'))
  with check (rol_es('administrador','director','gerente_licitaciones','presupuesto'));
create policy "presupuestos_delete" on presupuestos for delete to authenticated using (rol_es('administrador'));

create policy "presupuesto_partidas_select" on presupuesto_partidas for select to authenticated using (true);
create policy "presupuesto_partidas_write" on presupuesto_partidas for insert to authenticated
  with check (rol_es('administrador','director','gerente_licitaciones','presupuesto'));
create policy "presupuesto_partidas_update" on presupuesto_partidas for update to authenticated
  using (rol_es('administrador','director','gerente_licitaciones','presupuesto'))
  with check (rol_es('administrador','director','gerente_licitaciones','presupuesto'));
create policy "presupuesto_partidas_delete" on presupuesto_partidas for delete to authenticated
  using (rol_es('administrador','director','gerente_licitaciones','presupuesto'));

-- ------------------------------------------------------------
-- 6. Alta de usuarios desde Configuración.
--    SECURITY DEFINER es imprescindible (escribe en auth.users, que el rol
--    `authenticated` no puede tocar), pero la función comprueba POR DENTRO que
--    quien llama sea administrador. Sin esa comprobación sería un hueco.
-- ------------------------------------------------------------
create or replace function public.admin_crear_usuario(
  p_email text, p_password text, p_full_name text, p_role user_role
) returns uuid
language plpgsql security definer
set search_path = public, auth, extensions
as $function$
declare v_id uuid := gen_random_uuid();
begin
  if not rol_es('administrador') then
    raise exception 'Solo un administrador puede crear usuarios';
  end if;
  if p_password is null or length(p_password) < 8 then
    raise exception 'La contraseña debe tener al menos 8 caracteres';
  end if;
  if exists (select 1 from auth.users where email = lower(trim(p_email))) then
    raise exception 'Ya existe un usuario con ese correo';
  end if;

  -- Las 8 columnas de token van en '' (no NULL): con NULL, GoTrue falla al
  -- iniciar sesión con "Database error querying schema".
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token,
    email_change_token_current, phone_change, phone_change_token, reauthentication_token,
    raw_app_meta_data, raw_user_meta_data, is_super_admin
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
    lower(trim(p_email)), extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), now(), now(),
    '', '', '', '', '', '', '', '',
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('full_name', p_full_name),
    false
  );

  insert into auth.identities (
    provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
  ) values (
    v_id::text, v_id,
    jsonb_build_object('sub', v_id::text, 'email', lower(trim(p_email)), 'email_verified', true),
    'email', now(), now(), now()
  );

  insert into public.profiles (id, full_name, email, role, is_active)
  values (v_id, p_full_name, lower(trim(p_email)), p_role, true)
  on conflict (id) do update set
    full_name = excluded.full_name, email = excluded.email,
    role = excluded.role, is_active = true;

  return v_id;
end;
$function$;

revoke all on function public.admin_crear_usuario(text, text, text, user_role) from public, anon;
grant execute on function public.admin_crear_usuario(text, text, text, user_role) to authenticated;

create or replace function public.admin_cambiar_password(p_user_id uuid, p_password text)
returns void
language plpgsql security definer
set search_path = public, auth, extensions
as $function$
begin
  if not rol_es('administrador') then
    raise exception 'Solo un administrador puede cambiar contraseñas';
  end if;
  if p_password is null or length(p_password) < 8 then
    raise exception 'La contraseña debe tener al menos 8 caracteres';
  end if;
  update auth.users
  set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
      updated_at = now()
  where id = p_user_id;
end;
$function$;

revoke all on function public.admin_cambiar_password(uuid, text) from public, anon;
grant execute on function public.admin_cambiar_password(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- 7. Marca de licitación potencial: una estrella independiente del estado de
--    seguimiento, para destacar un proceso sin moverlo de etapa.
-- ------------------------------------------------------------
alter table oportunidades
  add column if not exists potencial boolean not null default false,
  add column if not exists potencial_marcada_en timestamptz;

create index if not exists idx_oportunidades_potencial on oportunidades(potencial) where potencial;

-- Las columnas nuevas van al final: create or replace view no permite
-- insertarlas en medio del select existente.
create or replace view v_oportunidades as
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
  p.estado_proceso = 'Proceso publicado'::text and p.fecha_fin_recepcion_ofertas > now() as abierta,
  extract(day from p.fecha_fin_recepcion_ofertas - now())::integer as dias_para_cierre,
  (select count(*) from dgcp_documentos d where d.codigo_proceso = p.codigo_proceso) as documentos,
  rub.rubros,
  adj.razon_social as adjudicado_a,
  adj.valor_contratado as valor_adjudicado,
  o.potencial,
  o.potencial_marcada_en,
  (current_date - p.fecha_publicacion::date)::integer as dias_desde_publicacion
from oportunidades o
join dgcp_procesos p on p.codigo_proceso = o.codigo_proceso
left join dgcp_unidades_compra u on u.codigo_unidad_compra = p.codigo_unidad_compra
left join lateral (
  select array_agg(distinct r.descripcion order by r.descripcion) as rubros
  from dgcp_articulos a
  join jmc_rubros r on r.familia_unspsc = a.familia_unspsc and r.activo
  where a.codigo_proceso = p.codigo_proceso
) rub on true
left join lateral (
  select c.razon_social, c.valor_contratado
  from dgcp_contratos c
  where c.codigo_proceso = p.codigo_proceso
  order by c.valor_contratado desc nulls last
  limit 1
) adj on true;
