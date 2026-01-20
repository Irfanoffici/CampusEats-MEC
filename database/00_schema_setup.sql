-- ==============================================================================
-- CampusEats Database Schema
-- ==============================================================================

-- 1. Enable UUID extension
create extension if not exists "uuid-ossp";

-- 2. Create Schemas
create schema if not exists core;
create schema if not exists orders;
create schema if not exists payments;
create schema if not exists vendors;
create schema if not exists logs;
create schema if not exists analytics;
create schema if not exists config;

-- 3. Define Roles Enum (used in core.roles or directly in users)
create type core.app_role as enum ('student', 'vendor', 'admin', 'super_admin');

-- ==============================================================================
-- SCHEMA: LOGS (Immutable System Logs)
-- ==============================================================================
create table logs.system_events (
    id uuid primary key default uuid_generate_v4(),
    event_type text not null,
    actor_id uuid references auth.users(id),
    target_resource text,
    payload jsonb,
    severity text default 'info',
    created_at timestamptz default now()
);

-- Security: Immutable Logs
alter table logs.system_events enable row level security;

-- Policy: SuperAdmin can read, but NO ONE can update/delete
create policy "SuperAdmin can view logs"
    on logs.system_events for select
    using ( core.get_user_role(auth.uid()) = 'super_admin' );

create policy "System can insert logs"
    on logs.system_events for insert
    with check ( true ); -- Application level logic to insert

-- Revoke all update/delete permissions
revoke update, delete on logs.system_events from public, authenticated, service_role;

-- ==============================================================================
-- SCHEMA: CORE (Users & Roles)
-- ==============================================================================
create table core.profiles (
    id uuid primary key references auth.users(id),
    email text,
    full_name text,
    role core.app_role default 'student',
    avatar_url text,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

alter table core.profiles enable row level security;

-- Helper function to get role (critical for RLS)
create or replace function core.get_user_role(user_id uuid)
returns core.app_role as $$
begin
    return (select role from core.profiles where id = user_id);
end;
$$ language plpgsql security definer;

-- Policies for Profiles
create policy "Public profiles are viewable by everyone"
    on core.profiles for select
    using ( true );

create policy "Users can update own profile"
    on core.profiles for update
    using ( auth.uid() = id );

-- ==============================================================================
-- SCHEMA: VENDORS
-- ==============================================================================
create table vendors.shops (
    id uuid primary key default uuid_generate_v4(),
    owner_id uuid references auth.users(id),
    name text not null,
    description text,
    is_open boolean default false,
    rating numeric(3, 2) default 0.0,
    created_at timestamptz default now()
);

alter table vendors.shops enable row level security;

create policy "Anyone can view open shops"
    on vendors.shops for select
    using ( true );

create policy "Vendors manage their own shop"
    on vendors.shops for all
    using ( auth.uid() = owner_id );

create table vendors.menu_items (
    id uuid primary key default uuid_generate_v4(),
    shop_id uuid references vendors.shops(id),
    name text not null,
    description text,
    price numeric(10, 2) not null,
    is_available boolean default true,
    image_url text,
    created_at timestamptz default now()
);

alter table vendors.menu_items enable row level security;

create policy "Anyone can view menu items"
    on vendors.menu_items for select
    using ( true );

create policy "Shop owners manage menu"
    on vendors.menu_items for all
    using ( exists (
        select 1 from vendors.shops s
        where s.id = vendors.menu_items.shop_id
        and s.owner_id = auth.uid()
    ));

-- ==============================================================================
-- SCHEMA: CONFIG (Feature Flags)
-- ==============================================================================
create table config.feature_flags (
    key text primary key,
    is_enabled boolean default false,
    description text
);

alter table config.feature_flags enable row level security;

create policy "Read enabled flags"
    on config.feature_flags for select
    using ( true );

create policy "SuperAdmin manages flags"
    on config.feature_flags for all
    using ( core.get_user_role(auth.uid()) = 'super_admin' );

-- Seed Flags
insert into config.feature_flags (key, is_enabled, description) values
('ENABLE_RFID', false, 'Enable RFID payment hooks'),
('ENABLE_SUPER_ANALYTICS', false, 'Enable advanced analytics dashboard');
