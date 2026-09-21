-- CMD #2135 — Registration v3: General · Location · Documents.
--
-- 1  DATA      every state/UT (36) and district (784) from the official Local
--              Government Directory (lgdirectory.gov.in, fetched 2026-09-21),
--              an alias list for the spellings people and Google actually use
--              (Raypur, Baloda Bazar, Bhilai, Uslapur…), and ONE matcher that
--              turns any of them into the official name — or says it cannot.
--              Existing profiles are normalised with it.
-- 2  GOOGLE    reverse-geocode goes through the geo-reverse-google edge
--              function (GOOGLE_GEOCODING_KEY, a server key) — never Nominatim.
-- 3  LOCATION  State + District are picked from the official list, auto-picked
--              from the pin; the district decides the zone, which is saved on
--              the profile and never shown.
-- 4  DOCUMENTS the zone's own list; an upload is saved the moment it lands (the
--              profile row is created early if it has to be); what OCR reads
--              sits on the row with Edit; unreadable → "tap to type".
--
-- Idempotent: every table IF NOT EXISTS, every row ON CONFLICT, every function
-- CREATE OR REPLACE. Replayed on live once by the direct deploy.

-- ─────────────────────────────────────────────────────────────── 1 · DATA ──
create table if not exists public.geo_state (
  lgd_code   int primary key,
  name       text not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.geo_district (
  lgd_code   int primary key,
  state_lgd  int not null references public.geo_state(lgd_code) on delete cascade,
  name       text not null,
  updated_at timestamptz not null default now()
);
create index if not exists geo_district_state_idx on public.geo_district(state_lgd);

-- What people (and Google) write, keyed the way the matcher keys everything:
-- lower case, letters and digits only. district_lgd null = a STATE alias.
create table if not exists public.geo_place_alias (
  alias_key    text not null,
  state_lgd    int  not null references public.geo_state(lgd_code) on delete cascade,
  district_lgd int  references public.geo_district(lgd_code) on delete cascade,
  note         text,
  primary key (alias_key, state_lgd)
);

alter table public.geo_state       enable row level security;
alter table public.geo_district    enable row level security;
alter table public.geo_place_alias enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='geo_state' and policyname='geo_state_read') then
    create policy geo_state_read on public.geo_state for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='geo_district' and policyname='geo_district_read') then
    create policy geo_district_read on public.geo_district for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='geo_place_alias' and policyname='geo_place_alias_read') then
    create policy geo_place_alias_read on public.geo_place_alias for select using (true);
  end if;
end $$;
grant select on public.geo_state, public.geo_district, public.geo_place_alias to anon, authenticated;

insert into public.geo_state(lgd_code, name) values
  (35, 'Andaman and Nicobar Islands'),
  (28, 'Andhra Pradesh'),
  (12, 'Arunachal Pradesh'),
  (18, 'Assam'),
  (10, 'Bihar'),
  (4, 'Chandigarh'),
  (22, 'Chhattisgarh'),
  (7, 'Delhi'),
  (30, 'Goa'),
  (24, 'Gujarat'),
  (6, 'Haryana'),
  (2, 'Himachal Pradesh'),
  (1, 'Jammu and Kashmir'),
  (20, 'Jharkhand'),
  (29, 'Karnataka'),
  (32, 'Kerala'),
  (37, 'Ladakh'),
  (31, 'Lakshadweep'),
  (23, 'Madhya Pradesh'),
  (27, 'Maharashtra'),
  (14, 'Manipur'),
  (17, 'Meghalaya'),
  (15, 'Mizoram'),
  (13, 'Nagaland'),
  (21, 'Odisha'),
  (34, 'Puducherry'),
  (3, 'Punjab'),
  (8, 'Rajasthan'),
  (11, 'Sikkim'),
  (33, 'Tamil Nadu'),
  (36, 'Telangana'),
  (38, 'The Dadra and Nagar Haveli and Daman and Diu'),
  (16, 'Tripura'),
  (9, 'Uttar Pradesh'),
  (5, 'Uttarakhand'),
  (19, 'West Bengal')
on conflict (lgd_code) do update set name = excluded.name, updated_at = now();

insert into public.geo_district(lgd_code, state_lgd, name) values
  (6, 37, 'Kargil'),
  (9, 37, 'Leh Ladakh'),
  (466, 27, 'Ahilyanagar'),
  (467, 27, 'Akola'),
  (468, 27, 'Amravati'),
  (470, 27, 'Beed'),
  (471, 27, 'Bhandara'),
  (472, 27, 'Buldhana'),
  (473, 27, 'Chandrapur'),
  (469, 27, 'Chhatrapati Sambhajinagar'),
  (488, 27, 'Dharashiv'),
  (474, 27, 'Dhule'),
  (475, 27, 'Gadchiroli'),
  (476, 27, 'Gondia'),
  (477, 27, 'Hingoli'),
  (478, 27, 'Jalgaon'),
  (479, 27, 'Jalna'),
  (480, 27, 'Kolhapur'),
  (481, 27, 'Latur'),
  (482, 27, 'Mumbai'),
  (483, 27, 'Mumbai Suburban'),
  (484, 27, 'Nagpur'),
  (485, 27, 'Nanded'),
  (486, 27, 'Nandurbar'),
  (487, 27, 'Nashik'),
  (665, 27, 'Palghar'),
  (489, 27, 'Parbhani'),
  (490, 27, 'Pune'),
  (491, 27, 'Raigad'),
  (492, 27, 'Ratnagiri'),
  (493, 27, 'Sangli'),
  (494, 27, 'Satara'),
  (495, 27, 'Sindhudurg'),
  (496, 27, 'Solapur'),
  (497, 27, 'Thane'),
  (498, 27, 'Wardha'),
  (499, 27, 'Washim'),
  (500, 27, 'Yavatmal'),
  (598, 34, 'Karaikal'),
  (600, 34, 'Puducherry'),
  (344, 21, 'Anugola'),
  (345, 21, 'Balangir'),
  (346, 21, 'Baleshwar'),
  (347, 21, 'Baragada'),
  (348, 21, 'Bhadrak'),
  (349, 21, 'Boudh'),
  (351, 21, 'Debagada'),
  (352, 21, 'Dhenkanal'),
  (353, 21, 'Gajapati'),
  (354, 21, 'Ganjam'),
  (355, 21, 'Jagatsinghapur'),
  (356, 21, 'Jajpur'),
  (357, 21, 'Jharsuguda'),
  (358, 21, 'Kalahandi'),
  (359, 21, 'Kandhamala'),
  (350, 21, 'Kataka'),
  (360, 21, 'Kendrapada'),
  (361, 21, 'Kendujhar'),
  (362, 21, 'Khordha'),
  (363, 21, 'Koraput'),
  (364, 21, 'Malkangiri'),
  (365, 21, 'Mayurbhanj'),
  (366, 21, 'Nabarangpur'),
  (367, 21, 'Nayagada'),
  (368, 21, 'Nuapada'),
  (369, 21, 'Puri'),
  (370, 21, 'Rayagada'),
  (371, 21, 'Sambalpur'),
  (372, 21, 'Subarnapur'),
  (373, 21, 'Sundaragada'),
  (269, 16, 'Dhalai'),
  (654, 16, 'Gomati'),
  (652, 16, 'Khowai'),
  (270, 16, 'North Tripura'),
  (653, 16, 'Sepahijala'),
  (271, 16, 'South Tripura'),
  (655, 16, 'Unakoti'),
  (272, 16, 'West Tripura'),
  (322, 20, 'Bokaro'),
  (323, 20, 'Chatra'),
  (324, 20, 'Deoghar'),
  (325, 20, 'Dhanbad'),
  (326, 20, 'Dumka'),
  (327, 20, 'East Singhbum'),
  (328, 20, 'Garhwa'),
  (329, 20, 'Giridih'),
  (330, 20, 'Godda'),
  (331, 20, 'Gumla'),
  (332, 20, 'Hazaribagh'),
  (333, 20, 'Jamtara'),
  (606, 20, 'Khunti'),
  (334, 20, 'Koderma'),
  (335, 20, 'Latehar'),
  (336, 20, 'Lohardaga'),
  (337, 20, 'Pakur'),
  (338, 20, 'Palamu'),
  (607, 20, 'Ramgarh'),
  (339, 20, 'Ranchi'),
  (340, 20, 'Sahebganj'),
  (341, 20, 'Saraikela Kharsawan'),
  (342, 20, 'Simdega'),
  (343, 20, 'West Singhbhum'),
  (646, 22, 'Balod'),
  (644, 22, 'Balodabazar-Bhatapara'),
  (649, 22, 'Balrampur-Ramanujganj'),
  (374, 22, 'Bastar'),
  (650, 22, 'Bemetara'),
  (636, 22, 'Bijapur'),
  (375, 22, 'Bilaspur'),
  (376, 22, 'Dakshin Bastar Dantewada'),
  (377, 22, 'Dhamtari'),
  (378, 22, 'Durg'),
  (645, 22, 'Gariyaband'),
  (734, 22, 'Gaurela-Pendra-Marwahi'),
  (379, 22, 'Janjgir-Champa'),
  (380, 22, 'Jashpur'),
  (382, 22, 'Kabeerdham'),
  (759, 22, 'Khairagarh-Chhuikhadan-Gandai'),
  (643, 22, 'Kondagaon'),
  (383, 22, 'Korba'),
  (384, 22, 'Korea'),
  (385, 22, 'Mahasamund'),
  (760, 22, 'Manendragarh-Chirmiri-Bharatpur(M C B)'),
  (761, 22, 'Mohla-Manpur-Ambagarh Chouki'),
  (647, 22, 'Mungeli'),
  (637, 22, 'Narayanpur'),
  (386, 22, 'Raigarh'),
  (387, 22, 'Raipur'),
  (388, 22, 'Rajnandgaon'),
  (762, 22, 'Sakti'),
  (763, 22, 'Sarangarh-Bilaigarh'),
  (642, 22, 'Sukma'),
  (648, 22, 'Surajpur'),
  (389, 22, 'Surguja'),
  (381, 22, 'Uttar Bastar Kanker'),
  (45, 5, 'Almora'),
  (46, 5, 'Bageshwar'),
  (47, 5, 'Chamoli'),
  (48, 5, 'Champawat'),
  (49, 5, 'Dehradun'),
  (50, 5, 'Haridwar'),
  (51, 5, 'Nainital'),
  (52, 5, 'Pauri Garhwal'),
  (53, 5, 'Pithoragarh'),
  (54, 5, 'Rudraprayag'),
  (55, 5, 'Tehri Garhwal'),
  (56, 5, 'Udham Singh Nagar'),
  (57, 5, 'Uttarkashi'),
  (524, 29, 'Bagalkote'),
  (528, 29, 'Ballari'),
  (527, 29, 'Belagavi'),
  (526, 29, 'Bengaluru Rural'),
  (631, 29, 'Bengaluru South'),
  (525, 29, 'Bengaluru Urban'),
  (529, 29, 'Bidar'),
  (531, 29, 'Chamarajanagar'),
  (630, 29, 'Chikkaballapura'),
  (532, 29, 'Chikkamagaluru'),
  (533, 29, 'Chitradurga'),
  (534, 29, 'Dakshina Kannada'),
  (535, 29, 'Davanagere'),
  (536, 29, 'Dharwad'),
  (537, 29, 'Gadag'),
  (539, 29, 'Hassan'),
  (540, 29, 'Haveri'),
  (538, 29, 'Kalaburagi'),
  (541, 29, 'Kodagu'),
  (542, 29, 'Kolar'),
  (543, 29, 'Koppal'),
  (544, 29, 'Mandya'),
  (545, 29, 'Mysuru'),
  (546, 29, 'Raichur'),
  (547, 29, 'Shivamogga'),
  (548, 29, 'Tumakuru'),
  (549, 29, 'Udupi'),
  (550, 29, 'Uttara Kannada'),
  (738, 29, 'Vijayanagara'),
  (530, 29, 'Vijayapura'),
  (635, 29, 'Yadgir'),
  (501, 36, 'Adilabad'),
  (690, 36, 'Bhadradri Kothagudem'),
  (686, 36, 'Hanumakonda'),
  (507, 36, 'Hyderabad'),
  (681, 36, 'Jagitial'),
  (689, 36, 'Jangoan'),
  (687, 36, 'Jayashankar Bhupalapally'),
  (695, 36, 'Jogulamba Gadwal'),
  (685, 36, 'Kamareddy'),
  (508, 36, 'Karimnagar'),
  (509, 36, 'Khammam'),
  (699, 36, 'Kumuram Bheem Asifabad'),
  (688, 36, 'Mahabubabad'),
  (512, 36, 'Mahabubnagar'),
  (684, 36, 'Mancherial'),
  (513, 36, 'Medak'),
  (700, 36, 'Medchal Malkajgiri'),
  (720, 36, 'Mulugu'),
  (694, 36, 'Nagarkurnool'),
  (514, 36, 'Nalgonda'),
  (721, 36, 'Narayanpet'),
  (680, 36, 'Nirmal'),
  (516, 36, 'Nizamabad'),
  (682, 36, 'Peddapalli'),
  (683, 36, 'Rajanna Sircilla'),
  (518, 36, 'Ranga Reddy'),
  (691, 36, 'Sangareddy'),
  (692, 36, 'Siddipet'),
  (696, 36, 'Suryapet'),
  (698, 36, 'Vikarabad'),
  (693, 36, 'Wanaparthy'),
  (522, 36, 'Warangal'),
  (697, 36, 'Yadadri Bhuvanagiri'),
  (1, 1, 'Anantnag'),
  (623, 1, 'Bandipora'),
  (3, 1, 'Baramulla'),
  (2, 1, 'Budgam'),
  (4, 1, 'Doda'),
  (626, 1, 'Ganderbal'),
  (5, 1, 'Jammu'),
  (7, 1, 'Kathua'),
  (620, 1, 'Kishtwar'),
  (622, 1, 'Kulgam'),
  (8, 1, 'Kupwara'),
  (10, 1, 'Poonch'),
  (11, 1, 'Pulwama'),
  (12, 1, 'Rajouri'),
  (621, 1, 'Ramban'),
  (627, 1, 'Reasi'),
  (624, 1, 'Samba'),
  (625, 1, 'Shopian'),
  (13, 1, 'Srinagar'),
  (14, 1, 'Udhampur'),
  (86, 8, 'Ajmer'),
  (87, 8, 'Alwar'),
  (775, 8, 'Balotra'),
  (88, 8, 'Banswara'),
  (89, 8, 'Baran'),
  (90, 8, 'Barmer'),
  (774, 8, 'Beawar'),
  (91, 8, 'Bharatpur'),
  (92, 8, 'Bhilwara'),
  (93, 8, 'Bikaner'),
  (94, 8, 'Bundi'),
  (95, 8, 'Chittorgarh'),
  (96, 8, 'Churu'),
  (97, 8, 'Dausa'),
  (767, 8, 'Deeg'),
  (98, 8, 'Dholpur'),
  (768, 8, 'Didwana-Kuchaman'),
  (99, 8, 'Dungarpur'),
  (100, 8, 'Ganganagar'),
  (101, 8, 'Hanumangarh'),
  (102, 8, 'Jaipur'),
  (103, 8, 'Jaisalmer'),
  (104, 8, 'Jalore'),
  (105, 8, 'Jhalawar'),
  (106, 8, 'Jhunjhunu'),
  (107, 8, 'Jodhpur'),
  (108, 8, 'Karauli'),
  (770, 8, 'Khairthal-Tijara'),
  (109, 8, 'Kota'),
  (782, 8, 'Kotputli-Behror'),
  (110, 8, 'Nagaur'),
  (111, 8, 'Pali'),
  (772, 8, 'Phalodi'),
  (629, 8, 'Pratapgarh'),
  (112, 8, 'Rajsamand'),
  (777, 8, 'Salumbar'),
  (113, 8, 'Sawai Madhopur'),
  (114, 8, 'Sikar'),
  (115, 8, 'Sirohi'),
  (116, 8, 'Tonk'),
  (117, 8, 'Udaipur'),
  (465, 38, 'Dadra And Nagar Haveli'),
  (463, 38, 'Daman'),
  (464, 38, 'Diu'),
  (15, 2, 'Bilaspur'),
  (16, 2, 'Chamba'),
  (17, 2, 'Hamirpur'),
  (18, 2, 'Kangra'),
  (19, 2, 'Kinnaur'),
  (20, 2, 'Kullu'),
  (21, 2, 'Lahaul And Spiti'),
  (22, 2, 'Mandi'),
  (23, 2, 'Shimla'),
  (24, 2, 'Sirmaur'),
  (25, 2, 'Solan'),
  (26, 2, 'Una'),
  (667, 23, 'Agar-Malwa'),
  (639, 23, 'Alirajpur'),
  (390, 23, 'Anuppur'),
  (391, 23, 'Ashoknagar'),
  (392, 23, 'Balaghat'),
  (393, 23, 'Barwani'),
  (394, 23, 'Betul'),
  (395, 23, 'Bhind'),
  (396, 23, 'Bhopal'),
  (397, 23, 'Burhanpur'),
  (398, 23, 'Chhatarpur'),
  (399, 23, 'Chhindwara'),
  (400, 23, 'Damoh'),
  (401, 23, 'Datia'),
  (402, 23, 'Dewas'),
  (403, 23, 'Dhar'),
  (404, 23, 'Dindori'),
  (406, 23, 'Guna'),
  (407, 23, 'Gwalior'),
  (408, 23, 'Harda'),
  (410, 23, 'Indore'),
  (411, 23, 'Jabalpur'),
  (412, 23, 'Jhabua'),
  (413, 23, 'Katni'),
  (405, 23, 'Khandwa (East Nimar)'),
  (414, 23, 'Khargone (West Nimar)'),
  (784, 23, 'Maihar'),
  (415, 23, 'Mandla'),
  (416, 23, 'Mandsaur'),
  (766, 23, 'MAUGANJ'),
  (417, 23, 'Morena'),
  (409, 23, 'Narmadapuram'),
  (418, 23, 'Narsimhapur'),
  (419, 23, 'Neemuch'),
  (722, 23, 'Niwari'),
  (785, 23, 'Pandhurna'),
  (420, 23, 'Panna'),
  (421, 23, 'Raisen'),
  (422, 23, 'Rajgarh'),
  (423, 23, 'Ratlam'),
  (424, 23, 'Rewa'),
  (425, 23, 'Sagar'),
  (426, 23, 'Satna'),
  (427, 23, 'Sehore'),
  (428, 23, 'Seoni'),
  (429, 23, 'Shahdol'),
  (430, 23, 'Shajapur'),
  (431, 23, 'Sheopur'),
  (432, 23, 'Shivpuri'),
  (433, 23, 'Sidhi'),
  (638, 23, 'Singrauli'),
  (434, 23, 'Tikamgarh'),
  (435, 23, 'Ujjain'),
  (436, 23, 'Umaria'),
  (437, 23, 'Vidisha'),
  (438, 24, 'Ahmedabad'),
  (439, 24, 'Amreli'),
  (440, 24, 'Anand'),
  (672, 24, 'Arvalli'),
  (441, 24, 'Banas Kantha'),
  (442, 24, 'Bharuch'),
  (443, 24, 'Bhavnagar'),
  (676, 24, 'Botad'),
  (668, 24, 'Chhotaudepur'),
  (445, 24, 'Dahod'),
  (444, 24, 'Dangs'),
  (674, 24, 'Devbhumi Dwarka'),
  (446, 24, 'Gandhinagar'),
  (675, 24, 'Gir Somnath'),
  (447, 24, 'Jamnagar'),
  (448, 24, 'Junagadh'),
  (449, 24, 'Kachchh'),
  (450, 24, 'Kheda'),
  (451, 24, 'Mahesana'),
  (669, 24, 'Mahisagar'),
  (673, 24, 'Morbi'),
  (452, 24, 'Narmada'),
  (453, 24, 'Navsari'),
  (454, 24, 'Panch Mahals'),
  (455, 24, 'Patan'),
  (456, 24, 'Porbandar'),
  (457, 24, 'Rajkot'),
  (458, 24, 'Sabar Kantha'),
  (459, 24, 'Surat'),
  (460, 24, 'Surendranagar'),
  (641, 24, 'Tapi'),
  (461, 24, 'Vadodara'),
  (462, 24, 'Valsad'),
  (789, 24, 'Vav-Tharad'),
  (745, 28, 'Alluri Sitharama Raju'),
  (744, 28, 'Anakapalli'),
  (502, 28, 'Ananthapuramu'),
  (753, 28, 'Annamayya'),
  (750, 28, 'Bapatla'),
  (503, 28, 'Chittoor'),
  (747, 28, 'Dr. B.R. Ambedkar Konaseema'),
  (505, 28, 'East Godavari'),
  (748, 28, 'Eluru'),
  (506, 28, 'Guntur'),
  (746, 28, 'Kakinada'),
  (510, 28, 'Krishna'),
  (511, 28, 'Kurnool'),
  (790, 28, 'Markapuram'),
  (755, 28, 'Nandyal'),
  (749, 28, 'Ntr'),
  (751, 28, 'Palnadu'),
  (743, 28, 'Parvathipuram Manyam'),
  (791, 28, 'Polavaram'),
  (517, 28, 'Prakasam'),
  (519, 28, 'Srikakulam'),
  (515, 28, 'Sri Potti Sriramulu Nellore'),
  (754, 28, 'Sri Sathya Sai'),
  (752, 28, 'Tirupati'),
  (520, 28, 'Visakhapatnam'),
  (521, 28, 'Vizianagaram'),
  (523, 28, 'West Godavari'),
  (504, 28, 'Y.S.R. Kadapa'),
  (27, 3, 'Amritsar'),
  (605, 3, 'Barnala'),
  (28, 3, 'Bathinda'),
  (29, 3, 'Faridkot'),
  (30, 3, 'Fatehgarh Sahib'),
  (651, 3, 'Fazilka'),
  (31, 3, 'Ferozepur'),
  (32, 3, 'Gurdaspur'),
  (33, 3, 'Hoshiarpur'),
  (34, 3, 'Jalandhar'),
  (35, 3, 'Kapurthala'),
  (36, 3, 'Ludhiana'),
  (737, 3, 'Malerkotla'),
  (37, 3, 'Mansa'),
  (38, 3, 'Moga'),
  (662, 3, 'Pathankot'),
  (41, 3, 'Patiala'),
  (42, 3, 'Rupnagar'),
  (43, 3, 'Sangrur'),
  (608, 3, 'S.A.S Nagar'),
  (40, 3, 'Shahid Bhagat Singh Nagar'),
  (39, 3, 'Sri Muktsar Sahib'),
  (609, 3, 'Tarn Taran'),
  (58, 6, 'Ambala'),
  (59, 6, 'Bhiwani'),
  (701, 6, 'Charkhi Dadri'),
  (60, 6, 'Faridabad'),
  (61, 6, 'Fatehabad'),
  (62, 6, 'Gurugram'),
  (792, 6, 'Hansi'),
  (63, 6, 'Hisar'),
  (64, 6, 'Jhajjar'),
  (65, 6, 'Jind'),
  (66, 6, 'Kaithal'),
  (67, 6, 'Karnal'),
  (68, 6, 'Kurukshetra'),
  (69, 6, 'Mahendragarh'),
  (604, 6, 'Nuh'),
  (619, 6, 'Palwal'),
  (70, 6, 'Panchkula'),
  (71, 6, 'Panipat'),
  (72, 6, 'Rewari'),
  (73, 6, 'Rohtak'),
  (74, 6, 'Sirsa'),
  (75, 6, 'Sonipat'),
  (76, 6, 'Yamunanagar'),
  (77, 7, 'Central'),
  (796, 7, 'Central North'),
  (78, 7, 'East'),
  (79, 7, 'New Delhi'),
  (80, 7, 'North'),
  (81, 7, 'North East'),
  (82, 7, 'North West'),
  (795, 7, 'Old Delhi'),
  (794, 7, 'Outer North'),
  (83, 7, 'South'),
  (670, 7, 'South East'),
  (84, 7, 'South West'),
  (85, 7, 'West'),
  (118, 9, 'Agra'),
  (119, 9, 'Aligarh'),
  (121, 9, 'Ambedkar Nagar'),
  (640, 9, 'Amethi'),
  (154, 9, 'Amroha'),
  (122, 9, 'Auraiya'),
  (140, 9, 'Ayodhya'),
  (123, 9, 'Azamgarh'),
  (124, 9, 'Baghpat'),
  (125, 9, 'Bahraich'),
  (126, 9, 'Ballia'),
  (127, 9, 'Balrampur'),
  (128, 9, 'Banda'),
  (129, 9, 'Bara Banki'),
  (130, 9, 'Bareilly'),
  (131, 9, 'Basti'),
  (179, 9, 'Bhadohi'),
  (132, 9, 'Bijnor'),
  (133, 9, 'Budaun'),
  (134, 9, 'Bulandshahr'),
  (135, 9, 'Chandauli'),
  (136, 9, 'Chitrakoot'),
  (137, 9, 'Deoria'),
  (138, 9, 'Etah'),
  (139, 9, 'Etawah'),
  (141, 9, 'Farrukhabad'),
  (142, 9, 'Fatehpur'),
  (143, 9, 'Firozabad'),
  (144, 9, 'Gautam Buddha Nagar'),
  (145, 9, 'Ghaziabad'),
  (146, 9, 'Ghazipur'),
  (147, 9, 'Gonda'),
  (148, 9, 'Gorakhpur'),
  (149, 9, 'Hamirpur'),
  (661, 9, 'Hapur'),
  (150, 9, 'Hardoi'),
  (163, 9, 'Hathras'),
  (151, 9, 'Jalaun'),
  (152, 9, 'Jaunpur'),
  (153, 9, 'Jhansi'),
  (155, 9, 'Kannauj'),
  (156, 9, 'Kanpur Dehat'),
  (157, 9, 'Kanpur Nagar'),
  (633, 9, 'Kasganj'),
  (158, 9, 'Kaushambi'),
  (159, 9, 'Kheri'),
  (160, 9, 'Kushinagar'),
  (161, 9, 'Lalitpur'),
  (162, 9, 'Lucknow'),
  (165, 9, 'Mahoba'),
  (164, 9, 'Mahrajganj'),
  (166, 9, 'Mainpuri'),
  (167, 9, 'Mathura'),
  (168, 9, 'Mau'),
  (169, 9, 'Meerut'),
  (170, 9, 'Mirzapur'),
  (171, 9, 'Moradabad'),
  (172, 9, 'Muzaffarnagar'),
  (173, 9, 'Pilibhit'),
  (174, 9, 'Pratapgarh'),
  (120, 9, 'Prayagraj'),
  (175, 9, 'Rae Bareli'),
  (176, 9, 'Rampur'),
  (177, 9, 'Saharanpur'),
  (659, 9, 'Sambhal'),
  (178, 9, 'Sant Kabir Nagar'),
  (180, 9, 'Shahjahanpur'),
  (660, 9, 'Shamli'),
  (181, 9, 'Shrawasti'),
  (182, 9, 'Siddharthnagar'),
  (183, 9, 'Sitapur'),
  (184, 9, 'Sonbhadra'),
  (185, 9, 'Sultanpur'),
  (186, 9, 'Unnao'),
  (187, 9, 'Varanasi'),
  (225, 11, 'Gangtok'),
  (228, 11, 'Gyalshing'),
  (226, 11, 'Mangan'),
  (227, 11, 'Namchi'),
  (741, 11, 'Pakyong'),
  (742, 11, 'Soreng'),
  (628, 12, 'Anjaw'),
  (787, 12, 'Bichom'),
  (229, 12, 'Changlang'),
  (230, 12, 'Dibang Valley'),
  (231, 12, 'East Kameng'),
  (232, 12, 'East Siang'),
  (718, 12, 'Kamle'),
  (786, 12, 'Keyi Panyor'),
  (677, 12, 'Kra Daadi'),
  (233, 12, 'Kurung Kumey'),
  (724, 12, 'Leparada'),
  (234, 12, 'Lohit'),
  (666, 12, 'Longding'),
  (235, 12, 'Lower Dibang Valley'),
  (719, 12, 'Lower Siang'),
  (236, 12, 'Lower Subansiri'),
  (678, 12, 'Namsai'),
  (723, 12, 'Pakke Kessang'),
  (237, 12, 'Papum Pare'),
  (725, 12, 'Shi Yomi'),
  (679, 12, 'Siang'),
  (238, 12, 'Tawang'),
  (239, 12, 'Tirap'),
  (240, 12, 'Upper Siang'),
  (241, 12, 'Upper Subansiri'),
  (242, 12, 'West Kameng'),
  (243, 12, 'West Siang'),
  (758, 13, 'Chumoukedima'),
  (244, 13, 'Dimapur'),
  (614, 13, 'Kiphire'),
  (245, 13, 'Kohima'),
  (615, 13, 'Longleng'),
  (788, 13, 'Meluri'),
  (246, 13, 'Mokokchung'),
  (247, 13, 'Mon'),
  (764, 13, 'Niuland'),
  (736, 13, 'Noklak'),
  (613, 13, 'Peren'),
  (248, 13, 'Phek'),
  (765, 13, 'Shamator'),
  (757, 13, 'Tseminyu'),
  (249, 13, 'Tuensang'),
  (250, 13, 'Wokha'),
  (251, 13, 'Zunheboto'),
  (252, 14, 'Bishnupur'),
  (253, 14, 'Chandel'),
  (254, 14, 'Churachandpur'),
  (255, 14, 'Imphal East'),
  (256, 14, 'Imphal West'),
  (713, 14, 'Jiribam'),
  (711, 14, 'Kakching'),
  (717, 14, 'Kamjong'),
  (712, 14, 'Kangpokpi'),
  (714, 14, 'Noney'),
  (715, 14, 'Pherzawl'),
  (257, 14, 'Senapati'),
  (258, 14, 'Tamenglong'),
  (716, 14, 'Tengnoupal'),
  (259, 14, 'Thoubal'),
  (260, 14, 'Ukhrul'),
  (261, 15, 'Aizawl'),
  (262, 15, 'Champhai'),
  (726, 15, 'Hnahthial'),
  (728, 15, 'Khawzawl'),
  (263, 15, 'Kolasib'),
  (264, 15, 'Lawngtlai'),
  (265, 15, 'Lunglei'),
  (266, 15, 'Mamit'),
  (727, 15, 'Saitual'),
  (268, 15, 'Serchhip'),
  (267, 15, 'Siaha'),
  (740, 17, 'Eastern West Khasi Hills'),
  (273, 17, 'East Garo Hills'),
  (657, 17, 'East Jaintia Hills'),
  (274, 17, 'East Khasi Hills'),
  (656, 17, 'North Garo Hills'),
  (276, 17, 'Ri Bhoi'),
  (277, 17, 'South Garo Hills'),
  (663, 17, 'South West Garo Hills'),
  (658, 17, 'South West Khasi Hills'),
  (278, 17, 'West Garo Hills'),
  (275, 17, 'West Jaintia Hills'),
  (279, 17, 'West Khasi Hills'),
  (739, 18, 'Bajali'),
  (616, 18, 'Baksa'),
  (280, 18, 'Barpeta'),
  (705, 18, 'Biswanath'),
  (281, 18, 'Bongaigaon'),
  (282, 18, 'Cachar'),
  (708, 18, 'Charaideo'),
  (612, 18, 'Chirang'),
  (283, 18, 'Darrang'),
  (284, 18, 'Dhemaji'),
  (285, 18, 'Dhubri'),
  (286, 18, 'Dibrugarh'),
  (299, 18, 'Dima Hasao'),
  (287, 18, 'Goalpara'),
  (288, 18, 'Golaghat'),
  (289, 18, 'Hailakandi'),
  (709, 18, 'Hojai'),
  (290, 18, 'Jorhat'),
  (291, 18, 'Kamrup'),
  (618, 18, 'Kamrup Metro'),
  (292, 18, 'Karbi Anglong'),
  (294, 18, 'Kokrajhar'),
  (295, 18, 'Lakhimpur'),
  (706, 18, 'Majuli'),
  (296, 18, 'Marigaon'),
  (297, 18, 'Nagaon'),
  (298, 18, 'Nalbari'),
  (300, 18, 'Sivasagar'),
  (301, 18, 'Sonitpur'),
  (707, 18, 'South Salmara Mancachar'),
  (293, 18, 'Sribhumi'),
  (756, 18, 'Tamulpur'),
  (302, 18, 'Tinsukia'),
  (617, 18, 'Udalguri'),
  (710, 18, 'West Karbi Anglong'),
  (664, 19, 'Alipurduar'),
  (305, 19, 'Bankura'),
  (307, 19, 'Birbhum'),
  (308, 19, 'Cooch Behar'),
  (310, 19, 'Dakshin Dinajpur'),
  (309, 19, 'Darjeeling'),
  (312, 19, 'Hooghly'),
  (313, 19, 'Howrah'),
  (314, 19, 'Jalpaiguri'),
  (703, 19, 'Jhargram'),
  (702, 19, 'Kalimpong'),
  (315, 19, 'Kolkata'),
  (316, 19, 'Malda'),
  (319, 19, 'Murshidabad'),
  (320, 19, 'Nadia'),
  (303, 19, 'North 24 Parganas'),
  (704, 19, 'Paschim Bardhaman'),
  (318, 19, 'Paschim Medinipur'),
  (306, 19, 'Purba Bardhaman'),
  (317, 19, 'Purba Medinipur'),
  (321, 19, 'Purulia'),
  (304, 19, 'South 24 Parganas'),
  (311, 19, 'Uttar Dinajpur'),
  (793, 30, 'Kushavati'),
  (551, 30, 'North Goa'),
  (552, 30, 'South Goa'),
  (553, 31, 'Lakshadweep District'),
  (554, 32, 'Alappuzha'),
  (555, 32, 'Ernakulam'),
  (556, 32, 'Idukki'),
  (557, 32, 'Kannur'),
  (558, 32, 'Kasaragod'),
  (559, 32, 'Kollam'),
  (560, 32, 'Kottayam'),
  (561, 32, 'Kozhikode'),
  (562, 32, 'Malappuram'),
  (563, 32, 'Palakkad'),
  (564, 32, 'Pathanamthitta'),
  (565, 32, 'Thiruvananthapuram'),
  (566, 32, 'Thrissur'),
  (567, 32, 'Wayanad'),
  (610, 33, 'Ariyalur'),
  (730, 33, 'Chengalpattu'),
  (568, 33, 'Chennai'),
  (569, 33, 'Coimbatore'),
  (570, 33, 'Cuddalore'),
  (571, 33, 'Dharmapuri'),
  (572, 33, 'Dindigul'),
  (573, 33, 'Erode'),
  (729, 33, 'Kallakurichi'),
  (574, 33, 'Kancheepuram'),
  (575, 33, 'Kanniyakumari'),
  (576, 33, 'Karur'),
  (577, 33, 'Krishnagiri'),
  (578, 33, 'Madurai'),
  (735, 33, 'Mayiladuthurai'),
  (579, 33, 'Nagapattinam'),
  (580, 33, 'Namakkal'),
  (581, 33, 'Perambalur'),
  (582, 33, 'Pudukkottai'),
  (583, 33, 'Ramanathapuram'),
  (731, 33, 'Ranipet'),
  (584, 33, 'Salem'),
  (585, 33, 'Sivaganga'),
  (733, 33, 'Tenkasi'),
  (586, 33, 'Thanjavur'),
  (588, 33, 'Theni'),
  (587, 33, 'The Nilgiris'),
  (589, 33, 'Thiruvallur'),
  (590, 33, 'Thiruvarur'),
  (594, 33, 'Thoothukkudi'),
  (591, 33, 'Tiruchirappalli'),
  (592, 33, 'Tirunelveli'),
  (732, 33, 'Tirupathur'),
  (634, 33, 'Tiruppur'),
  (593, 33, 'Tiruvannamalai'),
  (595, 33, 'Vellore'),
  (596, 33, 'Viluppuram'),
  (597, 33, 'Virudhunagar'),
  (603, 35, 'Nicobars'),
  (632, 35, 'North And Middle Andaman'),
  (602, 35, 'South Andamans'),
  (188, 10, 'Araria'),
  (611, 10, 'Arwal'),
  (189, 10, 'Aurangabad'),
  (190, 10, 'Banka'),
  (191, 10, 'Begusarai'),
  (192, 10, 'Bhagalpur'),
  (193, 10, 'Bhojpur'),
  (194, 10, 'Buxar'),
  (195, 10, 'Darbhanga'),
  (196, 10, 'Gaya'),
  (197, 10, 'Gopalganj'),
  (198, 10, 'Jamui'),
  (199, 10, 'Jehanabad'),
  (200, 10, 'Kaimur (Bhabua)'),
  (201, 10, 'Katihar'),
  (202, 10, 'Khagaria'),
  (203, 10, 'Kishanganj'),
  (204, 10, 'Lakhisarai'),
  (205, 10, 'Madhepura'),
  (206, 10, 'Madhubani'),
  (207, 10, 'Munger'),
  (208, 10, 'Muzaffarpur'),
  (209, 10, 'Nalanda'),
  (210, 10, 'Nawada'),
  (211, 10, 'Pashchim Champaran'),
  (212, 10, 'Patna'),
  (213, 10, 'Purbi Champaran'),
  (214, 10, 'Purnia'),
  (215, 10, 'Rohtas'),
  (216, 10, 'Saharsa'),
  (217, 10, 'Samastipur'),
  (218, 10, 'Saran'),
  (219, 10, 'Sheikhpura'),
  (220, 10, 'Sheohar'),
  (221, 10, 'Sitamarhi'),
  (222, 10, 'Siwan'),
  (223, 10, 'Supaul'),
  (224, 10, 'Vaishali'),
  (44, 4, 'Chandigarh')
on conflict (lgd_code) do update set state_lgd = excluded.state_lgd, name = excluded.name, updated_at = now();

create or replace function public.geo_key(p text)
 returns text language sql immutable
as $$ select nullif(regexp_replace(lower(coalesce(p,'')), '[^a-z0-9]', '', 'g'), '') $$;

-- Aliases. State spellings first, then the district ones the spec names
-- (Raypur → Raipur; Uslapur is a city in Bilaspur district) and the everyday
-- short forms of Chhattisgarh's newer districts.
insert into public.geo_place_alias(alias_key, state_lgd, district_lgd, note)
select public.geo_key(a.k), a.st, null, 'state spelling'
  from (values ('chattisgarh',22),('chhatisgarh',22),('chattishgarh',22),('cg',22),
               ('orissa',21),('pondicherry',34),('nctofdelhi',7),('newdelhi',7),
               ('uttaranchal',5),('dadraandnagarhaveli',38),('damananddiu',38),
               ('andamanandnicobar',35),('jk',1),('up',9),('mp',23)) a(k, st)
on conflict (alias_key, state_lgd) do update set district_lgd = excluded.district_lgd, note = excluded.note;

insert into public.geo_place_alias(alias_key, state_lgd, district_lgd, note)
select public.geo_key(a.k), 22, d.lgd_code, a.why
  from (values
    ('Raypur','Raipur','misspelling'),
    ('Raipur City','Raipur','city'),
    ('Naya Raipur','Raipur','city'),
    ('Nava Raipur','Raipur','city'),
    ('Atal Nagar','Raipur','city'),
    ('Uslapur','Bilaspur','city in Bilaspur district'),
    ('Bilaspur City','Bilaspur','city'),
    ('Bhilai','Durg','city in Durg district'),
    ('Bhilai Nagar','Durg','city'),
    ('Durg-Bhilai','Durg','city'),
    ('Baloda Bazar','Balodabazar-Bhatapara','short form'),
    ('Baloda Bazaar','Balodabazar-Bhatapara','short form'),
    ('Bhatapara','Balodabazar-Bhatapara','short form'),
    ('Kawardha','Kabeerdham','HQ town'),
    ('Kabirdham','Kabeerdham','spelling'),
    ('Kanker','Uttar Bastar Kanker','short form'),
    ('North Bastar Kanker','Uttar Bastar Kanker','english form'),
    ('Dantewada','Dakshin Bastar Dantewada','short form'),
    ('South Bastar Dantewada','Dakshin Bastar Dantewada','english form'),
    ('Jagdalpur','Bastar','HQ town'),
    ('Ambikapur','Surguja','HQ town'),
    ('Sarguja','Surguja','spelling'),
    ('Koriya','Korea','spelling'),
    ('Baikunthpur','Korea','HQ town'),
    ('Janjgir','Janjgir-Champa','short form'),
    ('Champa','Janjgir-Champa','short form'),
    ('Gaurela','Gaurela-Pendra-Marwahi','short form'),
    ('Pendra','Gaurela-Pendra-Marwahi','short form'),
    ('Manendragarh','Manendragarh-Chirmiri-Bharatpur(M C B)','short form'),
    ('Chirmiri','Manendragarh-Chirmiri-Bharatpur(M C B)','short form'),
    ('MCB','Manendragarh-Chirmiri-Bharatpur(M C B)','short form'),
    ('Mohla','Mohla-Manpur-Ambagarh Chouki','short form'),
    ('Khairagarh','Khairagarh-Chhuikhadan-Gandai','short form'),
    ('Sarangarh','Sarangarh-Bilaigarh','short form'),
    ('Balrampur','Balrampur-Ramanujganj','short form'),
    ('Gariaband','Gariyaband','spelling'),
    ('Rajnandgaon City','Rajnandgaon','city'),
    ('Korba City','Korba','city'),
    ('Raigarh City','Raigarh','city')) a(k, official, why)
  join public.geo_district d on d.state_lgd = 22 and d.name = a.official
on conflict (alias_key, state_lgd) do update set district_lgd = excluded.district_lgd, note = excluded.note;

-- The official state for anything a person, a file or Google wrote.
create or replace function public.geo_state_pick(p text)
 returns public.geo_state language sql stable set search_path to 'public'
as $$
  select s.* from public.geo_state s
   where public.geo_key(s.name) = public.geo_key(p)
      or public.geo_key(s.name) = public.geo_key(regexp_replace(coalesce(p,''), '^(the|state of)\s+', '', 'i'))
  union all
  select s.* from public.geo_place_alias a join public.geo_state s on s.lgd_code = a.state_lgd
   where a.district_lgd is null and a.alias_key = public.geo_key(p)
  limit 1
$$;

-- CMD #2135 — THE matcher. Official district for (state, text), or matched=false.
-- Order: exact official name → alias → first word of a hyphenated official
-- name ("Balodabazar" → "Balodabazar-Bhatapara"). Words Google appends
-- ("Raipur Division", "Durg District") are dropped first. With no state it
-- accepts only an answer that is unique across India.
create or replace function public.geo_district_pick(p_state text, p_text text)
 returns jsonb language plpgsql stable set search_path to 'public'
as $$
declare
  v_st public.geo_state; v_key text; v_d public.geo_district; v_n int;
begin
  v_st := public.geo_state_pick(p_state);
  v_key := public.geo_key(regexp_replace(coalesce(p_text,''),
             '\s*(district|division|dist\.?|zila|jila|tehsil)\s*$', '', 'i'));
  if v_key is null then
    return jsonb_build_object('matched', false, 'state', v_st.name, 'state_lgd', v_st.lgd_code);
  end if;

  select d.* into v_d from public.geo_district d
   where public.geo_key(d.name) = v_key
     and (v_st.lgd_code is null or d.state_lgd = v_st.lgd_code)
   order by d.lgd_code limit 1;
  if v_d.lgd_code is null then
    select d.* into v_d from public.geo_place_alias a join public.geo_district d on d.lgd_code = a.district_lgd
     where a.alias_key = v_key and (v_st.lgd_code is null or a.state_lgd = v_st.lgd_code)
     limit 1;
  end if;
  if v_d.lgd_code is null then
    select d.* into v_d from public.geo_district d
     where public.geo_key(split_part(d.name, '-', 1)) = v_key
       and (v_st.lgd_code is null or d.state_lgd = v_st.lgd_code)
     order by d.lgd_code limit 1;
  end if;
  -- Without a state the same word can be two districts (Bilaspur is in CG
  -- AND Himachal): only a unique answer counts.
  if v_d.lgd_code is not null and v_st.lgd_code is null then
    select count(*) into v_n from public.geo_district d where public.geo_key(d.name) = public.geo_key(v_d.name);
    if v_n > 1 then v_d := null; end if;
  end if;
  if v_d.lgd_code is null then
    return jsonb_build_object('matched', false, 'state', v_st.name, 'state_lgd', v_st.lgd_code);
  end if;
  if v_st.lgd_code is null then
    select * into v_st from public.geo_state where lgd_code = v_d.state_lgd;
  end if;
  return jsonb_build_object('matched', true, 'district', v_d.name, 'district_lgd', v_d.lgd_code,
                            'state', v_st.name, 'state_lgd', v_st.lgd_code);
end $$;

-- norm_district keeps its signature (zone lookups and old imports call it) but
-- now answers with the official name whenever the list knows the place.
create or replace function public.norm_district(p text)
 returns text language sql stable set search_path to 'public'
as $$
  select case
    when p is null or btrim(p) = '' then null
    when lower(btrim(p)) like 'test%' then null   -- test fixtures are not a real district
    else coalesce(public.geo_district_pick(null, p)->>'district',
                  public.geo_district_pick('Chhattisgarh', p)->>'district',
                  initcap(btrim(p)))
  end
$$;

-- Normalise what is already stored. Only a CONFIDENT match rewrites a name;
-- anything the list does not know is left exactly as it was (the Location
-- step flags it "Pick district"). session_replication_role=replica keeps the
-- stage-sync trigger from re-deriving registration stages on a spelling fix.
do $$
declare r record; v jsonb; v_n int := 0;
begin
  set local session_replication_role = replica;
  for r in select id, state, district, city from public.pharmacy_profiles
            where coalesce(district,'') <> '' or coalesce(city,'') <> '' loop
    v := public.geo_district_pick(coalesce(nullif(r.state,''), 'Chhattisgarh'), coalesce(nullif(r.district,''), r.city));
    if coalesce((v->>'matched')::boolean,false)
       and (r.district is distinct from v->>'district' or r.state is distinct from v->>'state') then
      update public.pharmacy_profiles set district = v->>'district', state = v->>'state' where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  raise notice 'cmd2135: normalised % pharmacy profile(s)', v_n;

  update public.scraped_leads l
     set district = p.d, state = p.s
    from (select id, (public.geo_district_pick(coalesce(nullif(state,''),'Chhattisgarh'), district)) j
            from public.scraped_leads where coalesce(district,'') <> '') x
    cross join lateral (select x.j->>'district' d, x.j->>'state' s) p
   where l.id = x.id and coalesce((x.j->>'matched')::boolean,false)
     and (l.district is distinct from p.d or l.state is distinct from p.s);

  update public.geo_pincode g
     set district = x.j->>'district'
    from (select pincode, public.geo_district_pick(coalesce(nullif(state,''),'Chhattisgarh'), district) j
            from public.geo_pincode where coalesce(district,'') <> '') x
   where g.pincode = x.pincode and coalesce((x.j->>'matched')::boolean,false)
     and g.district is distinct from x.j->>'district';
end $$;

-- Zone = district. The two live zones are keyed by their district (norm_place
-- form, as zone_for_district reads it); Uslapur stays as the city fallback
-- zone_resolve already walks to.
insert into public.zone_districts(zone_id, district)
select z.id, public.norm_place(d) from (values (1::smallint,'Raipur'),(2::smallint,'Bilaspur')) v(zid, d)
  join public.zones z on z.id = v.zid
on conflict do nothing;

-- ───────────────────────────────────────────────────────────── 2 · GOOGLE ──
-- The capability geo-reverse-google checks: only a service-role credential
-- can run this, whichever of the project's two service-role keys it is.
create or replace function public.geo_proxy_ok()
 returns boolean language sql stable as $$ select true $$;
revoke all on function public.geo_proxy_ok() from public, anon, authenticated;
grant execute on function public.geo_proxy_ok() to service_role;

insert into public.app_settings(key, value) values
  ('geo.reverse_provider', '"google_edge"'::jsonb),
  ('geo.reverse_edge_url', '"https://swojhmarmaijkshsbeih.supabase.co/functions/v1/geo-reverse-google"'::jsonb)
on conflict (key) do update set value = excluded.value;

-- Google's components → our fields. district = level 2 (a DIVISION in India),
-- district_alt = level 3 (the district); geo_reverse keeps whichever the
-- official list recognises, level 3 first.
create or replace function public.geo_reverse_parse(p_provider text, p_body jsonb)
 returns jsonb language plpgsql immutable set search_path to 'public'
as $function$
declare
  v_a jsonb; v_c jsonb;
  v_addr text; v_land text; v_city text; v_state text; v_pin text; v_dist text; v_dist3 text;
  v_house text; v_road text; v_prem text; v_sub2 text;
begin
  if p_body is null or jsonb_typeof(p_body) <> 'object' then return '{}'::jsonb; end if;

  if p_provider = 'google' then
    v_c := p_body->'results'->0->'address_components';
    if v_c is null then return '{}'::jsonb; end if;
    select max(case when c->'types' ? 'street_number' then c->>'long_name' end),
           max(case when c->'types' ? 'premise' or c->'types' ? 'subpremise'
                     or c->'types' ? 'establishment' then c->>'long_name' end),
           max(case when c->'types' ? 'route' then c->>'long_name' end),
           coalesce(max(case when c->'types' ? 'sublocality_level_1' then c->>'long_name' end),
                    max(case when c->'types' ? 'neighborhood' then c->>'long_name' end)),
           max(case when c->'types' ? 'sublocality_level_2' then c->>'long_name' end),
           max(case when c->'types' ? 'locality' or c->'types' ? 'postal_town'
                    then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_1' then c->>'long_name' end),
           max(case when c->'types' ? 'postal_code' then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_2' then c->>'long_name' end),
           max(case when c->'types' ? 'administrative_area_level_3' then c->>'long_name' end)
      into v_house, v_prem, v_road, v_land, v_sub2, v_city, v_state, v_pin, v_dist, v_dist3
      from jsonb_array_elements(v_c) c;
    v_addr := nullif(btrim(concat_ws(', ', v_prem, v_house, v_road, v_sub2)), '');
    if v_addr is null then
      -- formatted_address without its trailing city/state/pincode/country
      v_addr := nullif(btrim(split_part(coalesce(p_body->'results'->0->>'formatted_address',''),
                                        ', ' || coalesce(v_city, '~'), 1)), '');
    end if;
  else
    v_a := p_body->'address';
    if v_a is null then return '{}'::jsonb; end if;
    v_house := nullif(btrim(coalesce(v_a->>'house_number','')),'');
    v_road  := coalesce(nullif(btrim(coalesce(v_a->>'road','')),''),
                        nullif(btrim(coalesce(v_a->>'pedestrian','')),''),
                        nullif(btrim(coalesce(v_a->>'residential','')),''));
    v_land  := coalesce(nullif(btrim(coalesce(v_a->>'neighbourhood','')),''),
                        nullif(btrim(coalesce(v_a->>'suburb','')),''),
                        nullif(btrim(coalesce(v_a->>'quarter','')),''),
                        nullif(btrim(coalesce(v_a->>'village','')),''));
    v_city  := coalesce(nullif(btrim(coalesce(v_a->>'city','')),''),
                        nullif(btrim(coalesce(v_a->>'town','')),''),
                        nullif(btrim(coalesce(v_a->>'municipality','')),''),
                        nullif(btrim(coalesce(v_a->>'village','')),''));
    v_state := nullif(btrim(coalesce(v_a->>'state','')),'');
    v_pin   := nullif(btrim(coalesce(v_a->>'postcode','')),'');
    v_dist  := coalesce(nullif(btrim(coalesce(v_a->>'state_district','')),''),
                        nullif(btrim(coalesce(v_a->>'county','')),''));
    v_addr := nullif(btrim(concat_ws(', ', v_house, v_road)), '');
    if v_addr is null then
      v_addr := nullif(btrim(coalesce(p_body->>'display_name','')), '');
    end if;
  end if;

  return jsonb_strip_nulls(jsonb_build_object(
    'address',      v_addr,
    'landmark',     v_land,
    'city',         v_city,
    'state',        v_state,
    'pincode',      nullif(regexp_replace(coalesce(v_pin,''), '[^0-9]', '', 'g'), ''),
    'district',     v_dist,
    'district_alt', v_dist3));
end $function$;

-- Reverse geocode: Google through the edge function (server key). Nominatim
-- is only reachable when geo.reverse_provider is set back to 'nominatim'.
-- Every answer leaves here with state/district already OFFICIAL (or district
-- blank + district_matched=false, which the Location step flags).
create or replace function public.geo_reverse(p_lat numeric, p_lng numeric)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_lat numeric(9,4) := round(p_lat, 4);
  v_lng numeric(9,4) := round(p_lng, 4);
  v_days int := coalesce((select (value #>> '{}')::int from app_settings where key='geo.reverse_cache_days'), 180);
  v_wait int := coalesce((select (value #>> '{}')::int from app_settings where key='geo.reverse_wait_ms'), 6000);
  v_on   boolean := coalesce((select (value)::boolean from app_settings where key='geo.geocode_enabled'), true);
  v_mode text := coalesce((select value #>> '{}' from app_settings where key='geo.reverse_provider'), 'google_edge');
  v_gkey text := nullif(btrim(coalesce((select value #>> '{}' from app_settings where key='geo.reverse_google_key'),'')),'');
  v_prov text; v_url text; v_body jsonb; v_out jsonb := '{}'::jsonb;
  v_status int; v_pc_district text; v_pc_state text; v_hdr extensions.http_header[];
  v_pick jsonb; v_cand text;
begin
  if p_lat is null or p_lng is null
     or p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 then
    return jsonb_build_object('ok', false, 'source', 'invalid');
  end if;
  v_prov := case when v_mode = 'nominatim' then 'nominatim' else 'google' end;

  -- A cached answer counts only if it came from the provider in use now: an
  -- old Nominatim read must not keep answering after the switch to Google.
  select result into v_out
    from geo_reverse_cache
   where lat_key = v_lat and lng_key = v_lng and provider = v_prov
     and fetched_at > now() - make_interval(days => v_days);
  if v_out is not null and v_out <> '{}'::jsonb and v_out ? 'district_matched' then
    return v_out || jsonb_build_object('ok', true, 'source', 'cache', 'provider', v_prov);
  end if;
  v_out := '{}'::jsonb;

  if v_on then
    v_hdr := array[extensions.http_header('User-Agent', 'mediBO/1.0 (medibo.in)'),
                   extensions.http_header('Accept', 'application/json')];
    if v_mode = 'google_edge' then
      v_url := coalesce((select value #>> '{}' from app_settings where key='geo.reverse_edge_url'), '')
            || '?lat=' || v_lat::text || '&lng=' || v_lng::text;
      v_hdr := v_hdr || extensions.http_header('Authorization', 'Bearer ' || coalesce(public._service_key(), ''));
    elsif v_mode = 'google' and v_gkey is not null then
      v_url := coalesce((select value #>> '{}' from app_settings where key='geo.reverse_google_url'),
                        'https://maps.googleapis.com/maps/api/geocode/json')
            || '?latlng=' || v_lat::text || ',' || v_lng::text || '&region=in&key=' || v_gkey;
    elsif v_mode = 'nominatim' then
      v_url := coalesce((select value #>> '{}' from app_settings where key='geo.reverse_endpoint'),
                        'https://nominatim.openstreetmap.org/reverse')
            || '?format=jsonv2&addressdetails=1&zoom=18&lat=' || v_lat::text || '&lon=' || v_lng::text;
    end if;

    if v_url is not null and v_url <> '' then
      -- pgsql-http, not pg_net: pg_net only dispatches after commit, so this
      -- RPC could never read its own answer. Bounded; every failure leaves the
      -- shop typing instead of breaking the step.
      begin
        perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', least(v_wait, 8000)::text);
        select r.status,
               case when r.content is null then null else nullif(btrim(r.content), '')::jsonb end
          into v_status, v_body
          from extensions.http(('GET', v_url, v_hdr, null, null)::extensions.http_request) r;
      exception when others then
        v_status := null; v_body := null;
      end;
      if v_status = 200 and v_body is not null then
        v_out := public.geo_reverse_parse(v_prov, v_body);
      end if;
    end if;
  end if;

  -- A "state" the official list does not know (Google has put a district
  -- there) is dropped, so the pincode or the district supplies the real one.
  if coalesce(v_out->>'state','') <> '' and (public.geo_state_pick(v_out->>'state')).lgd_code is null then
    v_out := v_out - 'state';
  end if;

  -- The pincode table fills what the provider left blank.
  if coalesce(v_out->>'pincode','') <> '' then
    select pc.district, pc.state into v_pc_district, v_pc_state
      from public.geo_pincode pc where pc.pincode = (v_out->>'pincode');
    if v_pc_district is not null or v_pc_state is not null then
      v_out := jsonb_strip_nulls(v_out || jsonb_build_object(
                 'city',     coalesce(nullif(v_out->>'city',''),  v_pc_district),
                 'state',    coalesce(nullif(v_out->>'state',''), v_pc_state),
                 'district_pin', v_pc_district));
    end if;
  end if;

  if v_out <> '{}'::jsonb then
    -- Official names: the first candidate the list recognises wins.
    v_pick := null;
    -- Google's level 2 in India is the DIVISION ("Durg Division" spans five
    -- districts); level 3 is the district. So level 3 first, then the
    -- pincode's district, and the division/city only as a last resort.
    foreach v_cand in array array[v_out->>'district_alt', v_out->>'district_pin',
                                  v_out->>'city', v_out->>'district'] loop
      continue when coalesce(btrim(v_cand),'') = '';
      v_pick := public.geo_district_pick(v_out->>'state', v_cand);
      exit when coalesce((v_pick->>'matched')::boolean, false);
    end loop;
    if coalesce((v_pick->>'matched')::boolean, false) then
      v_out := v_out || jsonb_build_object('district', v_pick->>'district',
                                           'state', v_pick->>'state', 'district_matched', true);
    else
      v_out := (v_out - 'district') || jsonb_strip_nulls(jsonb_build_object(
                 'state', coalesce((public.geo_state_pick(v_out->>'state')).name, v_out->>'state'),
                 'district_matched', false));
    end if;
    v_out := v_out - 'district_alt' - 'district_pin';

    insert into geo_reverse_cache(lat_key, lng_key, result, provider)
    values (v_lat, v_lng, v_out, v_prov)
    on conflict (lat_key, lng_key)
      do update set result = excluded.result, provider = excluded.provider, fetched_at = now();
    return v_out || jsonb_build_object('ok', true, 'source', 'lookup', 'provider', v_prov);
  end if;

  return jsonb_build_object('ok', false, 'source', 'none', 'provider', v_prov);
end $function$;

-- ─────────────────────────────────────────────────────────── 3 · LOCATION ──
insert into public.ui_copy(key, value) values
  ('custreg.v3_filled_note',     to_jsonb('✓ Address filled from your location — change anything below'::text)),
  ('custreg.v3_f_address',       to_jsonb('Shop address'::text)),
  ('custreg.v3_f_landmark',      to_jsonb('Area / landmark'::text)),
  ('custreg.v3_f_city',          to_jsonb('City'::text)),
  ('custreg.v3_f_pincode',       to_jsonb('Pincode'::text)),
  ('custreg.v3_f_state',         to_jsonb('State'::text)),
  ('custreg.v3_f_district',      to_jsonb('District'::text)),
  ('custreg.v3_pick_state',      to_jsonb('Pick state'::text)),
  ('custreg.v3_pick_district',   to_jsonb('Pick district'::text)),
  ('custreg.v3_district_flag',   to_jsonb('Pick district'::text)),
  ('custreg.v3_district_flag_line', to_jsonb('"{typed}" is not on the official list — pick your district'::text)),
  ('custreg.v3_state_title',     to_jsonb('State'::text)),
  ('custreg.v3_state_sub',       to_jsonb('{n} states and union territories'::text)),
  ('custreg.v3_state_search',    to_jsonb('Search state'::text)),
  ('custreg.v3_district_title',  to_jsonb('District'::text)),
  ('custreg.v3_district_sub',    to_jsonb('{state} · {n} districts'::text)),
  ('custreg.v3_district_search', to_jsonb('Search district'::text)),
  ('custreg.v3_district_nostate',to_jsonb('Pick your state first'::text)),
  ('custreg.v3_list_empty',      to_jsonb('Nothing matches that — check the spelling'::text)),
  ('custreg.v3_loc_ask',         to_jsonb('Allow location so the pin jumps to your shop'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- District is a signup field of its own now (the admin form keeps its own).
insert into public.customer_form_field(key, section_key, label, field_type, required, sort_order,
                                       half_width, contexts, is_active)
values ('district', 'address', 'District', 'text', true, 112, true, array['signup'], true)
on conflict (key) do update set section_key = excluded.section_key, label = excluded.label,
  required = excluded.required, contexts = excluded.contexts, is_active = true;

-- The form under the map: labels, values, the two pickers and the flag. The
-- step draws it and composes nothing.
create or replace function public.custreg_location_form(p_values jsonb)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v jsonb := coalesce(p_values, '{}'::jsonb);
  v_state text := nullif(btrim(coalesce(v->>'state','')), '');
  v_dist  text := nullif(btrim(coalesce(v->>'district','')), '');
  v_ok boolean := false;
  v_pick jsonb;
begin
  -- An imported or typed spelling the list knows (Raypur) is shown official.
  if v_dist is not null then
    v_pick := public.geo_district_pick(v_state, v_dist);
    if coalesce((v_pick->>'matched')::boolean, false) then
      v_dist := v_pick->>'district'; v_state := v_pick->>'state';
    end if;
  end if;
  if v_dist is not null then
    v_ok := exists (select 1 from public.geo_district d join public.geo_state s on s.lgd_code = d.state_lgd
                     where d.name = v_dist and (v_state is null or s.name = v_state));
  end if;
  return jsonb_build_object(
    'filled_note', case when nullif(btrim(coalesce(v->>'address','')),'') is not null
                         and coalesce(v->>'_geo_source','') <> 'edit'
                        then public._c('custreg.v3_filled_note') else '' end,
    'fields', jsonb_build_array(
      jsonb_build_object('key','address',  'label', public._c('custreg.v3_f_address'),
                         'value', coalesce(v->>'address',''),  'half', false, 'numeric', false),
      jsonb_build_object('key','landmark', 'label', public._c('custreg.v3_f_landmark'),
                         'value', coalesce(v->>'landmark',''), 'half', false, 'numeric', false),
      jsonb_build_object('key','city',     'label', public._c('custreg.v3_f_city'),
                         'value', coalesce(v->>'city',''),     'half', true,  'numeric', false),
      jsonb_build_object('key','pincode',  'label', public._c('custreg.v3_f_pincode'),
                         'value', coalesce(v->>'pincode',''),  'half', true,  'numeric', true)),
    'state', jsonb_build_object('key','state', 'label', public._c('custreg.v3_f_state'),
                         'value', coalesce(v_state,''), 'placeholder', public._c('custreg.v3_pick_state')),
    'district', jsonb_build_object('key','district', 'label', public._c('custreg.v3_f_district'),
                         'value', case when v_ok then v_dist else '' end,
                         'placeholder', public._c('custreg.v3_pick_district'),
                         'flagged', (v_dist is not null and not v_ok),
                         'flag_label', case when v_dist is not null and not v_ok
                                            then public._c('custreg.v3_district_flag') else '' end,
                         'flag_line', case when v_dist is not null and not v_ok
                                           then public._cf('custreg.v3_district_flag_line',
                                                  jsonb_build_object('typed', v_dist)) else '' end),
    'ask_line', public._c('custreg.v3_loc_ask'));
end $$;

-- The two picker sheets. Official names, official order (alphabetical).
create or replace function public.geo_state_options()
 returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select jsonb_build_object(
    'title',       public._c('custreg.v3_state_title'),
    'subtitle',    public._cf('custreg.v3_state_sub', jsonb_build_object('n', count(*))),
    'search_hint', public._c('custreg.v3_state_search'),
    'empty_label', public._c('custreg.v3_list_empty'),
    'rows',        coalesce(jsonb_agg(jsonb_build_object('name', s.name) order by s.name), '[]'::jsonb))
  from public.geo_state s
$$;

create or replace function public.geo_district_options(p_state text)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare v_st public.geo_state; v_rows jsonb; v_n int;
begin
  v_st := public.geo_state_pick(p_state);
  if v_st.lgd_code is null then
    return jsonb_build_object('title', public._c('custreg.v3_district_title'),
      'subtitle', public._c('custreg.v3_district_nostate'),
      'search_hint', public._c('custreg.v3_district_search'),
      'empty_label', public._c('custreg.v3_district_nostate'), 'rows', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('name', d.name) order by d.name), '[]'::jsonb), count(*)
    into v_rows, v_n from public.geo_district d where d.state_lgd = v_st.lgd_code;
  return jsonb_build_object(
    'title',       public._c('custreg.v3_district_title'),
    'subtitle',    public._cf('custreg.v3_district_sub', jsonb_build_object('state', v_st.name, 'n', v_n)),
    'search_hint', public._c('custreg.v3_district_search'),
    'empty_label', public._c('custreg.v3_list_empty'),
    'rows',        v_rows);
end $$;
grant execute on function public.geo_state_options() to authenticated;
grant execute on function public.geo_district_options(text) to authenticated;

-- Resolve: the pin (or an edit) → values + the form. Now every state/district
-- leaving here is the official name when the list knows it.
create or replace function public.custreg_location_resolve(p_lat numeric default null, p_lng numeric default null,
                                                           p_values jsonb default '{}'::jsonb, p_geocode boolean default true)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_vals jsonb := coalesce(p_values, '{}'::jsonb);
  v_geo  jsonb := '{}'::jsonb;
  v_tmpl text; v_note text := ''; v_tone text := 'neutral'; v_pick jsonb; v_st public.geo_state;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;
  if not public._custreg_coord_ok('latitude',  p_lat::text)
     or not public._custreg_coord_ok('longitude', p_lng::text) then
    return jsonb_build_object('ok', false, 'error', 'invalid_point', 'tone', 'warning',
                              'message', public._c('custreg.loc_invalid_point'));
  end if;

  if p_lat is not null and p_lng is not null then
    v_vals := v_vals || jsonb_build_object('latitude',  round(p_lat, 6)::text,
                                           'longitude', round(p_lng, 6)::text);
    select nullif(btrim(coalesce(point_deeplink,'')),'') into v_tmpl from public.map_config order by id limit 1;
    if nullif(btrim(coalesce(v_tmpl,'')),'') is not null then
      v_vals := v_vals || jsonb_build_object('store_location_link',
                  replace(replace(v_tmpl, '{lat}', round(p_lat,6)::text), '{lng}', round(p_lng,6)::text));
    end if;

    if coalesce(p_geocode, true) then
      begin v_geo := public.geo_reverse(p_lat, p_lng);
      exception when others then v_geo := jsonb_build_object('ok', false); end;
      if coalesce((v_geo->>'ok')::boolean, false) then
        -- The pin is the answer: what it reads REPLACES what was there.
        -- An unmatched district clears the old one, so the picker asks.
        v_vals := (v_vals - 'district') || jsonb_strip_nulls(jsonb_build_object(
          'address',  nullif(btrim(coalesce(v_geo->>'address','')), ''),
          'landmark', nullif(btrim(coalesce(v_geo->>'landmark','')), ''),
          'city',     nullif(btrim(coalesce(v_geo->>'city','')), ''),
          'state',    nullif(btrim(coalesce(v_geo->>'state','')), ''),
          'district', nullif(btrim(coalesce(v_geo->>'district','')), ''),
          'pincode',  nullif(btrim(coalesce(v_geo->>'pincode','')), '')))
          || jsonb_build_object('_geo_source', 'pin');
        v_note := public._c('custreg.loc_read_ok');
        v_tone := 'success';
      else
        v_note := public._c('custreg.loc_read_failed');
        v_tone := 'warning';
      end if;
    end if;
  end if;

  -- Official spellings for whatever was typed, imported or picked.
  if nullif(btrim(coalesce(v_vals->>'state','')),'') is not null then
    v_st := public.geo_state_pick(v_vals->>'state');
    if v_st.lgd_code is not null then v_vals := v_vals || jsonb_build_object('state', v_st.name); end if;
  end if;
  if nullif(btrim(coalesce(v_vals->>'district','')),'') is not null then
    v_pick := public.geo_district_pick(v_vals->>'state', v_vals->>'district');
    if coalesce((v_pick->>'matched')::boolean, false) then
      v_vals := v_vals || jsonb_build_object('district', v_pick->>'district', 'state', v_pick->>'state');
    end if;
  end if;
  if not coalesce(p_geocode, true) then
    v_vals := v_vals || jsonb_build_object('_geo_source', 'edit');
  end if;

  return jsonb_build_object(
    'ok',     true,
    'values', v_vals - '_geo_source',
    'card',   public.custreg_location_card(v_vals),
    'form',   public.custreg_location_form(v_vals),
    'note',   v_note,
    'tone',   v_tone,
    'source', coalesce(v_geo->>'source', 'edit'));
end $function$;

-- ────────────────────────────────────────────────────────── 4 · DOCUMENTS ──
alter table public.kyc_documents add column if not exists read_fields jsonb;
alter table public.kyc_documents add column if not exists read_state  text;   -- read | unreadable | checked

-- What is read off each paper, in what order, under which label, and which
-- profile column it also fills. A new paper type is INSERTs, not a deploy.
create table if not exists public.custdoc_read_field (
  kind           text not null,
  field          text not null,          -- number | valid_to | name
  label_key      text not null,
  sort_order     int  not null default 10,
  profile_column text,
  primary key (kind, field)
);
alter table public.custdoc_read_field enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='custdoc_read_field' and policyname='custdoc_read_field_read') then
    create policy custdoc_read_field_read on public.custdoc_read_field for select using (true);
  end if;
end $$;
insert into public.custdoc_read_field(kind, field, label_key, sort_order, profile_column) values
  ('dl_20b','number',  'custreg.v3_rf_licence_no', 10, 'dl_20b'),
  ('dl_20b','valid_to','custreg.v3_rf_valid_till', 20, 'dl_expiry'),
  ('dl_20b','name',    'custreg.v3_rf_name_licence', 30, null),
  ('dl_21b','number',  'custreg.v3_rf_licence_no', 10, 'dl_21b'),
  ('dl_21b','valid_to','custreg.v3_rf_valid_till', 20, 'dl_expiry'),
  ('dl_21b','name',    'custreg.v3_rf_name_licence', 30, null),
  ('gst',   'number',  'custreg.v3_rf_gstin',      10, 'gstin'),
  ('gst',   'name',    'custreg.v3_rf_legal_name', 20, null),
  ('pan',   'number',  'custreg.v3_rf_pan',        10, null),
  ('pan',   'name',    'custreg.v3_rf_name_card',  20, null),
  ('fssai', 'number',  'custreg.v3_rf_licence_no', 10, null),
  ('fssai', 'valid_to','custreg.v3_rf_valid_till', 20, null),
  ('fssai', 'name',    'custreg.v3_rf_name_licence', 30, null),
  ('*',     'number',  'custreg.v3_rf_number',     10, null),
  ('*',     'valid_to','custreg.v3_rf_valid_till', 20, null),
  ('*',     'name',    'custreg.v3_rf_name',       30, null)
on conflict (kind, field) do update set label_key = excluded.label_key,
  sort_order = excluded.sort_order, profile_column = excluded.profile_column;

insert into public.ui_copy(key, value) values
  ('custreg.v3_reading',        to_jsonb('Reading the number…'::text)),
  ('custreg.v3_saved_note',     to_jsonb('✓ Saved — your uploads stay here if you leave and come back.'::text)),
  ('custreg.v3_upload_failed',  to_jsonb('That upload did not go through. Try again.'::text)),
  ('custreg.v3_valid_till',     to_jsonb('Valid till {date}'::text)),
  ('custreg.v3_uploaded',       to_jsonb('✓ Uploaded'::text)),
  ('custreg.v3_unreadable',     to_jsonb('Couldn''t read — tap to type'::text)),
  ('custreg.v3_act_edit',       to_jsonb('Edit'::text)),
  ('custreg.v3_act_type',       to_jsonb('Type'::text)),
  ('custreg.v3_act_view',       to_jsonb('View'::text)),
  ('custreg.v3_act_retake',     to_jsonb('Retake'::text)),
  ('custreg.v3_edit_line_read', to_jsonb('Read from your photo · tap the photo to zoom'::text)),
  ('custreg.v3_edit_line_type', to_jsonb('We couldn''t read it — type what is printed · tap the photo to zoom'::text)),
  ('custreg.v3_read_tick',      to_jsonb('Read ✓'::text)),
  ('custreg.v3_edit_retake',    to_jsonb('Retake photo'::text)),
  ('custreg.v3_edit_confirm',   to_jsonb('Looks right'::text)),
  ('custreg.v3_edit_saved',     to_jsonb('Saved.'::text)),
  ('custreg.v3_bad_date',       to_jsonb('Valid till should look like 31 Mar 2029'::text)),
  ('custreg.v3_rf_licence_no',  to_jsonb('Licence number'::text)),
  ('custreg.v3_rf_valid_till',  to_jsonb('Valid till'::text)),
  ('custreg.v3_rf_name_licence',to_jsonb('Name on licence'::text)),
  ('custreg.v3_rf_gstin',       to_jsonb('GSTIN'::text)),
  ('custreg.v3_rf_legal_name',  to_jsonb('Legal name'::text)),
  ('custreg.v3_rf_pan',         to_jsonb('PAN'::text)),
  ('custreg.v3_rf_name_card',   to_jsonb('Name on card'::text)),
  ('custreg.v3_rf_number',      to_jsonb('Number'::text)),
  ('custreg.v3_rf_name',        to_jsonb('Name'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function public._custreg_read_fields(p_kind text)
 returns table(field text, label text, sort_order int, profile_column text)
 language sql stable set search_path to 'public'
as $$
  select f.field, public._c(f.label_key), f.sort_order, f.profile_column
    from public.custdoc_read_field f
   where f.kind = case when exists (select 1 from public.custdoc_read_field x where x.kind = p_kind)
                       then p_kind else '*' end
   order by f.sort_order
$$;

-- One document row's v3 face: the number on the row, "Valid till …", the
-- line under the name, the trailing action and the Edit sheet.
create or replace function public._custreg_doc_row_v3(
  p_kind text, p_label text, p_ocr_field text, p_state text, p_has_file boolean,
  p_number text, p_valid_to date, p_read_state text, p_read jsonb, p_reason text)
 returns jsonb language plpgsql stable set search_path to 'public'
as $$
declare
  v_reads boolean := coalesce(p_ocr_field,'') <> '';
  v_num text := case when p_has_file then coalesce(nullif(btrim(coalesce(p_number,'')),''),'') else '' end;
  v_line text := ''; v_tone text := 'neutral'; v_act text; v_act_label text := '';
  v_fields jsonb;
begin
  if p_state = 'rejected' then
    v_act := 'retake'; v_act_label := public._c('custreg.v3_act_retake');
  elsif p_state = 'uploaded' and not v_reads then
    v_line := public._c('custreg.v3_uploaded'); v_tone := 'success';
    v_act := 'view'; v_act_label := public._c('custreg.v3_act_view');
  elsif p_state = 'uploaded' and v_num = '' then
    v_line := public._c('custreg.v3_unreadable'); v_tone := 'warning';
    v_act := 'type'; v_act_label := public._c('custreg.v3_act_type');
  elsif p_state = 'uploaded' then
    v_act := 'edit'; v_act_label := public._c('custreg.v3_act_edit');
  else
    v_act := 'upload';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   f.field,
           'label', f.label,
           'date',  f.field = 'valid_to',
           'value', case f.field
                      when 'number'   then v_num
                      when 'valid_to' then coalesce(to_char(p_valid_to, 'DD Mon YYYY'), '')
                      else coalesce(p_read->>f.field, '') end,
           'read',  coalesce(p_read_state,'') = 'read' and (case f.field
                      when 'number'   then v_num <> ''
                      when 'valid_to' then p_valid_to is not null
                      else coalesce(p_read->>f.field,'') <> '' end),
           'read_label', public._c('custreg.v3_read_tick')) order by f.sort_order), '[]'::jsonb)
    into v_fields from public._custreg_read_fields(p_kind) f;

  return jsonb_build_object(
    'reads',      v_reads,
    'number',     v_num,
    'valid_line', case when p_has_file and p_valid_to is not null
                       then public._cf('custreg.v3_valid_till',
                              jsonb_build_object('date', to_char(p_valid_to, 'DD Mon YYYY')))
                       else '' end,
    'line',       v_line,
    'line_tone',  v_tone,
    'act',        jsonb_build_object('kind', v_act, 'label', v_act_label),
    'edit',       case when v_reads and p_has_file then jsonb_build_object(
                    'title',         p_label,
                    'line',          case when v_num = '' then public._c('custreg.v3_edit_line_type')
                                          else public._c('custreg.v3_edit_line_read') end,
                    'fields',        v_fields,
                    'retake_label',  public._c('custreg.v3_edit_retake'),
                    'confirm_label', public._c('custreg.v3_edit_confirm'))
                  else null end);
end $$;
create or replace function public.custreg_licences_block(p_zone smallint DEFAULT NULL::smallint, p_owner_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rows jsonb := '[]'::jsonb;
  v_req_total int := 0;
  v_req_done  int := 0;
  v_opts jsonb := public.custreg_lic_options();
  v_tick text := public._c('custreg.lic_tick');
  v_sep  text := public._c('custreg.lic_sep');
begin
  with types as (
    select l.key, l.label, coalesce(l.hint,'') as hint, l.mode, l.sort_order,
           coalesce(l.camera_only,false) as camera_only, coalesce(l.ocr_field,'') as ocr_field
      from public.custdoc_list(p_zone) l
     where coalesce(l.mode,'off') <> 'off'
  ), latest as (
    select distinct on (d.kind) d.*
      from public.kyc_documents d
     where p_owner_id is not null
       and d.owner_kind = 'pharmacy' and d.owner_id = p_owner_id
     order by d.kind, d.created_at desc
  ), joined as (
    select t.*,
           d.id as doc_id,
           coalesce(d.path,'') as path,
           coalesce(d.bucket,'kyc-docs') as bucket,
           coalesce(d.file_name,'') as file_name,
           coalesce(d.mime_type,'') as mime,
           coalesce(d.number,'') as number,
           coalesce(d.pages, 0) as pages,
           d.valid_to,
           coalesce(d.read_state,'') as read_state,
           coalesce(d.read_fields,'{}'::jsonb) as read_fields,
           coalesce(d.reason,'') as reason,
           d.submitted_at,
           coalesce(d.status,'') as status,
           (d.id is not null
            and coalesce(d.status,'') <> 'superseded'
            and nullif(btrim(coalesce(d.path,'')),'') is not null) as has_file,
           (coalesce(d.status,'') = 'not_available') as skipped,
           (coalesce(d.status,'') = 'rejected') as rejected
      from types t
      left join latest d on d.kind = t.key
  ), shaped as (
    select j.sort_order as so, j.mode, j.has_file, j.rejected,
      case when j.rejected then 'rejected'
           when j.has_file then 'uploaded'
           when j.skipped  then 'skipped'
           else 'needed' end as state,
      j.key
      from joined j
  )
  select
    coalesce(jsonb_agg(r order by so), '[]'::jsonb),
    count(*) filter (where mode = 'mandatory')::int,
    count(*) filter (where mode = 'mandatory' and state = 'uploaded')::int
    into v_rows, v_req_total, v_req_done
  from (
    select s.so, s.mode, s.state,
      jsonb_build_object(
        'key',       j.key,
        'label',     j.label,
        'hint',      j.hint,
        'required',  (j.mode = 'mandatory'),
        'ocr_field', j.ocr_field,
        'camera_only', j.camera_only,
        -- Which of the three lists this row belongs to. A rejected paper
        -- leaves its list and joins "Needs your attention" — that move is
        -- decided HERE, never by the screen.
        'group',     case when s.state = 'rejected' then 'attention'
                          when j.mode = 'mandatory' then 'required'
                          else 'optional' end,
        'state',     s.state,
        'status_label',
                     case s.state
                       when 'rejected' then
                         case when nullif(btrim(j.reason),'') is null
                              then public._c('custreg.lic_rejected_plain')
                              else public._cf('custreg.lic_rejected',
                                     jsonb_build_object('reason', j.reason)) end
                       when 'uploaded' then
                         v_tick ||
                         case when nullif(btrim(j.number),'') is not null
                              then public._c('custreg.lic_uploaded') || v_sep || j.number
                              when j.pages > 1
                              then public._cf('custreg.lic_pages',
                                     jsonb_build_object('n', j.pages))
                                   || v_sep || public._c('custreg.lic_tap_view')
                              else public._c('custreg.lic_uploaded') || v_sep
                                   || public._c('custreg.lic_tap_view') end
                       when 'skipped' then public._c('custreg.lic_added_later')
                       else public._c('custreg.lic_needed') end,
        'status_tone',
                     case s.state when 'rejected' then 'danger'
                                  when 'uploaded' then 'success'
                                  when 'skipped'  then 'neutral'
                                  else 'warning' end,
        -- The trailing control. One shape, three readings.
        'action',    jsonb_build_object(
                       'kind', case when s.state = 'rejected' then 'retake'
                                    when s.state = 'uploaded' then 'done'
                                    else 'upload' end,
                       'icon', case when s.state = 'rejected' then 'retry'
                                    when s.state = 'uploaded' then 'check'
                                    else 'upload' end,
                       'tone', case when s.state = 'rejected' then 'danger'
                                    when s.state = 'uploaded' then 'success'
                                    else 'brand' end),
        'can_view',  (s.state in ('uploaded','rejected') and j.has_file),
        'thumb',     jsonb_build_object(
                       'kind', case when not j.has_file then 'none'
                                    when j.mime = 'application/pdf'
                                      or lower(right(j.path, 4)) = '.pdf' then 'pdf'
                                    else 'image' end,
                       'bucket', j.bucket,
                       'path',   case when j.has_file then j.path else '' end,
                       'badge',  public._c('custreg.lic_pdf_badge'),
                       'pages',  j.pages),
        'dont_have', jsonb_build_object(
                       'show',  (s.state in ('needed','skipped','rejected')),
                       'on',    (s.state = 'skipped'),
                       'label', public._c('custreg.lic_dont_have'),
                       'undo_label', public._c('custreg.lic_dont_have_undo')),
        -- The sheet is the ROW's, so its title already names the paper.
        'sheet',     jsonb_build_object(
                       'title',    public._cf('custreg.lic_sheet_title',
                                     jsonb_build_object('doc', j.label)),
                       'subtitle', public._c('custreg.lic_sheet_sub'),
                       'options',  v_opts),
        'viewer',    jsonb_build_object(
                       'title',        j.label,
                       'close_label',  public._c('custreg.lic_view_close'),
                       'retake_label', public._c('custreg.lic_view_retake'),
                       'keep_label',   public._c('custreg.lic_view_keep'),
                       'remove_label', public._c('custreg.lic_view_remove'),
                       'hint',         case when j.submitted_at is null
                                            then public._c('custreg.lic_view_zoom_new')
                                            else public._cf('custreg.lic_view_zoom',
                                                   jsonb_build_object('when',
                                                     to_char(j.submitted_at at time zone 'Asia/Kolkata',
                                                             'DD Mon, HH12:MI am'))) end,
                       'page_label',   public._c('custreg.lic_view_page'))
      ) || public._custreg_doc_row_v3(j.key, j.label, j.ocr_field, s.state, j.has_file,
                                        j.number, j.valid_to, j.read_state, j.read_fields, j.reason) as r
      from shaped s join joined j on j.key = s.key
  ) x;

  return jsonb_build_object(
    'show',      (jsonb_array_length(v_rows) > 0),
    'empty_label', public._c('custreg.lic_empty'),
    'zone_id',   p_zone,
    -- CMD #2135 — v3 rows (number on the row + Edit) and no Scan card: every
    -- upload is read by itself, so a separate scan is one tap too many.
    'layout',        'v3',
    'reading_label', public._c('custreg.v3_reading'),
    'saved_note',    case when exists (select 1 from jsonb_array_elements(v_rows) e
                                        where coalesce((e->>'can_view')::boolean,false))
                          then public._c('custreg.v3_saved_note') else '' end,
    'upload_failed_label', public._c('custreg.v3_upload_failed'),
    'scan',      jsonb_build_object(
                   'show',     false,
                   'title',    public._c('custreg.lic_scan_title'),
                   'subtitle', public._c('custreg.lic_scan_sub'),
                   'reading_label', public._c('custreg.lic_scan_reading'),
                   'none_label',    public._c('custreg.lic_scan_none')),
    'groups',    jsonb_build_array(
      jsonb_build_object(
        'key','attention', 'title', public._c('custreg.lic_group_attention'),
        'counter_label','', 'counter_tone','',
        'rows', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_rows) e
                           where e->>'group' = 'attention'), '[]'::jsonb)),
      jsonb_build_object(
        'key','required', 'title', public._c('custreg.lic_group_required'),
        'counter_label', case when v_req_total > 0
                              then public._cf('custreg.lic_counter',
                                     jsonb_build_object('done', v_req_done, 'total', v_req_total))
                              else '' end,
        'counter_tone',  case when v_req_total > 0 and v_req_done >= v_req_total
                              then 'success' else 'warning' end,
        'rows', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_rows) e
                           where e->>'group' = 'required'), '[]'::jsonb)),
      jsonb_build_object(
        'key','optional', 'title', public._c('custreg.lic_group_optional'),
        'counter_label','', 'counter_tone','',
        'rows', coalesce((select jsonb_agg(e) from jsonb_array_elements(v_rows) e
                           where e->>'group' = 'optional'), '[]'::jsonb))),
    'footnote',  public._c('custreg.lic_footnote'),
    'required_total', v_req_total,
    'required_done',  v_req_done);
end $function$;

create or replace function public._custreg_date(p text)
 returns date language plpgsql immutable
as $$
declare t text := btrim(coalesce(p,''));
begin
  if t = '' then return null; end if;
  begin
    if t ~ '^\d{4}-\d{2}-\d{2}$' then return t::date; end if;
    if t ~ '^\d{1,2}[/.-]\d{1,2}[/.-]\d{4}$' then
      return to_date(regexp_replace(t, '[/.]', '-', 'g'), 'DD-MM-YYYY');
    end if;
    if t ~* '^\d{1,2}[ -][a-z]{3,9}[ -,]*\d{4}$' then
      return to_date(regexp_replace(t, '[-,]+', ' ', 'g'), 'DD Mon YYYY');
    end if;
  exception when others then return null;
  end;
  return null;
end $$;

-- Whose papers these are: the signed-in shop's own row, or — for staff adding
-- a customer — the row they name, when they may write KYC.
create or replace function public._custreg_owner(p_owner uuid)
 returns uuid language plpgsql stable security definer set search_path to 'public'
as $$
declare v_sess jsonb; v_cid uuid;
begin
  if p_owner is not null then
    if exists (select 1 from public.pharmacy_profiles where id = p_owner and user_id = auth.uid())
       or public.kyc_can_review('write') then
      return p_owner;
    end if;
    return null;
  end if;
  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_cid := nullif(v_sess->>'customer_id','')::uuid;
  return v_cid;
end $$;

-- Copy what was read onto the profile's own columns (dl_20b, dl_expiry,
-- gstin …) so everything that already reads them — the order gate, the admin
-- page — sees the paper's numbers. Only non-blank values are written.
create or replace function public._custreg_mirror_read(p_owner uuid, p_kind text)
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare d record; f record; v text; v_sets text[] := '{}';
begin
  select * into d from public.kyc_documents
   where owner_kind = 'pharmacy' and owner_id = p_owner and kind = p_kind
     and coalesce(status,'') not in ('superseded','not_available')
   order by created_at desc limit 1;
  if d.id is null then return; end if;
  for f in select * from public._custreg_read_fields(p_kind) where profile_column is not null loop
    v := case f.field when 'number' then nullif(btrim(coalesce(d.number,'')),'')
                      when 'valid_to' then d.valid_to::text
                      else nullif(btrim(coalesce(d.read_fields->>f.field,'')),'') end;
    continue when v is null;
    if f.field = 'valid_to' then
      v_sets := v_sets || format('%I = %L::date', f.profile_column, v);
    else
      v_sets := v_sets || format('%I = %L', f.profile_column, v);
    end if;
  end loop;
  if array_length(v_sets,1) is not null then
    execute format('update public.pharmacy_profiles set %s, updated_at = now() where id = %L',
                   array_to_string(v_sets, ', '), p_owner);
  end if;
end $$;

-- An upload is saved the moment it lands — and a brand-new signup has no row
-- to hang it on yet. This makes the row early (the same guarded door Submit
-- uses) from what the person has filled so far; the draft remembers it so the
-- form keeps asking until they press Submit.
create or replace function public.custreg_ensure_profile(p_values jsonb default '{}'::jsonb)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_cid uuid := public._custreg_owner(null); v_sub jsonb; v_vals jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error','not_signed_in', 'message', public._c('custreg.err_not_signed_in'));
  end if;
  if v_cid is not null then
    return jsonb_build_object('ok', true, 'customer_id', v_cid, 'created', false);
  end if;
  v_vals := (public.customer_reg_draft_get('signup') - '_step' - '_seen' - '_early')
            || coalesce(p_values, '{}'::jsonb);
  v_sub := public.submit_registration('pharmacy',
             jsonb_strip_nulls(jsonb_build_object(
               'pharmacy_name', nullif(btrim(coalesce(v_vals->>'pharmacy_name','')),''),
               'customer_name', nullif(btrim(coalesce(v_vals->>'customer_name','')),''),
               'whatsapp_no',   nullif(btrim(coalesce(v_vals->>'whatsapp_no','')),''),
               'phone',         nullif(btrim(coalesce(v_vals->>'phone','')),''),
               'email',         nullif(btrim(coalesce(v_vals->>'email','')),''),
               'store_type',    nullif(btrim(coalesce(v_vals->>'store_type','')),''),
               'address',       nullif(btrim(coalesce(v_vals->>'address','')),''),
               'city',          nullif(btrim(coalesce(v_vals->>'city','')),''),
               'district',      nullif(btrim(coalesce(v_vals->>'district','')),''),
               'state',         nullif(btrim(coalesce(v_vals->>'state','')),''),
               'pincode',       nullif(btrim(coalesce(v_vals->>'pincode','')),''))));
  v_cid := nullif(v_sub->>'id','')::uuid;
  if v_cid is null then
    return jsonb_build_object('ok', false, 'error','save_failed', 'message', public._c('custreg.err_save'));
  end if;
  update public.pharmacy_profiles
     set zone_id = coalesce(public.zone_resolve(district, city, false), zone_id)
   where id = v_cid;
  perform public.customer_reg_draft_save(jsonb_build_object('_early', true), 'signup');
  return jsonb_build_object('ok', true, 'customer_id', v_cid, 'created', true);
end $$;
grant execute on function public.custreg_ensure_profile(jsonb) to authenticated;

-- OCR landed (or failed): its fields go onto the row, the row's state says
-- read / unreadable, the profile columns follow. The mapping from the model's
-- output to our three fields is HERE, per paper kind.
create or replace function public.custreg_doc_read_save(p_kind text, p_ocr jsonb, p_owner uuid default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_owner uuid := public._custreg_owner(p_owner); v_o jsonb := coalesce(p_ocr, '{}'::jsonb);
  v_num text; v_valid date; v_name text; v_id uuid; v_zone smallint;
begin
  if v_owner is null then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'message', public._c('custdoc.err_not_authorized'));
  end if;
  v_num := nullif(btrim(coalesce(case p_kind
             when 'dl_20b' then coalesce(nullif(v_o->>'licence_20b',''), v_o->>'licence_number')
             when 'dl_21b' then coalesce(nullif(v_o->>'licence_21b',''), v_o->>'licence_number')
             when 'gst'    then v_o->>'gstin'
             when 'pan'    then v_o->>'pan'
             when 'fssai'  then coalesce(nullif(v_o->>'fssai',''), v_o->>'licence_number')
             else coalesce(nullif(v_o->>'document_number',''), nullif(v_o->>'licence_number',''),
                           v_o->>'gstin') end, '')), '');
  v_valid := public._custreg_date(v_o->>'valid_to');
  v_name := nullif(btrim(coalesce(v_o->>'licensee_name','') || ''), '');
  v_name := coalesce(v_name, nullif(btrim(coalesce(v_o->>'legal_name','')),''),
                     nullif(btrim(coalesce(v_o->>'name','')),''));

  select id into v_id from public.kyc_documents
   where owner_kind = 'pharmacy' and owner_id = v_owner and kind = p_kind
     and coalesce(status,'') not in ('superseded','not_available')
   order by created_at desc limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error','no_file', 'message', public._c('custreg.v3_upload_failed'));
  end if;
  update public.kyc_documents
     set number = coalesce(v_num, number),
         valid_to = coalesce(v_valid, valid_to),
         read_fields = coalesce(read_fields,'{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object('name', v_name)),
         read_state = case when v_num is null then 'unreadable' else 'read' end,
         updated_at = now()
   where id = v_id;
  perform public._custreg_mirror_read(v_owner, p_kind);
  select zone_id into v_zone from public.pharmacy_profiles where id = v_owner;
  return jsonb_build_object('ok', true, 'read', v_num is not null,
                            'block', public.custreg_licences_block(v_zone, v_owner));
end $$;
grant execute on function public.custreg_doc_read_save(text, jsonb, uuid) to authenticated;

-- "Looks right" on the Edit sheet: what the person checked or typed wins.
create or replace function public.custreg_doc_read_edit(p_kind text, p_values jsonb, p_owner uuid default null)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  v_owner uuid := public._custreg_owner(p_owner); v jsonb := coalesce(p_values, '{}'::jsonb);
  v_id uuid; v_valid date; v_zone smallint;
begin
  if v_owner is null then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'message', public._c('custdoc.err_not_authorized'));
  end if;
  if nullif(btrim(coalesce(v->>'valid_to','')),'') is not null then
    v_valid := public._custreg_date(v->>'valid_to');
    if v_valid is null then
      return jsonb_build_object('ok', false, 'error','bad_date', 'field','valid_to',
                                'message', public._c('custreg.v3_bad_date'));
    end if;
  end if;
  select id into v_id from public.kyc_documents
   where owner_kind = 'pharmacy' and owner_id = v_owner and kind = p_kind
     and coalesce(status,'') not in ('superseded','not_available')
   order by created_at desc limit 1;
  if v_id is null then
    return jsonb_build_object('ok', false, 'error','no_file', 'message', public._c('custreg.v3_upload_failed'));
  end if;
  update public.kyc_documents
     set number = case when v ? 'number' then nullif(upper(btrim(coalesce(v->>'number',''))),'') else number end,
         valid_to = case when v ? 'valid_to' then v_valid else valid_to end,
         read_fields = coalesce(read_fields,'{}'::jsonb)
                       || case when v ? 'name' then jsonb_build_object('name', btrim(coalesce(v->>'name','')))
                               else '{}'::jsonb end,
         read_state = 'checked', updated_at = now()
   where id = v_id;
  perform public._custreg_mirror_read(v_owner, p_kind);
  select zone_id into v_zone from public.pharmacy_profiles where id = v_owner;
  return jsonb_build_object('ok', true, 'message', public._c('custreg.v3_edit_saved'),
                            'block', public.custreg_licences_block(v_zone, v_owner));
end $$;
grant execute on function public.custreg_doc_read_edit(text, jsonb, uuid) to authenticated;

-- The Documents step's list follows the ZONE OF THE DISTRICT picked on the
-- Location step — before the profile exists, and even if it changed since.
create or replace function public.custreg_licences_step()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_cid uuid; v_zone smallint; v_draft jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'show', false, 'message', public._c('custdoc.err_not_signed_in'));
  end if;
  v_cid := public._custreg_owner(null);
  v_draft := public.customer_reg_draft_get('signup');
  if nullif(btrim(coalesce(v_draft->>'district','')),'') is not null then
    v_zone := public.zone_resolve(v_draft->>'district', v_draft->>'city', false);
  end if;
  if v_zone is null and v_cid is not null then
    select zone_id into v_zone from public.pharmacy_profiles where id = v_cid;
  end if;
  if v_zone is null then v_zone := public.admin_active_zone(); end if;
  return jsonb_build_object('ok', true, 'customer_id', v_cid)
         || public.custreg_licences_block(v_zone, v_cid);
end $$;

-- ───────────────────────────────── wizard · payload · submit (CMD #2135) ──
create or replace function public.customer_registration_wizard(p_schema jsonb, p_values jsonb, p_docs jsonb, p_needs boolean, p_stage text, p_step text, p_prefill jsonb DEFAULT '{}'::jsonb, p_seen integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cfg    jsonb := coalesce((select value from public.app_settings where key = 'custreg_wizard'), '{}'::jsonb);
  v_fields jsonb := coalesce(p_schema->'fields', '[]'::jsonb);
  v_vals   jsonb := coalesce(p_values, '{}'::jsonb);
  v_steps  jsonb := '[]'::jsonb;
  v_total  int;
  v_step   jsonb; v_keys jsonb; v_f jsonb; v_k text;
  v_missing jsonb; v_i int := 0; v_resume int := -1; v_first_open int := -1;
  v_complete boolean; v_known text[] := '{}';
  v_by_key jsonb := '{}'::jsonb; v_done_map jsonb := '{}'::jsonb;
  v_docs_ok boolean; v_lic_any boolean; v_approved boolean;
  v_check jsonb; v_notes jsonb := '{}'::jsonb; v_seen int := greatest(coalesce(p_seen,0),0);
  v_map jsonb;
begin
  if coalesce((v_cfg->>'enabled')::boolean, false) is not true
     or jsonb_array_length(coalesce(v_cfg->'steps','[]'::jsonb)) = 0 then
    return jsonb_build_object('enabled', false);
  end if;

  select coalesce(jsonb_object_agg(f->>'key', f), '{}'::jsonb) into v_by_key
    from jsonb_array_elements(v_fields) f;
  select coalesce(array_agg(x #>> '{}'), '{}') into v_known
    from jsonb_array_elements(v_cfg->'steps') s, jsonb_array_elements(s->'fields') x;
  v_total := jsonb_array_length(v_cfg->'steps');

  for v_step in select value from jsonb_array_elements(v_cfg->'steps') loop
    -- The step's own list, in config order, kept to what the schema carries…
    select coalesce(jsonb_agg(x order by o), '[]'::jsonb) into v_keys
      from jsonb_array_elements_text(coalesce(v_step->'fields','[]'::jsonb)) with ordinality t(x, o)
     where v_by_key ? x;
    -- …plus any REQUIRED signup field no step names, on the step that owns
    -- its section — a new mandatory field can never fall off the flow.
    select v_keys || coalesce(jsonb_agg(f->>'key' order by (f->>'sort_order')::int), '[]'::jsonb)
      into v_keys
      from jsonb_array_elements(v_fields) f
     where coalesce((f->>'required')::boolean, false)
       and not ((f->>'key') = any (v_known))
       and (v_step->'sections') ? (f->>'section');

    v_missing := '[]'::jsonb;
    for v_k in select jsonb_array_elements_text(v_keys) loop
      v_f := v_by_key->v_k;
      if coalesce((v_f->>'required')::boolean, false) then
        if (v_f->>'type') = 'geo' then
          if nullif(btrim(coalesce(v_vals->>'latitude','')),'') is null
             or nullif(btrim(coalesce(v_vals->>'longitude','')),'') is null then
            v_missing := v_missing || to_jsonb(v_f->>'label');
          end if;
        elsif nullif(btrim(coalesce(v_vals->>v_k,'')),'') is null then
          v_missing := v_missing || to_jsonb(v_f->>'label');
        end if;
      end if;
    end loop;
    -- Filled is one thing; BEEN THROUGH is another. The checklist reads the
    -- raw answer (v_done_map); the bar's tick — and a forward jump — need the
    -- step to have been reached, or a step with no required field at all wears
    -- a tick before anybody has opened it.
    v_complete := jsonb_array_length(v_missing) = 0;
    v_done_map := v_done_map || jsonb_build_object(v_step->>'key', v_complete);
    v_complete := v_complete and v_i <= v_seen;
    if not v_complete and v_first_open < 0 then v_first_open := v_i; end if;
    if p_step is not null and (v_step->>'key') = p_step then v_resume := v_i; end if;

    -- CMD #2127 — the map step. Everything the map, the card and the Edit
    -- sheet print lives in this block; the step draws it and composes nothing.
    v_map := null;
    if coalesce((v_step->>'map')::boolean, false) then
      v_map := coalesce(p_schema->'geo', '{}'::jsonb)
            || jsonb_build_object(
                 'use_my_location_label', public._c('custreg.loc_use_my_location'),
                 'locating_label',        public._c('custreg.loc_locating'),
                 'denied_label',          public._c('custreg.loc_denied'),
                 'drag_hint',             public._c('custreg.loc_drag_hint'),
                 'reading_label',         public._c('custreg.loc_reading'),
                 'unavailable_label',     public._c('custreg.loc_map_unavailable'),
                 'card',                  public.custreg_location_card(v_vals),
                 -- CMD #2135 — the inline form under the map (State + District pickers).
                 'form',                  public.custreg_location_form(v_vals),
                 'edit', jsonb_build_object(
                   'title',        public._c('custreg.loc_edit_title'),
                   'save_label',   public._c('custreg.loc_edit_save'),
                   'cancel_label', public._c('custreg.loc_edit_cancel'),
                   'fields', (
                     select coalesce(jsonb_agg(jsonb_build_object(
                              'key',       k,
                              'label',     coalesce(v_by_key->k->>'label', k),
                              'hint',      coalesce(v_by_key->k->>'hint', ''),
                              'multiline', coalesce(v_by_key->k->>'type','') = 'textarea',
                              'numeric',   coalesce(v_by_key->k->>'type','') = 'number',
                              'value',     coalesce(nullif(btrim(coalesce(v_vals->>k,'')),''), ''))
                              order by o), '[]'::jsonb)
                       from unnest(array['address','landmark','city','state','pincode'])
                            with ordinality t(k, o)
                      where v_by_key ? k)));
    end if;

    v_steps := v_steps || jsonb_strip_nulls(jsonb_build_object(
      'key',      v_step->>'key',
      'n',        v_i + 1,
      'label',    public._cf('custreg.wiz_step_label',
                    jsonb_build_object('n', v_i + 1, 'label', public._c(v_step->>'label_key'))),
      'done_label', public._cf('custreg.wiz_step_done_label',
                    jsonb_build_object('n', v_i + 1, 'label', public._c(v_step->>'label_key'))),
      'title',    public._c(v_step->>'title_key'),
      'subtitle', coalesce(public._c(v_step->>'sub_key'), ''),
      'step_of',  public._cf('custreg.wiz_step_of',
                    jsonb_build_object('n', v_i + 1, 'total', v_total)),
      'fields',   v_keys,
      'docs',     coalesce((v_step->>'docs')::boolean, false),
      'map',      v_map,
      'continue_label', case when nullif(btrim(coalesce(v_step->>'continue_label_key','')),'') is not null
                             then public._c(v_step->>'continue_label_key') end,
      'complete', v_complete,
      'missing',  v_missing));
    v_i := v_i + 1;
  end loop;

  -- Resume where the person left (the step saved with the draft); a fresh
  -- start opens on step 1 — never mid-flow on an unsaved guess.
  if v_resume < 0 then v_resume := 0; end if;

  v_docs_ok := coalesce((p_docs->>'required_left')::int, 0) = 0;
  v_lic_any := coalesce(nullif(btrim(coalesce(v_vals->>'dl_20b','')),''),
                        nullif(btrim(coalesce(v_vals->>'dl_21b','')),''),
                        nullif(btrim(coalesce(v_vals->>'gstin','')),'')) is not null;
  v_approved := coalesce(p_stage,'') = 'approved' and not coalesce(p_needs,false);
  -- A licence counts once its number is typed or its paper is on file.
  v_lic_any := v_lic_any or exists (
    select 1 from jsonb_array_elements(coalesce(p_docs->'rows','[]'::jsonb)) r
     where r->>'key' in ('dl_20b','dl_21b') and coalesce((r->>'has_file')::boolean,false));

  -- Done checklist: the shop, its location, the licences, then every other
  -- paper the zone asks for — each Done or Add later.
  v_check := jsonb_build_array(
    jsonb_build_object('key','shop',     'label', public._c('custreg.done_part_shop'),
      'done', coalesce((v_done_map->>'shop')::boolean, false)),
    jsonb_build_object('key','location', 'label', public._c('custreg.done_part_location'),
      'done', coalesce((v_done_map->>'location')::boolean, false)),
    jsonb_build_object('key','licences', 'label', public._c('custreg.done_part_licences'),
      'done', v_lic_any));
  select v_check || coalesce(jsonb_agg(jsonb_build_object(
           'key', r->>'key', 'label', r->>'label',
           'done', coalesce((r->>'has_file')::boolean, false))), '[]'::jsonb)
    into v_check
    from jsonb_array_elements(coalesce(p_docs->'rows','[]'::jsonb)) r
   where coalesce(r->>'key','') not in ('dl_20b','dl_21b');

  -- "Pre-filled from your login" sits under WhatsApp only while the number
  -- on screen is the one the login gave us.
  if nullif(btrim(coalesce(p_prefill->>'whatsapp_no','')),'') is not null
     and btrim(coalesce(p_prefill->>'whatsapp_no','')) = btrim(coalesce(v_vals->>'whatsapp_no','')) then
    v_notes := jsonb_build_object('whatsapp_no', public._c('custreg.wiz_prefilled_note'));
  end if;

  return jsonb_build_object(
    'enabled',        true,
    'steps',          v_steps,
    'total',          v_total,
    'resume_step',    v_resume,
    'first_open',     greatest(v_first_open, 0),
    'continue_label', public._c('custreg.wiz_continue'),
    'back_label',     public._c('custreg.wiz_back'),
    'saving_label',   public._c('custreg.wiz_saving'),
    'submit_label',   public._c('custreg.submit_label'),
    'submitting_label', public._c('custreg.submitting_label'),
    'saved_label',    public._c('custreg.wiz_saved'),
    'chips',          coalesce(v_cfg->'chips', '{}'::jsonb),
    'field_notes',    v_notes,
    'done', jsonb_build_object(
      'title', case when v_approved then public._c('custreg.done_title')
                    else public._c('custreg.done_submitted_title') end,
      'line',  case when v_approved then public._c('custreg.done_line')
                    else public._c('custreg.done_submitted_line') end,
      'checklist', v_check,
      'done_label',  public._c('custreg.done_item_done'),
      'later_label', public._c('custreg.done_item_later'),
      'cta_label',   public._c('custreg.done_browse'),
      'cta_route',   coalesce(v_cfg->>'browse_route', '/')));
end $function$;

create or replace function public.customer_registration_payload()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_sess jsonb; v_needs_profile boolean := false; v_cid uuid;
  v_stage text; v_zone smallint;
  v_schema jsonb := '{}'::jsonb; v_draft jsonb := '{}'::jsonb;
  v_map jsonb; v_pre jsonb := '{}'::jsonb; v_u record; v_row record;
  v_docs jsonb; v_route text; v_needs boolean;
  v_missing text := ''; v_imported boolean := false;
  v_mail text := '';
begin
  if auth.uid() is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', false);
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_needs_profile := coalesce((v_sess->>'needs_profile')::boolean, false);
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  -- Staff and suppliers are not half-registered pharmacies.
  if not v_needs_profile and v_cid is null then
    return jsonb_build_object('needs', false, 'stage', 'none', 'signed_in', true);
  end if;

  v_route := coalesce(public.login_signup_cfg()->>'signup_form_route',
                      public.login_signup_cfg()->>'signup_route',
                      '/complete-registration');

  begin v_schema := public.customer_form_schema('signup');
  exception when others then v_schema := '{}'::jsonb; end;
  v_draft := public.customer_reg_draft_get('signup');

  -- Who is in front of us. An imported shop already has its row: every value
  -- on it becomes a prefill, so the person fills only what is blank.
  if v_cid is not null then
    select registration_stage::text as stage, zone_id,
           pharmacy_name, coalesce(owner_name, customer_name) as owner_name,
           phone, whatsapp_no, email, coalesce(address, address_local) as address,
           city, district, state, pincode, store_type, store_location_link,
           coalesce(gstin, gst_no) as gstin, dl_20b, dl_21b, dl_expiry,
           coalesce(drug_license,'') as drug_license,
           case when coalesce(created_by_admin,false) then 'admin_import' else '' end as source
      into v_row
      from public.pharmacy_profiles where id = v_cid;
    v_stage := v_row.stage;
    v_zone  := v_row.zone_id;
    -- CMD #2126 — an owner name that is only the email handle is not a name.
    v_mail := coalesce(v_row.email, '');
    if public.custreg_is_email_handle(v_row.owner_name, v_mail) then
      v_row.owner_name := null;
    end if;
    v_imported := coalesce(lower(btrim(coalesce(v_row.source,''))) in ('import','admin','admin_import'), false);
    v_pre := jsonb_strip_nulls(jsonb_build_object(
      'pharmacy_name',       nullif(btrim(coalesce(v_row.pharmacy_name,'')),''),
      'customer_name',       nullif(btrim(coalesce(v_row.owner_name,'')),''),
      'phone',               nullif(btrim(coalesce(v_row.phone,'')),''),
      'whatsapp_no',         nullif(btrim(coalesce(v_row.whatsapp_no,'')),''),
      'email',               nullif(btrim(coalesce(v_row.email,'')),''),
      'address',             nullif(btrim(coalesce(v_row.address,'')),''),
      'city',                nullif(btrim(coalesce(v_row.city,'')),''),
      'district',            nullif(btrim(coalesce(v_row.district,'')),''),
      'state',               nullif(btrim(coalesce(v_row.state,'')),''),
      'pincode',             nullif(btrim(coalesce(v_row.pincode,'')),''),
      'store_type',          nullif(btrim(coalesce(v_row.store_type,'')),''),
      'store_location_link', nullif(btrim(coalesce(v_row.store_location_link,'')),''),
      'gstin',               nullif(btrim(coalesce(v_row.gstin,'')),''),
      'dl_20b',              nullif(btrim(coalesce(v_row.dl_20b, v_row.drug_license,'')),''),
      'dl_21b',              nullif(btrim(coalesce(v_row.dl_21b,'')),''),
      'dl_expiry',           case when v_row.dl_expiry is null then null
                                  else to_char(v_row.dl_expiry,'YYYY-MM-DD') end));
  else
    -- Brand-new signup: the only thing known is the identity they logged in
    -- with, and WHICH field each identity value lands in is data.
    v_map := coalesce((select value from public.app_settings where key = 'signup_prefill_map'),
                      jsonb_build_object('name','customer_name','email','email','whatsapp','whatsapp_no'));
    select coalesce(nullif(btrim(coalesce(u.raw_user_meta_data->>'full_name','')),''),
                    nullif(btrim(coalesce(u.raw_user_meta_data->>'name','')),''),
                    '') as nm,
           case when lower(coalesce(u.email,'')) like
                     ('%@' || coalesce(public.login_signup_cfg()->>'internal_email_domain','wa.medibo.in'))
                then '' else coalesce(u.email,'') end as em,
           coalesce(nullif(right(regexp_replace(coalesce(u.phone,''),'\D','','g'),10),''),
                    coalesce(u.raw_user_meta_data->>'phone','')) as ph
      into v_u
      from auth.users u where u.id = auth.uid();
    -- CMD #2126 — Owner name is NEVER the email handle. A login that carries
    -- no real name (email/password signups copy the handle into `name`) leaves
    -- the field blank for the person to type.
    select coalesce(u.email,'') into v_mail from auth.users u where u.id = auth.uid();
    if public.custreg_is_email_handle(v_u.nm, v_mail) then
      v_u.nm := '';
    end if;
    v_pre := jsonb_strip_nulls(jsonb_build_object(
      coalesce(v_map->>'name','customer_name'),   nullif(coalesce(v_u.nm,''),''),
      coalesce(v_map->>'email','email'),          nullif(coalesce(v_u.em,''),''),
      coalesce(v_map->>'whatsapp','whatsapp_no'), nullif(coalesce(v_u.ph,''),'')));
    v_zone := public.admin_active_zone();
  end if;

  v_docs := public.custdoc_form_block(v_zone, v_cid);

  if v_cid is not null then
    begin v_missing := coalesce(public.customer_docs_missing_labels(v_cid), '');
    exception when others then v_missing := ''; end;
  end if;

  -- Owed while there is no profile at all, or while a mandatory paper is out.
  -- CMD #2112 — RE-SUBMISSION IS THE SAME SCREEN.
  -- The stage guard meant an APPROVED shop whose licence was later rejected,
  -- or which an admin later asked for an extra paper from, was told nothing
  -- was owed: `needs` was false, the bar never came up and there was no door
  -- back into the form. A mandatory paper that is OUT is owed at every stage;
  -- `customer_docs_missing_labels` already counts a rejected paper as out.
  v_needs := (v_cid is null)
             or coalesce(v_needs_profile, false)
             or (v_missing <> '')
             -- CMD #2135 — a row made early for an instant upload is still a
             -- registration in progress until Submit clears the draft.
             or coalesce((v_draft->>'_early')::boolean, false);

  return jsonb_build_object(
    'signed_in',   true,
    'needs',       v_needs,
    -- CMD #2061 — one form. 'documents' is no longer a stage of its own.
    'stage',       case when v_needs then 'form' else 'done' end,
    'route',       v_route,
    'customer_id', v_cid,
    'title',       public._c('custreg.form_title'),
    'subtitle',    public._c('custreg.form_subtitle'),
    'submit_label',     public._c('custreg.submit_label'),
    'submitting_label', public._c('custreg.submitting_label'),
    'error_label',      public._c('custreg.err_save'),
    'retry_label',      public._c('custreg.retry'),
    'close_label',      public._c('custreg.close_label'),
    'done_title',       public._c('custreg.done_title'),
    'done_line',        public._c('custreg.done_line'),
    'imported',    jsonb_build_object(
                     'is',   v_imported,
                     'note', case when v_imported then public._c('custreg.imported_note') else '' end),
    'schema',      v_schema,
    'prefill',     v_pre,
    'draft',       v_draft - '_step' - '_seen' - '_early',
    'has_draft',   (v_draft <> '{}'::jsonb),
    'draft_note',  case when v_draft <> '{}'::jsonb then public._c('custreg.draft_resumed') else '' end,
    'autosave',    jsonb_build_object(
                     'enabled', true, 'debounce_ms', 800,
                     'saving_label', public._c('custreg.draft_saving'),
                     'saved_label',  public._c('custreg.draft_saved')),
    'documents',   v_docs,
    -- The one line the customer sees once a starred paper was skipped.
    'docs_pending', jsonb_build_object(
                     'show',  (v_missing <> ''),
                     'title', public._c('custreg.pending_title'),
                     'line',  case when v_missing = '' then public._c('custreg.pending_done')
                                   else public._cf('custreg.pending_line',
                                          jsonb_build_object('docs', v_missing)) end,
                     'docs',  v_missing,
                     'cta',   public._c('custreg.pending_cta'),
                     'route', v_route,
                     'anchor','documents',
                     'tone',  case when v_missing = '' then 'success' else 'warning' end),
    -- Kept so anything still reading the old shape renders nothing rather
    -- than throwing. There are no steps any more.
    'steps',       '[]'::jsonb,
    'step',        jsonb_build_object('n', 1, 'total', 1, 'done', case when v_needs then 0 else 1 end,
                                      'label', '', 'progress_label', '', 'ratio', 0),
    'required_left', coalesce((v_docs->>'required_left')::int, 0),
    -- CMD #2126 — the 3-step flow: steps, their fields, where to resume,
    -- every caption and the Done screen. Absent (or enabled=false) and the
    -- app renders the single form exactly as before.
    'wizard',      public.customer_registration_wizard(
                     v_schema, v_pre || (v_draft - '_step' - '_early'), v_docs, v_needs,
                     coalesce(v_stage, ''), v_draft->>'_step', v_pre,
                     coalesce((v_draft->>'_seen')::int, 0)),
    'sheet', jsonb_build_object(
               'title',        public._c('custreg.sheet_title'),
               'line',         public._c('custreg.sheet_line'),
               'close_label',  public._c('custreg.sheet_close'),
               'done_message', public._c('custreg.sheet_done')));
end $function$;

create or replace function public.customer_registration_submit(p_values jsonb DEFAULT '{}'::jsonb, p_skips jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_cid uuid;
  v_sess jsonb;
  v_allowed text[] := array['pharmacy_name','customer_name','owner_name','phone','whatsapp_no',
                            'other_contact_no','email','address','address_local','city','district',
                            'state','pincode','gstin','gst_no','drug_license','dl_20b','dl_21b',
                            'dl_expiry','store_type','store_location_link','latitude','longitude',
                            'landmark'];
  v_key text; v_sets text[] := '{}'; v_rejected text[] := '{}';
  v_sub jsonb; v_skip text; v_zone smallint;
  v_missing text := ''; v_stage public.registration_stage;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','not_signed_in',
                              'message', public._c('custreg.err_not_signed_in'));
  end if;
  if p_values is null or jsonb_typeof(p_values) <> 'object' or p_values = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','no_values',
                              'message', public._c('custreg.err_no_values'));
  end if;

  begin v_sess := public.my_session_core(); exception when others then v_sess := '{}'::jsonb; end;
  v_cid := nullif(v_sess->>'customer_id','')::uuid;

  if v_cid is null then
    -- New shop: the same guarded door every other registration kind uses. It
    -- sets user_id, status and approved itself and refuses a privilege key.
    v_sub := public.submit_registration('pharmacy', p_values - 'dl_expiry' - 'latitude' - 'longitude' - 'landmark');
    v_cid := nullif(v_sub->>'id','')::uuid;
    v_rejected := coalesce((select array_agg(x #>> '{}') from jsonb_array_elements(v_sub->'rejected_keys') x), '{}');
  end if;

  if v_cid is null then
    return jsonb_build_object('ok', false, 'tone','danger', 'error','save_failed',
                              'message', public._c('custreg.err_save'));
  end if;

  -- An imported shop already had a row: the form UPDATES it, and only the
  -- columns the form is allowed to write. Approval state is never among them.
  for v_key in select jsonb_object_keys(p_values) loop
    if v_key = any (v_allowed) then
      if v_key = 'dl_expiry' then
        v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::date', v_key, p_values->>v_key);
      elsif v_key in ('latitude','longitude') then
        -- CMD #2127 QA — only a coordinate ON the globe is stored. Anything
        -- else (off the map, not a number) is listed in rejected_keys like a
        -- key the form may not write, instead of failing the whole cast.
        if public._custreg_coord_ok(v_key, p_values->>v_key) then
          v_sets := v_sets || format('%I = nullif(btrim(%L),'''')::numeric', v_key, p_values->>v_key);
        else
          v_rejected := v_rejected || v_key;
        end if;
      else
        v_sets := v_sets || format('%I = coalesce(nullif(btrim(%L),''''), %I)', v_key, p_values->>v_key, v_key);
      end if;
    else
      v_rejected := v_rejected || v_key;
    end if;
  end loop;

  if array_length(v_sets, 1) is not null then
    execute format('update public.pharmacy_profiles set %s, updated_at = now() where id = %L and user_id = %L',
                   array_to_string(v_sets, ', '), v_cid, v_uid);
    -- A brand-new row was just inserted by submit_registration under this
    -- user, so the user_id guard above always matches. An imported row whose
    -- identity was claimed at login matches too; anything else writes nothing.
  end if;

  -- CMD #2135 — zone = district. Saved here, never shown; an approved shop
  -- keeps the zone its orders already run in.
  update public.pharmacy_profiles
     set zone_id = coalesce(public.zone_resolve(district, city, false), zone_id)
   where id = v_cid and coalesce(registration_stage::text,'') <> 'approved'
     and nullif(btrim(coalesce(district,'')),'') is not null;
  select zone_id into v_zone from public.pharmacy_profiles where id = v_cid;

  -- "I don't have this" — recorded on the document ledger with the ledger's
  -- own vocabulary, so every reader (the form, the admin page, the reminder
  -- ladder) sees one truth. It is NOT a submission: the paper is still owed.
  if p_skips is not null and jsonb_typeof(p_skips) = 'array' then
    for v_skip in select x #>> '{}' from jsonb_array_elements(p_skips) x loop
      continue when coalesce(btrim(v_skip),'') = '';
      continue when coalesce(public.custdoc_mode_for(v_zone, v_skip), 'off') = 'off';
      if not exists (select 1 from public.kyc_documents kd
                      where kd.owner_kind = 'pharmacy' and kd.owner_id = v_cid
                        and kd.kind = v_skip
                        and kd.status in ('pending','submitted','verified')) then
        insert into public.kyc_documents(owner_kind, owner_id, kind, bucket, path,
                                         status, submitted_by, submitted_at, source, zone_id)
        values ('pharmacy', v_cid, btrim(v_skip), 'kyc-docs', '',
                'not_available', v_uid, now(), 'app', v_zone);
      end if;
    end loop;
  end if;

  begin v_missing := coalesce(public.customer_docs_missing_labels(v_cid), '');
  exception when others then v_missing := ''; end;

  -- The stage the account lands in. A starred paper still out is
  -- "documents" — Docs pending — and customer_approve_gate refuses from there.
  select registration_stage into v_stage from public.pharmacy_profiles where id = v_cid;
  if coalesce(v_stage::text,'') not in ('approved','verified') then
    update public.pharmacy_profiles
       set registration_stage = case when v_missing = '' then 'verified'::public.registration_stage
                                     else 'documents'::public.registration_stage end,
           updated_at = now()
     where id = v_cid;
  end if;

  begin perform public.customer_reg_draft_clear('signup'); exception when others then null; end;

  return jsonb_build_object(
    'ok', true, 'tone', case when v_missing = '' then 'success' else 'warning' end,
    'customer_id', v_cid,
    'message', case when v_missing = '' then public._c('custreg.saved_message')
                    else public._cf('custreg.pending_line', jsonb_build_object('docs', v_missing)) end,
    'docs_pending', (v_missing <> ''),
    'docs_missing', v_missing,
    'rejected_keys', to_jsonb(v_rejected),
    'payload', public.customer_registration_payload());
end $function$;

-- ───────────────────────────────────────── 5 · STEPS: General · Location · Documents
-- No numbers on the bar; each label centred under its own bar (the screen
-- centres, the words are these). Store type is one chip row — Retail,
-- Hospital, Clinic — whose values are the admin list's own, so nothing stored
-- changes meaning; Wholesale is gone. Documents carries no typed boxes: the
-- numbers come off the photos.
insert into public.ui_copy(key, value) values
  ('custreg.wiz_step_label',      to_jsonb('{label}'::text)),
  ('custreg.wiz_step_done_label', to_jsonb('✓ {label}'::text)),
  ('custreg.wiz_step_shop',       to_jsonb('General'::text)),
  ('custreg.wiz_step_location',   to_jsonb('Location'::text)),
  ('custreg.wiz_step_licences',   to_jsonb('Documents'::text)),
  ('custreg.wiz_title_licences',  to_jsonb('Upload your papers'::text)),
  ('custreg.wiz_sub_licences',    to_jsonb('Papers needed for your area. Just add a photo of each one — we read the numbers for you.'::text)),
  ('custreg.wiz_sub_location',    to_jsonb('Drag the pin onto your shop door.'::text)),
  ('custreg.done_part_shop',      to_jsonb('General'::text)),
  ('custreg.done_part_licences',  to_jsonb('Documents'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

update public.app_settings
   set value = jsonb_set(jsonb_set(jsonb_set(jsonb_set(value,
         '{chips,store_type}', jsonb_build_array(
            jsonb_build_object('label','Retail',   'value','Retail Pharmacy'),
            jsonb_build_object('label','Hospital', 'value','Hospital Pharmacy'),
            jsonb_build_object('label','Clinic',   'value','Clinic'))),
         '{chips_layout}', '"row"'::jsonb),
         '{steps}', (select jsonb_agg(
             case s->>'key'
               when 'location' then s || jsonb_build_object('fields',
                    jsonb_build_array('address','landmark','city','pincode','state','district'))
               when 'licences' then s || jsonb_build_object('fields','[]'::jsonb, 'sections','[]'::jsonb)
               else s end order by o)
           from jsonb_array_elements(value->'steps') with ordinality t(s, o))),
         '{layout}', '"v3"'::jsonb)
 where key = 'custreg_wizard';
