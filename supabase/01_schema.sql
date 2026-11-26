-- =============================================================================
-- Spices Cafe — Supabase schema
-- File 1 of 3. Run in the Supabase SQL Editor BEFORE 02_seed.sql.
--
-- Safe to re-run: types, tables, functions, triggers and policies are all
-- created with "if not exists" / "or replace" / "drop ... if exists".
--
-- Security model
--   * Customers (anon key) can READ the menu + settings, QUOTE a cart and
--     READ one order by its secret tracking token. Nothing else.
--   * Orders are created ONLY by public.place_order(), which is callable only
--     with the service_role key (i.e. from the Next.js server, after rate
--     limiting + honeypot). Prices are always recalculated in the database.
--   * Admins log in with Supabase Auth. A user is an admin only if they have
--     an active row in public.staff_members. Roles: OWNER (everything) and
--     STAFF (orders + sold-out toggles only).
--   * Order status can only change through public.update_order_status(),
--     which validates the allowed transitions.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Enum types
-- -----------------------------------------------------------------------------
do $$ begin create type public.item_type      as enum ('ITEM', 'DEAL');
exception when duplicate_object then null; end $$;

do $$ begin create type public.order_type     as enum ('DELIVERY', 'TAKEAWAY', 'DINE_IN');
exception when duplicate_object then null; end $$;

do $$ begin create type public.order_status   as enum ('PENDING', 'CONFIRMED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY', 'COMPLETED', 'CANCELLED');
exception when duplicate_object then null; end $$;

-- Add JazzCash / Easypaisa / card later with:
--   alter type public.payment_method add value 'JAZZCASH';
do $$ begin create type public.payment_method as enum ('COD', 'PAY_AT_COUNTER');
exception when duplicate_object then null; end $$;

do $$ begin create type public.payment_status as enum ('UNPAID', 'PAID', 'REFUNDED');
exception when duplicate_object then null; end $$;

do $$ begin create type public.order_source   as enum ('WEB', 'WHATSAPP', 'ADMIN');
exception when duplicate_object then null; end $$;

do $$ begin create type public.staff_role     as enum ('OWNER', 'STAFF');
exception when duplicate_object then null; end $$;


-- -----------------------------------------------------------------------------
-- 2. Tables — menu
--    All money is INTEGER rupees.
-- -----------------------------------------------------------------------------
create table if not exists public.categories (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  slug         text not null unique,
  subtitle     text,                       -- e.g. "Premium Appetizers Collection"
  description  text,
  image_url    text,
  sort_order   int  not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.menu_items (
  id            uuid primary key default gen_random_uuid(),
  category_id   uuid not null references public.categories(id) on delete restrict,
  type          public.item_type not null default 'ITEM',
  name          text not null,
  slug          text not null unique,
  section       text,                      -- sub-heading inside a category, e.g. "Curated Wings Selection"
  tagline       text,                      -- e.g. "Herb-Crusted Delight"
  description   text,
  includes      text[] not null default '{}',  -- deal / platter contents, shown as bullets
  serving_note  text,                      -- e.g. "4 pcs + dip sauce"
  image_url     text,
  is_spicy      boolean not null default false,
  is_new        boolean not null default false,
  is_featured   boolean not null default false,
  is_available  boolean not null default true, -- false = sold out
  sort_order    int not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);

-- Every item has at least one variant. Single-price items have one "Regular" variant.
create table if not exists public.item_variants (
  id             uuid primary key default gen_random_uuid(),
  item_id        uuid not null references public.menu_items(id) on delete cascade,
  label          text not null,            -- "Regular", "5 pcs", "Small", "F1", ...
  price          int  not null check (price >= 0),
  price_dine_in  int  check (price_dine_in is null or price_dine_in >= 0), -- override for DINE_IN orders
  sort_order     int  not null default 0,
  is_available   boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (item_id, label)
);

create table if not exists public.add_on_groups (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  slug         text not null unique,
  description  text,
  min_select   int  not null default 0 check (min_select >= 0),
  max_select   int  check (max_select is null or max_select >= 1), -- null = no limit
  sort_order   int  not null default 0,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- price = flat price. If price is NULL the add-on is priced per variant size
-- through public.add_on_prices (e.g. Extra Toppings: Small 70 / Medium 100 ...).
create table if not exists public.add_ons (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid not null references public.add_on_groups(id) on delete cascade,
  name          text not null,
  price         int  check (price is null or price >= 0),
  sort_order    int  not null default 0,
  is_available  boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (group_id, name)
);

create table if not exists public.add_on_prices (
  id          uuid primary key default gen_random_uuid(),
  add_on_id   uuid not null references public.add_ons(id) on delete cascade,
  size_label  text not null,               -- must match item_variants.label, e.g. "Large"
  price       int  not null check (price >= 0),
  unique (add_on_id, size_label)
);

-- Which add-on groups apply to which categories / individual items.
create table if not exists public.add_on_group_categories (
  group_id     uuid not null references public.add_on_groups(id) on delete cascade,
  category_id  uuid not null references public.categories(id)   on delete cascade,
  primary key (group_id, category_id)
);

create table if not exists public.add_on_group_items (
  group_id  uuid not null references public.add_on_groups(id) on delete cascade,
  item_id   uuid not null references public.menu_items(id)    on delete cascade,
  primary key (group_id, item_id)
);


-- -----------------------------------------------------------------------------
-- 3. Tables — settings & staff
-- -----------------------------------------------------------------------------
create table if not exists public.settings (
  id                   boolean primary key default true check (id), -- single row
  cafe_name            text not null default 'Spices Cafe',
  tagline              text,
  address              text,
  phones               text[] not null default '{}',   -- display format, e.g. '0317-0078675'
  whatsapp_number      text,                            -- international, digits only, e.g. '923491919877'
  email                text,
  social_links         jsonb not null default '{}',     -- {"facebook": "...", "instagram": "...", "x": "..."}
  -- {"mon": {"open": "12:00", "close": "01:00"}, "tue": null, ...}
  -- null / missing day = closed that day. close <= open means it closes after midnight.
  -- An EMPTY object {} means "hours not set" and only is_accepting_orders is used.
  opening_hours        jsonb not null default '{}',
  timezone             text not null default 'Asia/Karachi',
  is_accepting_orders  boolean not null default true,
  closed_message       text,
  delivery_fee         int not null default 0 check (delivery_fee >= 0),
  free_delivery_above  int check (free_delivery_above is null or free_delivery_above >= 0),
  minimum_order        int not null default 0 check (minimum_order >= 0),
  prep_minutes         int check (prep_minutes is null or prep_minutes >= 0),
  delivery_minutes     int check (delivery_minutes is null or delivery_minutes >= 0),
  delivery_areas       text,
  map_embed_url        text,
  announcement         text,
  logo_url             text,                            -- uploaded in admin; placeholder used when empty
  hero_image_url       text,                            -- home page hero photo; placeholder when empty
  updated_at           timestamptz not null default now(),
  updated_by           uuid
);
-- (for databases created before these columns existed)
alter table public.settings add column if not exists logo_url text;
alter table public.settings add column if not exists hero_image_url text;

-- Admin accounts. Login itself is Supabase Auth (auth.users); this table says
-- who is staff and with which role.
create table if not exists public.staff_members (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  name           text not null,
  email          text,
  role           public.staff_role not null default 'STAFF',
  is_active      boolean not null default true,
  last_login_at  timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);


-- -----------------------------------------------------------------------------
-- 4. Tables — orders
-- -----------------------------------------------------------------------------
-- Per-day counter used to build order numbers like SC-261126-0042.
create table if not exists public.order_counters (
  day         date primary key,
  last_value  int  not null
);

create table if not exists public.orders (
  id                   uuid primary key default gen_random_uuid(),
  order_number         text not null unique,
  tracking_token       text not null unique,
  order_type           public.order_type not null,
  status               public.order_status not null default 'PENDING',
  customer_name        text not null check (char_length(customer_name) between 2 and 80),
  customer_phone       text not null check (customer_phone ~ '^03[0-9]{9}$'), -- normalised 03XXXXXXXXX
  address              text check (address  is null or char_length(address)  <= 300),
  area                 text check (area     is null or char_length(area)     <= 100),
  landmark             text check (landmark is null or char_length(landmark) <= 150),
  table_number         text check (table_number is null or char_length(table_number) <= 20),
  pickup_time          timestamptz,          -- TAKEAWAY only; null = ASAP
  notes                text check (notes is null or char_length(notes) <= 500),
  subtotal             int not null check (subtotal >= 0),
  delivery_fee         int not null default 0 check (delivery_fee >= 0),
  discount             int not null default 0 check (discount >= 0),
  total                int not null check (total >= 0),
  payment_method       public.payment_method not null,
  payment_status       public.payment_status not null default 'UNPAID',
  source               public.order_source   not null default 'WEB',
  cancel_reason        text,
  seen_at              timestamptz,          -- first opened in admin (stops the "new" highlight)
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  confirmed_at         timestamptz,
  preparing_at         timestamptz,
  ready_at             timestamptz,
  out_for_delivery_at  timestamptz,
  completed_at         timestamptz,
  cancelled_at         timestamptz,
  constraint delivery_needs_address
    check (order_type <> 'DELIVERY' or (address is not null and char_length(btrim(address)) > 0)),
  constraint total_adds_up
    check (total = subtotal + delivery_fee - discount)
);

-- Snapshot of what was ordered. Never changes when the menu changes later.
create table if not exists public.order_items (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  menu_item_id   uuid references public.menu_items(id)    on delete set null,
  variant_id     uuid references public.item_variants(id) on delete set null,
  item_name      text not null,
  item_type      public.item_type not null default 'ITEM',
  variant_label  text not null,
  unit_price     int  not null check (unit_price >= 0),      -- variant price actually charged
  quantity       int  not null check (quantity between 1 and 50),
  add_ons        jsonb not null default '[]',                 -- [{"id": "...", "name": "Cheese Slice", "price": 60}]
  add_ons_total  int  not null default 0 check (add_ons_total >= 0), -- per unit
  notes          text check (notes is null or char_length(notes) <= 200),
  line_total     int  not null check (line_total >= 0),       -- (unit_price + add_ons_total) * quantity
  sort_order     int  not null default 0
);

create table if not exists public.order_status_history (
  id          bigint generated always as identity primary key,
  order_id    uuid not null references public.orders(id) on delete cascade,
  status      public.order_status not null,
  note        text,
  changed_by  uuid references auth.users(id) on delete set null, -- null = customer / system
  created_at  timestamptz not null default now()
);

-- Admin change log (price edits, sold-out toggles, settings, staff changes).
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  actor       uuid,                        -- auth.uid() of the admin, null = SQL editor / service
  table_name  text not null,
  row_id      text,
  action      text not null,               -- INSERT / UPDATE / DELETE
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);


-- -----------------------------------------------------------------------------
-- 5. Indexes
-- -----------------------------------------------------------------------------
create index if not exists menu_items_category_idx   on public.menu_items (category_id, sort_order);
create index if not exists menu_items_featured_idx   on public.menu_items (is_featured) where is_featured;
create index if not exists item_variants_item_idx    on public.item_variants (item_id, sort_order);
create index if not exists add_ons_group_idx         on public.add_ons (group_id, sort_order);
create index if not exists add_on_group_items_item_idx on public.add_on_group_items (item_id);
create index if not exists add_on_group_cats_cat_idx on public.add_on_group_categories (category_id);
create index if not exists orders_status_created_idx on public.orders (status, created_at desc);
create index if not exists orders_created_idx        on public.orders (created_at desc);
create index if not exists orders_phone_idx          on public.orders (customer_phone);
create index if not exists order_items_order_idx     on public.order_items (order_id);
create index if not exists order_items_menu_item_idx on public.order_items (menu_item_id);
create index if not exists order_history_order_idx   on public.order_status_history (order_id, created_at);
create index if not exists audit_log_created_idx     on public.audit_log (created_at desc);


-- -----------------------------------------------------------------------------
-- 6. Helper functions
-- -----------------------------------------------------------------------------

-- Is the logged-in user an active admin (any role)?
create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.staff_members
    where user_id = auth.uid() and is_active
  );
$$;

-- Is the logged-in user an active OWNER?
create or replace function public.is_owner()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.staff_members
    where user_id = auth.uid() and is_active and role = 'OWNER'
  );
$$;

-- '0349-1919877', '+92 349 1919877', '923491919877' -> '03491919877'. Invalid -> null.
create or replace function public.normalize_phone(p text)
returns text
language plpgsql immutable set search_path = ''
as $$
declare d text := regexp_replace(coalesce(p, ''), '[\s\-\(\)]', '', 'g');
begin
  if d ~ '^\+923[0-9]{9}$' then d := '0' || substr(d, 4);
  elsif d ~ '^923[0-9]{9}$' then d := '0' || substr(d, 3);
  elsif d ~ '^00923[0-9]{9}$' then d := '0' || substr(d, 5);
  end if;
  if d ~ '^03[0-9]{9}$' then return d; end if;
  return null;
end;
$$;

-- Open right now? = accepting orders AND (no hours set OR inside today's hours).
create or replace function public.is_store_open()
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  s      public.settings;
  v_now  timestamp;
  t      time;
  today  jsonb;
  yday   jsonb;
  o      time;
  c      time;
begin
  select * into s from public.settings where id;
  if not found or not s.is_accepting_orders then return false; end if;
  if s.opening_hours is null or s.opening_hours = '{}'::jsonb then return true; end if;

  v_now := now() at time zone s.timezone;
  t     := v_now::time;
  today := s.opening_hours -> to_char(v_now, 'dy');                     -- 'mon', 'tue', ...
  yday  := s.opening_hours -> to_char(v_now - interval '1 day', 'dy');

  if jsonb_typeof(today) = 'object' then
    o := (today ->> 'open')::time;
    c := (today ->> 'close')::time;
    if c > o then
      if t >= o and t < c then return true; end if;
    else                                    -- closes after midnight
      if t >= o then return true; end if;
    end if;
  end if;

  -- still inside yesterday's after-midnight hours?
  if jsonb_typeof(yday) = 'object' then
    o := (yday ->> 'open')::time;
    c := (yday ->> 'close')::time;
    if c <= o and t < c then return true; end if;
  end if;

  return false;
end;
$$;


-- -----------------------------------------------------------------------------
-- 7. Pricing engine (single source of truth for prices)
--
-- Input (jsonb):
--   {
--     "order_type": "DELIVERY" | "TAKEAWAY" | "DINE_IN",
--     "items": [
--       { "variant_id": "<uuid>", "quantity": 2,
--         "add_on_ids": ["<uuid>", ...], "notes": "no onions" }
--     ]
--   }
-- Any prices sent by the browser are IGNORED.
--
-- Output: lines (with per-line "error" when an item is sold out / invalid),
-- errors[], subtotal, delivery_fee, discount, total, minimum_order, meets_minimum.
-- -----------------------------------------------------------------------------
create or replace function public._price_order(p jsonb)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  s              public.settings;
  v_type         public.order_type;
  line           jsonb;
  idx            int := 0;
  v              record;
  qty            int;
  unit           int;
  addon_ids      uuid[];
  addons         jsonb;
  addons_total   int;
  n_ok           int;
  line_total     int;
  err            text;
  lines          jsonb := '[]'::jsonb;
  errors         jsonb := '[]'::jsonb;
  subtotal       int := 0;
  fee            int := 0;
begin
  select * into s from public.settings where id;
  if not found then raise exception 'Store settings are missing'; end if;

  begin
    v_type := (p ->> 'order_type')::public.order_type;
  exception when others then
    raise exception 'Please choose Delivery, Take Away or Dine-in';
  end;
  if v_type is null then raise exception 'Please choose Delivery, Take Away or Dine-in'; end if;

  if jsonb_typeof(p -> 'items') is distinct from 'array' or jsonb_array_length(p -> 'items') = 0 then
    raise exception 'Your cart is empty';
  end if;
  if jsonb_array_length(p -> 'items') > 50 then
    raise exception 'Too many different items in one order';
  end if;

  for line in select value from jsonb_array_elements(p -> 'items') loop
    idx := idx + 1;
    err := null;
    addons := '[]'::jsonb;
    addons_total := 0;
    unit := 0;
    line_total := 0;

    qty := case when (line ->> 'quantity') ~ '^[0-9]{1,3}$' then (line ->> 'quantity')::int else 0 end;

    select iv.id as variant_id, iv.label, iv.price, iv.price_dine_in, iv.is_available as variant_ok,
           mi.id as item_id, mi.name, mi.type, mi.is_available as item_ok, mi.category_id,
           c.is_active as category_ok
      into v
      from public.item_variants iv
      join public.menu_items mi on mi.id = iv.item_id
      join public.categories c  on c.id  = mi.category_id
     where iv.id = case when (line ->> 'variant_id') ~* '^[0-9a-f-]{36}$'
                        then (line ->> 'variant_id')::uuid end;

    if not found then
      err := 'An item in your cart is no longer on the menu';
    elsif not (v.variant_ok and v.item_ok and v.category_ok) then
      err := format('%s (%s) is sold out', v.name, v.label);
    elsif qty < 1 or qty > 50 then
      err := format('Please choose a quantity between 1 and 50 for %s', v.name);
    end if;

    if err is null then
      unit := case when v_type = 'DINE_IN' and v.price_dine_in is not null
                   then v.price_dine_in else v.price end;

      -- requested add-ons (ignore malformed ids, de-duplicate)
      addon_ids := coalesce(array(
        select distinct x::uuid
          from jsonb_array_elements_text(
                 case when jsonb_typeof(line -> 'add_on_ids') = 'array' then line -> 'add_on_ids' else '[]'::jsonb end) x
         where x ~* '^[0-9a-f-]{36}$'
      ), '{}');

      if cardinality(addon_ids) > 0 then
        select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'price', coalesce(ap.price, a.price))
                                  order by g.sort_order, a.sort_order), '[]'::jsonb),
               coalesce(sum(coalesce(ap.price, a.price)), 0),
               count(*)
          into addons, addons_total, n_ok
          from public.add_ons a
          join public.add_on_groups g on g.id = a.group_id
          left join public.add_on_prices ap on ap.add_on_id = a.id and ap.size_label = v.label
         where a.id = any(addon_ids)
           and a.is_available and g.is_active
           and coalesce(ap.price, a.price) is not null
           and (exists (select 1 from public.add_on_group_items gi
                         where gi.group_id = g.id and gi.item_id = v.item_id)
                or exists (select 1 from public.add_on_group_categories gc
                            where gc.group_id = g.id and gc.category_id = v.category_id));

        if n_ok <> cardinality(addon_ids) then
          err := format('An extra chosen for %s is not available', v.name);
        elsif exists (
          select 1 from public.add_ons a join public.add_on_groups g on g.id = a.group_id
           where a.id = any(addon_ids)
           group by g.id, g.max_select
          having g.max_select is not null and count(*) > g.max_select) then
          err := format('Too many extras chosen for %s', v.name);
        end if;
      end if;

      -- required groups (min_select > 0) that apply to this item
      if err is null and exists (
        select 1 from public.add_on_groups g
         where g.is_active and g.min_select > 0
           and (exists (select 1 from public.add_on_group_items gi where gi.group_id = g.id and gi.item_id = v.item_id)
                or exists (select 1 from public.add_on_group_categories gc where gc.group_id = g.id and gc.category_id = v.category_id))
           and (select count(*) from public.add_ons a where a.group_id = g.id and a.id = any(addon_ids)) < g.min_select) then
        err := format('Please choose the required options for %s', v.name);
      end if;
    end if;

    if err is null then
      line_total := (unit + addons_total) * qty;
      subtotal   := subtotal + line_total;
    else
      errors := errors || jsonb_build_object('index', idx - 1, 'message', err);
    end if;

    lines := lines || jsonb_build_object(
      'index',         idx - 1,
      'ok',            err is null,
      'error',         err,
      'item_id',       v.item_id,
      'variant_id',    v.variant_id,
      'item_name',     v.name,
      'item_type',     v.type,
      'variant_label', v.label,
      'unit_price',    unit,
      'quantity',      qty,
      'add_ons',       addons,
      'add_ons_total', addons_total,
      'notes',         nullif(left(btrim(coalesce(line ->> 'notes', '')), 200), ''),
      'line_total',    line_total
    );
  end loop;

  if v_type = 'DELIVERY' then
    fee := case when s.free_delivery_above is not null and subtotal >= s.free_delivery_above
                then 0 else s.delivery_fee end;
  end if;

  return jsonb_build_object(
    'order_type',     v_type,
    'lines',          lines,
    'errors',         errors,
    'subtotal',       subtotal,
    'delivery_fee',   fee,
    'discount',       0,
    'total',          subtotal + fee,
    'minimum_order',  s.minimum_order,
    'meets_minimum',  subtotal >= s.minimum_order,
    'is_open',        public.is_store_open()
  );
end;
$$;

-- Public wrapper: lets the cart / checkout show server-confirmed prices and
-- re-validate a saved cart. Read-only.
create or replace function public.quote_order(p jsonb)
returns jsonb
language sql stable security definer set search_path = ''
as $$ select public._price_order(p); $$;


-- -----------------------------------------------------------------------------
-- 8. Place order (service_role only — call from the Next.js server)
--
-- Input = quote input plus:
--   customer_name, customer_phone, address, area, landmark (DELIVERY),
--   pickup_time (TAKEAWAY, ISO timestamp or null for ASAP),
--   table_number (DINE_IN), notes, payment_method, source ('WEB' default)
-- Returns: { order_id, order_number, tracking_token, total }
-- -----------------------------------------------------------------------------
create or replace function public.place_order(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  s          public.settings;
  q          jsonb;
  v_type     public.order_type;
  v_source   public.order_source := coalesce(nullif(p ->> 'source', ''), 'WEB')::public.order_source;
  v_payment  public.payment_method;
  v_name     text := btrim(coalesce(p ->> 'customer_name', ''));
  v_phone    text := public.normalize_phone(p ->> 'customer_phone');
  v_address  text := nullif(btrim(coalesce(p ->> 'address', '')), '');
  v_area     text := nullif(btrim(coalesce(p ->> 'area', '')), '');
  v_landmark text := nullif(btrim(coalesce(p ->> 'landmark', '')), '');
  v_table    text := nullif(btrim(coalesce(p ->> 'table_number', '')), '');
  v_notes    text := nullif(btrim(coalesce(p ->> 'notes', '')), '');
  v_pickup   timestamptz;
  v_day      date;
  v_n        int;
  v_number   text;
  v_token    text;
  v_order_id uuid;
begin
  select * into s from public.settings where id;

  -- Admin-entered orders (phone/WhatsApp) may be taken while web ordering is off.
  if v_source = 'WEB' and not public.is_store_open() then
    raise exception using message = coalesce(nullif(s.closed_message, ''),
      'Sorry, we are not taking online orders right now. Please call us.');
  end if;

  q := public._price_order(p);
  v_type := (q ->> 'order_type')::public.order_type;

  if jsonb_array_length(q -> 'errors') > 0 then
    raise exception using message = q -> 'errors' -> 0 ->> 'message';
  end if;
  if not (q ->> 'meets_minimum')::boolean then
    raise exception using message = format('Minimum order is Rs %s', s.minimum_order);
  end if;

  -- customer details
  if char_length(v_name) < 2 or char_length(v_name) > 80 then
    raise exception 'Please enter your name';
  end if;
  if v_phone is null then
    raise exception 'Please enter a valid mobile number, e.g. 03XXXXXXXXX';
  end if;

  if v_type = 'DELIVERY' then
    if v_address is null or char_length(v_address) < 5 then
      raise exception 'Please enter your delivery address';
    end if;
  else
    v_address := null; v_area := null; v_landmark := null;
  end if;

  if v_type = 'TAKEAWAY' and nullif(p ->> 'pickup_time', '') is not null then
    begin
      v_pickup := (p ->> 'pickup_time')::timestamptz;
    exception when others then
      raise exception 'Please choose a valid pickup time';
    end;
    if v_pickup < now() - interval '5 minutes' or v_pickup > now() + interval '18 hours' then
      raise exception 'Please choose a pickup time later today';
    end if;
  end if;

  if v_type <> 'DINE_IN' then v_table := null; end if;

  if char_length(coalesce(v_address, '')) > 300 or char_length(coalesce(v_notes, '')) > 500
     or char_length(coalesce(v_area, '')) > 100 or char_length(coalesce(v_landmark, '')) > 150
     or char_length(coalesce(v_table, '')) > 20 then
    raise exception 'Some of the details you entered are too long';
  end if;

  v_payment := coalesce(nullif(p ->> 'payment_method', ''),
                        case when v_type = 'DELIVERY' then 'COD' else 'PAY_AT_COUNTER' end)::public.payment_method;

  -- order number: SC-YYMMDD-NNNN, sequential per day (cafe time zone)
  v_day := (now() at time zone s.timezone)::date;
  insert into public.order_counters (day, last_value) values (v_day, 1)
  on conflict (day) do update set last_value = public.order_counters.last_value + 1
  returning last_value into v_n;
  v_number := 'SC-' || to_char(v_day, 'YYMMDD') || '-' || lpad(v_n::text, 4, '0');

  -- 64 hex chars, ~244 bits of randomness
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  insert into public.orders (
    order_number, tracking_token, order_type, customer_name, customer_phone,
    address, area, landmark, table_number, pickup_time, notes,
    subtotal, delivery_fee, discount, total, payment_method, source
  ) values (
    v_number, v_token, v_type, v_name, v_phone,
    v_address, v_area, v_landmark, v_table, v_pickup, v_notes,
    (q ->> 'subtotal')::int, (q ->> 'delivery_fee')::int, (q ->> 'discount')::int, (q ->> 'total')::int,
    v_payment, v_source
  ) returning id into v_order_id;

  insert into public.order_items (
    order_id, menu_item_id, variant_id, item_name, item_type, variant_label,
    unit_price, quantity, add_ons, add_ons_total, notes, line_total, sort_order
  )
  select v_order_id, (l ->> 'item_id')::uuid, (l ->> 'variant_id')::uuid, l ->> 'item_name',
         (l ->> 'item_type')::public.item_type, l ->> 'variant_label',
         (l ->> 'unit_price')::int, (l ->> 'quantity')::int, l -> 'add_ons', (l ->> 'add_ons_total')::int,
         l ->> 'notes', (l ->> 'line_total')::int, ord::int
    from jsonb_array_elements(q -> 'lines') with ordinality as t(l, ord);

  insert into public.order_status_history (order_id, status, note, changed_by)
  values (v_order_id, 'PENDING', 'Order placed', auth.uid());

  return jsonb_build_object(
    'order_id',       v_order_id,
    'order_number',   v_number,
    'tracking_token', v_token,
    'total',          (q ->> 'total')::int
  );
end;
$$;


-- -----------------------------------------------------------------------------
-- 9. Customer order tracking
-- -----------------------------------------------------------------------------
-- Returns one order by its secret token (null if not found). Safe for anon.
create or replace function public.get_order_by_token(p_token text)
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'order_number',        o.order_number,
    'status',              o.status,
    'order_type',          o.order_type,
    'customer_name',       o.customer_name,
    'customer_phone',      o.customer_phone,
    'address',             o.address,
    'area',                o.area,
    'landmark',            o.landmark,
    'table_number',        o.table_number,
    'pickup_time',         o.pickup_time,
    'notes',               o.notes,
    'subtotal',            o.subtotal,
    'delivery_fee',        o.delivery_fee,
    'discount',            o.discount,
    'total',               o.total,
    'payment_method',      o.payment_method,
    'payment_status',      o.payment_status,
    'cancel_reason',       o.cancel_reason,
    'created_at',          o.created_at,
    'confirmed_at',        o.confirmed_at,
    'preparing_at',        o.preparing_at,
    'ready_at',            o.ready_at,
    'out_for_delivery_at', o.out_for_delivery_at,
    'completed_at',        o.completed_at,
    'cancelled_at',        o.cancelled_at,
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'name', oi.item_name, 'variant', oi.variant_label, 'quantity', oi.quantity,
               'unit_price', oi.unit_price, 'add_ons', oi.add_ons, 'notes', oi.notes,
               'line_total', oi.line_total) order by oi.sort_order), '[]'::jsonb)
        from public.order_items oi where oi.order_id = o.id),
    'timeline', (
      select coalesce(jsonb_agg(jsonb_build_object('status', h.status, 'at', h.created_at)
                                order by h.created_at, h.id), '[]'::jsonb)
        from public.order_status_history h where h.order_id = o.id)
  )
  from public.orders o
  where char_length(p_token) = 64 and o.tracking_token = p_token;
$$;

-- /track page: order number + phone -> tracking token. Service_role only
-- (the Next.js route rate-limits it to stop guessing).
create or replace function public.find_order_token(p_order_number text, p_phone text)
returns text
language sql stable security definer set search_path = ''
as $$
  select tracking_token from public.orders
   where order_number = upper(btrim(p_order_number))
     and customer_phone = public.normalize_phone(p_phone);
$$;


-- -----------------------------------------------------------------------------
-- 10. Admin actions (checked inside each function)
-- -----------------------------------------------------------------------------

-- Allowed status flow:
--   PENDING -> CONFIRMED -> PREPARING -> READY -> OUT_FOR_DELIVERY (delivery only) -> COMPLETED
--   READY -> COMPLETED for Take Away / Dine-in
--   Any status before COMPLETED -> CANCELLED (reason required)
create or replace function public.can_transition(p_from public.order_status, p_to public.order_status, p_type public.order_type)
returns boolean
language sql immutable set search_path = ''
as $$
  select case
    when p_from in ('COMPLETED', 'CANCELLED') then false
    when p_to = 'CANCELLED' then true
    when p_from = 'PENDING'          then p_to = 'CONFIRMED'
    when p_from = 'CONFIRMED'        then p_to = 'PREPARING'
    when p_from = 'PREPARING'        then p_to = 'READY'
    when p_from = 'READY'            then (p_type =  'DELIVERY' and p_to = 'OUT_FOR_DELIVERY')
                                       or (p_type <> 'DELIVERY' and p_to = 'COMPLETED')
    when p_from = 'OUT_FOR_DELIVERY' then p_to = 'COMPLETED'
    else false
  end;
$$;

create or replace function public.update_order_status(p_order_id uuid, p_status public.order_status, p_note text default null)
returns public.orders
language plpgsql volatile security definer set search_path = ''
as $$
declare
  o     public.orders;
  note  text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_staff() then raise exception 'Not allowed'; end if;

  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Order not found'; end if;

  if not public.can_transition(o.status, p_status, o.order_type) then
    raise exception 'Cannot change order % from % to %', o.order_number, o.status, p_status;
  end if;
  if p_status = 'CANCELLED' and note is null then
    raise exception 'Please give a reason for cancelling';
  end if;

  update public.orders set
    status              = p_status,
    seen_at             = coalesce(seen_at, now()),
    confirmed_at        = case when p_status = 'CONFIRMED'        then now() else confirmed_at end,
    preparing_at        = case when p_status = 'PREPARING'        then now() else preparing_at end,
    ready_at            = case when p_status = 'READY'            then now() else ready_at end,
    out_for_delivery_at = case when p_status = 'OUT_FOR_DELIVERY' then now() else out_for_delivery_at end,
    completed_at        = case when p_status = 'COMPLETED'        then now() else completed_at end,
    cancelled_at        = case when p_status = 'CANCELLED'        then now() else cancelled_at end,
    cancel_reason       = case when p_status = 'CANCELLED'        then note  else cancel_reason end,
    payment_status      = case when p_status = 'COMPLETED' and payment_status = 'UNPAID' then 'PAID'::public.payment_status
                               else payment_status end
  where id = p_order_id
  returning * into o;

  insert into public.order_status_history (order_id, status, note, changed_by)
  values (p_order_id, p_status, note, auth.uid());

  return o;
end;
$$;

-- Admin opened the order: stop the "new order" highlight.
create or replace function public.mark_order_seen(p_order_id uuid)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not public.is_staff() then raise exception 'Not allowed'; end if;
  update public.orders set seen_at = now() where id = p_order_id and seen_at is null;
end;
$$;

-- Sold-out toggles (STAFF and OWNER). Everything else on the menu is OWNER-only.
create or replace function public.set_item_availability(p_item_id uuid, p_available boolean)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not public.is_staff() then raise exception 'Not allowed'; end if;
  update public.menu_items set is_available = p_available, updated_by = auth.uid() where id = p_item_id;
  if not found then raise exception 'Item not found'; end if;
end;
$$;

create or replace function public.set_variant_availability(p_variant_id uuid, p_available boolean)
returns void
language plpgsql volatile security definer set search_path = ''
as $$
begin
  if not public.is_staff() then raise exception 'Not allowed'; end if;
  update public.item_variants set is_available = p_available where id = p_variant_id;
  if not found then raise exception 'Size not found'; end if;
end;
$$;

-- Call right after a successful admin login.
create or replace function public.touch_last_login()
returns void
language sql volatile security definer set search_path = ''
as $$
  update public.staff_members set last_login_at = now() where user_id = auth.uid();
$$;

-- Dashboard numbers for a time range (OWNER only).
create or replace function public.get_dashboard_stats(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare r jsonb;
begin
  if not public.is_owner() then raise exception 'Not allowed'; end if;

  with o as (
    select * from public.orders where created_at >= p_from and created_at < p_to
  )
  select jsonb_build_object(
    'orders_count',    (select count(*) from o where status <> 'CANCELLED'),
    'cancelled_count', (select count(*) from o where status =  'CANCELLED'),
    'pending_count',   (select count(*) from o where status =  'PENDING'),
    'revenue',         (select coalesce(sum(total), 0) from o where status = 'COMPLETED'),
    'avg_order_value', (select coalesce(round(avg(total))::int, 0) from o where status = 'COMPLETED'),
    'by_type', (select coalesce(jsonb_object_agg(order_type, n), '{}'::jsonb)
                  from (select order_type, count(*) n from o where status <> 'CANCELLED' group by order_type) t),
    'top_items', (select coalesce(jsonb_agg(jsonb_build_object('name', item_name, 'quantity', qty, 'revenue', rev)
                                            order by qty desc, rev desc), '[]'::jsonb)
                    from (select oi.item_name, sum(oi.quantity) qty, sum(oi.line_total) rev
                            from public.order_items oi join o on o.id = oi.order_id
                           where o.status <> 'CANCELLED'
                           group by oi.item_name
                           order by qty desc, rev desc
                           limit 5) t)
  ) into r;

  return r;
end;
$$;


-- -----------------------------------------------------------------------------
-- 11. Triggers: updated_at + audit log
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.write_audit_log()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.audit_log (actor, table_name, row_id, action, old_data, new_data)
  values (
    auth.uid(),
    tg_table_name,
    coalesce(v_row ->> 'id', v_row ->> 'user_id', v_row ->> 'add_on_id'),
    tg_op,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );
  return null;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['categories', 'menu_items', 'item_variants', 'add_on_groups', 'add_ons',
                           'settings', 'staff_members', 'orders']
  loop
    execute format('create or replace trigger %I before update on public.%I
                    for each row execute function public.set_updated_at()', t || '_updated_at', t);
  end loop;

  foreach t in array array['categories', 'menu_items', 'item_variants', 'add_on_groups', 'add_ons',
                           'add_on_prices', 'settings', 'staff_members']
  loop
    execute format('create or replace trigger %I after insert or update or delete on public.%I
                    for each row execute function public.write_audit_log()', t || '_audit', t);
  end loop;
end $$;


-- -----------------------------------------------------------------------------
-- 12. Row Level Security
-- -----------------------------------------------------------------------------
alter table public.categories              enable row level security;
alter table public.menu_items              enable row level security;
alter table public.item_variants           enable row level security;
alter table public.add_on_groups           enable row level security;
alter table public.add_ons                 enable row level security;
alter table public.add_on_prices           enable row level security;
alter table public.add_on_group_categories enable row level security;
alter table public.add_on_group_items      enable row level security;
alter table public.settings                enable row level security;
alter table public.staff_members           enable row level security;
alter table public.order_counters          enable row level security;
alter table public.orders                  enable row level security;
alter table public.order_items             enable row level security;
alter table public.order_status_history    enable row level security;
alter table public.audit_log               enable row level security;

-- Menu tables: everyone reads, OWNER writes.
-- (Inactive categories are hidden from customers; sold-out items stay visible
--  so the site can show a "Sold out" badge.)
do $$
declare t text;
begin
  foreach t in array array['menu_items', 'item_variants', 'add_on_groups', 'add_ons', 'add_on_prices',
                           'add_on_group_categories', 'add_on_group_items', 'settings']
  loop
    execute format('drop policy if exists "public read" on public.%I', t);
    execute format('create policy "public read" on public.%I for select to anon, authenticated using (true)', t);
  end loop;

  foreach t in array array['categories', 'menu_items', 'item_variants', 'add_on_groups', 'add_ons', 'add_on_prices',
                           'add_on_group_categories', 'add_on_group_items']
  loop
    execute format('drop policy if exists "owner insert" on public.%I', t);
    execute format('drop policy if exists "owner update" on public.%I', t);
    execute format('drop policy if exists "owner delete" on public.%I', t);
    execute format('create policy "owner insert" on public.%I for insert to authenticated with check ((select public.is_owner()))', t);
    execute format('create policy "owner update" on public.%I for update to authenticated using ((select public.is_owner())) with check ((select public.is_owner()))', t);
    execute format('create policy "owner delete" on public.%I for delete to authenticated using ((select public.is_owner()))', t);
  end loop;
end $$;

drop policy if exists "public read active" on public.categories;
create policy "public read active" on public.categories
  for select to anon, authenticated
  using (is_active or (select public.is_staff()));

drop policy if exists "owner update" on public.settings;
create policy "owner update" on public.settings
  for update to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));

-- Staff: everyone sees their own row; OWNER manages all.
-- (Creating the login itself needs the service_role key: done by the Next.js server.)
drop policy if exists "self or owner read" on public.staff_members;
create policy "self or owner read" on public.staff_members
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_owner()));

drop policy if exists "owner insert" on public.staff_members;
create policy "owner insert" on public.staff_members
  for insert to authenticated with check ((select public.is_owner()));

drop policy if exists "owner update" on public.staff_members;
create policy "owner update" on public.staff_members
  for update to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));

drop policy if exists "owner delete" on public.staff_members;
create policy "owner delete" on public.staff_members
  for delete to authenticated using ((select public.is_owner()) and user_id <> (select auth.uid()));

-- Orders: staff read only. Writes go through the functions above.
drop policy if exists "staff read" on public.orders;
create policy "staff read" on public.orders
  for select to authenticated using ((select public.is_staff()));

drop policy if exists "staff read" on public.order_items;
create policy "staff read" on public.order_items
  for select to authenticated using ((select public.is_staff()));

drop policy if exists "staff read" on public.order_status_history;
create policy "staff read" on public.order_status_history
  for select to authenticated using ((select public.is_staff()));

drop policy if exists "owner read" on public.audit_log;
create policy "owner read" on public.audit_log
  for select to authenticated using ((select public.is_owner()));

-- order_counters: no policies -> only security-definer functions touch it.


-- -----------------------------------------------------------------------------
-- 13. Grants (explicit, so nothing is exposed by accident)
-- -----------------------------------------------------------------------------
-- Only the cafe's own tables are touched, never other tables in the schema.
revoke all on public.categories, public.menu_items, public.item_variants, public.add_on_groups,
              public.add_ons, public.add_on_prices, public.add_on_group_categories,
              public.add_on_group_items, public.settings, public.staff_members, public.order_counters,
              public.orders, public.order_items, public.order_status_history, public.audit_log
  from anon, authenticated;
revoke all on sequence public.order_status_history_id_seq, public.audit_log_id_seq from anon, authenticated;

grant select on public.categories, public.menu_items, public.item_variants, public.add_on_groups,
                public.add_ons, public.add_on_prices, public.add_on_group_categories,
                public.add_on_group_items, public.settings
  to anon, authenticated;

grant insert, update, delete on public.categories, public.menu_items, public.item_variants,
                public.add_on_groups, public.add_ons, public.add_on_prices,
                public.add_on_group_categories, public.add_on_group_items
  to authenticated;
grant update on public.settings to authenticated;
grant select, insert, update, delete on public.staff_members to authenticated;
grant select on public.orders, public.order_items, public.order_status_history, public.audit_log
  to authenticated;

grant all on public.categories, public.menu_items, public.item_variants, public.add_on_groups,
             public.add_ons, public.add_on_prices, public.add_on_group_categories,
             public.add_on_group_items, public.settings, public.staff_members, public.order_counters,
             public.orders, public.order_items, public.order_status_history, public.audit_log
  to service_role;
grant all on sequence public.order_status_history_id_seq, public.audit_log_id_seq to service_role;

-- Functions: lock the cafe's functions down, then open what each role needs.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('is_staff', 'is_owner', 'normalize_phone', 'is_store_open', '_price_order',
                         'quote_order', 'place_order', 'get_order_by_token', 'find_order_token',
                         'can_transition', 'update_order_status', 'mark_order_seen',
                         'set_item_availability', 'set_variant_availability', 'touch_last_login',
                         'get_dashboard_stats', 'set_updated_at', 'write_audit_log')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

grant execute on function public.is_staff()                                     to anon, authenticated, service_role;
grant execute on function public.is_owner()                                     to anon, authenticated, service_role;
grant execute on function public.is_store_open()                                to anon, authenticated, service_role;
grant execute on function public.normalize_phone(text)                          to anon, authenticated, service_role;
grant execute on function public.quote_order(jsonb)                             to anon, authenticated, service_role;
grant execute on function public.get_order_by_token(text)                       to anon, authenticated, service_role;
grant execute on function public.can_transition(public.order_status, public.order_status, public.order_type)
                                                                                to authenticated, service_role;

grant execute on function public.update_order_status(uuid, public.order_status, text) to authenticated, service_role;
grant execute on function public.mark_order_seen(uuid)                          to authenticated, service_role;
grant execute on function public.set_item_availability(uuid, boolean)           to authenticated, service_role;
grant execute on function public.set_variant_availability(uuid, boolean)        to authenticated, service_role;
grant execute on function public.touch_last_login()                             to authenticated, service_role;
grant execute on function public.get_dashboard_stats(timestamptz, timestamptz)  to authenticated, service_role;

grant execute on function public.place_order(jsonb)                             to service_role;
grant execute on function public.find_order_token(text, text)                   to service_role;
grant execute on function public._price_order(jsonb)                            to service_role;


-- -----------------------------------------------------------------------------
-- 14. Realtime: admin "Live orders" screen gets new orders instantly
--     (RLS above means only staff receive them).
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders') then
    alter publication supabase_realtime add table public.orders;
  end if;
end $$;


-- -----------------------------------------------------------------------------
-- 15. Storage bucket for menu photos (public read, OWNER upload, max 5 MB)
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('menu-images', 'menu-images', true, 5242880, array['image/webp', 'image/jpeg', 'image/png', 'image/avif'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "menu images owner select" on storage.objects;
create policy "menu images owner select" on storage.objects
  for select to authenticated
  using (bucket_id = 'menu-images' and (select public.is_owner()));

drop policy if exists "menu images owner insert" on storage.objects;
create policy "menu images owner insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'menu-images' and (select public.is_owner()));

drop policy if exists "menu images owner update" on storage.objects;
create policy "menu images owner update" on storage.objects
  for update to authenticated
  using (bucket_id = 'menu-images' and (select public.is_owner()))
  with check (bucket_id = 'menu-images' and (select public.is_owner()));

drop policy if exists "menu images owner delete" on storage.objects;
create policy "menu images owner delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'menu-images' and (select public.is_owner()));

-- Done. Next: run 02_seed.sql
