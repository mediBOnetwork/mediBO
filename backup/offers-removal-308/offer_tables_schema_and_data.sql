--
-- PostgreSQL database dump
--

\restrict cbq5J9TmRemRsuSfy5WAttBqDjRZDl6qbX0WLOU27DxuhDHyBcgdBxJi81UPu2d

-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.11 (Ubuntu 17.11-1.pgdg24.04+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: supplier_offer_listings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_offer_listings (
    id bigint NOT NULL,
    supplier_id uuid NOT NULL,
    product_id bigint NOT NULL,
    listing_type text NOT NULL,
    available_qty numeric DEFAULT 0 NOT NULL,
    sold_qty numeric DEFAULT 0 NOT NULL,
    offer_ptr numeric,
    discount_pct numeric,
    net_price numeric,
    scheme_buy_qty numeric,
    scheme_free_qty numeric,
    batch_expiry_date date,
    min_order_qty numeric DEFAULT 1,
    end_date date,
    margin_pct numeric DEFAULT 0,
    moderated_at timestamp with time zone,
    moderated_by uuid,
    moderation_note text,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    zone_ids smallint[],
    CONSTRAINT supplier_offer_listings_available_qty_check CHECK ((available_qty >= (0)::numeric)),
    CONSTRAINT supplier_offer_listings_listing_type_check CHECK ((listing_type = ANY (ARRAY['scheme'::text, 'near_expiry'::text, 'discount'::text]))),
    CONSTRAINT supplier_offer_listings_status_check CHECK ((status = ANY (ARRAY['active'::text, 'paused'::text, 'expired'::text, 'delisted'::text])))
);


--
-- Name: offer_near_expiry_disclosures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offer_near_expiry_disclosures (
    id bigint NOT NULL,
    customer_id uuid NOT NULL,
    listing_id bigint NOT NULL,
    order_id uuid,
    accepted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: offer_near_expiry_disclosures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.offer_near_expiry_disclosures ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.offer_near_expiry_disclosures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: offer_push_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offer_push_log (
    id bigint NOT NULL,
    listing_id bigint NOT NULL,
    customer_id uuid NOT NULL,
    kind text NOT NULL,
    result jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: offer_push_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.offer_push_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.offer_push_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: offer_reservations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offer_reservations (
    id bigint NOT NULL,
    listing_id bigint NOT NULL,
    customer_id uuid NOT NULL,
    qty numeric NOT NULL,
    status text DEFAULT 'held'::text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    order_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    consumed_at timestamp with time zone,
    released_at timestamp with time zone,
    CONSTRAINT offer_reservations_qty_check CHECK ((qty > (0)::numeric)),
    CONSTRAINT offer_reservations_status_check CHECK ((status = ANY (ARRAY['held'::text, 'consumed'::text, 'released'::text])))
);


--
-- Name: offer_reservations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.offer_reservations ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.offer_reservations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: offer_waitlist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.offer_waitlist (
    id bigint NOT NULL,
    listing_id bigint NOT NULL,
    customer_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    notified_at timestamp with time zone
);


--
-- Name: offer_waitlist_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.offer_waitlist ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.offer_waitlist_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: short_dated_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.short_dated_config (
    id integer NOT NULL,
    months_max integer NOT NULL,
    discount_pct numeric(5,2) NOT NULL,
    label text NOT NULL,
    enabled boolean DEFAULT true,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: short_dated_config_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.short_dated_config_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: short_dated_config_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.short_dated_config_id_seq OWNED BY public.short_dated_config.id;


--
-- Name: short_dated_offers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.short_dated_offers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id bigint NOT NULL,
    product_name text,
    supplier_name text NOT NULL,
    batch_no text,
    batch_expiry date NOT NULL,
    available_qty numeric DEFAULT 0 NOT NULL,
    sourced_qty numeric DEFAULT 0 NOT NULL,
    discount_pct numeric(5,2) DEFAULT 0 NOT NULL,
    override_discount boolean DEFAULT false,
    bulk_clear_extra_pct numeric(5,2) DEFAULT 0,
    bulk_clear_min_qty numeric DEFAULT 0,
    status text DEFAULT 'pending_confirm'::text NOT NULL,
    zone_ids integer[],
    wa_push_sent boolean DEFAULT false,
    source_mention_id uuid,
    confirmed_by text,
    confirmed_at timestamp with time zone,
    admin_notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT sdo_status_values CHECK ((status = ANY (ARRAY['pending_confirm'::text, 'active'::text, 'exhausted'::text, 'expired'::text, 'disabled'::text])))
);


--
-- Name: supplier_offer_listings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.supplier_offer_listings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.supplier_offer_listings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: short_dated_config id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.short_dated_config ALTER COLUMN id SET DEFAULT nextval('public.short_dated_config_id_seq'::regclass);


--
-- Data for Name: offer_near_expiry_disclosures; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: offer_push_log; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: offer_reservations; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: offer_waitlist; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: short_dated_config; Type: TABLE DATA; Schema: public; Owner: -
--

INSERT INTO public.short_dated_config (id, months_max, discount_pct, label, enabled, sort_order, created_at) VALUES (1, 1, 40.00, 'Expires in < 1 month', true, 1, '2026-08-17 04:50:24.605385+00');
INSERT INTO public.short_dated_config (id, months_max, discount_pct, label, enabled, sort_order, created_at) VALUES (2, 3, 25.00, 'Expires in < 3 months', true, 2, '2026-08-17 04:50:24.605385+00');
INSERT INTO public.short_dated_config (id, months_max, discount_pct, label, enabled, sort_order, created_at) VALUES (3, 6, 10.00, 'Expires in < 6 months', true, 3, '2026-08-17 04:50:24.605385+00');


--
-- Data for Name: short_dated_offers; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Data for Name: supplier_offer_listings; Type: TABLE DATA; Schema: public; Owner: -
--



--
-- Name: offer_near_expiry_disclosures_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.offer_near_expiry_disclosures_id_seq', 2, true);


--
-- Name: offer_push_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.offer_push_log_id_seq', 1, false);


--
-- Name: offer_reservations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.offer_reservations_id_seq', 10, true);


--
-- Name: offer_waitlist_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.offer_waitlist_id_seq', 1, true);


--
-- Name: short_dated_config_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.short_dated_config_id_seq', 3, true);


--
-- Name: supplier_offer_listings_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.supplier_offer_listings_id_seq', 12, true);


--
-- Name: offer_near_expiry_disclosures offer_near_expiry_disclosures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_near_expiry_disclosures
    ADD CONSTRAINT offer_near_expiry_disclosures_pkey PRIMARY KEY (id);


--
-- Name: offer_push_log offer_push_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_push_log
    ADD CONSTRAINT offer_push_log_pkey PRIMARY KEY (id);


--
-- Name: offer_reservations offer_reservations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_reservations
    ADD CONSTRAINT offer_reservations_pkey PRIMARY KEY (id);


--
-- Name: offer_waitlist offer_waitlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_waitlist
    ADD CONSTRAINT offer_waitlist_pkey PRIMARY KEY (id);


--
-- Name: short_dated_config short_dated_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.short_dated_config
    ADD CONSTRAINT short_dated_config_pkey PRIMARY KEY (id);


--
-- Name: short_dated_offers short_dated_offers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.short_dated_offers
    ADD CONSTRAINT short_dated_offers_pkey PRIMARY KEY (id);


--
-- Name: supplier_offer_listings supplier_offer_listings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_offer_listings
    ADD CONSTRAINT supplier_offer_listings_pkey PRIMARY KEY (id);


--
-- Name: idx_sol_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sol_product ON public.supplier_offer_listings USING btree (product_id);


--
-- Name: idx_sol_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sol_status ON public.supplier_offer_listings USING btree (status) WHERE (status = 'active'::text);


--
-- Name: idx_sol_supplier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sol_supplier ON public.supplier_offer_listings USING btree (supplier_id);


--
-- Name: ix_offer_push_listing; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_offer_push_listing ON public.offer_push_log USING btree (listing_id);


--
-- Name: ix_offer_res_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_offer_res_expiry ON public.offer_reservations USING btree (expires_at) WHERE (status = 'held'::text);


--
-- Name: sdo_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sdo_product ON public.short_dated_offers USING btree (product_id);


--
-- Name: sdo_status_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sdo_status_expiry ON public.short_dated_offers USING btree (status, batch_expiry);


--
-- Name: uq_offer_res_held; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_offer_res_held ON public.offer_reservations USING btree (listing_id, customer_id) WHERE (status = 'held'::text);


--
-- Name: uq_offer_waitlist; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_offer_waitlist ON public.offer_waitlist USING btree (listing_id, customer_id);


--
-- Name: short_dated_offers sdo_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sdo_updated_at BEFORE UPDATE ON public.short_dated_offers FOR EACH ROW EXECUTE FUNCTION public._sdo_set_updated_at();


--
-- Name: supplier_offer_listings trg_c305_offer_expiry_wake; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_c305_offer_expiry_wake AFTER INSERT OR UPDATE OF available_qty, end_date, batch_expiry_date, status ON public.supplier_offer_listings FOR EACH STATEMENT EXECUTE FUNCTION public.trg_cron_wake_offer_expiry();


--
-- Name: offer_near_expiry_disclosures offer_near_expiry_disclosures_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_near_expiry_disclosures
    ADD CONSTRAINT offer_near_expiry_disclosures_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.supplier_offer_listings(id);


--
-- Name: offer_push_log offer_push_log_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_push_log
    ADD CONSTRAINT offer_push_log_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.supplier_offer_listings(id) ON DELETE CASCADE;


--
-- Name: offer_reservations offer_reservations_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_reservations
    ADD CONSTRAINT offer_reservations_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.supplier_offer_listings(id) ON DELETE CASCADE;


--
-- Name: offer_waitlist offer_waitlist_listing_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.offer_waitlist
    ADD CONSTRAINT offer_waitlist_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES public.supplier_offer_listings(id) ON DELETE CASCADE;


--
-- Name: supplier_offer_listings supplier_offer_listings_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_offer_listings
    ADD CONSTRAINT supplier_offer_listings_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: short_dated_config admin_all_sdc; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_all_sdc ON public.short_dated_config USING ((public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text]))) WITH CHECK ((public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text])));


--
-- Name: short_dated_offers admin_all_sdo; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY admin_all_sdo ON public.short_dated_offers USING ((public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text]))) WITH CHECK ((public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text])));


--
-- Name: short_dated_offers customer_read_active_sdo; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY customer_read_active_sdo ON public.short_dated_offers FOR SELECT USING (((status = 'active'::text) AND (public.get_my_role() = 'customer'::text)));


--
-- Name: offer_near_expiry_disclosures ned_customer_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ned_customer_all ON public.offer_near_expiry_disclosures USING (((customer_id = public.my_customer_id()) OR (public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text, 'service'::text]))));


--
-- Name: offer_near_expiry_disclosures; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.offer_near_expiry_disclosures ENABLE ROW LEVEL SECURITY;

--
-- Name: offer_push_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.offer_push_log ENABLE ROW LEVEL SECURITY;

--
-- Name: offer_reservations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.offer_reservations ENABLE ROW LEVEL SECURITY;

--
-- Name: offer_waitlist; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.offer_waitlist ENABLE ROW LEVEL SECURITY;

--
-- Name: offer_push_log opl_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opl_admin ON public.offer_push_log USING ((public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text, 'service'::text])));


--
-- Name: offer_reservations ores_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ores_own ON public.offer_reservations USING (((customer_id = public.my_customer_id()) OR (public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text, 'service'::text]))));


--
-- Name: offer_waitlist owl_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY owl_own ON public.offer_waitlist USING (((customer_id = public.my_customer_id()) OR (public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text, 'service'::text]))));


--
-- Name: short_dated_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.short_dated_config ENABLE ROW LEVEL SECURITY;

--
-- Name: short_dated_offers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.short_dated_offers ENABLE ROW LEVEL SECURITY;

--
-- Name: supplier_offer_listings sol_supplier_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sol_supplier_insert ON public.supplier_offer_listings FOR INSERT WITH CHECK (((supplier_id = auth.uid()) AND (public.get_my_role() = ANY (ARRAY['supplier'::text, 'admin'::text, 'super_admin'::text, 'service'::text]))));


--
-- Name: supplier_offer_listings sol_supplier_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sol_supplier_select ON public.supplier_offer_listings FOR SELECT USING (((supplier_id = auth.uid()) OR (public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text, 'service'::text]))));


--
-- Name: supplier_offer_listings sol_supplier_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY sol_supplier_update ON public.supplier_offer_listings FOR UPDATE USING ((((supplier_id = auth.uid()) AND (public.get_my_role() = ANY (ARRAY['supplier'::text, 'admin'::text, 'super_admin'::text, 'service'::text]))) OR (public.get_my_role() = ANY (ARRAY['admin'::text, 'super_admin'::text, 'service'::text]))));


--
-- Name: supplier_offer_listings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.supplier_offer_listings ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict cbq5J9TmRemRsuSfy5WAttBqDjRZDl6qbX0WLOU27DxuhDHyBcgdBxJi81UPu2d

