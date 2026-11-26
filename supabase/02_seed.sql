-- =============================================================================
-- Spices Cafe — seed data (full menu from SPICES-CAFE-MENU.md)
-- File 2 of 3. Run AFTER 01_schema.sql.
--
-- Re-runnable: it only ADDS rows that are missing (matched by slug / label).
-- It never overwrites anything, so prices or names you later change in the
-- admin panel are safe if this file is run again.
--
-- Fixes applied from "Notes on the Source PDF":
--   * phone is always 0349-1919877, brand is always "Spices Cafe"
--   * the Rs 500 duplicate "Spices Special Sandwich" is seeded as
--     "Spices Special Jalapeno Sandwich" (TODO: confirm real name with client)
--   * pasta sizes kept as F1 / F2 (TODO: confirm meaning with client)
--   * Signature pizza "Extra Large" is stored as "X-Large" so the Extra
--     Toppings per-size prices match every pizza
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Temporary helpers (pg_temp = removed automatically when the session ends)
-- -----------------------------------------------------------------------------
create temp table if not exists _seed_sort (cat text primary key, n int not null);
truncate _seed_sort;

create or replace function pg_temp.slugify(t text)
returns text language sql immutable as $$
  select trim(both '-' from regexp_replace(lower(replace(t, '&', 'and')), '[^a-z0-9]+', '-', 'g'));
$$;

create or replace function pg_temp.cat(p_sort int, p_name text, p_subtitle text default null, p_description text default null)
returns void language plpgsql as $$
begin
  insert into public.categories (name, slug, subtitle, description, sort_order)
  values (p_name, pg_temp.slugify(p_name), p_subtitle, p_description, p_sort)
  on conflict (slug) do nothing;
end;
$$;

-- p_variants: [["label", price], ["label", price, dine_in_price], ...]
-- p_opts keys: type, section, tagline, description, includes[], serving_note, spicy, new, featured, slug
create or replace function pg_temp.item(p_cat text, p_name text, p_variants jsonb, p_opts jsonb default '{}'::jsonb)
returns uuid language plpgsql as $$
declare
  v_cat  uuid;
  v_id   uuid;
  v_sort int;
  v_slug text := coalesce(p_opts ->> 'slug', pg_temp.slugify(p_name));
  e      jsonb;
  i      int := 0;
begin
  select id into v_cat from public.categories where slug = p_cat;
  if v_cat is null then raise exception 'Seed: unknown category %', p_cat; end if;

  insert into _seed_sort (cat, n) values (p_cat, 1)
  on conflict (cat) do update set n = _seed_sort.n + 1
  returning n into v_sort;

  insert into public.menu_items (category_id, type, name, slug, section, tagline, description, includes,
                                 serving_note, is_spicy, is_new, is_featured, sort_order)
  values (
    v_cat,
    coalesce(p_opts ->> 'type', 'ITEM')::public.item_type,
    p_name,
    v_slug,
    p_opts ->> 'section',
    p_opts ->> 'tagline',
    p_opts ->> 'description',
    coalesce(array(select jsonb_array_elements_text(p_opts -> 'includes')), '{}'),
    p_opts ->> 'serving_note',
    coalesce((p_opts ->> 'spicy')::boolean, false),
    coalesce((p_opts ->> 'new')::boolean, false),
    coalesce((p_opts ->> 'featured')::boolean, false),
    v_sort
  )
  on conflict (slug) do nothing;

  select id into v_id from public.menu_items where slug = v_slug;

  for e in select value from jsonb_array_elements(p_variants) loop
    i := i + 1;
    insert into public.item_variants (item_id, label, price, price_dine_in, sort_order)
    values (v_id, e ->> 0, (e ->> 1)::int, (e ->> 2)::int, i)
    on conflict (item_id, label) do nothing;
  end loop;

  return v_id;
end;
$$;


-- -----------------------------------------------------------------------------
-- Settings (contact details from the menu file; unknowns left as safe placeholders)
-- -----------------------------------------------------------------------------
insert into public.settings (
  id, cafe_name, tagline, address, phones, whatsapp_number, social_links, opening_hours,
  is_accepting_orders, closed_message, delivery_fee, free_delivery_above, minimum_order,
  delivery_areas, announcement
) values (
  true,
  'Spices Cafe',
  'Premium Dining Experience',
  '7/9-R Rehman Garh, 6KM Kacha Khuh, Abdul Hakim Road',
  array['0317-0078675', '0349-1919877'],
  '923491919877',
  '{}'::jsonb,          -- social links: add real URLs in admin (none known yet)
  '{}'::jsonb,          -- opening hours: TODO set in admin (unknown)
  true,
  'We are closed right now. Please check our opening hours or call us.',
  0,                    -- delivery fee: TODO confirm with client
  null,                 -- free delivery threshold: TODO
  0,                    -- minimum order: TODO
  null,                 -- delivery areas: TODO
  null
)
on conflict (id) do nothing;


-- -----------------------------------------------------------------------------
-- Categories (17, in menu order)
-- -----------------------------------------------------------------------------
select pg_temp.cat( 1, 'Appetizers',           'Premium Appetizers Collection');
select pg_temp.cat( 2, 'Fries',                'Curated Fries Collection');
select pg_temp.cat( 3, 'Pasta',                null, 'Two sizes: F1 (smaller) and F2 (larger).');
select pg_temp.cat( 4, 'Paratha Rolls');
select pg_temp.cat( 5, 'Shawarma');
select pg_temp.cat( 6, 'Burgers',              null, 'Add a cheese slice to any burger for Rs 60.');
select pg_temp.cat( 7, 'Spices Special Rolls', null, 'Served as 4 pcs + dip sauce.');
select pg_temp.cat( 8, 'Sandwiches',           'Special Sandwich Collection',
  'Loaded with a signature blend of spices and fresh chilies, with flavorful spiced chicken, melted mozzarella cheese or extra-crispy chicken fillets, on custom herbed flatbreads with golden-herbed crusts. Served with a large portion of golden, seasoned fries. Signature Spices Special CRUNCH sauce available.');
select pg_temp.cat( 9, 'Special Platters');
select pg_temp.cat(10, 'Traditional Pizzas',   null, 'All traditional pizzas share the same price per size.');
select pg_temp.cat(11, 'Signature Pizzas');
select pg_temp.cat(12, 'New Launches');
select pg_temp.cat(13, 'Burger Deals');
select pg_temp.cat(14, 'Crunchy Deals');
select pg_temp.cat(15, 'Pizza Deals',          'Exquisite Pizza Deals');
select pg_temp.cat(16, 'Family Deals',         'Premium Dining Experience');
select pg_temp.cat(17, 'Extras');


-- -----------------------------------------------------------------------------
-- 1. Appetizers
-- -----------------------------------------------------------------------------
select pg_temp.item('appetizers', 'Classic Chicken Nuggets', '[["5 pcs",250],["10 pcs",500]]',
  '{"section":"Chicken Nuggets","description":"Classic, crispy-cut, perfectly fried golden nuggets."}');
select pg_temp.item('appetizers', 'Arabian Nuggets', '[["5 pcs",350],["10 pcs",700]]',
  '{"section":"Chicken Nuggets","description":"Crispy nuggets with rich Arabian spices and flavors."}');

select pg_temp.item('appetizers', 'Hot Wings', '[["5 pcs",300],["10 pcs",600]]',
  '{"section":"Curated Wings Selection","description":"Our classic spicy wings, expertly sauced with bold flavor."}');
select pg_temp.item('appetizers', 'Oven Baked Wings', '[["5 pcs",300],["10 pcs",600]]',
  '{"section":"Curated Wings Selection","description":"Slow-cooked in our custom ovens for a unique tenderness."}');
select pg_temp.item('appetizers', 'Peri Peri Wings', '[["5 pcs",300],["10 pcs",600]]',
  '{"section":"Curated Wings Selection","description":"Tossed in a fiery peri-peri glaze with zesty heat."}');
select pg_temp.item('appetizers', 'Malai Wings', '[["5 pcs",300],["10 pcs",600]]',
  '{"section":"Curated Wings Selection","description":"Creamy and mild, with delicate cardamom and spice."}');

select pg_temp.item('appetizers', 'Spicy Hot Shots', '[["5 pcs",300],["10 pcs",600]]',
  '{"section":"Spicy Hot Shots","description":"A fiery experience; loaded with small, perfectly seasoned, extra-crisp chicken bites tossed in our signature spice blend."}');


-- -----------------------------------------------------------------------------
-- 2. Fries
-- -----------------------------------------------------------------------------
select pg_temp.item('fries', 'Plain Fries', '[["Small",60],["Medium",170],["Large",300]]',
  '{"section":"Plain Fries","description":"Classic, premium-cut, perfectly salted golden fries."}');
select pg_temp.item('fries', 'Mayo Garlic Fries', '[["Regular",350]]',
  '{"section":"Specialty Topped Fries","description":"Golden fries drizzled with our signature creamy garlic-mayonnaise and herbs."}');
select pg_temp.item('fries', 'Jalapeno Fries', '[["Regular",370]]',
  '{"section":"Specialty Topped Fries","description":"Spicy and crisp: our fries topped with melty cheese and sliced jalapenos."}');
select pg_temp.item('fries', 'Loaded Fries', '[["Half",350],["Full",550]]',
  '{"section":"Loaded Fries","featured":true,"description":"The ultimate fries experience: loaded with a rich combination of melted cheddar and mozzarella, spicy house-made sauces, freshly chopped peppers, and slow-pulled meat."}');


-- -----------------------------------------------------------------------------
-- 3. Pasta   -- TODO: confirm with client what F1 / F2 mean (e.g. Regular / Family)
-- -----------------------------------------------------------------------------
select pg_temp.item('pasta', 'Spices Special Pasta', '[["F1",450],["F2",700]]');
select pg_temp.item('pasta', 'Crunchy Pasta',        '[["F1",400],["F2",680]]');
select pg_temp.item('pasta', 'Home Town Pasta',      '[["F1",400],["F2",680]]');
select pg_temp.item('pasta', 'Flaming Pasta',        '[["F1",350],["F2",580]]');
select pg_temp.item('pasta', 'Creamy Pasta',         '[["F1",400],["F2",650]]');


-- -----------------------------------------------------------------------------
-- 4. Paratha Rolls
-- -----------------------------------------------------------------------------
select pg_temp.item('paratha-rolls', 'Chicken Paratha Roll', '[["Regular",200]]',
  '{"description":"Classic, spiced chicken in a flaky roll."}');
select pg_temp.item('paratha-rolls', 'Special Chicken Cheese Paratha Roll', '[["Regular",250]]',
  '{"description":"Gourmet chicken and melted cheese."}');
select pg_temp.item('paratha-rolls', 'Kabab Paratha Roll', '[["Regular",250]]',
  '{"description":"Flame-grilled kabab with signature spices."}');
select pg_temp.item('paratha-rolls', 'Malai Boti Paratha Roll', '[["Regular",250]]',
  '{"description":"Creamy malai boti pieces, melting in mouth."}');
select pg_temp.item('paratha-rolls', 'Zinger Paratha Roll', '[["Regular",260]]',
  '{"description":"Crispy zinger fillet with hot spice."}');


-- -----------------------------------------------------------------------------
-- 5. Shawarma
-- -----------------------------------------------------------------------------
select pg_temp.item('shawarma', 'Chicken Shawarma', '[["Regular",140]]',
  '{"description":"Classic, flavor-packed with special spices."}');
select pg_temp.item('shawarma', 'Special Chicken Cheese Shawarma', '[["Regular",200]]',
  '{"description":"Gourmet chicken and a blend of savory cheese."}');
select pg_temp.item('shawarma', 'Kabab Shawarma', '[["Regular",230]]',
  '{"description":"Rich minced kabab wrapped in flatbread."}');
select pg_temp.item('shawarma', 'Malai Boti Shawarma', '[["Regular",220]]',
  '{"description":"Creamy, succulent malai boti pieces."}');
select pg_temp.item('shawarma', 'Zinger Shawarma', '[["Regular",250]]',
  '{"description":"Crispy, spicy Zinger chicken fillet."}');
select pg_temp.item('shawarma', 'Mix Shawarma', '[["Regular",180]]',
  '{"description":"A medley of all our signature flavors."}');


-- -----------------------------------------------------------------------------
-- 6. Burgers   (Student Burger: Take Away & Delivery Rs 180, Dine-in Rs 150)
-- -----------------------------------------------------------------------------
select pg_temp.item('burgers', 'Student Burger', '[["Regular",180,150]]',
  '{"description":"Round-shaped chicken patty in a toasted bun with house sauces."}');
select pg_temp.item('burgers', 'Zinger Burger', '[["Regular",300]]',
  '{"featured":true,"description":"Large, crispy, crunchy zinger patty with fresh lettuce and spicy mayo."}');
select pg_temp.item('burgers', 'Double Zinger Burger', '[["Regular",450]]',
  '{"description":"Two crunchy zinger patties with double cheese and house-made sauces."}');
select pg_temp.item('burgers', 'Spices Special Burger', '[["Regular",400]]',
  '{"description":"A unique combo of one crunchy zinger and a classic chicken patty with layered sauces and cheese."}');
select pg_temp.item('burgers', 'Arabian Fillet Burger', '[["Regular",250]]',
  '{"description":"Crispy rectangle Arabian chicken patty with tomatoes, cucumbers, and special sauces."}');


-- -----------------------------------------------------------------------------
-- 7. Spices Special Rolls
-- -----------------------------------------------------------------------------
select pg_temp.item('spices-special-rolls', 'Special Spin Roll', '[["4 pcs",480]]',
  '{"serving_note":"4 pcs + dip sauce","description":"Bespoke blend of signature spices in a creamy cheese center, baked to a golden crisp. A unique twist of flavors in every bite."}');
select pg_temp.item('spices-special-rolls', 'Malai Boti Roll', '[["4 pcs",500]]',
  '{"serving_note":"4 pcs + dip sauce","featured":true,"description":"Classic Pakistani Malai Boti flavor; tender chicken pieces marinated in rich cream and spices, baked in rich savory cheese top. A velvety, indulgent experience."}');


-- -----------------------------------------------------------------------------
-- 8. Sandwiches
-- -----------------------------------------------------------------------------
select pg_temp.item('sandwiches', 'Chef Special Sandwich',   '[["Regular",600]]', '{"tagline":"Herb-Crusted Delight"}');
select pg_temp.item('sandwiches', 'Spices Special Sandwich', '[["Regular",600]]', '{"tagline":"Maximal Cheese Melt"}');
select pg_temp.item('sandwiches', 'Mexican Sandwich',        '[["Regular",550]]', '{"tagline":"Herb-Crusted Delight"}');
-- TODO: confirm the real name of this Rs 500 sandwich with the client
select pg_temp.item('sandwiches', 'Spices Special Jalapeno Sandwich', '[["Regular",500]]', '{"tagline":"Maximal Cheese Melt"}');


-- -----------------------------------------------------------------------------
-- 9. Special Platters
-- -----------------------------------------------------------------------------
select pg_temp.item('special-platters', 'Shawarma Platter', '[["Regular",250]]',
  '{"includes":["Shawarma chicken","2 breads","Dip sauce"]}');
select pg_temp.item('special-platters', 'Spices Special Platter', '[["Regular",700]]',
  '{"tagline":"The Ultimate Flavor Fest","featured":true,"includes":["4 spin rolls","5 oven-baked wings","Regular fries","Special dip sauce"]}');
select pg_temp.item('special-platters', 'Spices Cafe BBQ Platter', '[["Regular",800]]',
  '{"tagline":"Ultimate BBQ Feast","includes":["4 kababs","5 malai boti","5 oven-baked wings","2 parathas","Regular fries","Dip sauce"]}');


-- -----------------------------------------------------------------------------
-- 10. Traditional Pizzas
-- -----------------------------------------------------------------------------
select pg_temp.item('traditional-pizzas', 'Chicken Tikka Pizza',
  '[["Small",450],["Medium",830],["Large",1100],["X-Large",1650]]', '{"featured":true}');
select pg_temp.item('traditional-pizzas', 'Chicken Fajita Pizza',
  '[["Small",450],["Medium",830],["Large",1100],["X-Large",1650]]', '{"spicy":true}');
select pg_temp.item('traditional-pizzas', 'Hot & Spicy Pizza',
  '[["Small",450],["Medium",830],["Large",1100],["X-Large",1650]]');
select pg_temp.item('traditional-pizzas', 'Chicken Supreme Pizza',
  '[["Small",450],["Medium",830],["Large",1100],["X-Large",1650]]');
select pg_temp.item('traditional-pizzas', 'Chicken Tandoori Pizza',
  '[["Small",450],["Medium",830],["Large",1100],["X-Large",1650]]', '{"spicy":true}');
select pg_temp.item('traditional-pizzas', 'Cheese Lovers Pizza',
  '[["Small",450],["Medium",830],["Large",1100],["X-Large",1650]]');


-- -----------------------------------------------------------------------------
-- 11. Signature Pizzas   (missing sizes are simply not created)
-- -----------------------------------------------------------------------------
select pg_temp.item('signature-pizzas', 'Spices Special Pizza',
  '[["Small",550],["Medium",950],["Large",1450],["X-Large",1800]]', '{"featured":true}');
select pg_temp.item('signature-pizzas', 'Bon Fire Pizza',
  '[["Small",550],["Medium",950],["Large",1450],["X-Large",1800]]');
select pg_temp.item('signature-pizzas', 'Peri Peri Pizza',
  '[["Small",550],["Medium",950],["Large",1450],["X-Large",1800]]');
select pg_temp.item('signature-pizzas', 'Malai Boti Pizza',
  '[["Small",600],["Medium",1000],["Large",1500],["X-Large",1950]]');
select pg_temp.item('signature-pizzas', 'Behari Kebab Pizza',
  '[["Medium",950],["Large",1450],["X-Large",1950]]');
select pg_temp.item('signature-pizzas', 'Royal Crust Pizza',
  '[["Medium",1000],["Large",1450],["X-Large",1800]]');
select pg_temp.item('signature-pizzas', 'Kabab Stuff Pizza',
  '[["Medium",1000],["Large",1450],["X-Large",1800]]');
select pg_temp.item('signature-pizzas', 'Cheese Crust Pizza',
  '[["Medium",1000],["Large",1450],["X-Large",1800]]');
select pg_temp.item('signature-pizzas', 'Special Double Dough Pizza',
  '[["Large",2000]]');


-- -----------------------------------------------------------------------------
-- 12. New Launches
-- -----------------------------------------------------------------------------
select pg_temp.item('new-launches', 'Chicken Shawarma Pizza',
  '[["Small",600],["Medium",1300],["Large",1750]]', '{"new":true,"featured":true}');
select pg_temp.item('new-launches', 'Doner Kabab', '[["Regular",1100]]',
  '{"new":true,"featured":true,"description":"Filled with chicken, fresh veggies, melted cheese and lots of flavors!"}');
select pg_temp.item('new-launches', 'Doner Kabab Special Deal', '[["Deal",2300]]',
  '{"type":"DEAL","new":true,"includes":["2x Doner Kabab","2 ltr soft drink","Masala fries"]}');


-- -----------------------------------------------------------------------------
-- 13. Burger Deals
-- -----------------------------------------------------------------------------
select pg_temp.item('burger-deals', 'Solo Smart Deal', '[["Deal",400]]',
  '{"type":"DEAL","includes":["1 Zinger burger","Small plain fries","350 ml Coke"]}');
select pg_temp.item('burger-deals', 'Crunchy Deal', '[["Deal",500]]',
  '{"type":"DEAL","includes":["1 Zinger burger","1 crunchy drumstick","350 ml cold drink"]}');
select pg_temp.item('burger-deals', 'Teen Ka Tadka', '[["Deal",1000]]',
  '{"type":"DEAL","includes":["3 Zinger burgers","Small plain fries","1 ltr Coke"]}');
select pg_temp.item('burger-deals', 'Ultimate Arabian Feast Deal', '[["Deal",750]]',
  '{"type":"DEAL","includes":["1 Arabian fillet burger","5 pcs Arabian fillet nuggets","1 small plain fries","500 ml Coke"]}');
select pg_temp.item('burger-deals', 'Big House Deal', '[["Deal",1800]]',
  '{"type":"DEAL","includes":["5 Zinger burgers","1 large plain fries","1.5 ltr Coke"]}');


-- -----------------------------------------------------------------------------
-- 14. Crunchy Deals (+ Prime Chicken Broast)
-- -----------------------------------------------------------------------------
select pg_temp.item('crunchy-deals', 'Dus Ka Dum', '[["Deal",650]]',
  '{"type":"DEAL","includes":["10 pcs hot wings fried","1 small plain fries"]}');
select pg_temp.item('crunchy-deals', 'Crisp Master', '[["Deal",1150]]',
  '{"type":"DEAL","includes":["6 pcs crunchy fried chicken broast","1 small plain fries","1 ltr Coke"]}');
select pg_temp.item('crunchy-deals', 'Broast Blaster', '[["Deal",1600]]',
  '{"type":"DEAL","includes":["9 pcs crunchy fried chicken broast","1 large plain fries","1.5 ltr Coke"]}');
select pg_temp.item('crunchy-deals', 'Prime Chicken Broast', '[["3 pcs",500],["6 pcs",1000],["9 pcs",1500]]',
  '{"section":"Prime Chicken Broast"}');


-- -----------------------------------------------------------------------------
-- 15. Pizza Deals
-- -----------------------------------------------------------------------------
select pg_temp.item('pizza-deals', 'Double Pizza Double Maza', '[["Deal",900]]',
  '{"type":"DEAL","includes":["2 small pizzas (regular)","500 ml soft drink"]}');
select pg_temp.item('pizza-deals', 'Dosti Deal', '[["Deal",1650]]',
  '{"type":"DEAL","includes":["2 medium pizzas (regular)","1 ltr soft drink"]}');
select pg_temp.item('pizza-deals', 'Super Saver Dhamaka', '[["Deal",2900]]',
  '{"type":"DEAL","includes":["2 large pizzas (special)","1.5 ltr soft drink"]}');


-- -----------------------------------------------------------------------------
-- 16. Family Deals
-- -----------------------------------------------------------------------------
select pg_temp.item('family-deals', 'Deal 1: Chatkhara Party', '[["Deal",3500]]',
  '{"type":"DEAL","slug":"chatkhara-party","includes":["1 X-large pizza (special)","2 Zinger burgers","6 pcs crunchy chicken broast","Large plain fries","2 ltr Coke"]}');
select pg_temp.item('family-deals', 'Deal 2: Birthday Blaster', '[["Deal",4200]]',
  '{"type":"DEAL","slug":"birthday-blaster","includes":["2 large pizzas (special)","2 Zinger burgers","10 pcs crunchy hot wings","Large plain fries","2 ltr Coke"]}');
select pg_temp.item('family-deals', 'Deal 3: Spices Empire Deal', '[["Deal",2900]]',
  '{"type":"DEAL","slug":"spices-empire-deal","includes":["10 pcs crunchy hot wings or nuggets","1 large pizza (special)","2 Zinger burgers","1 large plain fries","1.5 ltr Coke"]}');


-- -----------------------------------------------------------------------------
-- 17. Extras (sold on their own)
-- -----------------------------------------------------------------------------
select pg_temp.item('extras', 'Extra Bread',   '[["Regular",45]]', '{"description":"Classic soft bread, served warm."}');
select pg_temp.item('extras', 'Extra Sauce',   '[["Regular",30]]', '{"description":"Add another layer of flavor."}');
select pg_temp.item('extras', 'Extra Paratha', '[["Regular",80]]', '{"description":"Authentic flaky paratha, baked to perfection."}');
select pg_temp.item('extras', 'Cheese Slice',  '[["Regular",60]]', '{"description":"Add a melted cheese slice to any burger."}');
select pg_temp.item('extras', 'Dip Sauce',     '[["Regular",50]]', '{"description":"Fresh mayo, signature dip for your sides."}');


-- -----------------------------------------------------------------------------
-- Add-ons
-- -----------------------------------------------------------------------------
-- Burger extras: Cheese Slice +Rs 60 on every burger
insert into public.add_on_groups (name, slug, description, min_select, max_select, sort_order)
values ('Burger Extras', 'burger-extras', 'Add a melted cheese slice.', 0, null, 1)
on conflict (slug) do nothing;

insert into public.add_ons (group_id, name, price, sort_order)
select id, 'Cheese Slice', 60, 1 from public.add_on_groups where slug = 'burger-extras'
on conflict (group_id, name) do nothing;

insert into public.add_on_group_categories (group_id, category_id)
select g.id, c.id from public.add_on_groups g, public.categories c
 where g.slug = 'burger-extras' and c.slug = 'burgers'
on conflict do nothing;

-- Extra toppings (chicken / cheese), priced by pizza size
insert into public.add_on_groups (name, slug, description, min_select, max_select, sort_order)
values ('Extra Toppings', 'extra-toppings', 'Extra chicken or cheese, priced by pizza size.', 0, null, 2)
on conflict (slug) do nothing;

insert into public.add_ons (group_id, name, price, sort_order)
select g.id, a.name, null, a.sort_order
  from public.add_on_groups g,
       (values ('Extra Chicken Topping', 1), ('Extra Cheese Topping', 2)) as a(name, sort_order)
 where g.slug = 'extra-toppings'
on conflict (group_id, name) do nothing;

insert into public.add_on_prices (add_on_id, size_label, price)
select a.id, p.size_label, p.price
  from public.add_ons a
  join public.add_on_groups g on g.id = a.group_id and g.slug = 'extra-toppings',
       (values ('Small', 70), ('Medium', 100), ('Large', 150), ('X-Large', 200)) as p(size_label, price)
on conflict (add_on_id, size_label) do nothing;

insert into public.add_on_group_categories (group_id, category_id)
select g.id, c.id from public.add_on_groups g, public.categories c
 where g.slug = 'extra-toppings' and c.slug in ('traditional-pizzas', 'signature-pizzas')
on conflict do nothing;

insert into public.add_on_group_items (group_id, item_id)
select g.id, i.id from public.add_on_groups g, public.menu_items i
 where g.slug = 'extra-toppings' and i.slug = 'chicken-shawarma-pizza'
on conflict do nothing;


-- -----------------------------------------------------------------------------
-- Check: should print 17 categories / 79 items / 136 variants / 3 add-ons
-- -----------------------------------------------------------------------------
select
  (select count(*) from public.categories)    as categories,
  (select count(*) from public.menu_items)    as items,
  (select count(*) from public.item_variants) as variants,
  (select count(*) from public.add_ons)       as add_ons;
