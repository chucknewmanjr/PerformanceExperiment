/*
	===========================================================================
	========================== PERFORMANCE EXPERIMENT =========================
	Try to make this run faster and without adding issues like deadlocks.
	Change procs, indexing or values. But avoid changing the columns in tables.
	Requires SQL Server 2022 (V16).
	To test it, run this script. (Takes a couple minutes.)
	And then run the following statement in 5 query windows
	so that they all run at the same time. (Takes a minute.)

		use [PerformanceExperiment];
		exec [dbo].[p_RunProcessTransactions];

	Once they're all done, run the following to check the results.

		use [PerformanceExperiment];
		exec [dbo].[p_PerformanceReport];

	After that, make some improvements and repeat the process.

	===========================================================================
*/

/*
	-- drop everything
	USE [PerformanceExperiment];
	drop proc if exists [dbo].[p_StartLogging];
	drop proc if exists [dbo].[p_EndLogging];
	drop proc if exists [dbo].[p_PerformanceReport];
	drop proc if exists [dbo].[p_ProcessTransactions];
	drop proc if exists [dbo].[p_RunProcessTransactions];
	drop proc if exists [dbo].[p_StageFakeTransactions];
	drop table if exists [dbo].[AppSetting];
	drop table if exists [dbo].[Staging];
	drop table if exists [dbo].[Transaction];
	drop table if exists [dbo].[User];
	-- drop table if exists [dbo].[Log];
--*/

USE [PerformanceExperiment];
GO

-- ============================================================================
-- DROP TABLES
-- ============================================================================

drop table if exists [dbo].[Staging];
drop table if exists [dbo].[Transaction];
drop table if exists [dbo].[User];
drop table if exists [dbo].[AppSetting];
go

-- ============================================================================
-- APP SETTINGS
-- ============================================================================

CREATE TABLE [dbo].[AppSetting] (AppSettingName sysname PRIMARY KEY, AppSettingValue int not null);
GO

insert [dbo].[AppSetting] values
	('NUMBER OF USERS', 5), -- tinyint. More users mean more sessions.
	('RUN SECONDS LIMIT', 60), -- How long should the test run.
	('SECONDS BETWEEN RUNS', 80), -- For spotting individual runs. must be more than limit.
	('PROCESS TRANSACTIONS ROW COUNT', 10e3), -- 10e3 is 10K. Rows processed in each loop.
	('REPORTING FREQUENCY', 50); -- How oftern to run p_LocksAndBlocks.
go

create or alter function [dbo].[p_GetAppSetting] (@AppSettingName sysname) returns int begin;
	return (
		select AppSettingValue 
		from [dbo].[AppSetting] with (nolock) 
		where AppSettingName = @AppSettingName
	);
end;
go

-- ============================================================================
-- USERS
-- ============================================================================

CREATE TABLE [dbo].[User] (
	UserID tinyint NOT NULL PRIMARY KEY, 
	IsProcessing bit NOT NULL DEFAULT 0 -- only 1 process per user at a time.
);
GO

insert [dbo].[User] (UserID)
select value from generate_series(1, [dbo].[p_GetAppSetting]('NUMBER OF USERS'))
except
select UserID from [dbo].[User];

update [dbo].[User] set IsProcessing = 0 where IsProcessing = 1;
go

-- ============================================================================
-- STAGING
-- ============================================================================

create table [dbo].[Staging] (
	StagingID int not null
		identity 
		primary key,
	UserID tinyint not null 
		references [dbo].[User] (UserID),
	StagingValue varchar(200) not null,
	ProcessDate datetime null
);
go

create or alter proc [dbo].[p_StageFakeTransactions] (
	@RowCount int = 10e3,
	@UserID tinyint = null
) as;
	/*
		How can we fake staging transactions?
		There are a lot of rows in sys.all_columns. Let's use that. 10K is the max.
	*/
	set nocount on;

	if @RowCount > 10e3 throw 50000, '@RowCount cannot exceed 10K.', 1;

	declare @NumberOfUsers int = [dbo].[p_GetAppSetting]('NUMBER OF USERS');

	with t as (
		select cast(abs(object_id) as bigint) * 142 + column_id as x
		from sys.all_columns
	)
	insert [dbo].[Staging] (UserID, StagingValue)
	select top (@RowCount)
		isnull(@UserID, x % @NumberOfUsers + 1),
		convert(varchar(max), HASHBYTES('SHA2_512', CONCAT(x, SYSDATETIME())), 2)
	from t;
GO

-- Clean up Staging table
declare @RowCount int = 1e6; -- 1e6 is 1 million. Staging 1 million rows takes a couple minutes.

while (select sum(rows) from sys.partitions where object_id = OBJECT_ID('dbo.Staging')) < @RowCount
	exec [dbo].[p_StageFakeTransactions];
go

update [dbo].[Staging] set ProcessDate = null where ProcessDate is not null;
go

-- ============================================================================
-- LOGGING
-- ============================================================================

-- drop table [dbo].[Log];
-- truncate table [dbo].[Log];
if OBJECT_ID('[dbo].[Log]') is null
	create table [dbo].[Log] (
		LogID int identity primary key,
		UserID tinyint not null,
		[RowCount] int not null,
		SPID int not null,
		StartTime datetime2(7) not null default sysdatetime(),
		EndTime datetime2(7) null,
		SelectCount int null,
		UpdateCount int null
	);
go

create or alter proc [dbo].[p_StartLogging] (@UserID tinyint, @RowCount int) as;
	insert [dbo].[Log] (UserID, [RowCount], SPID) values (@UserID, @RowCount, @@SPID);

	return scope_identity();
go

create or alter proc [dbo].[p_EndLogging] (
	@LogID int, @SelectCount int, @UpdateCount int
) as;
	update [dbo].[Log] 
	set EndTime = SYSDATETIME(), SelectCount = @SelectCount, UpdateCount = @UpdateCount 
	where LogID = @LogID;
go

create or alter proc [dbo].[p_PerformanceReport] as;
	/*
		spot individual runs by looking for time gaps between runs.

		use [PerformanceExperiment];
		exec [dbo].[p_PerformanceReport];
	*/
	with run as (
		select 
			LAG(StartTime) over (order by LogID) as PreviousStartTime,
			StartTime, 
			DATEDIFF(second, LAG(StartTime) over (order by LogID), StartTime) as Diff
		from [dbo].[Log]
	)
	select 
		identity(int) as Run
		, StartTime as FromTime
		, isnull(lead(PreviousStartTime) over (order by StartTime), '9999-12-31') as ToTime
	into #run
	from run
	where Diff is null or Diff > [dbo].[p_GetAppSetting]('SECONDS BETWEEN RUNS');

	-- performance report
	select 
		r.Run, 
		count(distinct l.SPID) as [Users],
		SUM(l.[RowCount]) / 1000 as TotalRowsK,
		iif(SUM(l.[RowCount]) = SUM(l.UpdateCount), 'fine', 'mismatch') as Warning,
		format(min(r.FromTime), 'yyyy-MM-dd hh:mm:ss') as FromTime,
		cast(round(DATEDIFF(MILLISECOND, MIN(l.StartTime), MAX(l.EndTime)) / 1000.0, 0) as real) as Secs,
		cast(round(SUM(l.[RowCount]) * 1000.0 / DATEDIFF(MILLISECOND, MIN(l.StartTime), MAX(l.EndTime)), 0) as real) as Rows_Per_Sec
	from #run r
	join [dbo].[Log] l on l.StartTime between r.FromTime and r.ToTime
	group by r.Run;
go

-- ============================================================================
-- TRANSACTION TABLE
-- ============================================================================

create table [dbo].[Transaction] (
	TransactionID int not null
		identity 
		primary key,
	UserID tinyint not null 
		references [dbo].[User] (UserID),
	TransactionValue varchar(200) not null
);
go

-- ============================================================================
-- PROCESS MESSAGE PROCS
-- ============================================================================

create or alter proc [dbo].[p_ProcessTransactions] (@UserID int) as;
	/*
		Copy rows from Staging to Transaction and then mark the rows as processed.

		exec [dbo].[p_ProcessTransactions] 1;
	*/
	set nocount on;

	declare @RowCount int = [dbo].[p_GetAppSetting]('PROCESS TRANSACTIONS ROW COUNT');
	declare @LogID int;

	exec @LogID = [dbo].[p_StartLogging] @UserID, @RowCount;

	begin try;
		begin tran;

		select top (@RowCount)
			IDENTITY(int) as TempTableID,
			StagingID * 1 as StagingID,
			UserID,
			StagingValue
		into #TempTable
		from [dbo].[Staging]
		where UserID = @UserID
			and ProcessDate is null;

		declare @SelectCount int = @@rowcount;

		insert [dbo].[Transaction] (UserID, TransactionValue)
		select t.UserID, t.StagingValue
		from #TempTable t

		-- This update must be in a transaction with the insert.
		update targt
		set ProcessDate = SYSDATETIME()
		from [dbo].[Staging] targt
		join #TempTable src on targt.StagingID = src.StagingID
		where targt.ProcessDate is null;

		declare @UpdateCount int = @@rowcount;

		commit;
	end try
	begin catch;
		if XACT_STATE() <> 0 rollback;

		throw;
	end catch;

	-- finish logging without more staging or debugging
	exec [dbo].[p_EndLogging] @LogID, @SelectCount, @UpdateCount;

	-- Stage some more just so we don't run out.
	exec [dbo].[p_StageFakeTransactions] @RowCount, @UserID;
go

create or alter proc [dbo].[p_RunProcessTransactions] as;
	/*
		Claim a user douring processing.
		Keep processing until time runs out.
	*/
	set nocount on;

	declare @UserID int;
	declare @RunLimit int = [dbo].[p_GetAppSetting]('RUN SECONDS LIMIT');
	declare @End datetime = dateadd(second, @RunLimit, sysdatetime());

	update top (1) [dbo].[User]
	set IsProcessing = 1, @UserID = UserID
	where IsProcessing = 0;

	while @End > sysdatetime()
		exec [dbo].[p_ProcessTransactions] @UserID;

	update [dbo].[User] set IsProcessing = 0 where UserID = @UserID;
go

