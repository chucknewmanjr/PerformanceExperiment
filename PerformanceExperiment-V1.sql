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
	Once you're ready to delete everything including the log ...

		DROP DATABASE [PerformanceExperiment];

	===========================================================================
*/
USE [master]
GO

if DB_ID('PerformanceExperiment') is null CREATE DATABASE [PerformanceExperiment];
go

USE [PerformanceExperiment];
GO

-- ============================================================================
-- APP SETTINGS
-- ============================================================================

DROP TABLE IF EXISTS [dbo].[AppSetting];
GO

CREATE TABLE [dbo].[AppSetting] (AppSettingName sysname PRIMARY KEY, AppSettingValue int not null);
GO

-- The settings
insert [dbo].[AppSetting] values
	('EXPERIMENT VERSION', 1), 
	('NUMBER OF USERS', 10), -- tinyint. More users mean more sessions.
	('RUN SECONDS LIMIT', 60), -- How long should the test run.
	('REQUEST ROW COUNT', 100e3); -- 10e3 is 10K. Rows processed in each loop.
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
-- CLEAN UP BEFORE SETTING READ COMMITTED SNAPSHOT
-- ============================================================================

DROP TABLE IF EXISTS [dbo].[Staging];
DROP TABLE IF EXISTS [dbo].[Transaction];
DROP TABLE IF EXISTS [dbo].[User];

if (select is_read_committed_snapshot_on from sys.databases where database_id = DB_ID()) = 1
	ALTER DATABASE [PerformanceExperiment] SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;
GO

-- ============================================================================
-- USERS
-- ============================================================================

CREATE TABLE [dbo].[User] (
	UserID tinyint NOT NULL PRIMARY KEY, 
	SessionID smallint null -- only 1 process per user at a time.
);
GO

-- make the right number of users
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
		identity,
	UserID tinyint not null 
		references [dbo].[User] (UserID),
	StagingValue varchar(200) not null,
	ProcessDate datetime null,
	primary key (StagingID)
);
go

create or alter proc [dbo].[p_StageFakeTransactions]
	@RowsRequested int = 10e3,
	@UserID tinyint = null
as;
	/*
		How can we fake staging transactions?
		There are a lot of rows in sys.all_columns. Let's use that.
	*/
	set nocount on;

	declare @NumberOfUsers int = [dbo].[p_GetAppSetting]('NUMBER OF USERS');

	while @RowsRequested > 0 begin;
		with t as (
			select CAST(ABS(object_id) as bigint) * 136 + column_id as x
			from sys.all_columns
		)
		insert [dbo].[Staging] (UserID, StagingValue)
		select top (@RowsRequested)
			ISNULL(@UserID, (x % @NumberOfUsers) + 1),
			CONVERT(varchar(MAX), HASHBYTES('SHA2_512', CONCAT(x, SYSDATETIME())), 2)
		from t;

		set @RowsRequested -= @@ROWCOUNT;
	end;
go

-- Initialize Staging table
declare @RowsRequested int = (
	select COUNT(*) 
		* [dbo].[p_GetAppSetting]('REQUEST ROW COUNT') 
		* 2 
	from [dbo].[User]
);

exec [dbo].[p_StageFakeTransactions] @RowsRequested = @RowsRequested;
go

-- ============================================================================
-- LOGGING
-- ============================================================================

-- drop sequence [dbo].[RunID];
if OBJECT_ID('[dbo].[RunID]') is null
	create sequence [dbo].[RunID] as smallint start with 1;
go

-- drop table [dbo].[ExecutionLog];
if OBJECT_ID('[dbo].[ExecutionLog]') is null
	create table [dbo].[ExecutionLog] (
		ExecutionLogID int identity primary key,
		RunID smallint not null,
		UserID tinyint not null,
		SPID smallint not null default @@SPID,
		[Version] tinyint not null,
		IsPartitioned BIT NOT NULL,
		IsSnapshot BIT NOT NULL,
		RowsRequested int not null,
		StartTime datetime2(7) not null,
		EndTime datetime2(7) not null default sysdatetime(),
		ErrorMessage varchar(500) null
	);
go

create or alter proc [dbo].[p_LogExecution]
	@RunID smallint, 
	@UserID tinyint, 
	@RowsRequested int, 
	@Start datetime2(7), 
	@ErrorMessage varchar(500) = null
as
	/*
		exec [dbo].[p_LogExecution] @RunID, @UserID, @RowsRequested, @Start, @ErrorMessage;
	*/
	declare @Version tinyint = 	[dbo].[p_GetAppSetting]('EXPERIMENT VERSION');

	DECLARE @IsPartitioned BIT = (
		SELECT IIF(MAX(partition_number) > 1, 1, 0)
		FROM sys.partitions
		WHERE object_id = OBJECT_ID('[dbo].[Transaction]')
	);

	DECLARE @IsSnapshot BIT = (
		SELECT is_read_committed_snapshot_on
		FROM sys.databases
		WHERE database_id = DB_ID()
	);

	insert [dbo].[ExecutionLog] (
		RunID, UserID, [Version], IsPartitioned, IsSnapshot, RowsRequested, StartTime, ErrorMessage
	)
	values (
		@RunID, @UserID, @Version, @IsPartitioned, @IsSnapshot, @RowsRequested, @Start, @ErrorMessage
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
		AVG(l.IsPartitioned * 1) AS Is_Partitioned,
		AVG(l.IsSnapshot * 1) AS Is_Snapshot,
		AVG(l.RowsRequested) as Rows_Requested,
		COUNT(distinct l.SPID) as [Users],
		FORMAT(MIN(r.StartTime), 'yyyy-MM-dd HH:mm:ss') as From_Time,
		CAST(ROUND(DATEDIFF(MILLISECOND, MIN(l.StartTime), MAX(l.EndTime)) / 1000.0, 0) as real) as Secs,
		SUM(l.RowsRequested) / 1000 as K_Rows,
		CAST(ROUND(SUM(l.RowsRequested) * 1.0 / DATEDIFF(MILLISECOND, MIN(l.StartTime), MAX(l.EndTime)), 1) as real) as K_Rows_Per_Sec,
		SUM(IIF(l.ErrorMessage is null, 0, 1)) as Errors
	from #RunGroup r
	join [dbo].[ExecutionLog] l on l.StartTime between r.StartTime and r.EndTime
	group by r.Experiment
	order by r.Experiment desc;
go

-- ============================================================================
-- TRANSACTION TABLE
-- ============================================================================

create table [dbo].[Transaction] (
	TransactionID int not null
		identity,
	UserID tinyint not null 
		references [dbo].[User] (UserID),
	TransactionValue varchar(200) not null,
	primary key (TransactionID)
);
go

-- ============================================================================
-- PROCESS MESSAGE PROCS
-- ============================================================================

create or alter proc [dbo].[p_ProcessTransactions]
	@RunID smallint,
	@UserID TINYINT
AS;
	/*
		Copy rows from Staging to Transaction and then mark the rows as processed.

		exec [dbo].[p_ProcessTransactions] @RunID = 1, @UserID = 1;
	*/
	declare @RowsRequested int = [dbo].[p_GetAppSetting]('REQUEST ROW COUNT');
	declare @ErrorMessage varchar(MAX);
	declare @Start datetime2(7) = SYSDATETIME();
	declare @RowsReturned int;

	declare @Transfer table (StagingValue varchar(200) NOT NULL);

	begin try;
		begin tran;

		-- This update must be in a transaction with the insert.
		update top (@RowsRequested) targt
		set ProcessDate = SYSDATETIME()
		output inserted.StagingValue 
		into @Transfer
		from [dbo].[Staging] targt
		where ProcessDate is null
			and UserID = @UserID;

		set @RowsReturned = @@ROWCOUNT;

		if @RowsReturned <> @RowsRequested begin;
			set @ErrorMessage = CONCAT(@RowsReturned, ' rows collected. Expected ', @RowsRequested, '.');

			throw 50100, @ErrorMessage, 1;
		end;

		insert [dbo].[Transaction] (UserID, TransactionValue)
		select @UserID, StagingValue
		from @Transfer

		set @RowsReturned = @@ROWCOUNT;

		if @RowsReturned <> @RowsRequested begin;
			set @ErrorMessage = CONCAT(@RowsReturned, ' rows inserted. Expected ', @RowsRequested, '.');

			throw 50200, @ErrorMessage, 1;
		end;

		commit;

		-- Stage some more so we don't run out.
		exec [dbo].[p_StageFakeTransactions] @RowsRequested, @UserID;
	end try
	begin catch;
		if XACT_STATE() <> 0 rollback;

		set @ErrorMessage = CONCAT('ERROR: ', ERROR_MESSAGE(), '. Line ', ERROR_LINE());

		-- It's likely a deadlock. Don't rethrow the error. That way, we can keep trying.
		print @ErrorMessage;
	end catch;

	exec [dbo].[p_LogExecution] @RunID, @UserID, @RowsRequested, @Start, @ErrorMessage;
go

create or alter proc [dbo].[p_RunProcessTransactions] as;
	/*
		Claim a user douring processing.
		Keep processing until time runs out.

		use [PerformanceExperiment];
		exec [dbo].[p_RunProcessTransactions];
	*/
	set nocount on;

	declare @UserID int;
	declare @RunLimit int = [dbo].[p_GetAppSetting]('RUN SECONDS LIMIT');
	declare @End datetime = DATEADD(SECOND, @RunLimit, SYSDATETIME());
	declare @RunID bigint = NEXT VALUE FOR [dbo].[RunID];
	declare @ErrorMessage varchar(MAX);

	BEGIN TRY;
		-- Set the flag and get the ID in one statement so a transaction isn't needed.
		update top (1) [dbo].[User]
		set SessionID = @@SPID, @UserID = UserID
		where SessionID is null;

		-- Did we get a user?
		if @UserID is null throw 50000, 'No users left.', 1;

		while @End > SYSDATETIME()
			exec [dbo].[p_ProcessTransactions] @RunID, @UserID;
	END TRY
	BEGIN CATCH;
		set @ErrorMessage = error_message();

		exec [dbo].[p_LogExecution] @RunID, @UserID, NULL, NULL, @ErrorMessage;

		THROW;
	END CATCH;

	update [dbo].[User] set SessionID = null where UserID = @UserID and SessionID is not null;
GO

