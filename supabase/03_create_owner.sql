-- =============================================================================
-- Spices Cafe — make the first OWNER admin
-- File 3 of 3.
--
-- 1. Supabase Dashboard -> Authentication -> Users -> "Add user" -> "Create new user"
--    Enter the owner's email + a strong password, tick "Auto Confirm User".
-- 2. Replace the email below with that same email and run this file.
--
-- Later staff accounts are added from the website's /admin/users page.
-- =============================================================================

insert into public.staff_members (user_id, name, email, role, is_active)
select id, 'Owner', email, 'OWNER', true
  from auth.users
 where email = 'owner@example.com'          -- <-- CHANGE THIS
on conflict (user_id) do update
  set role = 'OWNER', is_active = true;

-- Should show one row with role OWNER:
select user_id, name, email, role, is_active from public.staff_members;
