# Spices Cafe: Backend (Supabase)

The database, login, file storage and order logic all run on Supabase.
The Next.js website (the **`spices-cafe-web`** repository) talks to it.

## Set up the database

> **Use a new Supabase project just for the cafe.** Don't run these files in a project that another app uses.
> The free plan allows 2 projects.

In your Supabase project, open **SQL Editor → New query** and run these files in order:

| # | File | What it does |
|---|---|---|
| 1 | `supabase/01_schema.sql` | Tables, security rules (RLS), order and pricing functions, the `menu-images` storage bucket, realtime for orders |
| 2 | `supabase/02_seed.sql` | The full menu (17 categories, 79 items, 136 sizes/prices), add-ons and cafe settings. The last line prints the counts. |
| 3 | `supabase/03_create_owner.sql` | Makes your login the OWNER. First create the user under **Authentication → Users → Add user** (tick *Auto Confirm*), then put that email in the file and run it. |

You can run all three again safely. The seed only adds missing rows and never overwrites prices you changed in the admin panel.

## Supabase dashboard settings

- **Authentication → Sign In / Providers → Email:** turn **off** "Allow new users to sign up". Only the owner creates staff accounts.
- **Project Settings → API:** copy the Project URL, the anon/publishable key and the service_role/secret key. The Next.js app needs them as environment variables. **Never put the service_role key in browser code.**

## How the app uses the database

| Who | Can do |
|---|---|
| Customer (anon key) | Read the menu and settings · `quote_order(cart)` for server-confirmed prices · `get_order_by_token(token)` for order tracking |
| Next.js server (service_role) | `place_order(payload)` after rate limiting and the honeypot check · `find_order_token(order_number, phone)` for the /track page |
| STAFF (logged in) | Read orders (live via Realtime) · `update_order_status` · `mark_order_seen` · `set_item_availability` / `set_variant_availability` (sold-out) |
| OWNER (logged in) | All of the above, plus edit the menu, add-ons, settings and staff, upload photos, `get_dashboard_stats` |

Prices are **always recalculated in the database**. Any price the browser sends is ignored.

Order statuses: `PENDING → CONFIRMED → PREPARING → READY → OUT_FOR_DELIVERY (delivery only) → COMPLETED`, and `CANCELLED` (with a reason) from any status before completion.
