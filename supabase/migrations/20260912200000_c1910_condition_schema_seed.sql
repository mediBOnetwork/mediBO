-- CMD #1910 — "Use / Condition": the fourth browse door.
--
-- Customers think in conditions ("fever", "sugar", "acidity"), not in a
-- therapeutic class taxonomy scraped off a product page. This migration adds
-- the vocabulary (condition), the mapping (condition_medicine) and the rules
-- that seeded it ONCE (condition_seed_rule) — after which the mapping belongs
-- to the admin and is never auto-overwritten again.
--
-- Idempotent end to end: every object is IF NOT EXISTS, every seed row is an
-- ON CONFLICT DO NOTHING, and the mapping pass runs for a condition only while
-- its `seeded_at` is null. Re-running this file changes nothing.

-- ── the vocabulary ────────────────────────────────────────────────────────
create table if not exists public.condition (
  id            bigint generated always as identity primary key,
  condition_key text        not null unique,
  label         text        not null,
  synonyms      text[]      not null default '{}',
  sort_order    int         not null default 100,
  is_active     boolean     not null default true,
  seeded_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    text
);

create index if not exists idx_condition_active on public.condition (is_active, sort_order, label);

-- ── the mapping ───────────────────────────────────────────────────────────
-- `source` says who put the row here. 'seed' is the one-time pass below;
-- 'admin' is a person. Nothing in this file ever deletes an 'admin' row.
create table if not exists public.condition_medicine (
  condition_id bigint      not null references public.condition(id) on delete cascade,
  medicine_id  bigint      not null,
  source       text        not null default 'seed',
  created_at   timestamptz not null default now(),
  created_by   text,
  primary key (condition_id, medicine_id)
);

create index if not exists idx_condition_medicine_med on public.condition_medicine (medicine_id);

-- ── the rules that seeded it ──────────────────────────────────────────────
-- Authored with AI assistance over the MEDICINE taxonomy (therapeutic_class,
-- action_class, chemical_class, salt_composition). Kept as DATA so the seed is
-- reproducible and auditable, and so a new condition is one INSERT + one
-- admin re-seed rather than a migration.
create table if not exists public.condition_seed_rule (
  condition_key text not null,
  field         text not null check (field in ('therapeutic_class','chemical_class','action_class','salt_composition')),
  pattern       text not null,
  primary key (condition_key, field, pattern)
);

-- ── RLS: read is public (this is catalogue vocabulary), write is nobody's ──
-- Every write goes through a SECURITY DEFINER admin RPC.
alter table public.condition          enable row level security;
alter table public.condition_medicine enable row level security;
alter table public.condition_seed_rule enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='condition' and policyname='condition_read') then
    create policy condition_read on public.condition for select using (true);
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='condition_medicine' and policyname='condition_medicine_read') then
    create policy condition_medicine_read on public.condition_medicine for select using (true);
  end if;
end $$;

grant select on public.condition, public.condition_medicine to anon, authenticated;

-- ── the vocabulary itself ─────────────────────────────────────────────────
insert into public.condition (condition_key, label, synonyms, sort_order) values
  ('fever',            'Fever',                      array['bukhar','jwar','temperature','pyrexia','antipyretic'],          10),
  ('pain',             'Pain & body ache',           array['dard','badan dard','body pain','analgesic','painkiller'],       20),
  ('headache',         'Headache & migraine',        array['sar dard','sir dard','migraine','headache'],                    30),
  ('cold-cough',       'Cold & cough',               array['sardi','khansi','zukam','common cold','cough'],                 40),
  ('sore-throat',      'Sore throat',                array['gala kharab','throat infection','pharyngitis'],                 50),
  ('allergy',          'Allergy',                    array['allergy','antihistamine','rhinitis','chhinke','sneezing'],      60),
  ('acidity',          'Acidity & heartburn',        array['acidity','gas','jalan','heartburn','gerd','acid reflux','ulcer'],70),
  ('indigestion',      'Indigestion & bloating',     array['apach','bloating','indigestion','gas'],                         80),
  ('constipation',     'Constipation',               array['kabz','laxative','constipation'],                               90),
  ('diarrhoea',        'Diarrhoea & loose motion',   array['dast','loose motion','diarrhea','ors','dehydration'],          100),
  ('vomiting',         'Nausea & vomiting',          array['ulti','mitli','nausea','antiemetic'],                          110),
  ('worm-infection',   'Worm infection',             array['kirmi','deworming','anthelmintic','worms'],                    120),
  ('diabetes-type-2',  'Type 2 diabetes',            array['sugar','madhumeh','diabetes','antidiabetic','type 2'],         130),
  ('hypertension',     'High blood pressure',        array['bp','high bp','hypertension','blood pressure'],                140),
  ('heart-care',       'Heart care',                 array['dil','cardiac','angina','heart'],                              150),
  ('cholesterol',      'High cholesterol',           array['cholesterol','lipid','statin','triglyceride'],                 160),
  ('asthma',           'Asthma & breathing',         array['dama','saans','wheezing','asthma','copd','inhaler'],           170),
  ('bacterial-infection','Bacterial infection',      array['antibiotic','infection','sankraman'],                          180),
  ('fungal-infection', 'Fungal infection',           array['daad','ringworm','antifungal','fungal'],                       190),
  ('skin-care',        'Skin problems',              array['skin','twacha','eczema','rash','psoriasis'],                   200),
  ('hair-care',        'Hair fall',                  array['baal','hair fall','alopecia','hair'],                          210),
  ('acne',             'Acne & pimples',             array['pimple','muhase','acne'],                                      220),
  ('eye-care',         'Eye problems',               array['aankh','eye drop','conjunctivitis','eye'],                     230),
  ('ear-care',         'Ear problems',               array['kaan','ear drop','ear'],                                       240),
  ('dental',           'Dental & mouth',             array['daant','toothache','mouth ulcer','dental'],                    250),
  ('arthritis',        'Joint pain & arthritis',     array['jodo ka dard','gathiya','arthritis','joint pain','gout'],      260),
  ('bone-calcium',     'Bone & calcium',             array['haddi','calcium','osteoporosis','bone'],                       270),
  ('vitamins',         'Vitamins & nutrition',       array['vitamin','multivitamin','supplement','nutrition'],             280),
  ('anaemia',          'Anaemia & iron',             array['khoon ki kami','iron','haemoglobin','anemia','anaemia'],       290),
  ('thyroid',          'Thyroid',                    array['thyroid','hypothyroid','thyroxine'],                           300),
  ('anxiety-sleep',    'Anxiety & sleep',            array['neend','tension','insomnia','anxiety','sleep'],                310),
  ('depression',       'Depression',                 array['depression','antidepressant'],                                 320),
  ('epilepsy',         'Epilepsy & seizures',        array['mirgi','seizure','epilepsy','fits'],                           330),
  ('urinary',          'Urinary & kidney',           array['peshab','uti','kidney','urine','urinary'],                     340),
  ('prostate',         'Prostate',                   array['prostate','bph'],                                              350),
  ('piles',            'Piles & fissure',            array['bawasir','piles','haemorrhoid','fissure'],                     360),
  ('liver-care',       'Liver care',                 array['liver','jaundice','peelia','hepatic'],                         370),
  ('womens-health',    'Women''s health',            array['pcos','period','menstrual','mahwari','gynaec'],                380),
  ('pregnancy-care',   'Pregnancy care',             array['pregnancy','garbhavastha','prenatal','folic'],                 390),
  ('child-care',       'Child care',                 array['bachche','paediatric','pediatric','infant','baby'],            400),
  ('immunity',         'Immunity',                   array['immunity','rog pratirodhak','immune'],                         410),
  ('weight',           'Weight management',          array['motapa','obesity','weight'],                                   420),
  ('wound-care',       'Wound & antiseptic',         array['ghaav','antiseptic','wound','dressing'],                       430),
  ('cancer-care',      'Cancer care',                array['cancer','oncology','chemotherapy','tumour'],                   440),
  ('malaria',          'Malaria',                    array['malaria','antimalarial'],                                      450),
  ('tuberculosis',     'Tuberculosis (TB)',          array['tb','tuberculosis','antitubercular'],                          460)
on conflict (condition_key) do nothing;

-- ── the rules ─────────────────────────────────────────────────────────────
insert into public.condition_seed_rule (condition_key, field, pattern) values
  ('fever','action_class','%antipyretic%'),
  ('fever','salt_composition','%paracetamol%'),
  ('fever','salt_composition','%acetaminophen%'),
  ('fever','salt_composition','%nimesulide%'),
  ('fever','salt_composition','%mefenamic%'),

  ('pain','therapeutic_class','%pain analgesic%'),
  ('pain','action_class','%nsaid%'),
  ('pain','action_class','%non-steroidal anti-inflammatory%'),
  ('pain','action_class','%analgesic%'),
  ('pain','salt_composition','%diclofenac%'),
  ('pain','salt_composition','%ibuprofen%'),
  ('pain','salt_composition','%aceclofenac%'),
  ('pain','salt_composition','%tramadol%'),

  ('headache','salt_composition','%sumatriptan%'),
  ('headache','salt_composition','%rizatriptan%'),
  ('headache','salt_composition','%naratriptan%'),
  ('headache','salt_composition','%flunarizine%'),
  ('headache','salt_composition','%ergotamine%'),
  ('headache','action_class','%triptan%'),

  ('cold-cough','action_class','%mucolytic%'),
  ('cold-cough','action_class','%expectorant%'),
  ('cold-cough','action_class','%cough suppressant%'),
  ('cold-cough','action_class','%antitussive%'),
  ('cold-cough','action_class','%nasal decongestant%'),
  ('cold-cough','salt_composition','%ambroxol%'),
  ('cold-cough','salt_composition','%guaiphenesin%'),
  ('cold-cough','salt_composition','%dextromethorphan%'),
  ('cold-cough','salt_composition','%phenylephrine%'),
  ('cold-cough','salt_composition','%chlorpheniramine%'),
  ('cold-cough','salt_composition','%terbutaline%'),

  ('sore-throat','salt_composition','%benzydamine%'),
  ('sore-throat','salt_composition','%ammonium chloride%'),
  ('sore-throat','salt_composition','%menthol%'),
  ('sore-throat','salt_composition','%amoxycillin%'),
  ('sore-throat','salt_composition','%amoxicillin%'),

  ('allergy','action_class','%antihistamine%'),
  ('allergy','action_class','%h1 antagonist%'),
  ('allergy','action_class','%leukotriene%'),
  ('allergy','salt_composition','%cetirizine%'),
  ('allergy','salt_composition','%levocetirizine%'),
  ('allergy','salt_composition','%fexofenadine%'),
  ('allergy','salt_composition','%loratadine%'),
  ('allergy','salt_composition','%montelukast%'),
  ('allergy','salt_composition','%bilastine%'),
  ('allergy','salt_composition','%hydroxyzine%'),

  ('acidity','action_class','%proton pump inhibitor%'),
  ('acidity','action_class','%h2 receptor%'),
  ('acidity','action_class','%antacid%'),
  ('acidity','salt_composition','%pantoprazole%'),
  ('acidity','salt_composition','%omeprazole%'),
  ('acidity','salt_composition','%esomeprazole%'),
  ('acidity','salt_composition','%rabeprazole%'),
  ('acidity','salt_composition','%lansoprazole%'),
  ('acidity','salt_composition','%ranitidine%'),
  ('acidity','salt_composition','%famotidine%'),
  ('acidity','salt_composition','%sucralfate%'),
  ('acidity','salt_composition','%magaldrate%'),
  ('acidity','salt_composition','%sodium alginate%'),

  ('indigestion','action_class','%prokinetic%'),
  ('indigestion','action_class','%digestive enzyme%'),
  ('indigestion','salt_composition','%simethicone%'),
  ('indigestion','salt_composition','%simeticone%'),
  ('indigestion','salt_composition','%domperidone%'),
  ('indigestion','salt_composition','%pancreatin%'),
  ('indigestion','salt_composition','%dicyclomine%'),
  ('indigestion','salt_composition','%drotaverine%'),

  ('constipation','action_class','%laxative%'),
  ('constipation','salt_composition','%lactulose%'),
  ('constipation','salt_composition','%bisacodyl%'),
  ('constipation','salt_composition','%ispaghula%'),
  ('constipation','salt_composition','%sodium picosulphate%'),
  ('constipation','salt_composition','%polyethylene glycol%'),

  ('diarrhoea','action_class','%antidiarrhoeal%'),
  ('diarrhoea','action_class','%antidiarrheal%'),
  ('diarrhoea','salt_composition','%loperamide%'),
  ('diarrhoea','salt_composition','%racecadotril%'),
  ('diarrhoea','salt_composition','%oral rehydration%'),
  ('diarrhoea','salt_composition','%ors%'),
  ('diarrhoea','salt_composition','%saccharomyces%'),
  ('diarrhoea','salt_composition','%lactobacillus%'),

  ('vomiting','action_class','%antiemetic%'),
  ('vomiting','salt_composition','%ondansetron%'),
  ('vomiting','salt_composition','%doxylamine%'),
  ('vomiting','salt_composition','%metoclopramide%'),
  ('vomiting','salt_composition','%promethazine%'),

  ('worm-infection','action_class','%anthelmintic%'),
  ('worm-infection','salt_composition','%albendazole%'),
  ('worm-infection','salt_composition','%mebendazole%'),
  ('worm-infection','salt_composition','%ivermectin%'),
  ('worm-infection','salt_composition','%praziquantel%'),

  ('diabetes-type-2','therapeutic_class','%anti diabetic%'),
  ('diabetes-type-2','therapeutic_class','%antidiabetic%'),
  ('diabetes-type-2','action_class','%biguanide%'),
  ('diabetes-type-2','action_class','%sulfonylurea%'),
  ('diabetes-type-2','action_class','%sulphonylurea%'),
  ('diabetes-type-2','action_class','%dpp-4%'),
  ('diabetes-type-2','action_class','%sglt2%'),
  ('diabetes-type-2','salt_composition','%metformin%'),
  ('diabetes-type-2','salt_composition','%glimepiride%'),
  ('diabetes-type-2','salt_composition','%sitagliptin%'),
  ('diabetes-type-2','salt_composition','%vildagliptin%'),
  ('diabetes-type-2','salt_composition','%dapagliflozin%'),
  ('diabetes-type-2','salt_composition','%empagliflozin%'),
  ('diabetes-type-2','salt_composition','%teneligliptin%'),
  ('diabetes-type-2','salt_composition','%gliclazide%'),
  ('diabetes-type-2','salt_composition','%pioglitazone%'),
  ('diabetes-type-2','salt_composition','%insulin%'),

  ('hypertension','action_class','%angiotensin receptor blocker%'),
  ('hypertension','action_class','%calcium channel blocker%'),
  ('hypertension','action_class','%ace inhibitor%'),
  ('hypertension','action_class','%beta blocker%'),
  ('hypertension','action_class','%diuretic%'),
  ('hypertension','salt_composition','%telmisartan%'),
  ('hypertension','salt_composition','%amlodipine%'),
  ('hypertension','salt_composition','%losartan%'),
  ('hypertension','salt_composition','%olmesartan%'),
  ('hypertension','salt_composition','%ramipril%'),
  ('hypertension','salt_composition','%metoprolol%'),
  ('hypertension','salt_composition','%cilnidipine%'),
  ('hypertension','salt_composition','%chlorthalidone%'),

  ('heart-care','therapeutic_class','%cardiac%'),
  ('heart-care','action_class','%antiplatelet%'),
  ('heart-care','action_class','%anticoagulant%'),
  ('heart-care','action_class','%vitamin k antagonist%'),
  ('heart-care','salt_composition','%clopidogrel%'),
  ('heart-care','salt_composition','%ivabradine%'),
  ('heart-care','salt_composition','%nitroglycerin%'),
  ('heart-care','salt_composition','%isosorbide%'),
  ('heart-care','salt_composition','%warfarin%'),
  ('heart-care','salt_composition','%digoxin%'),

  ('cholesterol','action_class','%hmg-coa%'),
  ('cholesterol','action_class','%statin%'),
  ('cholesterol','action_class','%lipid%'),
  ('cholesterol','salt_composition','%atorvastatin%'),
  ('cholesterol','salt_composition','%rosuvastatin%'),
  ('cholesterol','salt_composition','%fenofibrate%'),
  ('cholesterol','salt_composition','%ezetimibe%'),

  ('asthma','therapeutic_class','%respiratory%'),
  ('asthma','action_class','%bronchodilator%'),
  ('asthma','action_class','%beta2 agonist%'),
  ('asthma','action_class','%corticosteroid%'),
  ('asthma','salt_composition','%salbutamol%'),
  ('asthma','salt_composition','%formoterol%'),
  ('asthma','salt_composition','%budesonide%'),
  ('asthma','salt_composition','%tiotropium%'),
  ('asthma','salt_composition','%doxofylline%'),
  ('asthma','salt_composition','%theophylline%'),

  ('bacterial-infection','therapeutic_class','%anti infective%'),
  ('bacterial-infection','therapeutic_class','%anti-infective%'),
  ('bacterial-infection','action_class','%antibiotic%'),
  ('bacterial-infection','action_class','%cephalosporin%'),
  ('bacterial-infection','action_class','%macrolide%'),
  ('bacterial-infection','action_class','%quinolone%'),
  ('bacterial-infection','action_class','%penicillin%'),
  ('bacterial-infection','salt_composition','%azithromycin%'),
  ('bacterial-infection','salt_composition','%amoxycillin%'),
  ('bacterial-infection','salt_composition','%amoxicillin%'),
  ('bacterial-infection','salt_composition','%cefixime%'),
  ('bacterial-infection','salt_composition','%ceftriaxone%'),
  ('bacterial-infection','salt_composition','%levofloxacin%'),
  ('bacterial-infection','salt_composition','%ofloxacin%'),
  ('bacterial-infection','salt_composition','%doxycycline%'),
  ('bacterial-infection','salt_composition','%metronidazole%'),

  ('fungal-infection','action_class','%antifungal%'),
  ('fungal-infection','salt_composition','%fluconazole%'),
  ('fungal-infection','salt_composition','%itraconazole%'),
  ('fungal-infection','salt_composition','%terbinafine%'),
  ('fungal-infection','salt_composition','%ketoconazole%'),
  ('fungal-infection','salt_composition','%clotrimazole%'),
  ('fungal-infection','salt_composition','%luliconazole%'),
  ('fungal-infection','salt_composition','%griseofulvin%'),

  ('skin-care','therapeutic_class','%derma%'),
  ('skin-care','salt_composition','%mometasone%'),
  ('skin-care','salt_composition','%calamine%'),
  ('skin-care','salt_composition','%tacrolimus%'),
  ('skin-care','salt_composition','%salicylic acid%'),
  ('skin-care','salt_composition','%urea%'),

  ('hair-care','salt_composition','%minoxidil%'),
  ('hair-care','salt_composition','%finasteride%'),
  ('hair-care','salt_composition','%ketoconazole%'),
  ('hair-care','salt_composition','%biotin%'),

  ('acne','salt_composition','%adapalene%'),
  ('acne','salt_composition','%benzoyl peroxide%'),
  ('acne','salt_composition','%clindamycin%'),
  ('acne','salt_composition','%isotretinoin%'),
  ('acne','salt_composition','%azelaic%'),

  ('eye-care','therapeutic_class','%ophthal%'),
  ('eye-care','salt_composition','%carboxymethylcellulose%'),
  ('eye-care','salt_composition','%moxifloxacin%'),
  ('eye-care','salt_composition','%timolol%'),
  ('eye-care','salt_composition','%latanoprost%'),

  ('ear-care','therapeutic_class','%otological%'),
  ('ear-care','salt_composition','%clotrimazole%'),

  ('dental','therapeutic_class','%stomatological%'),
  ('dental','salt_composition','%chlorhexidine%'),
  ('dental','salt_composition','%potassium nitrate%'),
  ('dental','salt_composition','%lignocaine%'),

  ('arthritis','action_class','%dmard%'),
  ('arthritis','action_class','%xanthine oxidase%'),
  ('arthritis','salt_composition','%methotrexate%'),
  ('arthritis','salt_composition','%hydroxychloroquine%'),
  ('arthritis','salt_composition','%febuxostat%'),
  ('arthritis','salt_composition','%allopurinol%'),
  ('arthritis','salt_composition','%etoricoxib%'),
  ('arthritis','salt_composition','%glucosamine%'),

  ('bone-calcium','salt_composition','%calcium carbonate%'),
  ('bone-calcium','salt_composition','%calcitriol%'),
  ('bone-calcium','salt_composition','%cholecalciferol%'),
  ('bone-calcium','salt_composition','%alendronate%'),
  ('bone-calcium','salt_composition','%zoledronic%'),

  ('vitamins','therapeutic_class','%vitamins%'),
  ('vitamins','therapeutic_class','%nutrient%'),
  ('vitamins','salt_composition','%multivitamin%'),
  ('vitamins','salt_composition','%vitamin b%'),
  ('vitamins','salt_composition','%vitamin c%'),
  ('vitamins','salt_composition','%ascorbic acid%'),
  ('vitamins','salt_composition','%methylcobalamin%'),
  ('vitamins','salt_composition','%zinc%'),

  ('anaemia','therapeutic_class','%blood related%'),
  ('anaemia','action_class','%haematinic%'),
  ('anaemia','salt_composition','%ferrous%'),
  ('anaemia','salt_composition','%iron%'),
  ('anaemia','salt_composition','%folic acid%'),
  ('anaemia','salt_composition','%erythropoietin%'),

  ('thyroid','salt_composition','%thyroxine%'),
  ('thyroid','salt_composition','%levothyroxine%'),
  ('thyroid','salt_composition','%carbimazole%'),
  ('thyroid','salt_composition','%methimazole%'),

  ('anxiety-sleep','action_class','%benzodiazepine%'),
  ('anxiety-sleep','action_class','%anxiolytic%'),
  ('anxiety-sleep','salt_composition','%alprazolam%'),
  ('anxiety-sleep','salt_composition','%clonazepam%'),
  ('anxiety-sleep','salt_composition','%zolpidem%'),
  ('anxiety-sleep','salt_composition','%etizolam%'),
  ('anxiety-sleep','salt_composition','%melatonin%'),

  ('depression','action_class','%ssri%'),
  ('depression','action_class','%antidepressant%'),
  ('depression','salt_composition','%escitalopram%'),
  ('depression','salt_composition','%sertraline%'),
  ('depression','salt_composition','%fluoxetine%'),
  ('depression','salt_composition','%amitriptyline%'),
  ('depression','salt_composition','%venlafaxine%'),

  ('epilepsy','action_class','%antiepileptic%'),
  ('epilepsy','action_class','%anticonvulsant%'),
  ('epilepsy','salt_composition','%levetiracetam%'),
  ('epilepsy','salt_composition','%sodium valproate%'),
  ('epilepsy','salt_composition','%carbamazepine%'),
  ('epilepsy','salt_composition','%phenytoin%'),
  ('epilepsy','salt_composition','%lamotrigine%'),

  ('urinary','therapeutic_class','%urology%'),
  ('urinary','salt_composition','%nitrofurantoin%'),
  ('urinary','salt_composition','%fosfomycin%'),
  ('urinary','salt_composition','%potassium citrate%'),
  ('urinary','salt_composition','%solifenacin%'),

  ('prostate','salt_composition','%tamsulosin%'),
  ('prostate','salt_composition','%dutasteride%'),
  ('prostate','salt_composition','%alfuzosin%'),
  ('prostate','salt_composition','%silodosin%'),

  ('piles','salt_composition','%diosmin%'),
  ('piles','salt_composition','%hesperidin%'),
  ('piles','salt_composition','%lignocaine%'),
  ('piles','salt_composition','%calcium dobesilate%'),

  ('liver-care','action_class','%hepatoprotective%'),
  ('liver-care','salt_composition','%ursodeoxycholic%'),
  ('liver-care','salt_composition','%silymarin%'),
  ('liver-care','salt_composition','%l-ornithine%'),

  ('womens-health','therapeutic_class','%gynaec%'),
  ('womens-health','salt_composition','%mifepristone%'),
  ('womens-health','salt_composition','%progesterone%'),
  ('womens-health','salt_composition','%myo-inositol%'),
  ('womens-health','salt_composition','%tranexamic%'),
  ('womens-health','salt_composition','%norethisterone%'),

  ('pregnancy-care','salt_composition','%folic acid%'),
  ('pregnancy-care','salt_composition','%doxylamine%'),
  ('pregnancy-care','salt_composition','%iron and folic%'),

  ('child-care','salt_composition','%zinc sulphate%'),
  ('child-care','salt_composition','%colic%'),
  ('child-care','salt_composition','%dill oil%'),

  ('immunity','salt_composition','%vitamin c%'),
  ('immunity','salt_composition','%zinc%'),
  ('immunity','salt_composition','%ashwagandha%'),
  ('immunity','salt_composition','%giloy%'),

  ('weight','salt_composition','%orlistat%'),
  ('weight','salt_composition','%liraglutide%'),
  ('weight','salt_composition','%semaglutide%'),

  ('wound-care','action_class','%antiseptic%'),
  ('wound-care','salt_composition','%povidone iodine%'),
  ('wound-care','salt_composition','%silver sulphadiazine%'),
  ('wound-care','salt_composition','%mupirocin%'),
  ('wound-care','salt_composition','%framycetin%'),

  ('cancer-care','therapeutic_class','%neoplastic%'),
  ('cancer-care','action_class','%antineoplastic%'),
  ('cancer-care','salt_composition','%imatinib%'),
  ('cancer-care','salt_composition','%tamoxifen%'),
  ('cancer-care','salt_composition','%capecitabine%'),

  ('malaria','therapeutic_class','%antimalarial%'),
  ('malaria','salt_composition','%artemether%'),
  ('malaria','salt_composition','%chloroquine%'),
  ('malaria','salt_composition','%primaquine%'),

  ('tuberculosis','therapeutic_class','%anti tb%'),
  ('tuberculosis','therapeutic_class','%antitubercular%'),
  ('tuberculosis','salt_composition','%rifampicin%'),
  ('tuberculosis','salt_composition','%isoniazid%'),
  ('tuberculosis','salt_composition','%pyrazinamide%'),
  ('tuberculosis','salt_composition','%ethambutol%')
on conflict do nothing;

-- ── the one-time mapping pass ─────────────────────────────────────────────
-- Four separate equality joins on purpose. The obvious single statement with
-- an OR across the four fields cannot hash-join, and Postgres falls back to a
-- nested loop of 250k MEDICINE rows against every resolved value — the shape
-- that makes a seed look like a hang. Each field is resolved to DISTINCT class
-- values first (a few thousand rows), then joined by equality.
create or replace function public.condition_seed_run(p_keys text[] default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_ins   bigint := 0;
  v_step  bigint;
  v_conds int    := 0;
  f       text;
begin
  -- A generous budget, set locally: the pass is one-time and it scans MEDICINE
  -- four times. The default role timeout is what turns a 90-second seed into a
  -- failed migration on a catalogue this size.
  set local statement_timeout = '900s';

  -- Dropped first, not just ON COMMIT DROP: a second call inside the SAME
  -- transaction (an admin re-seed, a test) would otherwise hit a temp table
  -- that already exists.
  drop table if exists _cs_target;
  drop table if exists _cs_val;

  create temp table _cs_target on commit drop as
    select c.id, c.condition_key
      from public.condition c
     where case when p_keys is null then c.seeded_at is null
                else c.condition_key = any(p_keys) end;
  select count(*) into v_conds from _cs_target;
  if v_conds = 0 then
    return jsonb_build_object('ok', true, 'conditions', 0, 'mapped', 0);
  end if;

  create temp table _cs_val on commit drop as
  with vals as (
    select 'therapeutic_class'::text as field, m.therapeutic_class as value
      from public."MEDICINE" m where nullif(btrim(m.therapeutic_class),'') is not null
    union
    select 'chemical_class', m.chemical_class
      from public."MEDICINE" m where nullif(btrim(m.chemical_class),'') is not null
    union
    select 'action_class', m.action_class
      from public."MEDICINE" m where nullif(btrim(m.action_class),'') is not null
    union
    select 'salt_composition', m.salt_composition
      from public."MEDICINE" m where nullif(btrim(m.salt_composition),'') is not null
  )
  select distinct t.id as condition_id, v.field, v.value
    from vals v
    join public.condition_seed_rule r on r.field = v.field and v.value ilike r.pattern
    join _cs_target t on t.condition_key = r.condition_key;

  create index on _cs_val (field, value);

  foreach f in array array['therapeutic_class','chemical_class','action_class','salt_composition'] loop
    execute format($q$
      insert into public.condition_medicine (condition_id, medicine_id, source)
      select distinct v.condition_id, m.id, 'seed'
        from public."MEDICINE" m
        join _cs_val v on v.field = %1$L and v.value = m.%2$I
       where m.id is not null
      on conflict do nothing
    $q$, f, f);
    get diagnostics v_step = row_count;
    v_ins := v_ins + v_step;
  end loop;

  update public.condition c
     set seeded_at = now()
    from _cs_target t
   where t.id = c.id;

  return jsonb_build_object('ok', true, 'conditions', v_conds, 'mapped', v_ins);
end $fn$;

revoke all on function public.condition_seed_run(text[]) from public, anon, authenticated;

-- Run it once, here, so the door has products the moment it ships. Every
-- condition it touches is stamped `seeded_at`, so a replay of this file is a
-- no-op and an admin's later edits are never overwritten.
-- CMD #1929 — the seed pass scans public."MEDICINE" four times and builds a
-- DISTINCT value set over four more scans. On live that runs past the default
-- 120 s statement_timeout, and because migration_replay.sh applies this file
-- with ON_ERROR_STOP the cancel failed the WHOLE live replay: #1929 and #1912
-- both died here at `canceling statement due to statement timeout`, with the
-- schema above already applied and only the seed outstanding.
--
-- The pass is a single statement, so a cancel rolls it back whole and leaves
-- `seeded_at` null — nothing is ever half-seeded. So it is given room, and if
-- it still cannot finish it DEFERS with a warning instead of taking every
-- other command's deploy down with it. The conditions simply stay unseeded
-- until `condition_seed_run()` is called again; an admin's rows are untouched
-- either way.
set statement_timeout = '600s';

do $seed$
begin
  perform public.condition_seed_run();
exception when others then
  raise warning 'condition_seed_run deferred (%) — conditions stay unseeded (seeded_at null); re-run select public.condition_seed_run();', sqlerrm;
end $seed$;

reset statement_timeout;
