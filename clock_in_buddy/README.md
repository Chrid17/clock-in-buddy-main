# Clock In Buddy

A Flutter mobile app that lets staff **clock in and out remotely with verifiable proof of attendance**: a live selfie, GPS location and a server-issued timestamp, all checked by a REST API before anything is saved. It runs on Android, iOS and the web.

## What staff get

- **One-tap clock in / out**, with a live status card showing time worked today and this week
- **Photo verification:** a selfie from the front camera. Gallery uploads are not possible, and each photo gets a SHA-256 fingerprint.
- **Geolocation capture:** GPS position, accuracy and street address, plus distance to the nearest work site
- **Fake-GPS detection:** on Android, records from mock-location apps are flagged
- **Works offline:** clock actions are saved on the phone and uploaded in order when the signal returns
- **History:** this week, last week, this month or last month, with hours per day and **CSV export**
- **Receipts:** every clock action shows a reference number and the server time

## What managers get (Team tab)

- **Who's in:** live list of who is clocked in, where and since when
- **Review:** verify or reject each clock-in with its photo, map location and flags
- **Work sites:** add offices or client sites with a radius (geofence), using your current location
- **Staff:** promote managers, require someone to be on site to clock in, deactivate accounts
- **Odoo sync (optional):** attendance is copied into Odoo `hr.attendance` from the server

The first account ever created becomes a manager automatically.

## How verification works

```
Phone                                   Supabase (REST API)
-----                                   -------------------
1. Selfie (front camera)  ──upload──▶   Storage /attendance-photos/<user-id>/...   (private)
2. GPS fix + accuracy
3. POST /rest/v1/rpc/clock_event  ──▶   clock_event() checks:
                                          • you are signed in and active
                                          • the photo exists in *your* folder
                                          • you are not already clocked in / out
                                          • distance to nearest work site (and blocks
                                            if you must be on site)
                                          • flags: fake GPS, outside site, low accuracy,
                                            offline capture, wrong phone clock
                                        Saves the record with the SERVER time.
4. Receipt with reference number  ◀──   Record is read-only; only managers can review it.
```

Staff can't edit or delete attendance records, upload photos into someone else's folder, or change their own role. Row Level Security enforces all of this in the database.

### REST endpoints

| Method | Endpoint | Purpose |
| --- | --- | --- |
| POST | `/storage/v1/object/attendance-photos/{user}/{file}.jpg` | Upload verification selfie |
| POST | `/rest/v1/rpc/clock_event` | Record a clock-in or clock-out |
| GET | `/rest/v1/attendance_events?user_id=eq.{id}&order=server_time.desc` | Attendance history |
| POST | `/storage/v1/object/sign/attendance-photos/{path}` | Temporary link to view a photo |
| POST | `/rest/v1/rpc/team_status` | Manager: who is clocked in |
| POST | `/rest/v1/rpc/review_event` | Manager: verify / reject |
| GET/POST/PATCH/DELETE | `/rest/v1/work_sites` | Manager: work sites |
| GET/PATCH | `/rest/v1/profiles` | Profile / manager staff settings |
| POST | `/functions/v1/odoo-sync` | Copy an event to Odoo (server-side) |

Every request sends the signed-in user's token (`Authorization: Bearer …`) and the project's publishable key (`apikey`). The client is in `lib/src/api/attendance_api.dart`.

## Setup

### 1. Database (once)

Supabase Dashboard → **SQL Editor** → New query → paste
`supabase/migrations/20261102000000_remote_clock_in.sql` → **Run**.

It is safe to run again, keeps existing users and imports history from the old `clock_events` table.

### 2. App

From this folder, in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

This reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from `.env`, recreates the Android, iOS and web projects, adds the camera and location permissions, and runs the tests. Then:

```powershell
flutter run              # Android phone or emulator
flutter run -d chrome    # web (camera and GPS need https or localhost)
```

### 3. Odoo sync (optional)

The Odoo password lives on the server, never in the app:

```powershell
npx supabase login
npx supabase functions deploy odoo-sync --project-ref YOUR_PROJECT_REF
npx supabase secrets set ODOO_URL=https://your.odoo.com ODOO_DB=your-db ODOO_USER=api@company.com ODOO_PASSWORD=... --project-ref YOUR_PROJECT_REF
```

Employees are matched by **work email** (then by name) in Odoo.

## Project structure

```
lib/
  main.dart                          start-up and dependency wiring
  src/api/attendance_api.dart        REST client (PostgREST, Storage, Functions)
  src/state/session.dart             sign-in and staff profile
  src/state/attendance_controller.dart  status, clocking, offline queue
  src/services/location_service.dart GPS, permissions, address lookup
  src/services/offline_queue.dart    clock actions saved without internet
  src/models.dart  src/utils.dart    data models, hours worked, CSV
  src/ui/                            screens (clock, capture, history, team, profile)
supabase/migrations/                 database, security rules, REST functions
supabase/functions/odoo-sync/        Odoo integration (Edge Function)
test/app_test.dart                   unit tests incl. REST client and offline queue
```
