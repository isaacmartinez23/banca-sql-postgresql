-- 02_clean.sql
-- Capa limpia del dataset Berka: pasa de raw (todo TEXT) a tablas con tipos
-- reales, llaves primarias y foráneas, y restricciones CHECK.
--
-- Qué se transforma:
--   * Fechas YYMMDD            -> date (todo el dataset es del siglo XX)
--   * birth_number del cliente -> fecha de nacimiento + género
--                                 (en mujeres el mes viene sumado con 50)
--   * Códigos en checo         -> etiquetas en inglés
--   * '?' y cadenas vacías     -> NULL
--   * Columnas A1..A16         -> nombres descriptivos
--
-- Requisito: haber corrido 01_raw_load.sql.
-- Ejecutar desde psql:  \i /docker-entrypoint-initdb.d/02_clean.sql
-- Se puede volver a correr: borra y recrea el esquema clean.

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS clean CASCADE;
CREATE SCHEMA clean;

-- Convierte 'YYMMDD' a date. Devuelve NULL si el texto viene vacío.
CREATE FUNCTION clean.yymmdd(txt text) RETURNS date
LANGUAGE sql IMMUTABLE AS $$
    SELECT to_date('19' || lpad(nullif(trim(txt), ''), 6, '0'), 'YYYYMMDD');
$$;

------------------------------------------------------------------------------
-- district: demografía de los 77 distritos
------------------------------------------------------------------------------
CREATE TABLE clean.district (
    district_id            int PRIMARY KEY,
    district_name          text NOT NULL,
    region                 text NOT NULL,
    inhabitants            int  NOT NULL CHECK (inhabitants > 0),
    municipalities_lt_500  int  NOT NULL,
    municipalities_500_2k  int  NOT NULL,
    municipalities_2k_10k  int  NOT NULL,
    municipalities_gt_10k  int  NOT NULL,
    cities                 int  NOT NULL,
    urban_ratio_pct        numeric(5,1) NOT NULL CHECK (urban_ratio_pct BETWEEN 0 AND 100),
    avg_salary             int  NOT NULL CHECK (avg_salary > 0),
    unemployment_1995_pct  numeric(5,2),          -- faltante en un distrito
    unemployment_1996_pct  numeric(5,2) NOT NULL,
    entrepreneurs_per_1000 int  NOT NULL,
    crimes_1995            int,                   -- faltante en un distrito
    crimes_1996            int  NOT NULL
);

INSERT INTO clean.district
SELECT a1::int,
       trim(a2),
       trim(a3),
       a4::int, a5::int, a6::int, a7::int, a8::int, a9::int,
       a10::numeric,
       a11::int,
       nullif(trim(a12), '?')::numeric,
       a13::numeric,
       a14::int,
       nullif(trim(a15), '?')::int,
       a16::int
FROM raw.district;

------------------------------------------------------------------------------
-- account: una fila por cuenta
------------------------------------------------------------------------------
CREATE TABLE clean.account (
    account_id          int  PRIMARY KEY,
    district_id         int  NOT NULL REFERENCES clean.district,
    statement_frequency text NOT NULL
        CHECK (statement_frequency IN ('monthly', 'weekly', 'after_transaction')),
    opened_date         date NOT NULL
);

INSERT INTO clean.account
SELECT account_id::int,
       district_id::int,
       CASE trim(frequency)
           WHEN 'POPLATEK MESICNE'   THEN 'monthly'
           WHEN 'POPLATEK TYDNE'     THEN 'weekly'
           WHEN 'POPLATEK PO OBRATU' THEN 'after_transaction'
           ELSE trim(frequency)      -- valor inesperado: lo detiene el CHECK
       END,
       clean.yymmdd(date)
FROM raw.account;

------------------------------------------------------------------------------
-- client: una fila por cliente
-- birth_number es YYMMDD en hombres y YY(MM+50)DD en mujeres
------------------------------------------------------------------------------
CREATE TABLE clean.client (
    client_id   int  PRIMARY KEY,
    birth_date  date NOT NULL,
    gender      text NOT NULL CHECK (gender IN ('F', 'M')),
    district_id int  NOT NULL REFERENCES clean.district
);

INSERT INTO clean.client
SELECT client_id::int,
       make_date(1900 + substr(bn, 1, 2)::int,
                 CASE WHEN substr(bn, 3, 2)::int > 50
                      THEN substr(bn, 3, 2)::int - 50
                      ELSE substr(bn, 3, 2)::int END,
                 substr(bn, 5, 2)::int),
       CASE WHEN substr(bn, 3, 2)::int > 50 THEN 'F' ELSE 'M' END,
       district_id::int
FROM (SELECT *, lpad(trim(birth_number), 6, '0') AS bn FROM raw.client) c;

------------------------------------------------------------------------------
-- disp: relación cliente-cuenta (titular o autorizado)
------------------------------------------------------------------------------
CREATE TABLE clean.disp (
    disp_id    int  PRIMARY KEY,
    client_id  int  NOT NULL REFERENCES clean.client,
    account_id int  NOT NULL REFERENCES clean.account,
    role       text NOT NULL CHECK (role IN ('owner', 'authorized'))
);

INSERT INTO clean.disp
SELECT disp_id::int,
       client_id::int,
       account_id::int,
       CASE trim(type)
           WHEN 'OWNER'     THEN 'owner'
           WHEN 'DISPONENT' THEN 'authorized'
           ELSE trim(type)
       END
FROM raw.disp;

------------------------------------------------------------------------------
-- orders: órdenes de pago permanentes (domiciliaciones)
------------------------------------------------------------------------------
CREATE TABLE clean.orders (
    order_id   int  PRIMARY KEY,
    account_id int  NOT NULL REFERENCES clean.account,
    bank_to    text NOT NULL,
    account_to text NOT NULL,
    amount     numeric(12,2) NOT NULL CHECK (amount > 0),
    purpose    text CHECK (purpose IN ('insurance', 'household', 'leasing', 'loan'))
);

INSERT INTO clean.orders
SELECT order_id::int,
       account_id::int,
       trim(bank_to),
       trim(account_to),
       amount::numeric,
       CASE nullif(trim(k_symbol), '')
           WHEN 'POJISTNE' THEN 'insurance'
           WHEN 'SIPO'     THEN 'household'
           WHEN 'LEASING'  THEN 'leasing'
           WHEN 'UVER'     THEN 'loan'
           ELSE nullif(trim(k_symbol), '')
       END
FROM raw.orders;

------------------------------------------------------------------------------
-- loan: préstamos. status:
--   A = terminado, pagado      B = terminado, sin pagar
--   C = vigente, al corriente  D = vigente, con adeudo
------------------------------------------------------------------------------
CREATE TABLE clean.loan (
    loan_id         int  PRIMARY KEY,
    account_id      int  NOT NULL REFERENCES clean.account,
    granted_date    date NOT NULL,
    amount          numeric(12,2) NOT NULL CHECK (amount > 0),
    duration_months int  NOT NULL CHECK (duration_months > 0),
    monthly_payment numeric(12,2) NOT NULL CHECK (monthly_payment > 0),
    status          text NOT NULL CHECK (status IN ('A', 'B', 'C', 'D')),
    is_bad          boolean GENERATED ALWAYS AS (status IN ('B', 'D')) STORED
);

INSERT INTO clean.loan (loan_id, account_id, granted_date, amount,
                        duration_months, monthly_payment, status)
SELECT loan_id::int,
       account_id::int,
       clean.yymmdd(date),
       amount::numeric,
       duration::int,
       payments::numeric,
       trim(status)
FROM raw.loan;

------------------------------------------------------------------------------
-- card: tarjetas. issued viene como 'YYMMDD 00:00:00'
------------------------------------------------------------------------------
CREATE TABLE clean.card (
    card_id     int  PRIMARY KEY,
    disp_id     int  NOT NULL REFERENCES clean.disp,
    card_type   text NOT NULL CHECK (card_type IN ('junior', 'classic', 'gold')),
    issued_date date NOT NULL
);

INSERT INTO clean.card
SELECT card_id::int,
       disp_id::int,
       lower(trim(type)),
       clean.yymmdd(left(trim(issued), 6))
FROM raw.card;

------------------------------------------------------------------------------
-- trans: transacciones (la tabla grande)
-- En el original, type trae 'VYBER' en algunos retiros en efectivo; son
-- cargos, así que se agrupan con 'VYDAJ' como 'debit'.
-- Los índices secundarios se dejan para el script de rendimiento, para poder
-- medir el antes y el después con EXPLAIN ANALYZE.
------------------------------------------------------------------------------
CREATE TABLE clean.trans (
    trans_id        int  PRIMARY KEY,
    account_id      int  NOT NULL REFERENCES clean.account,
    trans_date      date NOT NULL,
    direction       text NOT NULL CHECK (direction IN ('credit', 'debit')),
    operation       text CHECK (operation IN
                        ('cash_deposit', 'cash_withdrawal', 'card_withdrawal',
                         'transfer_in', 'transfer_out')),
    amount          numeric(12,2) NOT NULL CHECK (amount >= 0),
    balance         numeric(12,2) NOT NULL,   -- saldo después del movimiento
    purpose         text CHECK (purpose IN
                        ('insurance', 'statement_fee', 'interest_credited',
                         'penalty_interest', 'household', 'pension',
                         'loan_payment')),
    partner_bank    text,
    partner_account text
);

INSERT INTO clean.trans
SELECT trans_id::int,
       account_id::int,
       clean.yymmdd(date),
       CASE trim(type)
           WHEN 'PRIJEM' THEN 'credit'
           WHEN 'VYDAJ'  THEN 'debit'
           WHEN 'VYBER'  THEN 'debit'
           ELSE trim(type)
       END,
       CASE nullif(trim(operation), '')
           WHEN 'VKLAD'          THEN 'cash_deposit'
           WHEN 'VYBER'          THEN 'cash_withdrawal'
           WHEN 'VYBER KARTOU'   THEN 'card_withdrawal'
           WHEN 'PREVOD Z UCTU'  THEN 'transfer_in'
           WHEN 'PREVOD NA UCET' THEN 'transfer_out'
           ELSE nullif(trim(operation), '')
       END,
       amount::numeric,
       balance::numeric,
       CASE nullif(trim(k_symbol), '')
           WHEN 'POJISTNE'    THEN 'insurance'
           WHEN 'SLUZBY'      THEN 'statement_fee'
           WHEN 'UROK'        THEN 'interest_credited'
           WHEN 'SANKC. UROK' THEN 'penalty_interest'
           WHEN 'SIPO'        THEN 'household'
           WHEN 'DUCHOD'      THEN 'pension'
           WHEN 'UVER'        THEN 'loan_payment'
           ELSE nullif(trim(k_symbol), '')
       END,
       nullif(trim(bank), ''),
       nullif(nullif(trim(account), ''), '0')
FROM raw.trans;

ANALYZE clean.district, clean.account, clean.client, clean.disp,
        clean.orders, clean.loan, clean.card, clean.trans;

------------------------------------------------------------------------------
-- Verificación 1: no se perdió ninguna fila entre raw y clean
------------------------------------------------------------------------------
SELECT t.tabla, t.raw, t.clean,
       CASE WHEN t.raw = t.clean THEN 'ok' ELSE 'REVISAR' END AS estado
FROM (
              SELECT 'district' AS tabla, (SELECT count(*) FROM raw.district) AS raw, (SELECT count(*) FROM clean.district) AS clean
    UNION ALL SELECT 'account',  (SELECT count(*) FROM raw.account),  (SELECT count(*) FROM clean.account)
    UNION ALL SELECT 'client',   (SELECT count(*) FROM raw.client),   (SELECT count(*) FROM clean.client)
    UNION ALL SELECT 'disp',     (SELECT count(*) FROM raw.disp),     (SELECT count(*) FROM clean.disp)
    UNION ALL SELECT 'orders',   (SELECT count(*) FROM raw.orders),   (SELECT count(*) FROM clean.orders)
    UNION ALL SELECT 'loan',     (SELECT count(*) FROM raw.loan),     (SELECT count(*) FROM clean.loan)
    UNION ALL SELECT 'card',     (SELECT count(*) FROM raw.card),     (SELECT count(*) FROM clean.card)
    UNION ALL SELECT 'trans',    (SELECT count(*) FROM raw.trans),    (SELECT count(*) FROM clean.trans)
) t;

------------------------------------------------------------------------------
-- Verificación 2: rangos de fechas (deben caer entre 1993 y 1998, salvo
-- nacimientos) y reparto por género
------------------------------------------------------------------------------
SELECT 'account.opened_date' AS columna, min(opened_date) AS minimo, max(opened_date) AS maximo FROM clean.account
UNION ALL SELECT 'loan.granted_date', min(granted_date), max(granted_date) FROM clean.loan
UNION ALL SELECT 'card.issued_date',  min(issued_date),  max(issued_date)  FROM clean.card
UNION ALL SELECT 'trans.trans_date',  min(trans_date),   max(trans_date)   FROM clean.trans
UNION ALL SELECT 'client.birth_date', min(birth_date),   max(birth_date)   FROM clean.client;

SELECT gender, count(*) AS clientes FROM clean.client GROUP BY gender ORDER BY gender;