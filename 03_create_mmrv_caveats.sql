   -- MMRV  caveats 

IF OBJECT_ID('tempdb..#MMRV_Cohorts') IS NOT NULL DROP TABLE #MMRV_Cohorts;
IF OBJECT_ID('tempdb..#MMRContainingSummary') IS NOT NULL DROP TABLE #MMRContainingSummary;

-- determine cohorts from ref tbl
;WITH MMRV_Bands AS
(
    SELECT DISTINCT
        CAST(DateValidFrom AS date) AS DOB_From,
        CAST(NULLIF(DateValidTo, '') AS date) AS DOB_To
    FROM [Reference].[dbo].[tbl_ref_AntigenRules_AntigensONLY]
    WHERE VaccineName IN ('MMRV-1','MMRV-2')
),
Numbered AS
(
    SELECT
        DOB_From,
        DOB_To,
        ROW_NUMBER() OVER (ORDER BY DOB_From DESC) AS rn
    FROM MMRV_Bands
)
SELECT
    CASE rn
        WHEN 1 THEN 1  -- cohort 1
        WHEN 2 THEN 2  -- cohort 2
        WHEN 3 THEN 3  -- cohort 3
    END AS MMRV_Cohort,
    DOB_From,
    ISNULL(DOB_To, '99991231') AS DOB_To
INTO #MMRV_Cohorts
FROM Numbered
WHERE rn <= 3;

-- to determine if first valid mmr cotaining vac is mmr or mmrv
;WITH CTE_MMRContaining AS
(
    SELECT
        m.NHSNumber,
        m.DOB,
        c.MMRV_Cohort,
        v.DateOfImmunisation,
        CASE
            WHEN v.VaccineCode IN ('MMR','MMRV') THEN 1
            ELSE 0
        END AS IsMMRContaining,
        CASE
            WHEN v.VaccineCode = 'MMRV' THEN 1
            ELSE 0
        END AS IsMMRV,
        CASE
            WHEN v.DateOfImmunisation >= DATEADD(MONTH, 12, m.DOB) THEN 1 ELSE 0
        END AS IsValidForSchedule
    FROM (SELECT DISTINCT NHSNumber, DOB FROM ##AntigensMet_2) m
    LEFT JOIN #MMRV_Cohorts c
        ON m.DOB >= c.DOB_From AND m.DOB <= c.DOB_To
    INNER JOIN [CHIS_DW].[dbo].[tbl_Immunisations_ByVaccine] v
        ON v.NHSNumber = m.NHSNumber
    WHERE  v.VaccineCode IN ('MMR','MMRV')

),

CTE_ValidSeq AS
(
    SELECT
        NHSNumber,
        DOB,
        MMRV_Cohort,
        DateOfImmunisation,
        IsMMRV,
        ROW_NUMBER() OVER (PARTITION BY NHSNumber ORDER BY DateOfImmunisation, IsMMRV DESC) AS DoseSeq
    FROM CTE_MMRContaining
    WHERE IsMMRContaining = 1
      AND IsValidForSchedule = 1  -- Under-12-month doses excluded
),
CTE_Summary AS
(
    SELECT
        NHSNumber,
        MAX(DOB) AS DOB,
        MAX(MMRV_Cohort) AS MMRV_Cohort,
        COUNT(1) AS ValidMMRContainingDoseCount,
        SUM(CASE WHEN IsMMRV = 1 THEN 1 ELSE 0 END) AS MMRVDoseCount,
        MIN(CASE WHEN IsMMRV = 1 THEN DateOfImmunisation END) AS FirstMMRVDoseDate,
        MAX(CASE WHEN DoseSeq = 1 THEN DateOfImmunisation END) AS Dose1Date,
        MAX(CASE WHEN DoseSeq = 1 THEN IsMMRV END) AS Dose1IsMMRV,
        MAX(CASE WHEN DoseSeq = 2 THEN DateOfImmunisation END) AS Dose2Date,
        MAX(CASE WHEN DoseSeq = 2 THEN IsMMRV END) AS Dose2IsMMRV
    FROM CTE_ValidSeq
    GROUP BY NHSNumber
)
-- derrive caveat flags
SELECT
    s.NHSNumber,
    s.MMRV_Cohort,
    ISNULL(s.Dose1IsMMRV, 0) AS Dose1IsMMRV,
    ISNULL(s.Dose2IsMMRV, 0) AS Dose2IsMMRV,
    s.Dose1Date,
    s.Dose2Date,
    ISNULL(s.MMRVDoseCount, 0) AS MMRVDoseCount,
    s.FirstMMRVDoseDate,
    ISNULL(s.ValidMMRContainingDoseCount, 0) AS MMRContainingValidDoseCount,
    CASE
        WHEN CAST(GETDATE() AS date) >= CAST('20260101' AS DATE)
         AND s.MMRV_Cohort IN (1,2,3)
         AND ISNULL(s.ValidMMRContainingDoseCount, 0) < 2
        THEN 1 ELSE 0
    END AS MMRV_CatchUp_UseMMRV_From20260101,
    CASE
        WHEN s.MMRV_Cohort = 2
         AND ISNULL(s.ValidMMRContainingDoseCount, 0) >= 2
         AND s.Dose1IsMMRV = 1 AND s.Dose2IsMMRV = 1
        THEN 1 ELSE 0
    END AS Cohort2_TwoMMRV_NoThirdNeeded,
    CASE
        WHEN s.MMRV_Cohort = 3
         AND ISNULL(s.ValidMMRContainingDoseCount, 0) = 1
         AND s.Dose1IsMMRV = 1
         AND CAST(GETDATE() AS date) >= DATEADD(MONTH, 40, s.DOB)  -- 3y 4m
        THEN 1 ELSE 0
    END AS Cohort3_FirstIsMMRV_InviteSecondAt3y4m,
    CASE
        WHEN s.MMRV_Cohort = 3
         AND ISNULL(s.ValidMMRContainingDoseCount, 0) = 1
         AND s.Dose1IsMMRV = 1
         AND s.Dose1Date < DATEADD(MONTH, 40, s.DOB)  -- MMRV1 before 3y 4m
        THEN 1 ELSE 0
    END AS Cohort3_MMRV2_Action_LateAttenderRisk
INTO #MMRContainingSummary
FROM CTE_Summary s; 

--Hard coded flag amendment for MenB as it does not fit the same formula as the other imms
UPDATE ##AntigensMet_2
SET DosesRequired = 2
	,MetFlag = 1	
WHERE NHSNumber IN (
						SELECT NHSNumber
						FROM ##AntigensMet_2
						WHERE AntigenName =  'Menb'
							AND VaccineGroup = '12 Month' -- CHANGE
							AND NHSNumber IN (SELECT NHSNumber
												FROM ##AntigensMet_2
												WHERE AntigenName =  'Menb'
													AND VaccineGroup = 'Primary'
													AND MetFlag = 0))
	AND AntigenName =  'Menb'
	AND VaccineGroup = '12 Month'
UPDATE ##AntigensMet_2
	SET MetFlag = NULL
UPDATE ##AntigensMet_2
	SET MetFlag = 1
	WHERE ValidDosesGiven >=DosesRequired
UPDATE ##AntigensMet_2
	SET MetFlag = 0
	WHERE MetFlag IS NULL

-- adjust for children over 10 to no longer flag Pert as being needed over 10
UPDATE am2
SET  MetFlag = 1
	,ValidDosesGiven = DosesRequired
FROM ##AntigensMet_2 am2
WHERE am2.AntigenName = 'PERT'
  AND am2.VaccineName IN ('6IN1-Primary','6IN1-18Month','4IN1') -- CHANGE
  AND DATEDIFF(YEAR, am2.DOB, GETDATE()) > 10;


-- update those still required flags for MMR caveats
IF OBJECT_ID('tempdb..#MMRVCaveatChildAgg') IS NOT NULL DROP TABLE #MMRVCaveatChildAgg;

SELECT
      s.NHSNumber
    , s.MMRV_Cohort
    , s.Dose1IsMMRV
    , s.Dose2IsMMRV   
    , s.MMRVDoseCount
    , s.FirstMMRVDoseDate
    , s.MMRContainingValidDoseCount
    , s.MMRV_CatchUp_UseMMRV_From20260101
    , s.Cohort2_TwoMMRV_NoThirdNeeded
    , s.Cohort3_FirstIsMMRV_InviteSecondAt3y4m
    , s.Cohort3_MMRV2_Action_LateAttenderRisk
INTO #MMRVCaveatChildAgg
FROM #MMRContainingSummary s;

-- MMR(V)-1 should represent TOTAL valid MMR-containing doses (MMR or MMRV),
UPDATE am
SET
    am.ValidDosesGiven = CASE
        WHEN ISNULL(s.MMRContainingValidDoseCount,0) >= 2 THEN 2
        WHEN ISNULL(s.MMRContainingValidDoseCount,0) = 1 THEN 1
        ELSE 0
    END,
    am.MetFlag = CASE WHEN ISNULL(s.MMRContainingValidDoseCount,0) >= 1 THEN 1 ELSE 0 END
FROM ##AntigensMet_2 am
INNER JOIN #MMRContainingSummary s
    ON s.NHSNumber = am.NHSNumber
WHERE am.VaccineName = 'MMR(V)-1';

-- Ensure MMR-1 never exceeds 1 dose
UPDATE am
SET am.ValidDosesGiven = CASE WHEN am.ValidDosesGiven > 1 THEN 1 ELSE am.ValidDosesGiven END,
    am.MetFlag         = CASE WHEN am.ValidDosesGiven > 0 THEN 1 ELSE 0 END
FROM ##AntigensMet_2 am
WHERE am.VaccineName = 'MMR-1';

-- Ensure MMRV-1 / MMRV-2 dose counts only reflect ACTUAL MMRV doses

UPDATE am
SET
    am.ValidDosesGiven = CASE WHEN ISNULL(c.MMRVDoseCount,0) >= 1 THEN 1 ELSE 0 END,
    am.MetFlag         = CASE WHEN ISNULL(c.MMRVDoseCount,0) >= 1 THEN 1 ELSE 0 END
FROM ##AntigensMet_2 am
INNER JOIN #MMRVCaveatChildAgg c
    ON am.NHSNumber = c.NHSNumber
WHERE am.VaccineName = 'MMRV-1';

UPDATE am
SET
    am.ValidDosesGiven = CASE WHEN ISNULL(c.MMRVDoseCount,0) >= 2 THEN 1 ELSE 0 END,
    am.MetFlag         = CASE WHEN ISNULL(c.MMRVDoseCount,0) >= 2 THEN 1 ELSE 0 END
FROM ##AntigensMet_2 am
INNER JOIN #MMRVCaveatChildAgg c
    ON am.NHSNumber = c.NHSNumber
WHERE am.VaccineName = 'MMRV-2';
