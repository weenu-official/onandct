-- =============================================================
-- OnAnd Studio · Public Media Creator — 배포 전 백업 스크립트
-- Pre-deploy BACKUP for Supabase (run in SQL Editor → New query → Run)
--
-- 사용 시점: 새 PMC 프론트엔드 + 새 스키마(supabase_schema.sql)를
--           적용하기 "직전"에 1회 실행하세요.
-- 안전성: 이 스크립트는 읽기/복사만 합니다(원본 테이블을 수정·삭제하지 않음).
-- =============================================================


-- =============================================================
-- 방법 A) DB 안에 스냅샷 테이블 만들기 (권장 · 복구가 가장 쉬움)
--   - 실행하면 bk_<테이블>_<날짜시각> 형태의 사본 테이블이 생깁니다.
--   - 결과 패널에 생성된 테이블 이름이 NOTICE로 출력돼요(메모해 두세요).
-- =============================================================
do $$
declare
  ts text := to_char(now(), 'YYYYMMDD_HH24MI');   -- 예: 20260615_1430
  t  text;
  made text[] := '{}';
begin
  foreach t in array array['students','audience_reactions','certificates','surveys']
  loop
    -- 존재하는 테이블만 백업(surveys 처럼 없을 수도 있는 테이블은 건너뜀)
    if exists (select 1 from information_schema.tables
               where table_schema='public' and table_name=t) then
      execute format('drop table if exists public.%I', 'bk_'||t||'_'||ts);
      execute format('create table public.%I as table public.%I', 'bk_'||t||'_'||ts, t);
      made := made || ('bk_'||t||'_'||ts);
    end if;
  end loop;
  raise notice '✅ 백업 완료. 생성된 스냅샷 테이블: %', array_to_string(made, ', ');
end $$;

-- (선택) 방금 만든 백업 테이블 목록 확인
select table_name,
       (xpath('/row/c/text()',
         query_to_xml(format('select count(*) c from public.%I', table_name), false, true, '')))[1]::text::int as rows
from information_schema.tables
where table_schema='public' and table_name like 'bk\_%'
order by table_name;


-- =============================================================
-- 방법 B) CSV로 내려받기  (SQL Editor에서 각 쿼리 실행 후
--          결과 오른쪽 위 "Download CSV" 버튼 클릭)
--   - 한 번에 한 쿼리씩 실행하세요.
-- =============================================================
-- select * from public.students          order by updated_at;
-- select * from public.audience_reactions order by created_at;
-- select * from public.certificates       order by issued_on;
-- select * from public.surveys            order by updated_at;   -- 테이블이 있을 때만


-- =============================================================
-- 방법 C) JSON 한 덩어리로 백업  (결과 1행을 통째로 복사해 파일로 저장)
--   - 복구·이전이 필요할 때 가장 이식성이 좋아요.
-- =============================================================
select jsonb_pretty(jsonb_build_object(
  'exported_at',        now(),
  'students',           coalesce((select jsonb_agg(to_jsonb(s)) from public.students s), '[]'::jsonb),
  'audience_reactions', coalesce((select jsonb_agg(to_jsonb(a)) from public.audience_reactions a), '[]'::jsonb),
  'certificates',       coalesce((select jsonb_agg(to_jsonb(c)) from public.certificates c), '[]'::jsonb)
)) as backup_json;


-- =============================================================
-- 백업 점검 — 현재 행 수 확인 (배포 후 숫자가 같은지 비교용)
-- =============================================================
select 'students'           as table, count(*) from public.students
union all
select 'audience_reactions' as table, count(*) from public.audience_reactions
union all
select 'certificates'       as table, count(*) from public.certificates;


-- =============================================================
-- (참고) 복구 방법 — 문제가 생겼을 때만 사용
--   * 비어 있거나 일부만 날아간 경우 되돌리기:
--       insert into public.students select * from public.bk_students_<날짜시각>
--       on conflict (id) do nothing;
--   * 완전히 교체(주의: 현재 데이터를 지웁니다):
--       begin;
--         truncate public.students;
--         insert into public.students select * from public.bk_students_<날짜시각>;
--       commit;
--   * 백업 테이블 정리(확인 후):
--       drop table public.bk_students_<날짜시각>;
-- =============================================================
