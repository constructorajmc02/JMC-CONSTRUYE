-- ============================================================
-- Expediente Maestro — fundación del esquema.
-- Construido por un tercero (agosto 2026); exportado aquí desde Supabase para
-- que el esquema completo sea reconstruible desde el repositorio.
-- Guarda los papeles que JMC necesita tener al día para calificar en una
-- licitación: registro mercantil, RPE, estados financieros, actas, cuentas.
-- ============================================================

create extension if not exists "pgcrypto";

-- ENUMS
do $$ begin
  create type user_role as enum (
    'administrador','director','gerente_licitaciones','presupuesto',
    'compras','ingenieria','legal','finanzas','representante_legal','lectura');
exception when duplicate_object then null; end $$;

do $$ begin
  create type stakeholder_role as enum (
    'socio','administrador','representante_legal','beneficiario_final','gerente','otro');
exception when duplicate_object then null; end $$;

do $$ begin
  create type doc_status as enum (
    'vigente','proximo_vencer','vencido','en_renovacion','no_disponible','no_aplica');
exception when duplicate_object then null; end $$;

do $$ begin
  create type rpe_status as enum (
    'activo','desactualizado','provisional','suspendido','inhabilitado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type confidentiality_level as enum ('publico','interno','confidencial','restringido');
exception when duplicate_object then null; end $$;

-- ------------------------------------------------------------
-- Usuarios y roles
-- ------------------------------------------------------------
create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  email      text,
  role       user_role not null default 'lectura',
  phone      text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function current_user_role() returns user_role as $$
  select role from public.profiles where id = auth.uid();
$$ language sql security definer stable set search_path = public;

create or replace function handle_new_user() returns trigger as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', new.email));
  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ------------------------------------------------------------
-- Empresa, accionistas y cuentas
-- ------------------------------------------------------------
create table if not exists companies (
  id                  uuid primary key default gen_random_uuid(),
  legal_name          text not null,
  trade_name          text,
  rnc                 text,
  rpe                 text,
  company_type        text,
  incorporation_date  date,
  mercantile_registry text,
  social_object       text,
  address             text,
  phones              text,
  emails              text,
  website             text,
  is_primary          boolean not null default false,
  notes               text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table if not exists commercial_activities (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id) on delete cascade,
  code       text,
  name       text not null,
  is_primary boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists company_stakeholders (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references companies(id) on delete cascade,
  role          stakeholder_role not null,
  full_name     text not null,
  id_document   text,
  nationality   text,
  position      text,
  ownership_pct numeric,
  is_pep        boolean default false,
  email         text,
  phone         text,
  notes         text,
  created_at    timestamptz not null default now()
);

create table if not exists bank_accounts (
  id                uuid primary key default gen_random_uuid(),
  company_id        uuid not null references companies(id) on delete cascade,
  bank_name         text not null,
  account_number    text,
  account_type      text,
  currency          text default 'DOP',
  is_rpe_registered boolean default false,
  notes             text,
  created_at        timestamptz not null default now()
);

create table if not exists rpe_records (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references companies(id) on delete cascade,
  rpe_number   text,
  status       rpe_status not null default 'activo',
  consulted_at date,
  updated_on   date,
  categories   text,
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Documentos, versiones y control de vencimiento
-- ------------------------------------------------------------
create table if not exists document_categories (
  id         uuid primary key default gen_random_uuid(),
  key        text unique not null,
  name       text not null,
  sort_order int default 0
);

create table if not exists documents (
  id                  uuid primary key default gen_random_uuid(),
  company_id          uuid references companies(id) on delete cascade,
  category_id         uuid references document_categories(id),
  doc_type            text,
  name                text not null,
  description         text,
  responsible_id      uuid references profiles(id),
  issuing_authority   text,
  document_number     text,
  issue_date          date,
  expiry_date         date,
  status              doc_status not null default 'vigente',
  version             int not null default 1,
  requires_signature  boolean default false,
  is_signed           boolean default false,
  is_notarized        boolean default false,
  is_legalized        boolean default false,
  confidentiality     confidentiality_level not null default 'interno',
  observations        text,
  -- enlace con Google Drive y Storage
  drive_file_id       text,
  drive_url           text,
  drive_modified_time timestamptz,
  storage_path        text,
  file_name           text,
  mime_type           text,
  file_size           bigint,
  drive_folder_path   text,
  source              text not null default 'manual',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists idx_documents_company  on documents(company_id);
create index if not exists idx_documents_category on documents(category_id);
create index if not exists idx_documents_expiry   on documents(expiry_date);
create index if not exists idx_documents_status   on documents(status);
create unique index if not exists idx_documents_drive_file_id
  on documents(drive_file_id) where drive_file_id is not null;

create table if not exists document_versions (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references documents(id) on delete cascade,
  version     int not null,
  file_path   text,
  file_name   text,
  file_size   bigint,
  mime_type   text,
  issue_date  date,
  expiry_date date,
  uploaded_by uuid references profiles(id),
  notes       text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_docversions_document on document_versions(document_id);

create table if not exists alert_thresholds (
  id          uuid primary key default gen_random_uuid(),
  days_before int not null unique,
  is_active   boolean not null default true
);

-- ------------------------------------------------------------
-- Sincronización con Google Drive
-- ------------------------------------------------------------
create table if not exists drive_sync_state (
  id             int primary key default 1,
  root_folder_id text,
  last_run_at    timestamptz,
  last_status    text,
  files_seen     int default 0,
  files_uploaded int default 0,
  files_updated  int default 0,
  error          text,
  constraint drive_sync_singleton check (id = 1)
);

create table if not exists drive_sync_log (
  id            uuid primary key default gen_random_uuid(),
  run_at        timestamptz not null default now(),
  action        text,          -- inserted / updated / skipped / error
  drive_file_id text,
  file_name     text,
  detail        text
);

-- ------------------------------------------------------------
-- Disparadores
-- ------------------------------------------------------------
create or replace function set_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end;
$$ language plpgsql set search_path = pg_catalog, pg_temp;

drop trigger if exists trg_profiles_updated  on profiles;
drop trigger if exists trg_companies_updated on companies;
drop trigger if exists trg_rpe_updated       on rpe_records;
drop trigger if exists trg_documents_updated on documents;
create trigger trg_profiles_updated  before update on profiles    for each row execute function set_updated_at();
create trigger trg_companies_updated before update on companies   for each row execute function set_updated_at();
create trigger trg_rpe_updated       before update on rpe_records for each row execute function set_updated_at();
create trigger trg_documents_updated before update on documents   for each row execute function set_updated_at();

create or replace function compute_doc_status(p_expiry date, p_current doc_status)
returns doc_status as $$
declare max_days int;
begin
  if p_current in ('en_renovacion','no_disponible','no_aplica') then return p_current; end if;
  if p_expiry is null then return 'vigente'; end if;
  select coalesce(max(days_before), 30) into max_days from alert_thresholds where is_active;
  if p_expiry < current_date then return 'vencido';
  elsif p_expiry <= current_date + max_days then return 'proximo_vencer';
  else return 'vigente';
  end if;
end;
$$ language plpgsql set search_path = public;

create or replace function trg_documents_status() returns trigger as $$
begin
  new.status = compute_doc_status(new.expiry_date, new.status);
  return new;
end;
$$ language plpgsql set search_path = public;

drop trigger if exists trg_documents_set_status on documents;
create trigger trg_documents_set_status
  before insert or update on documents
  for each row execute function trg_documents_status();

create or replace function refresh_all_document_status() returns void as $$
begin
  update documents set status = compute_doc_status(expiry_date, status)
  where status not in ('en_renovacion','no_disponible','no_aplica');
end;
$$ language plpgsql set search_path = public;

-- ------------------------------------------------------------
-- Permisos
--
-- NOTA: estas políticas solo comprueban que el usuario esté autenticado; NO
-- filtran por rol. En la práctica cualquiera que entre ve los estados
-- financieros y las cuentas bancarias. Se dejan como estaban porque
-- endurecerlas puede romper la aplicación Next.js que las usa, cuyo código no
-- está en este repositorio. Ver 0003 para el patrón correcto por rol.
-- ------------------------------------------------------------
alter table profiles              enable row level security;
alter table companies             enable row level security;
alter table commercial_activities enable row level security;
alter table company_stakeholders  enable row level security;
alter table bank_accounts         enable row level security;
alter table rpe_records           enable row level security;
alter table document_categories   enable row level security;
alter table documents             enable row level security;
alter table document_versions     enable row level security;
alter table alert_thresholds      enable row level security;
alter table drive_sync_state      enable row level security;
alter table drive_sync_log        enable row level security;

drop policy if exists "profiles_select"       on profiles;
drop policy if exists "profiles_update_self"  on profiles;
drop policy if exists "profiles_admin_delete" on profiles;
create policy "profiles_select"       on profiles for select to authenticated using (true);
create policy "profiles_update_self"  on profiles for update to authenticated
  using (auth.uid() = id or current_user_role() = 'administrador')
  with check (auth.uid() = id or current_user_role() = 'administrador');
create policy "profiles_admin_delete" on profiles for delete to authenticated
  using (current_user_role() = 'administrador');

drop policy if exists "companies_all"    on companies;
drop policy if exists "activities_all"   on commercial_activities;
drop policy if exists "stakeholders_all" on company_stakeholders;
drop policy if exists "bank_all"         on bank_accounts;
drop policy if exists "rpe_all"          on rpe_records;
drop policy if exists "doccat_all"       on document_categories;
drop policy if exists "documents_all"    on documents;
drop policy if exists "docversions_all"  on document_versions;
drop policy if exists "thresholds_all"   on alert_thresholds;
drop policy if exists "sync_state_read"  on drive_sync_state;
drop policy if exists "sync_log_read"    on drive_sync_log;
create policy "companies_all"    on companies             for all to authenticated using (true) with check (true);
create policy "activities_all"   on commercial_activities for all to authenticated using (true) with check (true);
create policy "stakeholders_all" on company_stakeholders  for all to authenticated using (true) with check (true);
create policy "bank_all"         on bank_accounts         for all to authenticated using (true) with check (true);
create policy "rpe_all"          on rpe_records           for all to authenticated using (true) with check (true);
create policy "doccat_all"       on document_categories   for all to authenticated using (true) with check (true);
create policy "documents_all"    on documents             for all to authenticated using (true) with check (true);
create policy "docversions_all"  on document_versions     for all to authenticated using (true) with check (true);
create policy "thresholds_all"   on alert_thresholds      for all to authenticated using (true) with check (true);
create policy "sync_state_read"  on drive_sync_state      for select to authenticated using (true);
create policy "sync_log_read"    on drive_sync_log        for select to authenticated using (true);

revoke all on function public.current_user_role() from public;
grant execute on function public.current_user_role() to authenticated;
revoke all on function public.handle_new_user() from public;

-- ------------------------------------------------------------
-- Storage (bucket privado para los documentos)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
  values ('documentos', 'documentos', false)
  on conflict (id) do nothing;

drop policy if exists "documentos_auth_read"   on storage.objects;
drop policy if exists "documentos_auth_write"  on storage.objects;
drop policy if exists "documentos_auth_update" on storage.objects;
drop policy if exists "documentos_auth_delete" on storage.objects;
create policy "documentos_auth_read"   on storage.objects for select to authenticated using (bucket_id = 'documentos');
create policy "documentos_auth_write"  on storage.objects for insert to authenticated with check (bucket_id = 'documentos');
create policy "documentos_auth_update" on storage.objects for update to authenticated using (bucket_id = 'documentos');
create policy "documentos_auth_delete" on storage.objects for delete to authenticated using (bucket_id = 'documentos');

-- ------------------------------------------------------------
-- Semilla
-- ------------------------------------------------------------
insert into alert_thresholds (days_before) values (90),(60),(30),(15),(7),(1)
  on conflict (days_before) do nothing;

insert into document_categories (key, name, sort_order) values
  ('legal','Legal',1), ('fiscal','Fiscal',2), ('laboral','Laboral',3),
  ('financiera','Financiera',4), ('tecnica','Técnica',5), ('equipos','Equipos',6),
  ('personal','Personal',7), ('calidad','Calidad',8), ('seguridad','Seguridad',9)
  on conflict (key) do nothing;

insert into drive_sync_state (id, root_folder_id)
  values (1, '1RVdTF547lO_W1IdvYLuH4SVLLssG9Upe')
  on conflict (id) do nothing;
