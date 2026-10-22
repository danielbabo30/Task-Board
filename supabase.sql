-- הריצו את כל הקובץ ב-Supabase: SQL Editor > New query > Run

create table public.clients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

-- role: 'team' (צוות פיתוח) או 'client'. משתמש חדש נוצר כ-client ללא לקוח משויך.
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text,
  role text not null default 'client' check (role in ('team','client')),
  client_id uuid references public.clients on delete set null
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients on delete cascade,
  title text not null,
  description text not null default '',
  status text not null default 'todo' check (status in ('todo','doing','wait','live')),
  file_path text,
  file_name text,
  created_at timestamptz not null default now()
);

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks on delete cascade,
  client_id uuid not null references public.clients on delete cascade,
  text text not null,
  resolution text not null check (resolution in ('מחשב נייח','נייד','אייפון','אנדרואיד')),
  handled boolean not null default false,
  handled_at timestamptz,
  file_path text,
  file_name text,
  created_at timestamptz not null default now()
);

-- פונקציות עזר (security definer כדי שלא ייווצר לופ במדיניות)
create function public.is_team() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from profiles where id = auth.uid() and role = 'team') $$;

create function public.my_client() returns uuid
language sql stable security definer set search_path = public as
$$ select client_id from profiles where id = auth.uid() $$;

-- יצירת פרופיל אוטומטית בהרשמה
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as
$$ begin
  insert into profiles (id, email) values (new.id, new.email);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- אבטחה: כל לקוח רואה רק את הנתונים שלו
alter table clients  enable row level security;
alter table profiles enable row level security;
alter table tasks    enable row level security;
alter table notes    enable row level security;

create policy clients_read  on clients  for select using (is_team() or id = my_client());
create policy clients_write on clients  for all    using (is_team()) with check (is_team());

create policy profiles_read  on profiles for select using (is_team() or id = auth.uid());
create policy profiles_write on profiles for update using (is_team()) with check (is_team());

create policy tasks_read  on tasks for select using (is_team() or client_id = my_client());
create policy tasks_write on tasks for all    using (is_team()) with check (is_team());
-- לקוח יכול להוסיף משימה חדשה ללקוח שלו (בסטטוס 'מוכן לביצוע')
create policy tasks_client_insert on tasks for insert with check (client_id = my_client() and status = 'todo');

create policy notes_read   on notes for select using (is_team() or client_id = my_client());
create policy notes_insert on notes for insert with check (is_team() or (client_id = my_client() and handled = false));
-- לקוח יכול לערוך הערות שטרם טופלו, אך לא לסמן "טופל"
create policy notes_update on notes for update
  using (is_team() or (client_id = my_client() and handled = false))
  with check (is_team() or (client_id = my_client() and handled = false));
create policy notes_delete on notes for delete using (is_team());

-- קבצים: דלי פרטי, כל קובץ נשמר תחת תיקיית הלקוח שלו
insert into storage.buckets (id, name, public) values ('files', 'files', false);

create policy files_read   on storage.objects for select
  using (bucket_id = 'files' and (is_team() or (storage.foldername(name))[1] = my_client()::text));
create policy files_insert on storage.objects for insert
  with check (bucket_id = 'files' and (is_team() or (storage.foldername(name))[1] = my_client()::text));
create policy files_delete on storage.objects for delete
  using (bucket_id = 'files' and is_team());

-- עדכון חי בין משתמשים
alter publication supabase_realtime add table tasks, notes;
