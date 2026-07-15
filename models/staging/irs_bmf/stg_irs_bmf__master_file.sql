-- models/staging/irs_bmf/stg_irs_bmf__master_file.sql

WITH source AS (
    SELECT * FROM {{ source('irs_bmf', 'ext_irs_bmf_master') }}
),

-- Valid US state/territory/military codes (used for is_domestic flag)
-- 50 states + DC + territories (PR, VI, GU, AS, MP)
-- + military mail (AE=Europe/ME/Africa, AP=Pacific, AA=Americas)
-- + freely associated states (FM=Micronesia, MH=Marshall Islands, PW=Palau)
valid_us_codes AS (
    SELECT code FROM (VALUES
        ('AL'),('AK'),('AZ'),('AR'),('CA'),('CO'),('CT'),('DE'),('FL'),('GA'),
        ('HI'),('ID'),('IL'),('IN'),('IA'),('KS'),('KY'),('LA'),('ME'),('MD'),
        ('MA'),('MI'),('MN'),('MS'),('MO'),('MT'),('NE'),('NV'),('NH'),('NJ'),
        ('NM'),('NY'),('NC'),('ND'),('OH'),('OK'),('OR'),('PA'),('RI'),('SC'),
        ('SD'),('TN'),('TX'),('UT'),('VT'),('VA'),('WA'),('WV'),('WI'),('WY'),
        ('DC'),
        ('PR'),('VI'),('GU'),('AS'),('MP'),          -- US territories
        ('AE'),('AP'),('AA'),                          -- Military mail
        ('FM'),('MH'),('PW')                           -- Freely associated states
    ) AS t(code)
),

cleaned AS (
    SELECT
        -- ============================================================
        -- Primary Key
        -- ============================================================
        TRIM(ein) AS ein,

        -- ============================================================
        -- Organization Identity
        -- ============================================================
        TRIM(name) AS organization_name,
        TRIM(ico) AS in_care_of,
        TRIM(sort_name) AS sort_name,

        -- ============================================================
        -- Address (handles domestic + international patterns)
        -- ============================================================
        TRIM(street) AS street_address,

        -- For international orgs, IRS puts the country in city field
        -- and the actual city+region is crammed into street.
        -- We preserve the raw city value but also extract country separately.
        TRIM(city) AS city,
        UPPER(TRIM(state)) AS state_code,

        -- Null out fake placeholder ZIPs (international orgs get "00000-0000")
        CASE
            WHEN TRIM(zip) = '00000-0000' THEN NULL
            WHEN TRIM(zip) = '' THEN NULL
            ELSE TRIM(zip)
        END AS zip_code,

        -- ============================================================
        -- Domestic vs International Classification
        -- ============================================================

        -- is_domestic: TRUE for all US states, territories, military, associated states
        -- FALSE for international orgs (blank state code)
        CASE
            WHEN UPPER(TRIM(state)) IN (SELECT code FROM valid_us_codes) THEN TRUE
            ELSE FALSE
        END AS is_domestic,

        -- country: "United States" for domestic, parsed from city field for international
        -- Note: IRS data quality on country is imperfect — some records have wrong countries
        CASE
            WHEN UPPER(TRIM(state)) IN (SELECT code FROM valid_us_codes) THEN 'United States'
            WHEN TRIM(state) = '' OR state IS NULL THEN TRIM(city)  -- IRS puts country in city
            ELSE 'Unknown'
        END AS country,

        -- ============================================================
        -- Classification Codes (keep as VARCHAR — they're codes, not numbers)
        -- ============================================================
        TRIM(subsection_code) AS subsection_code,
        TRIM(affiliation_code) AS affiliation_code,
        TRIM(classification_code) AS classification_code,
        TRIM(deductibility_code) AS deductibility_code,
        TRIM(foundation_code) AS foundation_code,
        TRIM(organization_code) AS organization_code,
        TRIM(status_code) AS status_code,
        TRIM(activity_code) AS activity_code,
        TRIM(ntee_code) AS ntee_code,
        TRIM(group_code) AS group_exemption_number,

        -- ============================================================
        -- Filing Info
        -- ============================================================
        TRIM(filing_req_code) AS filing_requirement_code,
        TRIM(pf_filing_req_code) AS pf_filing_requirement_code,
        TRIM(accounting_period) AS fiscal_year_end_month,

        -- ============================================================
        -- Size Codes (keep as VARCHAR — bucket codes, not amounts)
        -- ============================================================
        TRIM(asset_code) AS asset_size_code,
        TRIM(income_code) AS income_size_code,

        -- ============================================================
        -- Financial Amounts (cast to NUMBER — actual dollar values)
        -- ============================================================
        TRY_TO_NUMBER(asset_amt) AS total_assets,
        TRY_TO_NUMBER(income_amt) AS total_income,
        TRY_TO_NUMBER(revenue_amt) AS total_revenue,

        -- ============================================================
        -- Dates (parse from YYYYMM strings to DATE)
        -- ============================================================
        TRY_TO_DATE(ruling_date, 'YYYYMM') AS ruling_date,
        TRY_TO_DATE(tax_period, 'YYYYMM') AS latest_tax_period,

        -- ============================================================
        -- Decoded Labels (human-readable from cryptic codes)
        -- ============================================================

        -- Tax exempt type from subsection code
        CASE subsection_code
            WHEN '03' THEN '501(c)(3) Charitable'
            WHEN '04' THEN '501(c)(4) Social Welfare'
            WHEN '05' THEN '501(c)(5) Labor/Agriculture'
            WHEN '06' THEN '501(c)(6) Business League'
            WHEN '07' THEN '501(c)(7) Social/Recreational'
            WHEN '08' THEN '501(c)(8) Fraternal'
            WHEN '13' THEN '501(c)(13) Cemetery'
            WHEN '19' THEN '501(c)(19) Veterans'
            WHEN '01' THEN '501(c)(1) Congressional Corps'
            WHEN '02' THEN '501(c)(2) Title Holding'
            WHEN '09' THEN '501(c)(9) Employee Benefit (VEBA)'
            WHEN '10' THEN '501(c)(10) Domestic Fraternal'
            WHEN '12' THEN '501(c)(12) Benevolent Insurance'
            WHEN '14' THEN '501(c)(14) Credit Union'
            WHEN '15' THEN '501(c)(15) Mutual Insurance'
            WHEN '25' THEN '501(c)(25) Title Holding (Multiple)'
            ELSE '501(c)(' || subsection_code || ') Other'
        END AS tax_exempt_type,

        -- Foundation classification
        CASE
            WHEN foundation_code IN ('02', '03', '04') THEN 'Private Foundation'
            WHEN foundation_code IN ('10', '11', '12', '13', '14', '15', '16', '17', '18') THEN 'Public Charity'
            WHEN foundation_code = '00' THEN 'Not 501(c)(3)'
            ELSE 'Other/Unknown'
        END AS foundation_type,

        -- Tax deductibility as boolean
        CASE deductibility_code
            WHEN '1' THEN TRUE
            WHEN '2' THEN FALSE
            ELSE NULL
        END AS is_contributions_deductible,

        -- Filing requirement as readable label
        CASE
            WHEN filing_req_code = '01' THEN '990 (Full)'
            WHEN filing_req_code = '02' THEN '990-EZ (Simplified)'
            WHEN filing_req_code = '06' THEN '990-N (e-Postcard)'
            WHEN filing_req_code = '03' THEN '990-PF (Private Foundation)'
            WHEN filing_req_code = '00' THEN 'Not Required'
            ELSE 'Unknown'
        END AS filing_requirement,

        -- NTEE major category (first letter of ntee_code)
        LEFT(TRIM(ntee_code), 1) AS ntee_major_category,

        -- NTEE major category human-readable name
        CASE LEFT(TRIM(ntee_code), 1)
            WHEN 'A' THEN 'Arts, Culture, Humanities'
            WHEN 'B' THEN 'Education'
            WHEN 'C' THEN 'Environment'
            WHEN 'D' THEN 'Animal-Related'
            WHEN 'E' THEN 'Health'
            WHEN 'F' THEN 'Mental Health'
            WHEN 'G' THEN 'Disease/Disorder'
            WHEN 'H' THEN 'Medical Research'
            WHEN 'I' THEN 'Crime/Legal'
            WHEN 'J' THEN 'Employment'
            WHEN 'K' THEN 'Food/Agriculture'
            WHEN 'L' THEN 'Housing/Shelter'
            WHEN 'M' THEN 'Public Safety/Disaster'
            WHEN 'N' THEN 'Recreation/Sports'
            WHEN 'O' THEN 'Youth Development'
            WHEN 'P' THEN 'Human Services'
            WHEN 'Q' THEN 'International'
            WHEN 'R' THEN 'Civil Rights'
            WHEN 'S' THEN 'Community Improvement'
            WHEN 'T' THEN 'Philanthropy/Grantmaking'
            WHEN 'U' THEN 'Science/Technology'
            WHEN 'V' THEN 'Social Science'
            WHEN 'W' THEN 'Public/Society Benefit'
            WHEN 'X' THEN 'Religion'
            WHEN 'Y' THEN 'Mutual Benefit'
            WHEN 'Z' THEN 'Unknown'
            ELSE NULL
        END AS ntee_major_category_name,

        -- ============================================================
        -- Metadata (pass through from raw)
        -- ============================================================
        _loaded_at,
        _source_file

    FROM source
    WHERE ein IS NOT NULL  -- Drop rows with no EIN (can't identify or join them)
)

SELECT * FROM cleaned