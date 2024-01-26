/*
	===========================================================================
	========================== PERFORMANCE EXPERIMENT =========================
	Try to make this run faster and without adding issues like deadlocks.
	Change procs, indexing, values or isolation level.
	But avoid changing the columns in tables. Requires SQL Server 2019 (V15).
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

USE [master]
GO

if DB_ID('PerformanceExperiment') is null CREATE DATABASE [PerformanceExperiment];
go

USE [PerformanceExperiment];
GO

-- ============================================================================
-- CLEAN UP BEFORE SETTING READ COMMITTED SNAPSHOT
-- ============================================================================

DROP TABLE IF EXISTS [dbo].[Staging];
DROP TABLE IF EXISTS [dbo].[Transaction];
DROP TABLE IF EXISTS [dbo].[User];
DROP TABLE IF EXISTS [dbo].[AppSetting];

ALTER INDEX ALL ON [dbo].[ExecutionLog] REBUILD; -- free up pages

DBCC SHRINKDATABASE (0, 0) WITH NO_INFOMSGS; -- remove unused pages

-- Changing this can take a while. Dropping tables helps.
ALTER DATABASE [PerformanceExperiment] SET READ_COMMITTED_SNAPSHOT ON;
GO

-- ============================================================================
-- APP SETTINGS
-- ============================================================================

CREATE TABLE [dbo].[AppSetting] (AppSettingName sysname PRIMARY KEY, AppSettingValue int not null);
GO

-- The settings
insert [dbo].[AppSetting] values
	('EXPERIMENT VERSION', 3), 
	('NUMBER OF USERS', 5), -- tinyint. More users mean more sessions.
	('RUN SECONDS LIMIT', 60), -- How long should the test run.
	('PROCESS TRANSACTIONS ROW COUNT', 20e3) -- 10e3 is 10K. Rows processed in each loop.
go

create or alter function [dbo].[p_GetAppSetting] (@AppSettingName sysname) returns int begin;
	-- Get those settings
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
	SessionID smallint null -- only 1 process per user at a time.
);
GO

with t(x) as (
	select 1 
	union all 
	select x + 1 from t where x < [dbo].[p_GetAppSetting]('NUMBER OF USERS')
)
insert [dbo].[User] (UserID)
select x from t;
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
		There are a lot of rows in sys.all_columns. Let's use that.
	*/
	set nocount on;

	declare @NumberOfUsers int = [dbo].[p_GetAppSetting]('NUMBER OF USERS');

	while @RowCount > 0 begin;
		with t as (
			select CAST(ABS(object_id) as bigint) * 136 + column_id as x
			from sys.all_columns
		)
		insert [dbo].[Staging] (UserID, StagingValue)
		select top (@RowCount)
			ISNULL(@UserID, (x % @NumberOfUsers) + 1),
			CONVERT(varchar(MAX), HASHBYTES('SHA2_512', CONCAT(x, SYSDATETIME())), 2)
		from t;

		set @RowCount -= @@ROWCOUNT;
	end;
go

-- Clean up Staging table
-- 1e6 is 1 million. Staging 1 million rows takes a minute.
exec [dbo].[p_StageFakeTransactions] @RowCount = 1e6;
go

-- ============================================================================
-- LOGGING
-- ============================================================================

-- drop sequence [dbo].[RunID];
if OBJECT_ID('[dbo].[RunID]') is null
	create sequence [dbo].[RunID] as smallint start with 1;
go

-- drop table [dbo].[ExecutionLog];
if OBJECT_ID('[dbo].[ExecutionLog]') is null begin;
	create table [dbo].[ExecutionLog] (
		ExecutionLogID int identity primary key,
		RunID smallint not null,
		UserID tinyint not null,
		SPID smallint not null default @@SPID,
		[Version] tinyint not null,
		[RowCount] int not null,
		StartTime datetime2(7) not null,
		EndTime datetime2(7) not null default sysdatetime(),
		ErrorMessage varchar(500) null
	);
end;
else begin;
	UPDATE STATISTICS [dbo].[ExecutionLog];

	alter index all on [dbo].[ExecutionLog] rebuild;
end;
go

if INDEXPROPERTY(object_id('[dbo].[ExecutionLog]'), 'IX1', 'IndexID') is null
	create index IX1 on [dbo].[ExecutionLog] (RunID) include (StartTime, EndTime);
go

create or alter proc [dbo].[p_LogExecution] (
	@RunID smallint, 
	@UserID tinyint, 
	@RowCount int, 
	@Start datetime2(7), 
	@ErrorMessage varchar(500) = null
) as
	/*
		exec [dbo].[p_LogExecution] @RunID, @UserID, @RowCount, @Start, @ErrorMessage;
	*/
	declare @Version tinyint = 	[dbo].[p_GetAppSetting]('EXPERIMENT VERSION');

	insert [dbo].[ExecutionLog] (
		RunID, UserID, [Version], [RowCount], StartTime, ErrorMessage
	)
	values (
		@RunID, @UserID, @Version, @RowCount, @Start, @ErrorMessage
	);
go

create or alter proc [dbo].[p_PerformanceReport] as;
	/*
		Spot individual runs by looking for time gaps between runs.

		use [PerformanceExperiment];
		exec [dbo].[p_PerformanceReport];
	*/

	-- Runs
	-- Figure out the time range for each group of runs.
	with Runs as (
		SELECT 
			lag(MAX(EndTime)) over (order by MAX(EndTime)) as PrevEndTime,
			MIN(StartTime) as StartTime
		FROM [dbo].[ExecutionLog] 
		group by RunID
	)
	select 
		identity(int) as Experiment,
		StartTime,
		isnull(lead(PrevEndTime) over (order by StartTime), '9999-01-01') as EndTime
	into #RunGroup
	from Runs
	where DATEDIFF(SECOND, PrevEndTime, StartTime) > 0
		or PrevEndTime is null;

	-- performance report
	select
		r.Experiment, 
		AVG(l.[Version]) as [Version],
		AVG(l.[RowCount]) as Row_Count,
		COUNT(distinct l.SPID) as [Users],
		FORMAT(MIN(r.StartTime), 'yyyy-MM-dd HH:mm:ss') as From_Time,
		CAST(ROUND(DATEDIFF(MILLISECOND, MIN(l.StartTime), MAX(l.EndTime)) / 1000.0, 0) as real) as Secs,
		SUM(l.[RowCount]) / 1000 as K_Rows,
		CAST(ROUND(SUM(l.[RowCount]) * 1.0 / DATEDIFF(MILLISECOND, MIN(l.StartTime), MAX(l.EndTime)), 1) as real) as K_Rows_Per_Sec,
		SUM(IIF(l.ErrorMessage is null, 0, 1)) as Errors
	from #RunGroup r
	join [dbo].[ExecutionLog] l on l.StartTime between r.StartTime and r.EndTime
	group by r.Experiment
	order by r.Experiment;
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

create or alter proc [dbo].[p_ProcessTransactions] (
	@RunID smallint,
	@UserID tinyint
) as;
	/*
		Copy rows from Staging to Transaction and then mark the rows as processed.

		exec [dbo].[p_ProcessTransactions] @UserID = 1;
	*/
	declare @RowCount int = [dbo].[p_GetAppSetting]('PROCESS TRANSACTIONS ROW COUNT');
	declare @ErrorMessage varchar(MAX);
	declare @Start datetime2(7) = SYSDATETIME();

	declare @Transfer table (StagingValue varchar(200) NOT NULL);

	begin try;
		begin tran;

		-- This update must be in a transaction with the insert.
		update top (@RowCount) targt
		set ProcessDate = SYSDATETIME()
		output inserted.StagingValue 
		into @Transfer
		from [dbo].[Staging] targt
		where ProcessDate is null
			and UserID = @UserID;

		if @@ROWCOUNT <> @RowCount begin;
			set @ErrorMessage = CONCAT(@@ROWCOUNT, ' rows updated. Expected ', @RowCount, '.');

			throw 50100, @ErrorMessage, 1;
		end;

		insert [dbo].[Transaction] (UserID, TransactionValue)
		select @UserID, StagingValue
		from @Transfer

		if @@ROWCOUNT <> @RowCount begin;
			set @ErrorMessage = CONCAT(@@ROWCOUNT, ' rows inserted. Expected ', @RowCount, '.');

			throw 50200, @ErrorMessage, 1;
		end;

		commit;

		-- Stage some more so we don't run out.
		exec [dbo].[p_StageFakeTransactions] @RowCount, @UserID;
	end try
	begin catch;
		if XACT_STATE() <> 0 rollback;

		set @ErrorMessage = CONCAT('ERROR: ', ERROR_MESSAGE(), '. Line ', ERROR_LINE());

		-- It's likely a deadlock. Don't rethrow the error. That way, we can keep trying.
		print @ErrorMessage;
	end catch;

	exec [dbo].[p_LogExecution] @RunID, @UserID, @RowCount, @Start, @ErrorMessage;
go

create or alter proc [dbo].[p_RunProcessTransactions] as;
	/*
		Claim a user douring processing.
		Keep processing until time runs out.
	*/
	set nocount on;

	declare @UserID int;
	declare @RunLimit int = [dbo].[p_GetAppSetting]('RUN SECONDS LIMIT');
	declare @End datetime = DATEADD(SECOND, @RunLimit, SYSDATETIME());
	declare @RunID bigint = NEXT VALUE FOR [dbo].[RunID];

	-- Set the flag and get the ID in one statement so a transaction isn't needed.
	update top (1) [dbo].[User]
	set SessionID = @@SPID, @UserID = UserID
	where SessionID is null;

	-- Did we get a user?
	if @UserID is null throw 50000, 'No users left.', 1;

	while @End > SYSDATETIME()
		exec [dbo].[p_ProcessTransactions] @RunID, @UserID;

	update [dbo].[User] set SessionID = null where UserID = @UserID;
go

DECLARE @is_read_committed_snapshot_on BIT = (
	SELECT is_read_committed_snapshot_on
	FROM sys.databases
	WHERE database_id = DB_ID()
);

SELECT
	IIF(MAX(partition_number) > 1, 1, 0) AS Partitioned,
	@is_read_committed_snapshot_on AS [Read_Committed_Snapshot]
FROM sys.partitions
WHERE object_id = OBJECT_ID('[dbo].[Transaction]');
GO

