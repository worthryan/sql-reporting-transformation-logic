--Start to aggregage all of the code together
SELECT NHSNumber, VaccineName, MIN(MetFlag) AS MinMetFlag
INTO  ##VaccinesMet
FROM ##AntigensMet_2
GROUP BY NHSNumber,VaccineName
CREATE CLUSTERED INDEX [NHS_Idx] ON ##VaccinesMet ([NHSNumber] ASC)

-- select * from ##VaccinesMet

--Start to aggregage all of the code together
SELECT NHSNumber, Anti.VaccineName,Anti.VaccineGroup, MIN(MetFlag) AS MinMetFlag, 
CASE 
	WHEN Anti.VaccineName = 'ROTA' AND Anti.ValidDosesGiven = 0 AND Anti.DosesRequired = 2 THEN 0
	WHEN Ref IS NULL THEN 0 ELSE 1
END StillNeeded
INTO  ##VaccinesMet_2
FROM ##AntigensMet_2 Anti
LEFT JOIN [Reference].[dbo].[tbl_ref_AntigenRules_AntigensONLY]  ar 
  -- Does today fall between the timeframes for when the Antigen is due to be given to the child?
		ON GETDATE() > [analysts].[dbo].[ConvertDate]([DOB],ar.[AgeMissingFromValue],ar.AgeMissingFromUnit) 
		AND GETDATE() < [analysts].[dbo].[ConvertDate]([DOB],ar.[AgeMissingtoValue], ar.[AgeMissingToUnit])
		AND AntigenRef = Ref
GROUP BY NHSNumber, Anti.VaccineName, CASE WHEN Anti.VaccineName = 'ROTA' AND Anti.ValidDosesGiven = 0 AND Anti.DosesRequired = 2 THEN 0
WHEN Ref IS NULL THEN 0 ELSE 1 END, Anti.VaccineGroup

CREATE CLUSTERED INDEX [NHS_Idx] ON ##VaccinesMet_2 ([NHSNumber] ASC)
CREATE INDEX [VaccGroup_Idx] ON ##VaccinesMet_2 ([VaccineGroup] ASC)

-- Speeds frequent updates filtered by VaccineName and joins by NHSNumber + VaccineName
CREATE NONCLUSTERED INDEX IX_VaccinesMet2_NHS_VaccineName
ON ##VaccinesMet_2 (NHSNumber, VaccineName)
INCLUDE (VaccineGroup, StillNeeded, MinMetFlag);

UPDATE v
SET v.StillNeeded = 0
FROM ##VaccinesMet_2 v
INNER JOIN #MMRVCaveatChildAgg c
    ON v.NHSNumber = c.NHSNumber
WHERE c.MMRV_CatchUp_UseMMRV_From20260101 = 1
  AND v.VaccineName IN ('MMR-1','MMR-2')
  AND ISNULL(v.MinMetFlag,0) = 0; 

-- If catch-up policy applies and FIRST MMR-containing dose was NOT MMRV, flag MMRV-1 as still needed (Cohort 3+)
UPDATE v_mmrsv
SET v_mmrsv.StillNeeded = 1
FROM ##VaccinesMet_2 v_mmrsv
INNER JOIN #MMRVCaveatChildAgg c
    ON v_mmrsv.NHSNumber = c.NHSNumber
WHERE c.MMRV_CatchUp_UseMMRV_From20260101 = 1
  AND c.MMRV_Cohort >= 3
  AND ISNULL(c.Dose1IsMMRV,0) = 0
  AND v_mmrsv.VaccineName = 'MMRV-1'
  AND ISNULL(v_mmrsv.MinMetFlag,0) = 0;

-- If MMR-2 is still needed, set MMRV-2 to still needed
UPDATE v_mmrsv
SET v_mmrsv.StillNeeded = 1
FROM ##VaccinesMet_2 v_mmrsv
INNER JOIN #MMRVCaveatChildAgg c
    ON v_mmrsv.NHSNumber = c.NHSNumber
INNER JOIN ##VaccinesMet_2 v_mmr
    ON v_mmr.NHSNumber = c.NHSNumber
   AND v_mmr.VaccineName = 'MMR-2'
WHERE c.MMRV_CatchUp_UseMMRV_From20260101 = 1
  AND c.MMRContainingValidDoseCount < 2
  AND v_mmr.StillNeeded = 1
  AND v_mmrsv.VaccineName = 'MMRV-2';

--  Cohort 2: if first two MMR-containing doses are BOTH MMRV,
--    no further MMRV neeeded

UPDATE v
SET v.StillNeeded = 0
FROM ##VaccinesMet_2 v
INNER JOIN #MMRVCaveatChildAgg c
    ON v.NHSNumber = c.NHSNumber
WHERE c.Cohort2_TwoMMRV_NoThirdNeeded = 1
  AND v.VaccineName IN ('MMRV-2');

--  Cohort 3: If first valid MMR-containing dose was MMRV,
--    second invite should be MMRV at 3y4m

UPDATE v
SET v.StillNeeded = 0
FROM ##VaccinesMet_2 v
INNER JOIN #MMRVCaveatChildAgg c
    ON v.NHSNumber = c.NHSNumber
WHERE c.Cohort3_FirstIsMMRV_InviteSecondAt3y4m = 1
  AND v.VaccineName = 'MMR-2';

UPDATE v_mmrsv
SET v_mmrsv.StillNeeded = 1
FROM ##VaccinesMet_2 v_mmrsv
INNER JOIN #MMRVCaveatChildAgg c
    ON v_mmrsv.NHSNumber = c.NHSNumber
WHERE c.Cohort3_FirstIsMMRV_InviteSecondAt3y4m = 1
  AND v_mmrsv.VaccineName = 'MMRV-2';

--  Cohort 3 late attenders

UPDATE v
SET v.StillNeeded = 0
FROM ##VaccinesMet_2 v
INNER JOIN #MMRVCaveatChildAgg c
    ON v.NHSNumber = c.NHSNumber
WHERE c.Cohort3_MMRV2_Action_LateAttenderRisk = 1
  AND v.VaccineName = 'MMR-2';

UPDATE v_mmrsv
SET v_mmrsv.StillNeeded = 1
FROM ##VaccinesMet_2 v_mmrsv
INNER JOIN #MMRVCaveatChildAgg c
    ON v_mmrsv.NHSNumber = c.NHSNumber
WHERE c.Cohort3_MMRV2_Action_LateAttenderRisk = 1
  AND v_mmrsv.VaccineName = 'MMRV-2';

-- Cohort 3: If neither Cohort3 action applies, MMRV-2 is not required
UPDATE v_mmrsv
SET v_mmrsv.StillNeeded = 0
FROM ##VaccinesMet_2 v_mmrsv
INNER JOIN #MMRVCaveatChildAgg c
    ON v_mmrsv.NHSNumber = c.NHSNumber
WHERE c.MMRV_Cohort = 3
  AND v_mmrsv.VaccineName = 'MMRV-2'
  AND ISNULL(c.Cohort3_FirstIsMMRV_InviteSecondAt3y4m, 0) = 0
  AND ISNULL(c.Cohort3_MMRV2_Action_LateAttenderRisk, 0) = 0;

----------------------------------------------------------------
--    6IN1 
--    If a child receives ANY 6IN1 dose AFTER 12 months of age,
--    they do NOT require the new 18-month 6IN1
----------------------------------------------------------------
IF OBJECT_ID('tempdb..#SixInOneAfter12M') IS NOT NULL DROP TABLE #SixInOneAfter12M;

SELECT DISTINCT
    v.NHSNumber
INTO #SixInOneAfter12M
FROM [CHIS_DW].[dbo].[tbl_Immunisations_ByVaccine] v
INNER JOIN (SELECT DISTINCT NHSNumber, DOB FROM ##AntigensMet_2) d
    ON d.NHSNumber = v.NHSNumber
WHERE
    v.DateOfImmunisation >= DATEADD(MONTH, 12, d.DOB)
    AND v.VaccineCode IN ('6IN1')
    ;

UPDATE v18
SET
    v18.StillNeeded = 0
FROM ##VaccinesMet_2 v18
INNER JOIN #SixInOneAfter12M s
    ON s.NHSNumber = v18.NHSNumber
WHERE v18.VaccineName = '6IN1-18Month';


UPDATE ##VaccinesMet_2
SET StillNeeded = 0, MinMetFlag = 1
WHERE VaccineName = 'HIBMENC'
	AND NHSNUMBER IN (SELECT NHSNUMBER FROM ##AntigensMet_2
										WHERE ANTIGENNAME = 'HIB'
											AND METFLAG = 1)
		AND NHSNUMBER IN (SELECT bv.[NHSNumber] FROM [CHIS_DW].[dbo].[tbl_Immunisations_ByVaccine] bv
											LEFT JOIN [CHIS_DW].[dbo].[tbl_Demographic_Details] dd
											ON dd.NHSNumber = bv.NHSNumber
											WHERE VACCINEDESC = 'Meningitis ACWY'
												AND [DateOfImmunisation] >= [analysts].[dbo].[ConvertDate](dd.DOB,51,'WEEK')
												)
			AND NHSNUMBER IN (SELECT NHSNUMBER FROM ##AntigensMet_2 
											WHERE ANTIGENNAME = 'MENC'
												AND METFLAG = 0)

SELECT NHSNumber, VaccineName, MIN(ValidDosesGiven) as ValidDosesGiven
INTO  ##DosesGiven 
FROM ##AntigensMet_2
GROUP BY [VaccineGroup], NHSNumber, VaccineName

CREATE CLUSTERED INDEX [NHS_Idx] ON ##DosesGiven([NHSNumber] ASC)
CREATE NONCLUSTERED INDEX IX_DosesGiven_NHS_VaccineName ON ##DosesGiven (NHSNumber, VaccineName) INCLUDE (ValidDosesGiven);

SELECT NHSNumber, VaccineName, MAX(DosesRequired) as DosesRequired
INTO ##DosesRequired
FROM ##AntigensMet_2
GROUP BY [VaccineGroup], NHSNumber, VaccineName

CREATE CLUSTERED INDEX [NHS_Idx] ON ##DosesRequired([NHSNumber] ASC)
CREATE NONCLUSTERED INDEX IX_DosesRequired_NHS_VaccineName ON ##DosesRequired (NHSNumber, VaccineName) INCLUDE (DosesRequired);

UPDATE v
SET v.MinMetFlag = 1
FROM ##VaccinesMet_2 v
INNER JOIN ##DosesGiven dg
    ON dg.NHSNumber = v.NHSNumber
   AND dg.VaccineName = v.VaccineName
INNER JOIN ##DosesRequired dr
    ON dr.NHSNumber = v.NHSNumber
   AND dr.VaccineName = v.VaccineName
WHERE v.VaccineName IN ('MMR-1','MMR-2')
  AND ISNULL(dr.DosesRequired,0) > 0
  AND ISNULL(dg.ValidDosesGiven,0) >= dr.DosesRequired;

UPDATE v
SET v.MinMetFlag = 0
FROM ##VaccinesMet_2 v
INNER JOIN ##DosesGiven dg
    ON dg.NHSNumber = v.NHSNumber
   AND dg.VaccineName = v.VaccineName
INNER JOIN ##DosesRequired dr
    ON dr.NHSNumber = v.NHSNumber
   AND dr.VaccineName = v.VaccineName
WHERE v.VaccineName IN ('MMR-1','MMR-2')
  AND ISNULL(dr.DosesRequired,0) > 0
  AND ISNULL(dg.ValidDosesGiven,0) < dr.DosesRequired;