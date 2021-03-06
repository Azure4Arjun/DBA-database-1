SET QUOTED_IDENTIFIER ON
GO
SET ANSI_NULLS ON
GO
--=============================================
-- Copyright (C) 2018 Raul Gonzalez, @SQLDoubleG
-- All rights reserved.
--   
-- You may alter this code for your own *non-commercial* purposes. You may
-- republish altered code as long as you give due credit.
--   
-- THIS CODE AND INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF 
-- ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED 
-- TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A
-- PARTICULAR PURPOSE.
--
-- =============================================
-- Author:		Raul Gonzalez
-- Create date: 02/07/2013
-- Description:	Returns Jobs Defined for the Server and their schedules
--
--	Values taken from 
--	http://msdn.microsoft.com/en-us/library/ms178644.aspx
--
-- Dependencies: Bit values for the days of the week are taken from [DBA].[dbo].[DaysOfWeekBitWise]
--					Duration is calculated using the function [DBA].[dbo].[formatMStimeToHR]
--
-- Permissions:
--				GRANT EXECUTE ON [DBA].[dbo].[DBA_jobsHistory] TO [dbaMonitoringUser]
-- 
-- Log History:	
--				29/04/2015 RAG -- Added Parameter @includeSteps to display info for each step of a job
--				07/05/2015 RAG -- Added Parameters @jobName and @includeLastNexecutions to filter by name and display some history
--				13/04/2016 SZO -- Added element to ORDER BY clause so results returned by step_id with result step (step 0) returned last.
--				21/04/2016 SZO -- Modified ORDER BY clause so results display as shown in SQL Agent View History Window.
--				22/04/2016 RAG -- Renamed to [dbo].[DBA_jobsHistory] as [dbo].[DBA_jobsDescription] now will show only information about jobs, not history
--				30/06/2016 RAG -- Added column server_name and EXECUTE AS 'dbo' due to this SP will be called by dbaMonitoringUser
--				20/10/2018 RAG - Added column [job_id_binary] to help locate output files when they user the token $(JOBID)
--				22/11/2018 RAG 	- Added columns jobsteps.subsystem and jobsteps.command
--								- Added parameter @commandText to filter the job step command text
--				21/02/2019 RAG 	- Fixed multiple rows per job due to adding steps
--				15/03/2019 RAG 	- Added active_start_time and active_time for schedules
--								- Other fixes 
--				19/03/2019 RAG 	- Changed to FULL OUTER JOIN from jobhistory to jobsteps as there is Step 0 in jobhistory that does not exist as such
--								- Changed column [schedules] to concatenate multiple schedules with [AND] as multiple schedules returned multiple rows
--				20/03/2019 RAG 	- Added ISNULL for null columns when there is no history for a job
--								- Added column last_run_duration
--								- Removed comments
--
-- =============================================
CREATE PROCEDURE [dbo].[DBA_jobsHistory]
	@onlyActiveJobs				BIT = 0
	, @includeSteps				BIT = 0
	, @jobName					SYSNAME = NULL
	, @commandText				SYSNAME = NULL	
	, @includeLastNexecutions	INT = 1
WITH EXECUTE AS 'dbo'
AS
BEGIN
	
SET NOCOUNT ON

IF ISNULL(@commandText, '')	<> '' SET @includeSteps = 1

SET @includeLastNexecutions = ISNULL(@includeLastNexecutions, 1)

IF OBJECT_ID('tempdb..#jobHistory')			IS NOT NULL DROP TABLE #jobHistory
IF OBJECT_ID('tempdb..#jobs')				IS NOT NULL DROP TABLE #jobs
IF OBJECT_ID('tempdb..#monthlyRelative')	IS NOT NULL DROP TABLE #monthlyRelative

CREATE TABLE #monthlyRelative (ID TINYINT NOT NULL, Name VARCHAR(15) NOT NULL)
INSERT INTO #monthlyRelative
	VALUES (1, 'Sunday')
			, (2, 'Monday')
			, (3, 'Tuesday')
			, (4, 'Wednesday')
			, (5, 'Thursday')
			, (6, 'Friday')
			, (7, 'Saturday')
			, (8, 'Day')
			, (9, 'Weekday')
			, (10, 'Weekend day')

--Get all jobs we're interested
SELECT * 
	INTO #jobs
	FROM msdb.dbo.sysjobs AS j
	WHERE (( @onlyActiveJobs = 1 AND j.enabled = 1 ) OR @onlyActiveJobs = 0)
		AND j.name LIKE ISNULL(@jobName, j.name)
		
-- Take from history, the last run for each job
;WITH CTE AS(
	SELECT 	j.name AS job_name
			, ISNULL(js.job_id, jh.job_id) AS job_id
			, jh.instance_id
			, ISNULL(js.step_id, jh.step_id) AS step_id
			, ISNULL(js.step_name, jh.step_name) AS step_name
			, jh.run_date
			, jh.run_status
			, jh.run_time
			, jh.run_duration
			, ISNULL(js.subsystem, '-') AS subsystem
			, ISNULL(js.command, '-') AS command
			, ROW_NUMBER() OVER (PARTITION BY jh.job_id, jh.step_id ORDER BY jh.run_date DESC, run_time DESC) AS rowNumber		
		-- SELECT *
		FROM #jobs AS j
			FULL OUTER JOIN msdb.dbo.sysjobsteps AS js
				ON js.job_id = j.job_id
			FULL OUTER JOIN msdb.dbo.sysjobhistory AS jh
				ON jh.job_id = js.job_id
					AND jh.step_id = js.step_id
		WHERE jh.step_id = 0 OR @includeSteps = 1
	)
	SELECT * 
		INTO #jobHistory
		FROM CTE
	WHERE rowNumber <= @includeLastNexecutions

-- Get final results
SELECT  @@SERVERNAME AS server_name
		, j.job_id
		, CONVERT(VARBINARY(85), j.job_id) AS job_id_binary
		, j.name AS job_name
		, ISNULL(jh.step_id, '-')   AS step_id
		, ISNULL(jh.step_name, '-')	AS step_name
		, ISNULL(jh.subsystem, '-')   AS subsystem
		, ISNULL(jh.command, '-')	AS command
		, CASE WHEN jh.run_date <> 0 THEN 
			(CONVERT(VARCHAR, CONVERT(DATE, 
					SUBSTRING(CONVERT(VARCHAR(8),jh.run_date), 1,4)		+ '-' +
					SUBSTRING(CONVERT(VARCHAR(8),jh.run_date), 5,2)		+ '-' +
					SUBSTRING(CONVERT(VARCHAR(8),jh.run_date), 7,2))))	+ ' ' +
				[DBA].[dbo].[formatMStimeToHR](jh.run_time)
			ELSE '-'
		END AS last_run
		, [DBA].[dbo].[formatMStimeToHR](jh.run_duration) AS last_run_duration
		, STUFF((SELECT  ' [AND] ' + 
					CASE 
						WHEN s.freq_type = 1	THEN 'Once'					
						WHEN s.freq_type = 4	THEN 'Every' + CASE WHEN s.freq_interval > 1 THEN ' ' ELSE '' END + ISNULL(NULLIF(CONVERT(VARCHAR, s.freq_interval),1),'') + ' Day' + CASE WHEN s.freq_interval > 1 THEN 's' ELSE '' END
						WHEN s.freq_type = 8	THEN -- Weekly
														ISNULL( STUFF( (SELECT N', ' + name 
																			FROM DBA.dbo.DaysOfWeekBitWise AS B 
																			WHERE B.bitValue & s.freq_interval = B.bitValue 
																				AND s.freq_type = 8
																			FOR XML PATH('') ), 1, 2, '' ), 'None' )
						WHEN s.freq_type = 16	THEN 'Every ' + CONVERT(VARCHAR, s.freq_interval) + ' of the month'
						WHEN s.freq_type = 32	THEN 
														CASE 
															WHEN s.freq_relative_interval = 1	THEN 'First ' 
															WHEN s.freq_relative_interval = 2	THEN 'Second ' 
															WHEN s.freq_relative_interval = 4	THEN 'Third ' 
															WHEN s.freq_relative_interval = 8	THEN 'Fourth ' 
															WHEN s.freq_relative_interval = 16	THEN 'Last ' 
														END
														+ (SELECT Name FROM #monthlyRelative WHERE ID = s.freq_interval) + ' of the month'
						WHEN s.freq_type = 64	THEN 'Starts when SQL Server Agent service starts'
						WHEN s.freq_type = 128	THEN 'Runs when computer is idle'
						ELSE 'None'
					END 
					+ 
					CASE s.freq_subday_type 
						WHEN 1 THEN ' @ ' + 
							SUBSTRING( RIGHT('000000' + CONVERT(VARCHAR(6),s.active_start_time), 6), 1, 2) + ':' + 
							SUBSTRING( RIGHT('000000' + CONVERT(VARCHAR(6),s.active_start_time), 6), 3, 2) + ':' + 
							SUBSTRING( RIGHT('000000' + CONVERT(VARCHAR(6),s.active_start_time), 6), 5, 2) 
						WHEN 2 THEN '. Every ' + CONVERT(VARCHAR,s.freq_subday_interval) + ' second'	+ CASE WHEN s.freq_subday_interval > 1 THEN 's' ELSE '' END
						WHEN 4 THEN '. Every ' + CONVERT(VARCHAR,s.freq_subday_interval) + ' minute'	+ CASE WHEN s.freq_subday_interval > 1 THEN 's' ELSE '' END
						WHEN 8 THEN '. Every ' + CONVERT(VARCHAR,s.freq_subday_interval) + ' hour'		+ CASE WHEN s.freq_subday_interval > 1 THEN 's' ELSE '' END
						ELSE ''
					END + 
					CASE s.freq_subday_type 
						WHEN 1 THEN ''
						ELSE ', From ' + [DBA].[dbo].[formatMStimeToHR](s.active_start_time) + ' till ' + [DBA].[dbo].[formatMStimeToHR](s.active_end_time)			
					END
				FROM msdb.dbo.sysjobschedules AS jsch
					INNER JOIN msdb.dbo.sysschedules AS s
						ON s.schedule_id = jsch.schedule_id
				WHERE jsch.job_id = j.job_id
				FOR XML PATH('')), 1, 7, '') AS schedules
	FROM #jobs AS j
		FULL OUTER JOIN #jobHistory AS jh
			ON jh.job_id = j.job_id
				AND (jh.step_id = 0 OR @includeSteps = 1)
	WHERE ISNULL(jh.command, '') LIKE '%' + ISNULL(@commandText, '') + '%'
	ORDER BY job_name, jh.rowNumber, CASE WHEN jh.step_id = 0 THEN POWER(2, 30) ELSE jh.step_id END DESC, jh.instance_id DESC
	
DROP TABLE #jobHistory
DROP TABLE #jobs
DROP TABLE #monthlyRelative
END
GO
GRANT EXECUTE ON  [dbo].[DBA_jobsHistory] TO [dbaMonitoringUser]
GO
