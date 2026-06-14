-- =============================================================
-- OnAnd Studio · Public Media Creator — Supabase backend schema
-- Run this once in your Supabase project (SQL Editor → New query → Run).
-- Then: Auth → Providers → enable "Anonymous sign-in".
-- =============================================================

-- ---------- 1) TABLES ----------

-- Students: one row per (anonymous) participant. `state` holds the full app
-- progress JSON (visited steps, survey answers, etc.) for resume + admin rollup.
create table if not exists public.students (
  id           uuid primary key references auth.users(id) on delete cascade,
  name         text,
  group_label  text,
  work_id      text,
  work_title   text,
  hook_text    text,
  quiz_passed  boolean default false,
  submitted    boolean default false,
  public_code  text unique,        -- gallery-QR code for audience rating
  state        jsonb,
  updated_at   timestamptz default now()
);

-- Feedback loop columns (added in v2). Safe to re-run.
alter table public.students add column if not exists vimeo_url        text;  -- participant's published video link (gallery QR target)
alter table public.students add column if not exists mentor_feedback  text;  -- written by operator (admin) → shown to the participant
alter table public.students add column if not exists curator_feedback text;  -- written by operator (admin) → shown to the participant
alter table public.students add column if not exists creator_score    jsonb; -- {hook,story,visual,emotion,easy} 0–5
alter table public.students add column if not exists feedback_at      timestamptz;

-- Audience reactions: anonymous, written only through submit_reaction() RPC.
create table if not exists public.audience_reactions (
  id              uuid primary key default gen_random_uuid(),
  submission_code text not null,                 -- = students.public_code
  stars           int  check (stars between 1 and 5),
  watch_pct       int  default 100,
  reactions       jsonb default '[]'::jsonb,     -- ['easy','fun','share','live']
  created_at      timestamptz default now()
);
create index if not exists idx_reactions_code on public.audience_reactions(submission_code);

-- Certificates: verifiable, revocable. Public lookup via verify_certificate().
create table if not exists public.certificates (
  user_id     uuid references auth.users(id) on delete cascade,
  name        text,
  program     text,
  exhibition  text,
  level_n     int,
  verify_code text primary key,    -- e.g. OAS-SEMA-2026-48420
  issued_on   date default current_date,
  status      text default 'valid',-- valid | revoked
  snapshot    jsonb
);

-- ---------- 2) ROW LEVEL SECURITY ----------

alter table public.students           enable row level security;
alter table public.certificates       enable row level security;
alter table public.audience_reactions enable row level security; -- no policies → only SECURITY DEFINER RPC can touch it

drop policy if exists students_self_rw on public.students;
create policy students_self_rw on public.students
  for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists cert_self_rw on public.certificates;
create policy cert_self_rw on public.certificates
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- 3) RPCs (server-side functions) ----------

-- Operator dashboard: returns all students (name/group/work/submitted/state).
-- Pilot-level gate: change the passcode below AND ADMIN_CODE in the HTML.
create or replace function public.admin_overview(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
  if p_code is distinct from 'onand-sema-2026' then   -- <<< CHANGE THIS PASSCODE
    raise exception 'unauthorized';
  end if;
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', id, 'name', name, 'group_label', group_label,
             'work_title', work_title, 'submitted', submitted,
             'public_code', public_code, 'vimeo_url', vimeo_url,
             'mentor_feedback', mentor_feedback, 'curator_feedback', curator_feedback,
             'creator_score', creator_score, 'state', state)
           order by updated_at desc), '[]'::jsonb)
    into result from public.students;
  return result;
end; $$;

-- Operator writes per-student feedback/score/video (pilot passcode gate).
create or replace function public.admin_set_feedback(
  p_code text, p_id uuid, p_mentor text, p_curator text, p_score jsonb, p_vimeo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_code is distinct from 'onand-sema-2026' then   -- <<< SAME PASSCODE as admin_overview / ADMIN_CODE
    raise exception 'unauthorized';
  end if;
  update public.students
     set mentor_feedback  = p_mentor,
         curator_feedback = p_curator,
         creator_score    = p_score,
         vimeo_url        = coalesce(p_vimeo, vimeo_url),
         feedback_at      = now()
   where id = p_id;
end; $$;

-- Participant (logged-in) reads the audience-reaction summary for their OWN submission.
create or replace function public.my_reactions()
returns jsonb language plpgsql security definer set search_path = public as $$
declare my_code text; result jsonb;
begin
  select public_code into my_code from public.students where id = auth.uid();
  if my_code is null then return jsonb_build_object('count',0); end if;
  select jsonb_build_object(
           'count', count(*),
           'avg',   round(avg(stars)::numeric, 1),
           'tags',  jsonb_build_object(
             'easy',  count(*) filter (where reactions ? 'easy'),
             'fun',   count(*) filter (where reactions ? 'fun'),
             'share', count(*) filter (where reactions ? 'share'),
             'live',  count(*) filter (where reactions ? 'live')))
    into result from public.audience_reactions where submission_code = my_code;
  return result;
end; $$;

-- Gallery rating page (public): minimal submission info to show before rating.
create or replace function public.get_submission(p_code text)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object('name', name, 'work_title', work_title, 'vimeo_url', vimeo_url)
  from public.students where public_code = p_code and submitted = true limit 1;
$$;

-- Audience rating (anonymous, public). Validates the code is a published video.
create or replace function public.submit_reaction(p_code text, p_stars int, p_watch int, p_tags jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_stars is null or p_stars < 1 or p_stars > 5 then raise exception 'invalid rating'; end if;
  if not exists (select 1 from public.students where public_code = p_code and submitted = true) then
    raise exception 'invalid code';
  end if;
  insert into public.audience_reactions(submission_code, stars, watch_pct, reactions)
  values (p_code, p_stars, coalesce(p_watch, 100), coalesce(p_tags, '[]'::jsonb));
end; $$;

-- Certificate verification (public): returns only non-sensitive fields.
create or replace function public.verify_certificate(p_code text)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
           'name', name, 'program', program, 'exhibition', exhibition,
           'level', level_n, 'issued_on', issued_on, 'status', status)
  from public.certificates where verify_code = p_code limit 1;
$$;

-- ---------- 4) GRANTS ----------
grant execute on function public.admin_overview(text)                 to anon, authenticated;
grant execute on function public.submit_reaction(text,int,int,jsonb)  to anon, authenticated;
grant execute on function public.verify_certificate(text)             to anon, authenticated;
grant execute on function public.admin_set_feedback(text,uuid,text,text,jsonb,text) to anon, authenticated;
grant execute on function public.my_reactions()                       to authenticated;
grant execute on function public.get_submission(text)                 to anon, authenticated;

-- Done. Copy your Project URL + anon public key into CONFIG in the HTML.
